package com.vibepad.voice

import android.Manifest
import android.annotation.SuppressLint
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothGattServer
import android.bluetooth.BluetoothGattServerCallback
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.BluetoothStatusCodes
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.bluetooth.le.BluetoothLeAdvertiser
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import android.os.SystemClock
import android.util.Log
import androidx.core.content.ContextCompat
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlin.math.abs
import kotlin.math.sqrt

/**
 * BLE GATT peripheral for the phone microphone.
 *
 * Audio is a byte stream on the AUDIO characteristic: every 20 ms the phone
 * emits [4-byte header][160-byte ADPCM]. Notifications are split to the
 * negotiated MTU, so the Mac side must append notifications to a buffer and
 * split on the 4-byte header rather than assuming one notification == one
 * packet.
 */
@SuppressLint("MissingPermission")
class PhoneVoiceGattServer(private val context: Context) {

    sealed interface State {
        data object Idle : State
        data object Advertising : State
        data class Connected(val name: String) : State
        data object Talking : State
        data class Error(val message: String) : State
    }

    private val tag = "VibePadVoice"

    private val manager =
        context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
    private val adapter = manager?.adapter

    private val _state = MutableStateFlow<State>(State.Idle)
    val state: StateFlow<State> = _state.asStateFlow()

    private val _level = MutableStateFlow(0f)
    val level: StateFlow<Float> = _level.asStateFlow()

    private val _macFlags = MutableStateFlow(0)
    val macFlags: StateFlow<Int> = _macFlags.asStateFlow()

    private var server: BluetoothGattServer? = null
    private var advertiser: BluetoothLeAdvertiser? = null
    private var advertiseCallback: AdvertiseCallback? = null
    private var audioChar: BluetoothGattCharacteristic? = null
    private var controlChar: BluetoothGattCharacteristic? = null

    @Volatile
    private var peripheral: BluetoothDevice? = null

    @Volatile
    private var audioSubscribed = false

    @Volatile
    private var controlSubscribed = false

    @Volatile
    private var notifyRejected = 0

    @Volatile
    private var mtu = 23

    @Volatile
    private var recording = false

    @Volatile
    private var serviceAdded = false

    private val mainHandler = Handler(Looper.getMainLooper())
    private var subscribeCheck: Runnable? = null
    private var heartbeat: Runnable? = null

    private var audioThread: Thread? = null
    private var record: AudioRecord? = null
    private var seq = 0
    private val notifyLock = Any()
    private val gain = AutoGain()

    fun start() {
        if (server != null) return
        if (!hasPermission()) {
            _state.value = State.Error("缺少蓝牙或录音权限")
            return
        }
        if (adapter == null) {
            _state.value = State.Error("设备不支持蓝牙")
            return
        }
        if (!adapter.isEnabled) {
            _state.value = State.Error("蓝牙未开启")
            return
        }
        advertiser = adapter.bluetoothLeAdvertiser
        if (advertiser == null) {
            _state.value = State.Error("设备不支持 BLE 广播")
            return
        }
        val gatt = manager?.openGattServer(context, callback)
        if (gatt == null) {
            _state.value = State.Error("打开 GATT server 失败")
            return
        }
        server = gatt
        if (!gatt.addService(buildService())) {
            _state.value = State.Error("添加 GATT service 失败")
            return
        }
        _state.value = State.Advertising
    }

    private fun buildService(): BluetoothGattService {
        val service = BluetoothGattService(
            PhoneVoiceProtocol.SERVICE,
            BluetoothGattService.SERVICE_TYPE_PRIMARY
        )
        val audio = BluetoothGattCharacteristic(
            PhoneVoiceProtocol.AUDIO,
            BluetoothGattCharacteristic.PROPERTY_NOTIFY,
            BluetoothGattCharacteristic.PERMISSION_READ
        )
        audio.addDescriptor(cccd())
        val control = BluetoothGattCharacteristic(
            PhoneVoiceProtocol.CONTROL,
            BluetoothGattCharacteristic.PROPERTY_NOTIFY or
                BluetoothGattCharacteristic.PROPERTY_WRITE or
                BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE,
            BluetoothGattCharacteristic.PERMISSION_READ or
                BluetoothGattCharacteristic.PERMISSION_WRITE
        )
        control.addDescriptor(cccd())
        audioChar = audio
        controlChar = control
        service.addCharacteristic(audio)
        service.addCharacteristic(control)
        return service
    }

