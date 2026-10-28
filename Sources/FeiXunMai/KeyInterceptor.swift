import Foundation
import CoreGraphics
import AppKit

/// tap 专用线程使用的不可变规则快照（主线程更新，NSLock 保护读取）
struct EventRules {
    var swallowVoiceKeyEcho: Bool = false
    var arrowsAsMouse: Bool = false
    var mappings: [String: KeyAction] = [:]
}

/// 精简版按键动作：比 SayAll 的三段手势/按 App 方案简单得多。
enum KeyAction: String, CaseIterable, Identifiable {
    case system = "system"
    case none = "none"
    case enter = "enter"
    case esc = "esc"
    case copy = "copy"
    case paste = "paste"
    case leftClick = "leftClick"
    case rightClick = "rightClick"
    case missionControl = "missionControl"
    case lockScreen = "lockScreen"
    case deleteBack = "deleteBack"

    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: return "系统默认"
        case .none: return "屏蔽（无动作）"
        case .enter: return "回车"
        case .esc: return "Esc"
        case .copy: return "复制 ⌘C"
        case .paste: return "粘贴 ⌘V"
        case .leftClick: return "鼠标左键（按住可拖动）"
        case .rightClick: return "鼠标右键"
        case .missionControl: return "调度中心"
        case .lockScreen: return "锁屏"
        case .deleteBack: return "删除（退格，按住连删）"
        }
    }

    /// 四个命令键的推荐默认值（设计文档《按键设计.md》）
    static func recommendedDefault(for button: MappedButton, mouseMode: Bool) -> KeyAction {
        switch button {
        case .home: return .esc
        case .back: return .deleteBack
        case .menu: return .enter
        case .ott: return .paste
        case .ok: return mouseMode ? .leftClick : .system
        }
    }
}

enum MappedButton: String, CaseIterable, Identifiable {
    // 顺序对应实物布局（从上到下）：OTT电源 → OK → 菜单 → 返回 → 主页
    case ott, ok, menu, back, home

    var id: String { rawValue }
    var label: String {
        switch self {
        case .home: return "主页"
        case .back: return "返回"
        case .menu: return "菜单"
        case .ok: return "OK"
        case .ott: return "OTT 电源"
        }
    }

    // 有 mac 原生键码的键（经 CGEventTap 布防拦截）
    static let keyCode: [Int64: MappedButton] = [36: .ok]
    // 消费键 usage（0x0C 页，经 systemDefined 布防拦截）
    static let consumerUsage: [UInt32: MappedButton] = [
        0x0223: .home, 0x0224: .back, 0x0040: .menu,
    ]
}

/// CGEventTap 拦截器：**只处理被 ButtonMonitor 布防的键事件**（即确证来自
/// 遥控器的），真键盘的同键码按键（回车/方向键/F5…）不被布防、永远直通。
/// 拦截后按映射执行动作。需要辅助功能 + 输入监控权限。
final class KeyInterceptor {
    static let shared = KeyInterceptor()
    static let systemDefined = CGEventType(rawValue: 14)!  // kCGEventSystemDefined

    private var tap: CFMachPort?
    private(set) var tapActive = false

    // 布防窗口（ButtonMonitor 与 tap 回调都在主 runloop，无并发问题）
    private static var armedKeyboard: [UInt64: Date] = [:]
    private static var armedConsumer: [UInt32: Date] = [:]
    private static var heldKeyboardMacKeys: Set<UInt64> = []
    private static var heldConsumerUsage: UInt32?

    // MARK: - 布防接口（ButtonMonitor 调用）

    static func armKeyboard(_ keycode: UInt64, seconds: Double) {
        armedKeyboard[keycode] = Date().addingTimeInterval(seconds)
    }

    static func armConsumer(_ usage: UInt32, seconds: Double) {
        armedConsumer[usage] = Date().addingTimeInterval(seconds)
    }

    static func markHeldKeyboardKey(_ keycode: UInt64) {
        heldKeyboardMacKeys.insert(keycode)
    }

    static func clearHeldKeyboardKeys() {
        heldKeyboardMacKeys.removeAll()
    }

    static func sharedHeldKeyboardKeys() -> Set<UInt64> {
        heldKeyboardMacKeys
    }

    static func setHeldConsumerUsage(_ usage: UInt32?) {
        heldConsumerUsage = usage
    }

    static func sharedHeldConsumerUsage() -> UInt32? {
        heldConsumerUsage
    }

    private static func isArmedKeyboard(_ keycode: UInt64) -> Bool {
        armedKeyboard[keycode].map { $0 > Date() } ?? false
    }

    private static func isArmedConsumer(_ usage: UInt32) -> Bool {
        armedConsumer[usage].map { $0 > Date() } ?? false
    }

    // MARK: - 生命周期

