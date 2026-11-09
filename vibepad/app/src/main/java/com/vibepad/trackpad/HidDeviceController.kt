package com.vibepad.trackpad

import android.Manifest
import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothHidDevice
import android.bluetooth.BluetoothHidDeviceAppSdpSettings
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.core.content.ContextCompat
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * Owns the Android BluetoothHidDevice registration and the relative
 * pointer report pipeline.
 *
 * All HID reports are serialized on one sender thread. Pointer motion is
 * accumulated by the touch layer and flushed at a fixed 120 Hz tick; buttons
 * and key combos are submitted to the same thread so a release can never
 * overtake a press.
 */
@SuppressLint("MissingPermission")
object HidDeviceController {

    private const val TAG = "VibePadHid"
    private const val PREFS = "vibepad"
    private const val KEY_TARGET = "target_address"
    private const val KEY_SENSITIVITY = "sensitivity"
    private const val KEY_NATURAL_SCROLL = "natural_scroll"

    private const val BUTTON_LEFT = 0x01
    private const val BUTTON_RIGHT = 0x02
    private const val BUTTON_MIDDLE = 0x04

    private const val TICK_MS = 8L

    sealed interface State {
        data object Idle : State
        data object BluetoothOff : State
        data object NoPermission : State
        data object Registering : State
        data object Registered : State
        data class Connecting(val name: String) : State
        data class Connected(val name: String) : State
        data class Error(val message: String) : State
    }

    private val _state = MutableStateFlow<State>(State.Idle)
    val state: StateFlow<State> = _state.asStateFlow()

    private var appContext: Context? = null
    private var manager: BluetoothManager? = null
    private var adapter: BluetoothAdapter? = null
    private var hid: BluetoothHidDevice? = null
    private var target: BluetoothDevice? = null
    private var registered = false

    private val mainHandler = Handler(Looper.getMainLooper())
    private val sender: ScheduledExecutorService =
        Executors.newSingleThreadScheduledExecutor { runnable ->
            Thread(runnable, "vibepad-hid-sender").apply { isDaemon = true }
        }
    private val callbacks: ScheduledExecutorService =
        Executors.newSingleThreadScheduledExecutor { runnable ->
            Thread(runnable, "vibepad-hid-callback").apply { isDaemon = true }
        }

    private val lock = Any()
    private var pendingDx = 0.0
    private var pendingDy = 0.0
    private var pendingWheel = 0
    private var pendingPan = 0

    @Volatile
    private var heldButtons = 0

    @Volatile
    private var hidConnected = false

    @Volatile
    var sensitivity: Float = 1.4f
        private set

    @Volatile
    var naturalScroll: Boolean = true
        private set

    private var initialized = false
    private var senderStarted = false
    private var reconnectAttempt = 0
    private var receiverRegistered = false