    private fun cccd(): BluetoothGattDescriptor =
        BluetoothGattDescriptor(
            PhoneVoiceProtocol.CCCD,
            BluetoothGattDescriptor.PERMISSION_READ or BluetoothGattDescriptor.PERMISSION_WRITE
        )

    /// 新连接只有在客户端写了音频 CCCD 之后才有用。等 2.5 秒还没有订阅，
    /// 说明这条链路是「僵尸连接」（对方的订阅状态已随旧进程消失），
    /// 主动断掉，让 Mac 重新连接并重新订阅。
    private fun scheduleSubscribeCheck() {
        subscribeCheck?.let { mainHandler.removeCallbacks(it) }
        val check = Runnable {
            subscribeCheck = null
            val device = peripheral
            if (device != null && !audioSubscribed) {
                Log.w(tag, "no CCCD within 2.5s — dropping link to ${device.name}")
                server?.cancelConnection(device)
            }
        }
        subscribeCheck = check
        mainHandler.postDelayed(check, 2500)
    }

    /// 每 2 秒一条控制心跳。Mac 端用它判断订阅是否还有效：覆盖安装后
    /// macOS 会保留旧 LE 链路，心跳断了 Mac 才会重新连接并重新订阅。
    private fun startHeartbeat() {
        heartbeat?.let { mainHandler.removeCallbacks(it) }
        val beat = object : Runnable {
            override fun run() {
                if (peripheral == null) return
                if (controlSubscribed) {
                    sendControl(PhoneVoiceProtocol.OP_HEARTBEAT)
                }
                mainHandler.postDelayed(this, 2000)
            }
        }
        heartbeat = beat
        mainHandler.postDelayed(beat, 2000)
    }

    private fun stopHeartbeat() {
        heartbeat?.let { mainHandler.removeCallbacks(it) }
        heartbeat = null
    }

    private val callback = object : BluetoothGattServerCallback() {
        override fun onServiceAdded(status: Int, service: BluetoothGattService?) {
            Log.i(tag, "service added status=$status")
            if (status == BluetoothGatt.GATT_SUCCESS) {
                serviceAdded = true
                startAdvertising()
            }
        }

        override fun onConnectionStateChange(device: BluetoothDevice?, status: Int, newState: Int) {
            Log.i(tag, "connection status=$status newState=$newState device=${device?.name}")
            if (newState == BluetoothProfile.STATE_CONNECTED) {
                if (!serviceAdded || server == null) {
                    // A connection can only arrive before the service exists if
                    // macOS kept a stale LE link across our process restart (app
                    // update). Its CCCD state died with the old process, so drop
                    // the link and let the Mac make a clean, subscribing one.
                    Log.w(tag, "stale link before service added — cancelling")
                    server?.cancelConnection(device)
                    return
                }
                peripheral = device
                audioSubscribed = false
                // A connectable advertisement is consumed by the connection;
                // clear the callback so a later disconnect can re-advertise.
                stopAdvertising()
                _state.value = State.Connected(device?.name ?: "Mac")
                scheduleSubscribeCheck()
                startHeartbeat()
            } else {
                subscribeCheck?.let { mainHandler.removeCallbacks(it) }
                subscribeCheck = null
                stopHeartbeat()
                controlSubscribed = false
                peripheral = null
                audioSubscribed = false
                _macFlags.value = 0
                stopTalk()
                _state.value = State.Advertising
                startAdvertising()
            }
        }

        override fun onMtuChanged(device: BluetoothDevice?, mtu: Int) {
            Log.i(tag, "mtu=$mtu")
            this@PhoneVoiceGattServer.mtu = mtu
        }

        override fun onDescriptorWriteRequest(
            device: BluetoothDevice?,
            requestId: Int,
            descriptor: BluetoothGattDescriptor?,
            preparedWrite: Boolean,
            responseNeeded: Boolean,
            offset: Int,
            value: ByteArray?
        ) {
            if (descriptor?.uuid == PhoneVoiceProtocol.CCCD) {
                val enabled = value?.contentEquals(BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE) == true
                // Keep the local attribute value in sync with the client's
                // write; some stacks decide whether a notification may be sent
                // by looking at this descriptor value.
                if (value != null) {
                    @Suppress("DEPRECATION")
                    descriptor.value = value
                }
                if (descriptor.characteristic?.uuid == PhoneVoiceProtocol.AUDIO) {
                    audioSubscribed = enabled
                    Log.i(tag, "audio notifications enabled=$enabled")
                    // 清掉之前「Mac 还没订阅音频」的报错状态，否则按钮会
                    // 一直停在「语音等待」，即使链路已经恢复。
                    if (enabled) {
                        subscribeCheck?.let { mainHandler.removeCallbacks(it) }
                        subscribeCheck = null
                        _state.value = State.Connected(device?.name ?: "Mac")
                    }
                }
                if (descriptor.characteristic?.uuid == PhoneVoiceProtocol.CONTROL) {
                    controlSubscribed = enabled
                    Log.i(tag, "control notifications enabled=$enabled")
                }
                if (enabled) sendControl(PhoneVoiceProtocol.OP_READY)
            }
            if (responseNeeded) {
                server?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, 0, null)
            }
        }

