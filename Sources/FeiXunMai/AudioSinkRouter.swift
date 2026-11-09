import Foundation

/// Owns the single AudioSink used by every voice source.
///
/// The remote path used to create a second AudioSink during the startup
/// migration (the `selectedDeviceUID.didSet` rebuild plus the explicit
/// creation in `start()`), which produced two AVAudioEngines feeding the same
/// virtual device. Routing every source through this object guarantees one
/// engine, one monitor path, and one device selection.
final class AudioSinkRouter {
    static let shared = AudioSinkRouter()

    private(set) var device: AudioDeviceInfo?
    private(set) var monitor = true
    private var sink: AudioSink?

    private init() {}

    func configure(device: AudioDeviceInfo?, monitor: Bool) {
        if sink != nil, self.device == device, self.monitor == monitor {
            return
        }
        rebuild(device: device, monitor: monitor)
    }

    func rebuild(device: AudioDeviceInfo?, monitor: Bool) {
        sink?.stop()
        sink = nil
        self.device = device
        self.monitor = monitor
        do {
            sink = try AudioSink(device: device, monitor: monitor)
            FileLog.write(
                "sink rebuilt → \(device?.name ?? "系统默认") monitor=\(monitor ? 1 : 0)"
            )
            if Diag.on {
                NSLog(
                    "VibeDeck[diag] sink rebuilt → %@ monitor=%d",
                    device?.name ?? "系统默认",
                    monitor ? 1 : 0
                )
            }
        } catch {
            sink = nil
            FileLog.write(
                "sink FAILED → \(device?.name ?? "系统默认"): \(String(describing: error))"
            )
            NSLog(
                "VibeDeck[diag] sink FAILED for %@: %@",
                device?.name ?? "系统默认",
                String(describing: error)
            )
        }
    }

    func enqueue(_ samples: [Int16]) {
        guard !samples.isEmpty else { return }
        sink?.enqueue(samples)
    }

    /// 一行诊断：引擎是否真的在跑、输出到哪个设备。
    var describe: String {
        guard let sink else { return "none" }
        return "\(device?.name ?? "系统默认")\(sink.isRunning ? "" : "(stopped)")"
    }

    var meterLevel: Float {
        sink?.meterLevel ?? 0
    }

    func takeStats() -> String {
        sink?.takeStats() ?? "none"
    }

    func playTone(seconds: Double) {
        sink?.playTone(seconds: seconds)
    }

    func shutdown() {
        sink?.stop()
        sink = nil
        device = nil
    }
}
