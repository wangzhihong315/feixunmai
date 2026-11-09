package com.vibepad.voice

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import androidx.core.content.ContextCompat
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.sqrt

/**
 * 语音走局域网：Bonjour 找到 Mac 的 `_vibedeck._tcp` 服务，TCP 直连后送
 * 16 kHz PCM16（比蓝牙 8 kHz ADPCM 清晰），控制指令与音频复用同一条连接。
 *
 * 帧格式（小端）：
 *   [version][type][seq][flags][len lo][len hi][payload…]
 *   type 1 = PCM16 单声道 16 kHz；type 2 = 控制（payload 一个 op 字节）
 */
class WifiVoiceClient(private val context: Context) {
    private val tag = "VibePadWifi"

    private val _state = MutableStateFlow<PhoneVoiceGattServer.State>(PhoneVoiceGattServer.State.Idle)
    val state: StateFlow<PhoneVoiceGattServer.State> = _state

    private val _level = MutableStateFlow(0f)
    val level: StateFlow<Float> = _level

    private val _macFlags = MutableStateFlow(0)
    val macFlags: StateFlow<Int> = _macFlags

    private val nsd: NsdManager? =
        context.getSystemService(Context.NSD_SERVICE) as? NsdManager

    @Volatile
    private var running = true

    @Volatile
    private var recording = false

    private var socket: Socket? = null
    private var output: OutputStream? = null
    private val writeLock = Any()
    private var seq = 0
    private var audioThread: Thread? = null
    private var heartbeat: Thread? = null
    private var ndsListener: NsdManager.DiscoveryListener? = null
    private val gain = AutoGain()
    // 所有 socket 写入都走这条队列 + 专用线程：主线程直接 write 会抛
    // NetworkOnMainThreadException（按语音键时就会把链路写断）。
    private val writeQueue = LinkedBlockingQueue<ByteArray>()
    private var writer: Thread? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private val connectLock = Any()

    @Volatile
    private var connecting = false

    private val reconnectTask = Runnable {
        if (running && socket?.isConnected != true && !connecting) {
            closeSocket()
            discover()
        }
    }

    fun start() {
        running = true
        _state.value = PhoneVoiceGattServer.State.Advertising
        startWriter()
        discover()
        startHeartbeat()
    }

    fun shutdown() {
        running = false
        writer?.interrupt()
        writer = null
        stopTalk()
        stopHeartbeat()
        runCatching { ndsListener?.let { nsd?.stopServiceDiscovery(it) } }
        ndsListener = null
        closeSocket()
        _state.value = PhoneVoiceGattServer.State.Idle
    }

    // MARK: - Discovery