        override fun onCharacteristicWriteRequest(
            device: BluetoothDevice?,
            requestId: Int,
            characteristic: BluetoothGattCharacteristic?,
            preparedWrite: Boolean,
            responseNeeded: Boolean,
            offset: Int,
            value: ByteArray?
        ) {
            if (characteristic?.uuid == PhoneVoiceProtocol.CONTROL && value != null) {
                val op = value.getOrNull(3)?.toInt()?.and(0xFF)
                Log.i(tag, "control write op=$op")
                if (op == PhoneVoiceProtocol.OP_STATUS) {
                    _macFlags.value = value.getOrNull(4)?.toInt()?.and(0xFF) ?: 0
                }
                if (op == PhoneVoiceProtocol.OP_STOP && recording) stopTalk()
            }
            if (responseNeeded) {
                server?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, value)
            }
        }
    }

    private fun startAdvertising() {
        val adv = advertiser ?: return
        if (advertiseCallback != null) return
        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
            .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_HIGH)
            .setConnectable(true)
            .setTimeout(0)
            .build()
        val data = AdvertiseData.Builder()
            .setIncludeDeviceName(false)
            .addServiceUuid(ParcelUuid(PhoneVoiceProtocol.SERVICE))
            .build()
        val scanResponse = AdvertiseData.Builder()
            .setIncludeDeviceName(true)
            .build()
        val cb = object : AdvertiseCallback() {
            override fun onStartSuccess(settingsInEffect: AdvertiseSettings?) {
                Log.i(tag, "advertising started")
                _state.value = if (peripheral != null) {
                    State.Connected(peripheral?.name ?: "Mac")
                } else {
                    State.Advertising
                }
            }

            override fun onStartFailure(errorCode: Int) {
                Log.w(tag, "advertising failed $errorCode")
                advertiseCallback = null
                _state.value = State.Error("BLE 广播失败：$errorCode")
            }
        }
        advertiseCallback = cb
        adv.startAdvertising(settings, data, scanResponse, cb)
    }

    private fun stopAdvertising() {
        val cb = advertiseCallback ?: return
        advertiseCallback = null
        runCatching { advertiser?.stopAdvertising(cb) }
    }

    fun startTalk() {
        if (recording) return
        if (!hasPermission()) {
            _state.value = State.Error("缺少录音或蓝牙权限")
            return
        }
        val device = peripheral
        if (device == null) {
            _state.value = State.Error("Mac 还没连接")
            return
        }
        if (!audioSubscribed) {
            _state.value = State.Error("Mac 还没订阅音频")
            return
        }
        val minBuf = AudioRecord.getMinBufferSize(
            PhoneVoiceProtocol.SAMPLE_RATE,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT
        )
        val bufSize = maxOf(minBuf, PhoneVoiceProtocol.FRAME_SAMPLES * 2 * 4)
        val rec = try {
            AudioRecord(
                // VOICE_RECOGNITION 会走系统的降噪/回声抑制链路，正是手机
                // VOICE_COMMUNICATION 走系统的通话音频链路：自带 AGC、降噪
                // 和回声抑制，电平和手机原生语音输入一致；裸 MIC 什么处理
                // 都没有，VOICE_RECOGNITION 又衰减过度（实测 -44 dBFS）。
                MediaRecorder.AudioSource.VOICE_COMMUNICATION,
                PhoneVoiceProtocol.SAMPLE_RATE,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
                bufSize
            )
        } catch (t: Throwable) {
            Log.w(tag, "AudioRecord create failed", t)
            _state.value = State.Error("录音初始化失败")
            return
        }
        if (rec.state != AudioRecord.STATE_INITIALIZED) {
            rec.release()
            _state.value = State.Error("录音设备不可用")
            return
        }
        record = rec
        try {
            rec.startRecording()
        } catch (t: Throwable) {
            Log.w(tag, "startRecording failed", t)
            rec.release()
            record = null
            _state.value = State.Error("开始录音失败")
            return
        }
        recording = true
        _state.value = State.Talking
        Log.i(tag, "talk start → OP_START peripheral=${device.name} mtu=$mtu")
        sendControl(PhoneVoiceProtocol.OP_START)
        audioThread = Thread({ audioLoop(rec) }, "vibepad-audio").apply {
            isDaemon = true
            start()
        }
    }

    private fun audioLoop(rec: AudioRecord) {
        // 40 ms @16 kHz 采集，降采样到 8 kHz 后 ADPCM 编码成 160 字节。
        val pcm = ShortArray(PhoneVoiceProtocol.FRAME_SAMPLES)
        val wire = ShortArray(PhoneVoiceProtocol.FRAME_SAMPLES / 2)
        val encoder = AdpcmEncoder()
        gain.reset()
        var packetSeq = 0
        var windowPackets = 0
        var windowPeak = 0
        var windowStart = SystemClock.elapsedRealtime()
        var silentReads = 0
        Log.i(tag, "audio loop start subscribed=$audioSubscribed peripheral=${peripheral?.name}")
        while (recording) {
            val n = try {
                rec.read(pcm, 0, pcm.size)
            } catch (t: Throwable) {
                Log.w(tag, "read failed", t)
                -1
            }
            if (n <= 0) {
                if (n == AudioRecord.ERROR_DEAD_OBJECT) {
                    Log.w(tag, "read dead object")
                    break
                }
                silentReads++
                if (silentReads == 50) Log.w(tag, "read stalled n=$n")
                continue
            }
            silentReads = 0
            if (n < pcm.size) pcm.fill(0, n, pcm.size)
            gain.apply(pcm, n)
            // 2:1 降采样（简单平均，天然带一点抗混叠）
            for (i in wire.indices) {
                wire[i] = ((pcm[i * 2].toInt() + pcm[i * 2 + 1].toInt()) / 2).toShort()
            }
            val payload = encoder.encode(wire, wire.size)
            val packet = ByteArray(PhoneVoiceProtocol.HEADER_BYTES + payload.size)
            packet[0] = PhoneVoiceProtocol.VERSION.toByte()
            packet[1] = PhoneVoiceProtocol.TYPE_AUDIO.toByte()
            packet[2] = (packetSeq++ and 0xFF).toByte()
            packet[3] = 0x01
            payload.copyInto(packet, PhoneVoiceProtocol.HEADER_BYTES)
            sendAudio(packet)
            windowPackets++
            var sum = 0.0
            for (i in 0 until n) {
                val v = pcm[i].toInt()
                if (abs(v) > windowPeak) windowPeak = abs(v)
                sum += v.toDouble() * v.toDouble()
            }
            _level.value = (sqrt(sum / n) / 32768.0).toFloat().coerceIn(0f, 1f)
            val now = SystemClock.elapsedRealtime()
            if (now - windowStart >= 1000) {
                Log.i(
                    tag,
                    "sent ${windowPackets}pkt/s peak=$windowPeak subscribed=$audioSubscribed"
                )
                windowPackets = 0
                windowPeak = 0
                windowStart = now
            }
        }
        Log.i(tag, "audio loop end")
        _level.value = 0f
    }

    private fun sendAudio(packet: ByteArray) {
        val device = peripheral ?: return
        val ch = audioChar ?: return
        if (!audioSubscribed) return
        val srv = server ?: return
        val chunkSize = (mtu - 3).coerceAtLeast(20)
        synchronized(notifyLock) {
            var offset = 0
            while (offset < packet.size) {
                val end = minOf(offset + chunkSize, packet.size)
                val chunk = packet.copyOfRange(offset, end)
                try {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        val status = srv.notifyCharacteristicChanged(device, ch, false, chunk)
                        if (status != BluetoothStatusCodes.SUCCESS) {
                            notifyRejected++
                            Log.w(tag, "audio notify rejected status=$status len=${chunk.size} mtu=$mtu")
                            @Suppress("DEPRECATION")
                            ch.value = chunk
                            @Suppress("DEPRECATION")
                            srv.notifyCharacteristicChanged(device, ch, false)
                        }
                    } else {
                        @Suppress("DEPRECATION")
                        ch.value = chunk
                        @Suppress("DEPRECATION")
                        srv.notifyCharacteristicChanged(device, ch, false)
                    }
                } catch (t: Throwable) {
                    Log.w(tag, "audio notify failed", t)
                    return
                }
                offset = end
            }
        }
    }

    private fun sendControl(op: Int) {
        val device = peripheral ?: return
        val ch = controlChar ?: return
        val srv = server ?: return
        val packet = byteArrayOf(
            PhoneVoiceProtocol.VERSION.toByte(),
            PhoneVoiceProtocol.TYPE_CONTROL.toByte(),
            (seq++ and 0xFF).toByte(),
            op.toByte()
        )
        synchronized(notifyLock) {
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    val status = srv.notifyCharacteristicChanged(device, ch, false, packet)
                    Log.i(tag, "control notify op=$op status=$status")
                    if (status != BluetoothStatusCodes.SUCCESS) {
                        @Suppress("DEPRECATION")
                        ch.value = packet
                        @Suppress("DEPRECATION")
                        srv.notifyCharacteristicChanged(device, ch, false)
                    }
                } else {
                    @Suppress("DEPRECATION")
                    ch.value = packet
                    @Suppress("DEPRECATION")
                    srv.notifyCharacteristicChanged(device, ch, false)
                }
            } catch (t: Throwable) {
                Log.w(tag, "control notify failed", t)
            }
        }
    }

    fun stopTalk() {
        if (!recording) return
        Log.i(tag, "talk stop")
        recording = false
        val rec = record
        record = null
        runCatching { rec?.stop() }
        runCatching { audioThread?.join(500) }
        audioThread = null
        runCatching { rec?.release() }
        _level.value = 0f
        if (peripheral != null) {
            sendControl(PhoneVoiceProtocol.OP_STOP)
            _state.value = State.Connected(peripheral?.name ?: "Mac")
        } else {
            _state.value = State.Advertising
        }
    }

    fun shutdown() {
        stopTalk()
        stopHeartbeat()
        subscribeCheck?.let { mainHandler.removeCallbacks(it) }
        subscribeCheck = null
        stopAdvertising()
        runCatching { server?.close() }
        server = null
        peripheral = null
        audioSubscribed = false
        controlSubscribed = false
        serviceAdded = false
        _macFlags.value = 0
        _state.value = State.Idle
    }

    private fun hasPermission(): Boolean {
        if (ContextCompat.checkSelfPermission(
                context,
                Manifest.permission.RECORD_AUDIO
            ) != PackageManager.PERMISSION_GRANTED
        ) {
            return false
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            return ContextCompat.checkSelfPermission(
                context,
                Manifest.permission.BLUETOOTH_CONNECT
            ) == PackageManager.PERMISSION_GRANTED &&
                ContextCompat.checkSelfPermission(
                    context,
                    Manifest.permission.BLUETOOTH_ADVERTISE
                ) == PackageManager.PERMISSION_GRANTED
        }
        return true
    }
}
