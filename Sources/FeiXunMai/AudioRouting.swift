import Foundation
import AVFoundation
import CoreAudio

struct AudioDeviceInfo: Identifiable, Hashable {
    let id: AudioDeviceID
    let name: String
    let uid: String
}

func audioString(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var value: CFString = "" as CFString
    var size = UInt32(MemoryLayout<CFString>.size)
    let status = withUnsafeMutablePointer(to: &value) { pointer in
        AudioObjectGetPropertyData(id, &address, 0, nil, &size, pointer)
    }
    guard status == noErr else { return nil }
    return value as String
}

func outputDevices() -> [AudioDeviceInfo] {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
    ) == noErr, size > 0 else { return [] }

    let count = Int(size) / MemoryLayout<AudioDeviceID>.size
    var ids = [AudioDeviceID](repeating: 0, count: count)
    guard AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids
    ) == noErr else { return [] }

    return ids.compactMap { id in
        var streamAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var propSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &streamAddress, 0, nil, &propSize) == noErr,
              propSize > 0 else { return nil }
        let bufferList = UnsafeMutableRawPointer.allocate(
            byteCount: Int(propSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { bufferList.deallocate() }
        guard AudioObjectGetPropertyData(id, &streamAddress, 0, nil, &propSize, bufferList) == noErr else {
            return nil
        }
        let abl = UnsafeMutableAudioBufferListPointer(
            bufferList.assumingMemoryBound(to: AudioBufferList.self)
        )
        let channels = abl.reduce(0) { $0 + Int($1.mNumberChannels) }
        guard channels > 0 else { return nil }
        let name = audioString(id, kAudioObjectPropertyName) ?? "Unknown"
        let uid = audioString(id, kAudioDevicePropertyDeviceUID) ?? ""
        return AudioDeviceInfo(id: id, name: name, uid: uid)
    }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
}

/// Every CoreAudio device, including input-only microphones. The previous
/// default-input lookup went through outputDevices() and therefore returned
/// nil for real microphones, which broke input restoration.
func allDevices() -> [AudioDeviceInfo] {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
    ) == noErr, size > 0 else { return [] }

    let count = Int(size) / MemoryLayout<AudioDeviceID>.size
    var ids = [AudioDeviceID](repeating: 0, count: count)
    guard AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids
    ) == noErr else { return [] }

    return ids.map { id in
        let name = audioString(id, kAudioObjectPropertyName) ?? "Unknown"
        let uid = audioString(id, kAudioDevicePropertyDeviceUID) ?? ""
        return AudioDeviceInfo(id: id, name: name, uid: uid)
    }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
}

func defaultOutputDevice() -> AudioDeviceInfo? {
    defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
}

func defaultInputDevice() -> AudioDeviceInfo? {
    defaultDevice(kAudioHardwarePropertyDefaultInputDevice)
}

private func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioDeviceInfo? {
    var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var id: AudioDeviceID = 0
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id
    ) == noErr else { return nil }
    return allDevices().first { $0.id == id }
}

func setDefaultInputDevice(_ device: AudioDeviceInfo) -> Bool {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var id = device.id
    let status = AudioObjectSetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
        UInt32(MemoryLayout<AudioDeviceID>.size), &id
    )
    return status == noErr
}

/// Plays decoded 16 kHz mono PCM into a selectable output device
/// (typically the BlackHole 2ch loopback, which apps use as a microphone).
///
/// 接线顺序对齐 remote-mic-app 的 AudioOutput：只连 player→mixer，
/// 选好设备后 prepare/start（mixer→output 由引擎按设备格式自动接）。
/// 之前先按默认设备格式 connect 再切设备，导致连接格式失配、输出静音。
final class AudioSink {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    /// 第二路：本机扬声器/耳机监听
    private let monitorEngine = AVAudioEngine()
    private let monitorPlayer = AVAudioPlayerNode()
    /// 监听引擎是否真的启动了（关闭监听时不启动，enqueue 也不能喂它）
    private var monitorActive = false
    private let format: AVAudioFormat
    /// 诊断：最近 1 秒内实际流向输出设备的波形峰值（0 = 静音）
    private(set) var recentPeak: Float = 0
    /// 给界面电平条用的平滑值，带衰减（0…1）
    private var meter: Float = 0
    private var peakLock = NSLock()
    /// 每秒统计：入队、丢弃、回调次数
    private var statEnqueued = 0
    private var statDropped = 0
    private var statTaps = 0

