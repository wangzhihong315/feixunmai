import Foundation
import CoreGraphics
import ApplicationServices
import AppKit

/// Emulates a trigger key for the duration of a voice session so that
/// voice-input apps (豆包、微信输入法、听写…) start listening when the remote
/// voice key is held, same trick SayAll uses for the Xiaomi remote.
enum VoiceKeyMode: String, CaseIterable, Identifiable {
    /// 零注入：语音键的 F5 (kc=96) 是遥控器硬件原生 HID 事件，直接作为
    /// 语音应用的触发键（对齐 remote 的 Fn 硬件模式）。实测端到端出字。
    case nativeF5 = "原生 F5 直连（仅限快捷键=F5 的工具）"
    case fnHold = "Fn 长按（合成）"
    case leftCommand = "左 Command ⌘ 长按（合成）"
    case rightCommand = "右 Command ⌘ 长按（合成）"
    case leftOption = "左 Option ⌥ 长按（合成）"
    case rightOption = "右 Option ⌥ 长按（合成）"
    case none = "不发送（仅采集声音）"

    var id: String { rawValue }

    var keyCode: CGKeyCode? {
        switch self {
        case .nativeF5, .none: return nil
        case .fnHold: return 63
        case .leftCommand: return 55
        case .rightCommand: return 54
        case .leftOption: return 58
        case .rightOption: return 61
        }
    }

    /// 合成模式需要吞掉 F5 回声（kc=96）；原生 F5 模式必须放行（它就是触发键）
    var needsEchoSwallow: Bool {
        keyCode != nil
    }

    /// 真实修饰键按下时携带的标志位（对齐 remote 的 VoiceKeyMode.eventFlags）：
    /// 除修饰键位外还要带设备侧左右标志，应用靠它区分左/右键。
    var flags: CGEventFlags {
        switch self {
        case .nativeF5, .none: return []
        case .fnHold: return .maskSecondaryFn
        case .leftCommand: return [.maskCommand, CGEventFlags(rawValue: 0x08)]   // NX_DEVICELCMDKEYMASK
        case .rightCommand: return [.maskCommand, CGEventFlags(rawValue: 0x10)]  // NX_DEVICERCMDKEYMASK
        case .leftOption: return [.maskAlternate, CGEventFlags(rawValue: 0x40)]  // NX_DEVICELALTKEYMASK
        case .rightOption: return [.maskAlternate, CGEventFlags(rawValue: 0x20)] // NX_DEVICERALTKEYMASK
        case .none: return []
        }
    }
}

final class VoiceKeyDriver {
    private(set) var accessibilityGranted = AXIsProcessTrusted()

    var mode: VoiceKeyMode
    /// true = 按一下开始、再按一下结束（配豆包等开关式语音工具）；
    /// false = 按住期间保持按下（配长按式语音工具）。
    var tapToggle: Bool
    private var pendingEnd: DispatchWorkItem?

    init(mode: VoiceKeyMode, tapToggle: Bool) {
        self.mode = mode
        self.tapToggle = tapToggle
    }

    func refreshPermission() {
        accessibilityGranted = AXIsProcessTrusted()
    }

    func voiceStarted() {
        pendingEnd?.cancel()
        pendingEnd = nil
        if Diag.on { NSLog("斐讯麦[diag] voiceStarted mode=%@ AX=%d", mode.rawValue, AXIsProcessTrusted() ? 1 : 0) }
        guard let keyCode = mode.keyCode else { return }
        if tapToggle {
            tap(keyCode)
        } else {
            post(keyCode, down: true)
        }
    }

    func voiceStopped() {
        guard let keyCode = mode.keyCode else { return }
        // 稍等音频尾巴排空再发结束事件，避免最后几个字被掐掉
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.tapToggle {
                self.tap(keyCode)
            } else {
                self.post(keyCode, down: false)
            }
            self.pendingEnd = nil
        }
        pendingEnd?.cancel()
        pendingEnd = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private func tap(_ keyCode: CGKeyCode) {
        post(keyCode, down: true)
        post(keyCode, down: false)
    }

    private func post(_ keyCode: CGKeyCode, down: Bool) {
        guard let event = CGEvent(
            keyboardEventSource: nil,
            virtualKey: keyCode,
            keyDown: down
        ) else { return }
        // 对齐 remote（KeyboardInjector.swift:244）：
        // 按下带完整标志位，松开必须发空 flags，否则系统认为修饰键仍按着
        if down {
            let flags = mode.flags
            if !flags.isEmpty { event.flags = flags }
        }
        event.post(tap: .cghidEventTap)
    }

    static func openAccessibilitySettings() {
        if let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) {
            NSWorkspace.shared.open(url)
        }
    }
}
