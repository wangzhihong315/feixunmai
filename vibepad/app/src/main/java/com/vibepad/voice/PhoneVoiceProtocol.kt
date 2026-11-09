package com.vibepad.voice

import java.util.UUID

/**
 * Dedicated phone audio service. This intentionally does not reuse the
 * Feixun remote's 0x1920 service so the phone and the physical remote can
 * coexist without stealing each other's connection.
 */
object PhoneVoiceProtocol {
    val SERVICE: UUID = UUID.fromString("7A1B0001-4C3D-4E5F-8A9B-0C1D2E3F4A01")
    val AUDIO: UUID = UUID.fromString("7A1B0002-4C3D-4E5F-8A9B-0C1D2E3F4A01")
    val CONTROL: UUID = UUID.fromString("7A1B0003-4C3D-4E5F-8A9B-0C1D2E3F4A01")
    val CCCD: UUID = UUID.fromString("00002902-0000-1000-8000-00805F9B34FB")

    const val SAMPLE_RATE = 16_000
    /// 线上格式：8 kHz 单声道 IMA ADPCM（4 bit/样本 = 4 KB/s）。
    /// 实测 BLE 链路只能跑约 4 KB/s（macOS 把连接间隔放在 50~60 ms，
    /// 每个周期一个包），μ-law 8k 需要 8 KB/s，必然丢一半并累积时延。
    const val WIRE_RATE = 8_000
    /// 40 ms @16 kHz 采集，2:1 降采样后得到 320 个 8 kHz 样本。
    const val FRAME_SAMPLES = 640
    const val FRAME_BYTES = 160
    const val HEADER_BYTES = 4
    const val PACKET_BYTES = HEADER_BYTES + FRAME_BYTES

    const val VERSION = 1
    const val TYPE_AUDIO = 1
    const val TYPE_CONTROL = 2
    /// 胶囊同步：独立 TCP 连接，首帧类型决定 Mac 端把这条连接归为胶囊通道。
    const val TYPE_CAPSULE = 5
    const val TYPE_CAPSULE_ACK = 6
    const val TYPE_CAPSULE_TEXT = 7

    const val OP_STOP = 0x00
    const val OP_START = 0x01
    const val OP_READY = 0x02
    const val OP_HEARTBEAT = 0x03
    const val OP_STATUS = 0x04

    const val CAP_BEGIN: Byte = 0x01
    const val CAP_DATA: Byte = 0x02
    const val CAP_END: Byte = 0x03
    const val CAP_QUERY: Byte = 0x04
}
