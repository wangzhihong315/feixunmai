import AppKit
import CoreGraphics
import Foundation

/// 一段 16 kHz 单声道 PCM。
struct WavData {
    let samples: [Int16]
    let sampleRate: Int
}

/// 读手机录的 WAV（16-bit PCM）。采样率不是 16 kHz 时做一次线性重采样，
/// 保证喂给 AudioSink 的格式和语音链路一致。
enum WavReader {
    static func load(url: URL) -> WavData? {
        guard let data = try? Data(contentsOf: url), data.count > 44 else {
            return nil
        }
        let bytes = [UInt8](data)

        func u16(_ offset: Int) -> UInt16 {
            UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
        }
        func u32(_ offset: Int) -> UInt32 {
            UInt32(bytes[offset]) |
                (UInt32(bytes[offset + 1]) << 8) |
                (UInt32(bytes[offset + 2]) << 16) |
                (UInt32(bytes[offset + 3]) << 24)
        }
        func tag(_ offset: Int) -> String {
            String(bytes: bytes[offset..<(offset + 4)], encoding: .ascii) ?? ""
        }

        guard tag(0) == "RIFF", tag(8) == "WAVE" else { return nil }

        var sampleRate = 0
        var channels = 1
        var bits = 16
        var pcmOffset = -1
        var pcmLength = 0
        var offset = 12
        while offset + 8 <= bytes.count {
            let id = tag(offset)
            let size = Int(u32(offset + 4))
            let body = offset + 8
            if id == "fmt " {
                guard size >= 16, body + 16 <= bytes.count else { return nil }
                let format = u16(body)
                channels = Int(u16(body + 2))
                sampleRate = Int(u32(body + 4))
                bits = Int(u16(body + 14))
                guard format == 1, bits == 16, channels >= 1 else { return nil }
            } else if id == "data" {
                pcmOffset = body
                pcmLength = min(size, bytes.count - body)
                break
            }
            offset = body + size + (size & 1)
        }
        guard pcmOffset >= 0, sampleRate > 0, pcmLength >= 2 else { return nil }

        let frameCount = pcmLength / 2
        let frameBytesPer = max(1, channels)
        let monoCount = frameCount / frameBytesPer
        guard monoCount > 0 else { return nil }
        var mono = [Int16](repeating: 0, count: monoCount)
        var source = pcmOffset
        for index in 0..<monoCount {
            var sum = 0
            for _ in 0..<channels {
                let raw = UInt16(bytes[source]) | (UInt16(bytes[source + 1]) << 8)
                sum += Int(Int16(bitPattern: raw))
                source += 2
            }
            mono[index] = Int16(clamping: sum / channels)
        }

        let targetRate = 16_000
        var samples = mono
        if sampleRate != targetRate {
            let ratio = Double(sampleRate) / Double(targetRate)
            let outCount = Int(Double(monoCount) / ratio)
            guard outCount > 0 else { return nil }
            var out = [Int16](repeating: 0, count: outCount)
            for i in 0..<outCount {
                let position = Double(i) * ratio
                let low = min(monoCount - 1, Int(position))
                let high = min(monoCount - 1, low + 1)
                let t = Float(position - Double(low))
                let value = Float(mono[low]) * (1 - t) + Float(mono[high]) * t
                out[i] = Int16(clamping: Int(value))
            }
            samples = out
        }
        // 上限 90 秒，防止坏文件把内存吃满。
        let limit = targetRate * 90
        if samples.count > limit {
            samples = Array(samples.prefix(limit))
        }
        return WavData(samples: samples, sampleRate: targetRate)
    }
}

/// 转写时接收豆包输入的小浮窗：拿到焦点，豆包把中文打进来，我们再读走。
final class CapsuleHUD: NSPanel {
    static let shared = CapsuleHUD()

    private let textView = NSTextView()
    private let titleLabel = NSTextField(labelWithString: "正在转写闪念胶囊…")
    private let hintLabel = NSTextField(labelWithString: "豆包输入法正在识别录音，请稍候")

    private init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 190),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 190))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 0.96).cgColor
        container.layer?.cornerRadius = 18

        titleLabel.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = NSColor.white.withAlphaComponent(0.95)
        titleLabel.frame = NSRect(x: 24, y: 150, width: 512, height: 20)

        hintLabel.font = NSFont.systemFont(ofSize: 11)
        hintLabel.textColor = NSColor.white.withAlphaComponent(0.38)
        hintLabel.frame = NSRect(x: 24, y: 130, width: 512, height: 16)

        textView.frame = NSRect(x: 22, y: 16, width: 516, height: 102)
        textView.isEditable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.textColor = .white
        textView.insertionPointColor = .white
        textView.font = NSFont.systemFont(ofSize: 17)
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        textView.textContainerInset = NSSize(width: 0, height: 4)

        container.addSubview(titleLabel)
        container.addSubview(hintLabel)
        container.addSubview(textView)
        contentView = container
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    var text: String { textView.string }

    func present() {
        textView.string = ""
        // 多显示器：放在鼠标所在的那块屏，用户才看得到（之前放在
        // NSScreen.main 会跑到另一块屏上，字幕窗口像是没弹出来）。
        if let screen = targetScreen() {
            let visible = screen.visibleFrame
            setFrameOrigin(NSPoint(
                x: visible.midX - frame.width / 2,
                y: visible.maxY - frame.height - 72
            ))
        }
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
        makeFirstResponder(textView)
    }

    func dismiss() {
        orderOut(nil)
    }

    private func targetScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first {
            NSMouseInRect(mouse, $0.frame, false)
        } ?? NSScreen.main ?? NSScreen.screens.first
    }
}

