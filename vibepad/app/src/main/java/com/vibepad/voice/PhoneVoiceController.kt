package com.vibepad.voice

import android.content.Context
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/**
 * 语音链路的统一入口。同一时刻只跑一种传输：
 *
 *  - `ble`  — 手机做 GATT server，25 包/秒 ADPCM（默认，不依赖网络）
 *  - `wifi` — Bonjour 找到 Mac，TCP 直连送 16 kHz PCM（更清晰，需同一局域网）
 *
 * 触控板始终是蓝牙 HID，与这里无关。
 */
object PhoneVoiceController {
    const val LINK_BLE = "ble"
    const val LINK_WIFI = "wifi"

    private const val PREFS = "vibepad"
    private const val KEY_LINK = "voice_link"

    private var appContext: Context? = null
    private var gatt: PhoneVoiceGattServer? = null
    private var wifi: WifiVoiceClient? = null
    private val idle = MutableStateFlow<PhoneVoiceGattServer.State>(PhoneVoiceGattServer.State.Idle)
    private val zero = MutableStateFlow(0f)
    private val zeroFlags = MutableStateFlow(0)
    private val linkFlow = MutableStateFlow(LINK_BLE)

    val link: StateFlow<String>
        get() = linkFlow

    private val isWifi: Boolean
        get() = linkFlow.value == LINK_WIFI

    val state: StateFlow<PhoneVoiceGattServer.State>
        get() = if (isWifi) wifi?.state ?: idle else gatt?.state ?: idle

    val level: StateFlow<Float>
        get() = if (isWifi) wifi?.level ?: zero else gatt?.level ?: zero

    val macFlags: StateFlow<Int>
        get() = if (isWifi) wifi?.macFlags ?: zeroFlags else gatt?.macFlags ?: zeroFlags

    fun init(context: Context) {
        appContext = context.applicationContext
        linkFlow.value = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getString(KEY_LINK, LINK_BLE) ?: LINK_BLE
        applyLink()
    }

    fun setLink(value: String) {
        if (value != LINK_BLE && value != LINK_WIFI) return
        if (linkFlow.value == value) return
        appContext?.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            ?.edit()?.putString(KEY_LINK, value)?.apply()
        linkFlow.value = value
        applyLink()
    }

    private fun applyLink() {
        val context = appContext ?: return
        if (isWifi) {
            gatt?.shutdown()
            gatt = null
            if (wifi == null) {
                wifi = WifiVoiceClient(context).also { it.start() }
            }
        } else {
            wifi?.shutdown()
            wifi = null
            if (gatt == null) {
                gatt = PhoneVoiceGattServer(context).also { it.start() }
            }
        }
    }

    fun startTalk() {
        if (isWifi) wifi?.startTalk() else gatt?.startTalk()
    }

    fun stopTalk() {
        if (isWifi) wifi?.stopTalk() else gatt?.stopTalk()
    }

    fun restart() {
        if (isWifi) {
            wifi?.shutdown()
            wifi = appContext?.let { WifiVoiceClient(it).also { client -> client.start() } }
        } else {
            gatt?.shutdown()
            gatt = appContext?.let { PhoneVoiceGattServer(it).also { server -> server.start() } }
        }
    }

    fun shutdown() {
        gatt?.shutdown()
        gatt = null
        wifi?.shutdown()
        wifi = null
    }
}