    init(device: AudioDeviceInfo?, monitor: Bool = true) throws {
        format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        )!

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)

        if let device {
            guard let unit = engine.outputNode.audioUnit else {
                throw NSError(domain: "AudioSink", code: -1)
            }
            var id = device.id
            let status = AudioUnitSetProperty(
                unit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &id,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            guard status == noErr else {
                throw NSError(
                    domain: "AudioSink", code: Int(status),
                    userInfo: [NSLocalizedDescriptionKey: "select device \(device.name): OSStatus \(status)"]
                )
            }
            Self.ensureAudible(device)
        }

        engine.prepare()
        try engine.start()
        player.play()

        // 回读引擎真正绑定的输出设备：只报告 chosenDevice 是不够的，
        // AUHAL 有可能忽略了 CurrentDevice 而继续用系统默认输出。
        if let unit = engine.outputNode.audioUnit {
            var actual: AudioDeviceID = 0
            var actualSize = UInt32(MemoryLayout<AudioDeviceID>.size)
            let status = AudioUnitGetProperty(
                unit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &actual,
                &actualSize
            )
            let actualName = allDevices().first { $0.id == actual }?.name ?? "id=\(actual)"
            let outFormat = engine.outputNode.outputFormat(forBus: 0)
            FileLog.write(
                "sink engine device=\(actualName) status=\(status) wanted=\(device?.name ?? "系统默认")"
                    + " outRate=\(Int(outFormat.sampleRate)) outCh=\(outFormat.channelCount)"
            )
        }

        // 监听引擎：同样的声音同时送到本机真实输出（扬声器/耳机），
        // 解决"声音全进了虚拟麦、本机没声"的问题。虚拟设备本身不监听。
        if monitor, let monitorDevice = defaultOutputDevice(),
           monitorDevice.name.localizedCaseInsensitiveContains("BlackHole") == false {
            monitorEngine.attach(monitorPlayer)
            monitorEngine.connect(monitorPlayer, to: monitorEngine.mainMixerNode, format: format)
            if let unit = monitorEngine.outputNode.audioUnit {
                var id = monitorDevice.id
                AudioUnitSetProperty(
                    unit,
                    kAudioOutputUnitProperty_CurrentDevice,
                    kAudioUnitScope_Global,
                    0,
                    &id,
                    UInt32(MemoryLayout<AudioDeviceID>.size)
                )
            }
            monitorEngine.prepare()
            try monitorEngine.start()
            monitorPlayer.play()
            monitorActive = true
        }

        // 诊断探头：挂在 mixer→output 的必经之路上
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 2048, format: nil) { [weak self] buffer, _ in
            guard let self, let data = buffer.floatChannelData?[0] else { return }
            var peak: Float = 0
            for i in 0..<Int(buffer.frameLength) where abs(data[i]) > peak {
                peak = abs(data[i])
            }
            self.peakLock.lock()
            self.recentPeak = max(self.recentPeak, peak)
            self.meter = max(peak, self.meter * 0.82)
            self.statTaps += 1
            self.peakLock.unlock()
        }
    }

    /// 取走并清零窗口峰值（BridgeModel 的诊断定时器每秒调用）
    func consumePeak() -> (peak: Float, engineRunning: Bool) {
        peakLock.lock()
        let value = recentPeak
        recentPeak = 0
        peakLock.unlock()
        return (value, engine.isRunning)
    }

    /// 界面电平条用的平滑值（不消费峰值，可随时读）。
    var meterLevel: Float {
        peakLock.lock()
        let value = meter
        peakLock.unlock()
        return value
    }

    var isRunning: Bool { engine.isRunning }

    /// 回环自检用：往当前设备灌一段 1 kHz 正弦波。
    func playTone(seconds: Double, frequency: Float = 1_000, amplitude: Float = 0.35) {
        let frames = AVAudioFrameCount(format.sampleRate * seconds)
        guard frames > 0,
              engine.isRunning,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let data = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = frames
        let rate = Float(format.sampleRate)
        for index in 0..<Int(frames) {
            data[index] = amplitude * sinf(2 * .pi * frequency * Float(index) / rate)
        }
        player.scheduleBuffer(buffer, completionHandler: nil)
        FileLog.write(
            "tone \(Int(frequency))Hz \(String(format: "%.1f", seconds))s → sink"
        )
    }

    /// 每秒取一次并清零：送进播放器的缓冲数、被丢的缓冲数、mixer 回调数。
    func takeStats() -> String {
        peakLock.lock()
        let line = "enq=\(statEnqueued) drop=\(statDropped) tap=\(statTaps)"
            + " run=\(engine.isRunning ? 1 : 0) play=\(player.isPlaying ? 1 : 0)"
        statEnqueued = 0
        statDropped = 0
        statTaps = 0
        peakLock.unlock()
        return line
    }

    /// 虚拟声卡可能被静音或音量为 0，信号虽在但谁都听不到；强制拉回。
    private static func ensureAudible(_ device: AudioDeviceInfo) {
        for element in [AudioObjectPropertyElement(kAudioObjectPropertyElementMain), 1, 2] {
            var mute: UInt32 = 0
            var muteAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: element
            )
            let size = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectHasProperty(device.id, &muteAddr) {
                AudioObjectSetPropertyData(device.id, &muteAddr, 0, nil, size, &mute)
            }
            var volume: Float32 = 1.0
            var volAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: element
            )
            let volSize = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectHasProperty(device.id, &volAddr) {
                AudioObjectSetPropertyData(device.id, &volAddr, 0, nil, volSize, &volume)
            }
        }
    }

    func enqueue(_ samples: [Int16]) {
        guard engine.isRunning, player.isPlaying,
              !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(samples.count)
              ) else {
            peakLock.lock()
            statDropped += 1
            peakLock.unlock()
            return
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        guard let destination = buffer.floatChannelData?[0] else { return }
        for index in 0..<samples.count {
            destination[index] = Float(samples[index]) / 32_768.0
        }
        player.scheduleBuffer(buffer, completionHandler: nil)
        peakLock.lock()
        statEnqueued += 1
        peakLock.unlock()
        if monitorActive, let copy = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ) {
            copy.frameLength = buffer.frameLength
            if let src = buffer.floatChannelData?[0], let dst = copy.floatChannelData?[0] {
                for i in 0..<Int(buffer.frameLength) { dst[i] = src[i] }
            }
            monitorPlayer.scheduleBuffer(copy, completionHandler: nil)
        }
    }

    func stop() {
        player.stop()
        engine.stop()
        monitorPlayer.stop()
        monitorEngine.stop()
    }
}