/// 胶囊转写队列：
///
///  1. 只有 Mac 连续 8 秒没有键鼠输入时才启动（可以在打字/操作时不打扰）；
///  2. 切系统默认输入到虚拟麦 → 重建 AudioSink → 按住语音键 → 把 WAV 播进虚拟麦；
///  3. 豆包输入法把识别结果打进浮窗，浮窗内容稳定后收字、落盘、回传手机；
///  4. 转写途中一旦检测到真实键鼠输入（HID 层），立刻松键、恢复输入和焦点，
///     胶囊保持待转写，等下次空闲重试。
final class CapsuleTranscriber {
    static let shared = CapsuleTranscriber()

    private let hud = CapsuleHUD.shared
    private let keyDriver = VoiceKeyDriver(mode: .fnHold, tapToggle: false)
    private var timer: Timer?
    private var pollTimer: Timer?
    private var active = false
    private var cooldownUntil = Date.distantPast
    private var current: CapsuleMeta?
    private var previousApp: NSRunningApplication?
    /// 自己合成的语音键事件可能短暂重置 HID 空闲计时，按下前后设一个豁免窗。
    private var ignoreInputUntil = Date.distantPast

    private init() {}

    func start() {
        NotificationCenter.default.addObserver(
            forName: CapsuleStoreMac.storedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.cooldownUntil = .distantPast
        }
        timer?.invalidate()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        FileLog.write("capsule transcriber started (idle=\(Int(idleSeconds))s)")
    }

    private var idleSeconds: TimeInterval {
        let value = UserDefaults.standard.double(forKey: "capsuleIdleSeconds")
        return value > 0 ? value : 8
    }

    /// 桌面端"空闲时自动转写"开关。
    private var automationEnabled: Bool {
        (UserDefaults.standard.object(forKey: "capsuleAutoTranscribe") as? Bool) ?? true
    }