    private fun discover() {
        val manager = nsd ?: run {
            _state.value = PhoneVoiceGattServer.State.Error("系统不支持网络发现")
            return
        }
        if (ndsListener != null) return
        val listener = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(serviceType: String) {
                Log.i(tag, "discovery started $serviceType")
            }

            override fun onServiceFound(info: NsdServiceInfo) {
                Log.i(tag, "found ${info.serviceName} ${info.serviceType}")
                if (info.serviceType.startsWith("_vibedeck._tcp")) {
                    resolve(manager, info)
                }
            }

            override fun onServiceLost(info: NsdServiceInfo) {}

            override fun onDiscoveryStopped(serviceType: String) {}

            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                Log.w(tag, "discovery failed $errorCode")
                ndsListener = null
            }

            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {
                ndsListener = null
            }
        }
        ndsListener = listener
        runCatching {
            manager.discoverServices("_vibedeck._tcp", NsdManager.PROTOCOL_DNS_SD, listener)
        }.onFailure {
            ndsListener = null
            Log.w(tag, "discover threw", it)
        }
    }

    private fun resolve(manager: NsdManager, info: NsdServiceInfo) {
        manager.resolveService(info, object : NsdManager.ResolveListener {
            override fun onServiceResolved(resolved: NsdServiceInfo) {
                val host = resolved.host ?: return
                Log.i(tag, "resolved ${host.hostAddress}:${resolved.port}")
                connect(host.hostAddress ?: return, resolved.port)
            }

            override fun onResolveFailed(info: NsdServiceInfo, errorCode: Int) {
                Log.w(tag, "resolve failed $errorCode")
            }
        })
    }

    private fun connect(host: String, port: Int) {
        synchronized(connectLock) {
            if (connecting || socket?.isConnected == true) return
            connecting = true
        }
        Thread({
            try {
                val candidate = Socket()
                candidate.tcpNoDelay = true
                candidate.connect(InetSocketAddress(host, port), 3000)
                socket = candidate
                output = candidate.getOutputStream()
                seq = 0
                Log.i(tag, "connected $host:$port")
                stopDiscovery()
                _state.value = PhoneVoiceGattServer.State.Connected("Wi-Fi")
                sendControl(PhoneVoiceProtocol.OP_READY)
                startReader(candidate)
            } catch (t: Throwable) {
                Log.w(tag, "connect failed", t)
                _state.value = PhoneVoiceGattServer.State.Error("Wi-Fi 连接失败")
                closeSocket()
                scheduleReconnect(2000)
            } finally {
                synchronized(connectLock) { connecting = false }
            }
        }, "vibepad-wifi-connect").start()
    }

    private fun stopDiscovery() {
        ndsListener?.let { runCatching { nsd?.stopServiceDiscovery(it) } }
        ndsListener = null
    }

    private fun scheduleReconnect(delayMs: Long = 1500) {
        if (!running) return
        if (socket?.isConnected == true || connecting) return
        mainHandler.removeCallbacks(reconnectTask)
        mainHandler.postDelayed(reconnectTask, delayMs)
    }

    private fun closeSocket() {
        runCatching { socket?.close() }
        socket = null
        output = null
    }

    /// Mac → 手机：ready / 状态（授权标志）。同时用它判断连接是否已经断开。
    private fun startReader(active: Socket) {
        Thread({
            val input = runCatching { active.getInputStream() }.getOrNull() ?: return@Thread
            val header = ByteArray(6)
            while (running && !active.isClosed) {
                try {
                    if (!readFully(input, header, 6)) break
                    val type = header[1].toInt() and 0xFF
                    val length = (header[4].toInt() and 0xFF) or
                        ((header[5].toInt() and 0xFF) shl 8)
                    val payload = ByteArray(length)
                    if (length > 0 && !readFully(input, payload, length)) break
                    if (type == PhoneVoiceProtocol.TYPE_CONTROL && payload.isNotEmpty()) {
                        when (payload[0].toInt() and 0xFF) {
                            PhoneVoiceProtocol.OP_STATUS ->
                                _macFlags.value = if (payload.size > 1) {
                                    payload[1].toInt() and 0xFF
                                } else {
                                    0
                                }
                            PhoneVoiceProtocol.OP_READY,
                            PhoneVoiceProtocol.OP_HEARTBEAT -> Unit
                            else -> Unit
                        }
                    }
                } catch (t: Throwable) {
                    Log.w(tag, "read failed", t)
                    break
                }
            }
            if (running) {
                Log.i(tag, "Mac 断开，准备重连")
                closeSocket()
                _state.value = PhoneVoiceGattServer.State.Advertising
                scheduleReconnect(1200)
            }
        }, "vibepad-wifi-reader").apply {
            isDaemon = true
            start()
        }
    }

    private fun readFully(
        input: java.io.InputStream,
        buffer: ByteArray,
        length: Int
    ): Boolean {
        var offset = 0
        while (offset < length) {
            val read = input.read(buffer, offset, length - offset)
            if (read <= 0) return false
            offset += read
        }
        return true
    }

    // MARK: - Talk

    fun startTalk() {
        if (recording) return
        if (socket?.isConnected != true || output == null) {
            _state.value = PhoneVoiceGattServer.State.Error("Mac 还没连接")
            return
        }
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO)
            != PackageManager.PERMISSION_GRANTED
        ) {
            _state.value = PhoneVoiceGattServer.State.Error("缺少录音权限")
            return
        }
        val frame = PhoneVoiceProtocol.FRAME_SAMPLES
        val minBuf = AudioRecord.getMinBufferSize(
            PhoneVoiceProtocol.SAMPLE_RATE,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT
        )
        val record = try {
            AudioRecord(
                MediaRecorder.AudioSource.VOICE_COMMUNICATION,
                PhoneVoiceProtocol.SAMPLE_RATE,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
                max(minBuf, frame * 2 * 4)
            )
        } catch (t: Throwable) {
            Log.w(tag, "AudioRecord create failed", t)
            _state.value = PhoneVoiceGattServer.State.Error("录音初始化失败")
            return
        }
        if (record.state != AudioRecord.STATE_INITIALIZED) {
            record.release()
            _state.value = PhoneVoiceGattServer.State.Error("录音设备不可用")
            return
        }
        try {
            record.startRecording()
        } catch (t: Throwable) {
            record.release()
            _state.value = PhoneVoiceGattServer.State.Error("开始录音失败")
            return
        }
        recording = true
        gain.reset()
        _state.value = PhoneVoiceGattServer.State.Talking
        sendControl(PhoneVoiceProtocol.OP_START)
        audioThread = Thread({ audioLoop(record) }, "vibepad-wifi-audio").apply {
            isDaemon = true
            start()
        }
    }

    fun stopTalk() {
        if (!recording) return
        recording = false
        audioThread?.let { runCatching { it.join(500) } }
        audioThread = null
        _level.value = 0f
        sendControl(PhoneVoiceProtocol.OP_STOP)
        if (socket?.isConnected == true) {
            _state.value = PhoneVoiceGattServer.State.Connected("Wi-Fi")
        }
    }

    private fun audioLoop(record: AudioRecord) {
        val pcm = ShortArray(PhoneVoiceProtocol.FRAME_SAMPLES)
        val bytes = ByteArray(pcm.size * 2)
        var windowStart = SystemClock.elapsedRealtime()
        var windowPackets = 0
        var windowPeak = 0
        Log.i(tag, "audio loop start")
        while (recording) {
            val read = try {
                record.read(pcm, 0, pcm.size)
            } catch (t: Throwable) {
                Log.w(tag, "read failed", t)
                break
            }
            if (read <= 0) continue
            if (read < pcm.size) pcm.fill(0, read, pcm.size)
            gain.apply(pcm, read)
            for (i in pcm.indices) {
                val value = pcm[i].toInt()
                bytes[i * 2] = (value and 0xFF).toByte()
                bytes[i * 2 + 1] = ((value shr 8) and 0xFF).toByte()
            }
            sendFrame(PhoneVoiceProtocol.TYPE_AUDIO, bytes)
            windowPackets++
            var sum = 0.0
            for (i in 0 until read) {
                val v = pcm[i].toInt()
                if (abs(v) > windowPeak) windowPeak = abs(v)
                sum += v.toDouble() * v.toDouble()
            }
            _level.value = (sqrt(sum / read) / 32768.0).toFloat().coerceIn(0f, 1f)
            val now = SystemClock.elapsedRealtime()
            if (now - windowStart >= 1000) {
                Log.i(tag, "sent ${windowPackets}pkt/s peak=$windowPeak")
                windowPackets = 0
                windowPeak = 0
                windowStart = now
            }
        }
        runCatching { record.stop() }
        runCatching { record.release() }
        _level.value = 0f
        Log.i(tag, "audio loop end")
    }

    // MARK: - Frames

    private fun sendControl(op: Int, arg: Int = 0) {
        sendFrame(
            PhoneVoiceProtocol.TYPE_CONTROL,
            byteArrayOf(op.toByte(), arg.toByte())
        )
    }

    private fun sendFrame(type: Int, payload: ByteArray) {
        val frame = ByteArray(6 + payload.size)
        frame[0] = PhoneVoiceProtocol.VERSION.toByte()
        frame[1] = type.toByte()
        frame[2] = (seq++ and 0xFF).toByte()
        frame[3] = 0
        frame[4] = (payload.size and 0xFF).toByte()
        frame[5] = ((payload.size shr 8) and 0xFF).toByte()
        payload.copyInto(frame, 6)
        writeQueue.offer(frame)
    }

    private fun startWriter() {
        if (writer != null) return
        writer = Thread({
            while (running) {
                val frame = try {
                    writeQueue.poll(500, TimeUnit.MILLISECONDS)
                } catch (t: InterruptedException) {
                    break
                } ?: continue
                val out = output ?: continue
                try {
                    synchronized(writeLock) {
                        out.write(frame)
                        out.flush()
                    }
                } catch (t: Throwable) {
                    Log.w(tag, "write failed", t)
                    closeSocket()
                    if (running) {
                        _state.value = PhoneVoiceGattServer.State.Advertising
                        scheduleReconnect(800)
                    }
                }
            }
        }, "vibepad-wifi-writer").apply {
            isDaemon = true
            start()
        }
    }

    // MARK: - Heartbeat

    private fun startHeartbeat() {
        if (heartbeat != null) return
        heartbeat = Thread({
            while (running) {
                if (socket?.isConnected == true) {
                    sendControl(PhoneVoiceProtocol.OP_HEARTBEAT)
                } else if (!connecting) {
                    scheduleReconnect(1000)
                }
                Thread.sleep(2000)
            }
        }, "vibepad-wifi-heartbeat").apply {
            isDaemon = true
            start()
        }
    }

    private fun stopHeartbeat() {
        heartbeat?.interrupt()
        heartbeat = null
    }
}