    private val adapterReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action != BluetoothAdapter.ACTION_STATE_CHANGED) return
            when (intent.getIntExtra(BluetoothAdapter.EXTRA_STATE, BluetoothAdapter.ERROR)) {
                BluetoothAdapter.STATE_ON -> {
                    Log.i(TAG, "adapter on, re-registering")
                    startProfileProxy()
                }
                BluetoothAdapter.STATE_OFF -> {
                    resetLink()
                    _state.value = State.BluetoothOff
                }
            }
        }
    }

    fun init(context: Context) {
        if (initialized) return
        initialized = true
        appContext = context.applicationContext
        manager = context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
        adapter = manager?.adapter
        sensitivity = prefs().getFloat(KEY_SENSITIVITY, 1.4f)
        naturalScroll = prefs().getBoolean(KEY_NATURAL_SCROLL, true)
        if (!receiverRegistered) {
            ContextCompat.registerReceiver(
                context,
                adapterReceiver,
                IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED),
                ContextCompat.RECEIVER_NOT_EXPORTED
            )
            receiverRegistered = true
        }
        startSender()
        startProfileProxy()
    }

    fun updateSettings(sensitivity: Float, naturalScroll: Boolean) {
        this.sensitivity = sensitivity.coerceIn(0.5f, 3.0f)
        this.naturalScroll = naturalScroll
        prefs().edit()
            .putFloat(KEY_SENSITIVITY, this.sensitivity)
            .putBoolean(KEY_NATURAL_SCROLL, naturalScroll)
            .apply()
    }

    fun pairedDevices(): List<BluetoothDevice> {
        if (!hasConnectPermission()) return emptyList()
        return try {
            adapter?.bondedDevices?.toList().orEmpty()
        } catch (t: Throwable) {
            Log.w(TAG, "bondedDevices failed", t)
            emptyList()
        }
    }

    fun savedTargetAddress(): String? = prefs().getString(KEY_TARGET, null)

    fun connect(device: BluetoothDevice) {
        if (!hasConnectPermission()) {
            _state.value = State.NoPermission
            return
        }
        // The watchdog may see an empty HID profile list even while the
        // connection is up; do not reset a live connection back to Connecting.
        if (hidConnected && target?.address == device.address) return
        val h = hid
        if (h == null) {
            _state.value = State.Registering
            return
        }
        Log.i(TAG, "connect ${device.name}")
        prefs().edit()
            .putString(KEY_TARGET, device.address)
            .apply()
        target = device
        _state.value = State.Connecting(device.name ?: device.address)
        try {
            h.connect(device)
        } catch (t: Throwable) {
            Log.w(TAG, "connect failed", t)
            _state.value = State.Error(t.message ?: "connect failed")
        }
    }

    // ---- Pointer pipeline ----

    fun move(dx: Float, dy: Float) {
        synchronized(lock) {
            pendingDx += dx * sensitivity
            pendingDy += dy * sensitivity
        }
    }

    fun scroll(pan: Int, wheel: Int) {
        if (pan == 0 && wheel == 0) return
        synchronized(lock) {
            pendingPan += pan
            pendingWheel += wheel
        }
    }

    fun click(button: Int) {
        sender.execute {
            val mask = button and 0x07
            if (mask == 0) return@execute
            heldButtons = heldButtons or mask
            sendMouse(0, 0, 0, 0)
            sleep(20)
            heldButtons = heldButtons and mask.inv()
            sendMouse(0, 0, 0, 0)
            sleep(20)
        }
    }

    fun button(button: Int, down: Boolean) {
        sender.execute {
            val mask = button and 0x07
            heldButtons = if (down) heldButtons or mask else heldButtons and mask.inv()
            sendMouse(0, 0, 0, 0)
        }
    }

    fun keyCombo(modifiers: Int, keyCode: Int) {
        sender.execute {
            if (modifiers != 0) {
                // macOS 处理 Cmd+Tab 时看的是"上一个事件"里 Cmd 是否已经按下。
                // 修饰键和 Tab 塞进同一包时，会被当成普通 Tab（之前切换键没反应就是这个原因），
                // 所以先单独发一包修饰键，再发组合，按住 70ms 再松。
                sendKeyboard(modifiers, 0)
                sleep(30)
                sendKeyboard(modifiers, keyCode)
                sleep(70)
                sendKeyboard(modifiers, 0)
                sleep(20)
                sendKeyboard(0, 0)
                sleep(20)
            } else {
                sendKeyboard(0, keyCode)
                sleep(35)
                sendKeyboard(0, 0)
                sleep(20)
            }
        }
    }

    fun releaseAll() {
        sender.execute {
            heldButtons = 0
            sendMouse(0, 0, 0, 0)
            sendKeyboard(0, 0)
            sendConsumer(0)
        }
    }

    fun rescan() {
        resetLink()
        startProfileProxy()
    }

    fun shutdown() {
        mainHandler.removeCallbacksAndMessages(null)
        if (receiverRegistered) {
            try {
                appContext?.unregisterReceiver(adapterReceiver)
            } catch (_: Throwable) {
            }
            receiverRegistered = false
        }
        releaseAll()
        try {
            hid?.unregisterApp()
        } catch (_: Throwable) {
        }
        if (hasConnectPermission()) {
            try {
                adapter?.closeProfileProxy(BluetoothProfile.HID_DEVICE, hid)
            } catch (_: Throwable) {
            }
        }
        hid = null
        resetLink()
        initialized = false
        _state.value = State.Idle
    }

    // ---- HID profile setup ----

    private fun startSender() {
        if (senderStarted) return
        senderStarted = true
        sender.scheduleAtFixedRate({ flushPointer() }, 0, TICK_MS, TimeUnit.MILLISECONDS)
    }

    private fun startProfileProxy() {
        val ctx = appContext ?: return
        if (!hasConnectPermission()) {
            _state.value = State.NoPermission
            return
        }
        val a = adapter
        if (a == null) {
            _state.value = State.BluetoothOff
            return
        }
        if (!a.isEnabled) {
            _state.value = State.BluetoothOff
            return
        }
        _state.value = State.Registering
        try {
            a.getProfileProxy(ctx, profileListener, BluetoothProfile.HID_DEVICE)
        } catch (t: Throwable) {
            Log.w(TAG, "getProfileProxy failed", t)
            _state.value = State.Error(t.message ?: "getProfileProxy failed")
        }
    }

    private val profileListener = object : BluetoothProfile.ServiceListener {
        override fun onServiceConnected(profile: Int, proxy: BluetoothProfile?) {
            if (profile != BluetoothProfile.HID_DEVICE) return
            hid = proxy as? BluetoothHidDevice
            Log.i(TAG, "HID proxy connected")
            registerApp()
        }

        override fun onServiceDisconnected(profile: Int) {
            if (profile != BluetoothProfile.HID_DEVICE) return
            Log.w(TAG, "HID proxy disconnected")
            hid = null
            registered = false
            resetLink()
            _state.value = State.Registering
            mainHandler.postDelayed({ startProfileProxy() }, 1000)
        }
    }

    private fun registerApp() {
        val h = hid ?: return
        if (!hasConnectPermission()) {
            _state.value = State.NoPermission
            return
        }
        val sdp = BluetoothHidDeviceAppSdpSettings(
            "VibePad Trackpad",
            "Android trackpad and voice input for Mac",
            "VibePad",
            BluetoothHidDevice.SUBCLASS1_COMBO,
            HidDescriptor.DESCRIPTOR
        )
        val ok = try {
            h.registerApp(sdp, null, null, callbacks, hidCallback)
        } catch (t: Throwable) {
            Log.w(TAG, "registerApp failed", t)
            false
        }
        Log.i(TAG, "registerApp -> $ok")
        if (!ok) {
            _state.value = State.Error("HID 注册失败，请确认蓝牙已开启并授予附近设备权限")
        }
    }

    private val hidCallback = object : BluetoothHidDevice.Callback() {
        override fun onAppStatusChanged(pluggedDevice: BluetoothDevice?, registered: Boolean) {
            Log.i(TAG, "appStatus registered=$registered")
            this@HidDeviceController.registered = registered
            if (!registered) {
                hidConnected = false
                _state.value = State.Registering
                return
            }
            _state.value = State.Registered
            startWatchdog()
            autoConnectSaved()
        }

        override fun onConnectionStateChanged(device: BluetoothDevice?, state: Int) {
            Log.i(TAG, "connection state=$state device=${device?.name}")
            when (state) {
                BluetoothProfile.STATE_CONNECTED -> {
                    if (device != null) {
                        hidConnected = true
                        target = device
                        reconnectAttempt = 0
                        prefs().edit().putString(KEY_TARGET, device.address).apply()
                        _state.value = State.Connected(device.name ?: device.address)
                    }
                }
                BluetoothProfile.STATE_DISCONNECTED -> {
                    hidConnected = false
                    target = null
                    releaseAll()
                    _state.value = State.Registered
                    scheduleReconnect()
                }
            }
        }

        override fun onGetReport(
            device: BluetoothDevice?,
            type: Byte,
            id: Byte,
            bufferSize: Int
        ) {
            val h = hid ?: return
            val d = device ?: return
            val report = when (id.toInt()) {
                HidDescriptor.REPORT_MOUSE -> ByteArray(5)
                HidDescriptor.REPORT_KEYBOARD -> ByteArray(8)
                HidDescriptor.REPORT_CONSUMER -> ByteArray(2)
                else -> ByteArray(bufferSize.coerceAtLeast(0))
            }
            try {
                h.replyReport(d, type, id, report)
            } catch (t: Throwable) {
                Log.w(TAG, "replyReport failed", t)
            }
        }

        override fun onSetReport(device: BluetoothDevice?, type: Byte, id: Byte, data: ByteArray?) {
            val d = device ?: return
            try {
                hid?.reportError(d, BluetoothHidDevice.ERROR_RSP_SUCCESS)
            } catch (t: Throwable) {
                Log.w(TAG, "setReport ack failed", t)
            }
        }

        override fun onSetProtocol(device: BluetoothDevice?, protocol: Byte) {
            val d = device ?: return
            try {
                hid?.reportError(d, BluetoothHidDevice.ERROR_RSP_SUCCESS)
            } catch (t: Throwable) {
                Log.w(TAG, "setProtocol ack failed", t)
            }
        }

        override fun onInterruptData(device: BluetoothDevice?, reportId: Byte, data: ByteArray?) {}

        override fun onVirtualCableUnplug(device: BluetoothDevice?) {
            Log.w(TAG, "virtual cable unplug")
            hidConnected = false
            resetLink()
            _state.value = State.Registering
            scheduleReconnect()
        }
    }

    private fun autoConnectSaved() {
        val address = savedTargetAddress() ?: return
        val device = pairedDevices().firstOrNull { it.address == address } ?: return
        Log.i(TAG, "auto-connect saved ${device.name}")
        connect(device)
    }

    private fun scheduleReconnect() {
        val address = savedTargetAddress() ?: return
        reconnectAttempt = min(reconnectAttempt + 1, 4)
        val delay = when (reconnectAttempt) {
            1 -> 1000L
            2 -> 2000L
            3 -> 5000L
            else -> 10000L
        }
        mainHandler.postDelayed({
            val device = pairedDevices().firstOrNull { it.address == address } ?: return@postDelayed
            if (registered) {
                Log.i(TAG, "reconnect attempt=$reconnectAttempt")
                connect(device)
            }
        }, delay)
    }

    private fun startWatchdog() {
        mainHandler.removeCallbacks(watchdog)
        mainHandler.postDelayed(watchdog, 5000)
    }

    private val watchdog = object : Runnable {
        override fun run() {
            val a = adapter
            if (a != null && a.isEnabled && registered) {
                val connected = try {
                    manager?.getConnectedDevices(BluetoothProfile.HID_DEVICE).orEmpty()
                } catch (_: Throwable) {
                    emptyList()
                }
                if (connected.isEmpty() && !hidConnected && savedTargetAddress() != null) {
                    mainHandler.postDelayed({
                        val address = savedTargetAddress() ?: return@postDelayed
                        val device = pairedDevices().firstOrNull { it.address == address }
                        if (device != null && registered) connect(device)
                    }, 500)
                }
            }
            mainHandler.postDelayed(this, 5000)
        }
    }

    private fun resetLink() {
        hidConnected = false
        target = null
        heldButtons = 0
        synchronized(lock) {
            pendingDx = 0.0
            pendingDy = 0.0
            pendingWheel = 0
            pendingPan = 0
        }
    }

    // ---- Report senders ----

    private fun flushPointer() {
        if (target == null || hid == null) return
        if (!hasConnectPermission()) return

        val dx: Int
        val dy: Int
        val wheel: Int
        val pan: Int
        synchronized(lock) {
            dx = pendingDx.roundToInt()
            pendingDx -= dx
            dy = pendingDy.roundToInt()
            pendingDy -= dy
            wheel = pendingWheel.coerceIn(-127, 127)
            pendingWheel -= wheel
            pan = pendingPan.coerceIn(-127, 127)
            pendingPan -= pan
        }
        if (dx == 0 && dy == 0 && wheel == 0 && pan == 0) return

        val x = dx.coerceIn(-127, 127)
        val y = dy.coerceIn(-127, 127)
        if (dx != x) synchronized(lock) { pendingDx += dx - x }
        if (dy != y) synchronized(lock) { pendingDy += dy - y }
        sendMouse(x, y, wheel, pan)
    }

    private fun sendMouse(dx: Int, dy: Int, wheel: Int, pan: Int) {
        val h = hid ?: return
        val t = target ?: return
        if (!hasConnectPermission()) return
        val report = byteArrayOf(
            heldButtons.toByte(),
            dx.coerceIn(-127, 127).toByte(),
            dy.coerceIn(-127, 127).toByte(),
            wheel.coerceIn(-127, 127).toByte(),
            pan.coerceIn(-127, 127).toByte()
        )
        try {
            h.sendReport(t, HidDescriptor.REPORT_MOUSE, report)
        } catch (t: Throwable) {
            Log.w(TAG, "send mouse failed", t)
        }
    }

    private fun sendKeyboard(modifiers: Int, keyCode: Int) {
        val h = hid ?: return
        val t = target ?: return
        if (!hasConnectPermission()) return
        val report = byteArrayOf(
            (modifiers and 0xFF).toByte(),
            0,
            (keyCode and 0xFF).toByte(),
            0, 0, 0, 0, 0
        )
        try {
            h.sendReport(t, HidDescriptor.REPORT_KEYBOARD, report)
        } catch (t: Throwable) {
            Log.w(TAG, "send keyboard failed", t)
        }
    }

    private fun sendConsumer(usage: Int) {
        val h = hid ?: return
        val t = target ?: return
        if (!hasConnectPermission()) return
        val report = byteArrayOf(
            (usage and 0xFF).toByte(),
            ((usage shr 8) and 0xFF).toByte()
        )
        try {
            h.sendReport(t, HidDescriptor.REPORT_CONSUMER, report)
        } catch (t: Throwable) {
            Log.w(TAG, "send consumer failed", t)
        }
    }

    // ---- Helpers ----

    private fun prefs() = appContext!!.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    private fun hasConnectPermission(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return true
        val ctx = appContext ?: return false
        return ContextCompat.checkSelfPermission(
            ctx,
            Manifest.permission.BLUETOOTH_CONNECT
        ) == PackageManager.PERMISSION_GRANTED
    }

    private fun sleep(ms: Long) {
        try {
            Thread.sleep(ms)
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
        }
    }

    fun buttonLeft(): Int = BUTTON_LEFT
    fun buttonRight(): Int = BUTTON_RIGHT
    fun buttonMiddle(): Int = BUTTON_MIDDLE
}