    /// HID 层（真实硬件）的空闲时间：合成事件不会重置它，所以自己的
    /// 语音键和 Fake 输入不会误判成"用户在操作"。
    private func hardwareIdle() -> TimeInterval {
        let types: [CGEventType] = [
            .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown,
            .mouseMoved, .scrollWheel
        ]
        let seconds = types.map {
            CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0)
        }
        return seconds.min() ?? 9_999
    }

    private func tick(manual: Bool = false) {
        guard !active else { return }
        if !manual, !automationEnabled { return }
        guard manual || Date() >= cooldownUntil else { return }
        guard !PhoneVoiceSession.shared.active, !BridgeModel.shared.voiceActive else {
            return
        }
        if !manual, hardwareIdle() < idleSeconds { return }
        guard let capsule = CapsuleStoreMac.shared
            .pendingTranscription(includeExhausted: manual).first else {
            return
        }
        guard let wav = WavReader.load(url: CapsuleStoreMac.shared.audioURL(capsule.id)),
              !wav.samples.isEmpty else {
            FileLog.write("capsule wav unreadable \(capsule.id)")
            cooldownUntil = Date().addingTimeInterval(30)
            return
        }
        if manual {
            CapsuleStoreMac.shared.resetAttempts(for: capsule.id)
        }
        begin(capsule, wav: wav)
    }

    private func begin(_ capsule: CapsuleMeta, wav: WavData) {
        active = true
        current = capsule
        previousApp = NSWorkspace.shared.frontmostApplication
        hud.present()

        let mode = BridgeModel.shared.voiceKeyMode
        keyDriver.mode = (mode == .nativeF5 || mode == .none) ? .fnHold : mode
        keyDriver.tapToggle = false
        keyDriver.refreshPermission()

        // 顺序和手机语音一致：先切输入，再重建 sink，最后按语音键。
        if BridgeModel.shared.autoSwitchInput, let target = virtualDevice() {
            SystemInputSwitcher.shared.begin(owner: .capsule, target: target)
        }
        AudioSinkRouter.shared.rebuild(
            device: BridgeModel.shared.chosenDevice(),
            monitor: false
        )
        FileLog.write(
            "capsule transcribe begin \(capsule.id) \(wav.samples.count) samples sink=\(AudioSinkRouter.shared.describe)"
        )

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.active else { return }
            self.ignoreInputUntil = Date().addingTimeInterval(1.2)
            self.keyDriver.voiceStarted()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let self, self.active else { return }
                self.play(wav, capsule: capsule)
            }
        }
    }

    private func play(_ wav: WavData, capsule: CapsuleMeta) {
        // 和实时链路相同的入队粒度（200 ms 一块），一次排完由播放器顺序播。
        let chunk = 3_200
        var index = 0
        while index < wav.samples.count {
            let end = min(index + chunk, wav.samples.count)
            AudioSinkRouter.shared.enqueue(Array(wav.samples[index..<end]))
            index = end
        }
        let duration = Double(wav.samples.count) / Double(wav.sampleRate)
        FileLog.write(
            "capsule audio queued \(capsule.id) \(String(format: "%.2f", duration))s"
        )
        startPolling(audioEnd: Date().addingTimeInterval(duration + 0.3))
    }

    private func startPolling(audioEnd: Date) {
        var lastText = ""
        var textChangedAt = Date()
        let started = Date()
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in
            guard let self, self.active else { return }
            let now = Date()

            // 真实键鼠一动就回滚，别抢用户的操作。
            if now > self.ignoreInputUntil, self.hardwareIdle() < 0.4 {
                FileLog.write("capsule transcribe abort: user input")
                self.finish(text: nil, failure: .userInput)
                return
            }
            if PhoneVoiceSession.shared.active || BridgeModel.shared.voiceActive {
                FileLog.write("capsule transcribe abort: voice session started")
                self.finish(text: nil, failure: .voiceConflict)
                return
            }
            guard now >= audioEnd else { return }

            let text = self.hud.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text != lastText {
                lastText = text
                textChangedAt = now
            }
            if !text.isEmpty, now.timeIntervalSince(textChangedAt) > 0.7 {
                self.finish(text: text, failure: nil)
            } else if text.isEmpty, now.timeIntervalSince(audioEnd) > 5 {
                FileLog.write("capsule transcribe no text")
                self.finish(text: nil, failure: .noText)
            } else if now.timeIntervalSince(started) > 20 {
                if text.isEmpty {
                    self.finish(text: nil, failure: .noText)
                } else {
                    self.finish(text: text, failure: nil)
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private enum Failure {
        /// 用户动了键鼠，立刻回滚（不记失败次数，稍后再试）。
        case userInput
        /// 手机语音会话插进来，让路（不记失败次数）。
        case voiceConflict
        /// 播完了但没有出字（豆包没识别/输入法不对），记一次失败并退避。
        case noText
    }

    private func finish(text: String?, failure: Failure?) {
        pollTimer?.invalidate()
        pollTimer = nil
        guard active else { return }
        active = false

        keyDriver.forceRelease()
        SystemInputSwitcher.shared.end(owner: .capsule)
        AudioSinkRouter.shared.rebuild(
            device: BridgeModel.shared.chosenDevice(),
            monitor: BridgeModel.shared.monitorEnabled
        )
        hud.dismiss()

        let capsule = current
        current = nil
        let interrupted = failure == .userInput || failure == .voiceConflict
        if let text, !text.isEmpty, let capsule {
            CapsuleStoreMac.shared.setText(text, for: capsule.id)
            VoiceTCPServer.shared.broadcastCapsuleText(id: capsule.id, text: text)
            FileLog.write("capsule transcribed \(capsule.id) \(text.count)字")
        } else {
            if let capsule, failure == .noText {
                let attempts = CapsuleStoreMac.shared.incrementAttempts(for: capsule.id)
                let backoff = min(120.0, 15.0 * pow(2.0, Double(max(0, attempts - 1))))
                cooldownUntil = Date().addingTimeInterval(backoff)
                FileLog.write(
                    "capsule retry \(capsule.id) attempt=\(attempts) backoff=\(Int(backoff))s"
                )
            } else {
                cooldownUntil = Date().addingTimeInterval(8)
            }
            FileLog.write(
                "capsule transcribe pending \(capsule?.id ?? "-") failure=\(String(describing: failure))"
            )
        }

        // 收字失败或被用户打断时，焦点已经在用户手里，不要再抢回来。
        let front = NSWorkspace.shared.frontmostApplication
        let ours = Bundle.main.bundleIdentifier
        if !interrupted || front?.bundleIdentifier == ours {
            if let app = previousApp, app.bundleIdentifier != ours {
                app.activate(options: [.activateIgnoringOtherApps])
            }
        }
        previousApp = nil
    }

    /// 立即转写：传 id 转写指定胶囊，不传则取最早待转写的一条。
    func transcribeNow(id: String? = nil) {
        guard !active else { return }
        cooldownUntil = .distantPast
        if let id {
            guard let capsule = CapsuleStoreMac.shared.meta(id: id),
                  (capsule.text ?? "").isEmpty else { return }
            guard let wav = WavReader.load(url: CapsuleStoreMac.shared.audioURL(id)),
                  !wav.samples.isEmpty else {
                FileLog.write("capsule wav unreadable \(id)")
                return
            }
            CapsuleStoreMac.shared.resetAttempts(for: id)
            begin(capsule, wav: wav)
        } else {
            tick(manual: true)
        }
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
