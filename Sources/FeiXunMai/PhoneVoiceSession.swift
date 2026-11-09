import Foundation
import ApplicationServices

enum PhoneTransport: String {
    case ble = "蓝牙"
    case wifi = "Wi-Fi"
}

/// 与传输无关的语音会话：首包门槛、触发键、系统默认输入切换、AudioSink
/// 重建、静音看门狗、统计。
///
/// BLE 与 Wi-Fi 两条链路共用这一份时序——之前最容易出问题的就是"两套逻辑
/// 各写一遍"，所以 TCP 只是换了个数据来源，其余完全一致。
final class PhoneVoiceSession {
    static let shared = PhoneVoiceSession()

    private(set) var owner: PhoneTransport?
    private(set) var active = false
    private(set) var keySent = false

    private let voiceKeyDriver = VoiceKeyDriver(mode: .fnHold, tapToggle: false)
    private var gateBuffer: [[Int16]] = []
    private var sessionFirstAudio: Date?
    private var sessionStart: Date?
    private var lastAudio = Date()
    private var watchdog: Timer?

    private init() {}

    var transportName: String {
        owner?.rawValue ?? "未启用"
    }

    private var keyMode: VoiceKeyMode {
        let mode = BridgeModel.shared.voiceKeyMode
        return (mode == .nativeF5 || mode == .none) ? .fnHold : mode
    }

    /// 返回 true 表示这次开始被接受（或本来就是同一传输的会话）。
    @discardableResult
    func begin(from transport: PhoneTransport) -> Bool {
        if active { return owner == transport }
        active = true
        owner = transport
        keySent = false
        gateBuffer.removeAll()
        sessionFirstAudio = nil
        sessionStart = nil
        lastAudio = Date()
        AudioSinkRouter.shared.configure(
            device: BridgeModel.shared.chosenDevice(),
            monitor: BridgeModel.shared.monitorEnabled
        )
        voiceKeyDriver.mode = keyMode
        voiceKeyDriver.tapToggle = false
        voiceKeyDriver.refreshPermission()
        startWatchdog()
        FileLog.write(
            "session start [\(transport.rawValue)] · sink=\(AudioSinkRouter.shared.describe) key=\(keyMode.rawValue)"
        )
        return true
    }

    func ingest(_ samples: [Int16], from transport: PhoneTransport) {
        guard active, owner == transport, !samples.isEmpty else { return }
        lastAudio = Date()
        if keySent {
            AudioSinkRouter.shared.enqueue(samples)
            return
        }
        if sessionFirstAudio == nil {
            sessionFirstAudio = Date()
        }
        gateBuffer.append(samples)
        let total = gateBuffer.reduce(0) { $0 + $1.count }
        if total > 16_000 {
            gateBuffer.removeFirst(max(0, gateBuffer.count - 1))
        }
        if let first = sessionFirstAudio,
           Date().timeIntervalSince(first) >= 0.15 {
            keySent = true
            beginVoice()
            for chunk in gateBuffer {
                AudioSinkRouter.shared.enqueue(chunk)
            }
            gateBuffer.removeAll()
        }
    }

    func end(force: Bool, from transport: PhoneTransport? = nil) {
        guard active else { return }
        if let transport, owner != transport { return }
        active = false
        gateBuffer.removeAll()
        sessionFirstAudio = nil
        let hadKey = keySent
        keySent = false
        if hadKey {
            if force {
                voiceKeyDriver.forceRelease()
                SystemInputSwitcher.shared.end(owner: .phone)
            } else {
                voiceKeyDriver.voiceStopped()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    SystemInputSwitcher.shared.end(owner: .phone)
                }
            }
            if let start = sessionStart {
                BridgeModel.shared.recordVoiceSession(seconds: Date().timeIntervalSince(start))
            }
        }
        sessionStart = nil
        BridgeModel.shared.voiceActive = false
        FileLog.write(
            "session end [\(owner?.rawValue ?? "-")] force=\(force ? 1 : 0) hadKey=\(hadKey ? 1 : 0)"
        )
        owner = nil
    }

    /// 数据源侧的存活检查：超过 1 秒没有音频就强制收尾。
    func noteLinkActive(from transport: PhoneTransport) {
        if active, owner == transport {
            lastAudio = Date()
        }
    }

    private func beginVoice() {
        sessionStart = Date()
        // 顺序关键：先切系统默认输入，再按触发键。输入法在按键瞬间取设备。
        if BridgeModel.shared.autoSwitchInput, let target = virtualDevice() {
            SystemInputSwitcher.shared.begin(owner: .phone, target: target)
        } else {
            FileLog.write("input switch skipped (auto=\(BridgeModel.shared.autoSwitchInput))")
        }
        // 切默认输入会让虚拟声卡的输出绑定失效：引擎 running、mixer 有电平，
        // 但设备收不到（docs/经验教训.md 第四条）。每次会话重建一次。
        AudioSinkRouter.shared.rebuild(
            device: BridgeModel.shared.chosenDevice(),
            monitor: BridgeModel.shared.monitorEnabled
        )
        BridgeModel.shared.voiceActive = true
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.active else { return }
            self.voiceKeyDriver.voiceStarted()
            FileLog.write(
                "key down mode=\(self.keyMode.rawValue) AX=\(AXIsProcessTrusted() ? 1 : 0)"
                    + " gate=\(String(format: "%.0fms", Date().timeIntervalSince(self.sessionFirstAudio ?? Date()) * 1000))"
            )
        }
        pendingKeyDown?.cancel()
        pendingKeyDown = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    private var pendingKeyDown: DispatchWorkItem?

    private func startWatchdog() {
        watchdog?.invalidate()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard self.active, self.keySent else { return }
            if Date().timeIntervalSince(self.lastAudio) > 1.0 {
                FileLog.write("session silence timeout [\(self.owner?.rawValue ?? "-")]")
                self.end(force: true)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }

    private func virtualDevice() -> AudioDeviceInfo? {
        if let chosen = BridgeModel.shared.chosenDevice(),
           chosen.name.localizedCaseInsensitiveContains("FeiXunV")
            || chosen.name.localizedCaseInsensitiveContains("BlackHole") {
            return chosen
        }
        return BridgeModel.shared.audioDevices.first {
            $0.name.localizedCaseInsensitiveContains("FeiXunV")
        } ?? BridgeModel.shared.audioDevices.first {
            $0.name.localizedCaseInsensitiveContains("BlackHole")
        }
    }
}
