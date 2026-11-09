import AVFoundation
import CoreAudio
import Foundation

/// One input channel: an AVAudioEngine bound to a specific device that reports
/// the peak of everything it receives.
final class ProbeChannel {
    let label: String
    let device: AudioDeviceInfo
    /// 非空时把这一路收到的内容写成 wav，用来试听"对方到底听到了什么"。
    let recordURL: URL?
    private var engine: AVAudioEngine?
    private var peak: Float = 0
    private var frames: [Int16] = []
    private var sampleRate: Double = 48_000
    private let lock = NSLock()

    init(label: String, device: AudioDeviceInfo, recordURL: URL? = nil) {
        self.label = label
        self.device = device
        self.recordURL = recordURL
    }

    var uid: String { device.uid }

    func start() -> Bool {
        let e = AVAudioEngine()
        var deviceID = device.id
        if let unit = e.inputNode.audioUnit {
            AudioUnitSetProperty(
                unit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &deviceID,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
        }
        let format = e.inputNode.inputFormat(forBus: 0)
        sampleRate = format.sampleRate
        let shouldRecord = recordURL != nil
        e.inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self, let data = buffer.floatChannelData?[0] else { return }
            var local: Float = 0
            for index in 0..<Int(buffer.frameLength) {
                let value = abs(data[index])
                if value > local { local = value }
            }
            self.lock.lock()
            self.peak = max(self.peak, local)
            if shouldRecord {
                for index in 0..<Int(buffer.frameLength) {
                    let sample = max(-1, min(1, data[index]))
                    self.frames.append(Int16(sample * 32_767))
                }
            }
            self.lock.unlock()
        }
        do {
            e.prepare()
            try e.start()
        } catch {
            FileLog.write("probe[\(label)] FAILED \(device.name): \(error.localizedDescription)")
            return false
        }
        engine = e
        FileLog.write(
            "probe[\(label)] start \(device.name) rate=\(Int(format.sampleRate))"
        )
        return true
    }

    func takePeak() -> Float {
        lock.lock()
        let value = peak
        peak = 0
        lock.unlock()
        return value
    }

    func stop() {
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
        if let url = recordURL {
            lock.lock()
            let captured = frames
            frames = []
            lock.unlock()
            Self.writeWav(url, samples: captured, sampleRate: sampleRate)
            FileLog.write("probe[\(label)] wrote \(captured.count) samples → \(url.path)")
        }
    }

    private static func writeWav(_ url: URL, samples: [Int16], sampleRate: Double) {
        let dataSize = samples.count * 2
        var data = Data()
        func append(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append("RIFF".data(using: .ascii)!)
        append(UInt32(36 + dataSize))
        data.append("WAVE".data(using: .ascii)!)
        data.append("fmt ".data(using: .ascii)!)
        append(16)
        append16(1)
        append16(1)
        append(UInt32(sampleRate))
        append(UInt32(sampleRate * 2))
        append16(2)
        append16(16)
        data.append("data".data(using: .ascii)!)
        append(UInt32(dataSize))
        for sample in samples {
            withUnsafeBytes(of: sample.littleEndian) { data.append(contentsOf: $0) }
        }
        try? data.write(to: url)
    }
}

/// Reads the chosen virtual device and the physical default input at the same
/// time: if the physical mic shows speech while the virtual device stays at
/// zero, the loopback (or the permission to record it) is the problem.
final class MicProbe {
    static let shared = MicProbe()

    private var channels: [ProbeChannel] = []
    private var timer: Timer?

    var isRunning: Bool { !channels.isEmpty }

    func start(device: AudioDeviceInfo?, seconds: TimeInterval = 12, record: Bool = false) {
        stop()
        var list: [ProbeChannel] = []
        let url = record
            ? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs/VibeDeck-virtualmic.wav")
            : nil
        if let device {
            list.append(ProbeChannel(label: "dev", device: device, recordURL: url))
        }
        if !record, let mic = defaultInputDevice(), mic.uid != device?.uid {
            list.append(ProbeChannel(label: "mic", device: mic))
        }
        channels = list.filter { $0.start() }
        guard !channels.isEmpty else {
            FileLog.write("probe: nothing started")
            return
        }
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            let parts = self.channels.map {
                "\($0.label)=\(String(format: "%.3f", $0.takePeak()))"
            }
            FileLog.write("probe " + parts.joined(separator: " "))
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            self?.stop()
        }
    }

    func stop() {
        guard !channels.isEmpty else { return }
        timer?.invalidate()
        timer = nil
        for channel in channels { channel.stop() }
        channels = []
        FileLog.write("probe stop")
    }
}