    func start() {
        // 隔离实验开关：defaults write com.feixun.mai disableInterceptor -bool YES
        if UserDefaults.standard.bool(forKey: "disableInterceptor") {
            NSLog("斐讯麦[diag] interceptor DISABLED by switch")
            return
        }
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << Self.systemDefined.rawValue)
        // 必须用会话层 tap：systemDefined（消费键）事件只在会话层存在，
        // HID 层（cghidEventTap）的 tap 永远收不到——对齐 remote 的 suppressor。
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: tapCallback,
            userInfo: nil
        ) else {
            tapActive = false
            return
        }
        self.tap = tap
        NSLog("斐讯麦[BOOT] tap created, AX=%d, mapping mode on", AXIsProcessTrusted() ? 1 : 0)
        // 关键：tap 必须挂在专用线程的 RunLoop 上。挂主线程的话，
        // 应用在后台被 AppNap 挂起时，切回前台的头几秒事件全被吞掉。
        tapRunLoopThread = Thread { [weak self] in
            guard let self else { return }
            let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .defaultMode)
            CGEvent.tapEnable(tap: tap, enable: true)
            self.tapActive = true
            RunLoop.current.run()
        }
        tapRunLoopThread?.name = "feixunmai-eventtap"
        tapRunLoopThread?.stackSize = 256 * 1024
        tapRunLoopThread?.start()
    }

    private var tapRunLoopThread: Thread?

    // MARK: - 动作执行

    static func apply(button: MappedButton, isDown: Bool, rules: EventRules) {
        let action = rules.mappings[button.rawValue]
            ?? KeyAction.recommendedDefault(for: button, mouseMode: rules.arrowsAsMouse)
        guard action != .system else { return }
        switch action {
        case .leftClick:
            postMouseClick(down: isDown, button: .left)
        case .rightClick:
            postMouseClick(down: isDown, button: .right)
        case .deleteBack:
            // 遥控器按住不产生系统自动重复（E2 实测），连删自己驱动
            if isDown {
                startDeleteRepeat()
            } else {
                stopDeleteRepeat()
            }
        default:
            if isDown && action != .none {
                perform(action)
            }
        }
    }

    fileprivate static func handle(event: CGEvent, type: CGEventType) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            CGEvent.tapEnable(tap: shared.tap!, enable: true)
            return Unmanaged.passUnretained(event)
        }

        let model = BridgeModel.shared
        model.rulesLock.lock()
        let rules = model.eventRules
        model.rulesLock.unlock()

        if type == .keyDown || type == .keyUp {
            let keycode = event.getIntegerValueField(.keyboardEventKeycode)
            guard isArmedKeyboard(UInt64(bitPattern: keycode)) else {
                return Unmanaged.passUnretained(event)  // 真键盘直通
            }
            let isDown = type == .keyDown
            if keycode == 96 {
                // 合成模式：F5 是语音键回声，吞掉防干扰；原生 F5 模式：放行（触发键）
                if rules.swallowVoiceKeyEcho { return nil }
                return Unmanaged.passUnretained(event)
            }
            if rules.arrowsAsMouse, let arrow = MouseMover.arrowKeyCodes[keycode] {
                DispatchQueue.main.async {
                    if isDown {
                        MouseMover.shared.press(arrow)
                    } else {
                        MouseMover.shared.release(arrow)
                    }
                }
                return nil
            }
            if let button = MappedButton.keyCode[keycode] {
                apply(button: button, isDown: isDown, rules: rules)
                return nil
            }
            return Unmanaged.passUnretained(event)
        }

        if type == Self.systemDefined,
           let nsEvent = NSEvent(cgEvent: event),
           nsEvent.subtype.rawValue == 8 {
            let data1 = nsEvent.data1
            let usage = UInt32((data1 & 0xFFFF_0000) >> 16)
            let state = (data1 & 0xFF00) >> 8
            let isDown = state == 0x0A
            let armed = isArmedConsumer(usage)
            NSLog("斐讯麦[CHAIN] tap systemDefined usage=0x%04x down=%d armed=%d", usage, isDown ? 1 : 0, armed ? 1 : 0)
            guard armed, let button = MappedButton.consumerUsage[usage] else {
                return Unmanaged.passUnretained(event)
            }
            NSLog("斐讯麦[CHAIN] apply %@ isDown=%d", button.rawValue, isDown ? 1 : 0)
            apply(button: button, isDown: isDown, rules: rules)
            return nil
        }

        return Unmanaged.passUnretained(event)
    }

    private static func postMouseClick(down: Bool, button: CGMouseButton) {
        guard let current = CGEvent(source: nil)?.location,
              let event = CGEvent(
                mouseEventSource: nil,
                mouseType: down ? (button == .left ? .leftMouseDown : .rightMouseDown)
                                : (button == .left ? .leftMouseUp : .rightMouseUp),
                mouseCursorPosition: current,
                mouseButton: button
              ) else { return }
        event.post(tap: .cghidEventTap)
    }

    private static var deleteTimer: Timer?

    private static func startDeleteRepeat() {
        stopDeleteRepeat()
        postKey(keycode: 51)  // kVK_Delete
        let timer = Timer(timeInterval: 0.15, repeats: true) { _ in
            postKey(keycode: 51)
        }
        RunLoop.main.add(timer, forMode: .common)
        deleteTimer = timer
    }

    private static func stopDeleteRepeat() {
        deleteTimer?.invalidate()
        deleteTimer = nil
    }

    private static func perform(_ action: KeyAction) {
        switch action {
        case .system, .none, .leftClick, .rightClick, .deleteBack:
            break
        case .enter:
            postKey(keycode: 36)
        case .esc:
            postKey(keycode: 53)
        case .copy:
            postCombo(keycode: 8, flags: .maskCommand)
        case .paste:
            postCombo(keycode: 9, flags: .maskCommand)
        case .missionControl:
            postCombo(keycode: 126, flags: .maskControl)   // Ctrl+↑
        case .lockScreen:
            postCombo(keycode: 13, flags: [.maskControl, .maskCommand])  // ⌃⌘Q
        }
    }

    private static func postKey(keycode: CGKeyCode) {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: keycode, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: keycode, keyDown: false) else { return }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private static func postCombo(keycode: CGKeyCode, flags: CGEventFlags) {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: keycode, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: keycode, keyDown: false) else { return }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}

private func tapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    KeyInterceptor.handle(event: event, type: type)
}
