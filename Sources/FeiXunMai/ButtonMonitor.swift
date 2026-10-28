import Foundation
import IOKit.hid

/// Watches the Phicomm remote's HID interface (VID 0x005D / PID 0x0001).
///
/// 职责（对齐 remote 的 KeyboardEventSuppressor 架构）：
/// 1. 把 HID 报告解析成按键，通知 UI 显示；
/// 2. **布防**：遥控器按键对应的 mac 原生键码/消费 usage 登记一个布防窗口，
///    CGEventTap 只吞布防窗口内的原生事件——真键盘的同键码按键（如回车）
///    从未被布防，永远直通，不会被误吞。
/// 3. 没有原生键码对应的键（OTT 电源 0x66）在这里直接触发映射动作。
final class ButtonMonitor {
    /// HID 键盘 usage → mac 键码（语音键 0x3E→F5(96) 用于吞回声）
    static let keyboardUsageToMac: [UInt8: UInt64] = [
        0x28: 36,   // OK → Return
        0x52: 126,  // 上
        0x51: 125,  // 下
        0x50: 123,  // 左
        0x4F: 124,  // 右
        0x3E: 96,   // 语音键回声 = F5
    ]
    /// 需要布防的消费键（音量键保持原生直通，不布防）
    static let consumerUsagesToArm: Set<UInt32> = [0x0223, 0x0224, 0x0040]

    private var manager: IOHIDManager?
    private var heldKeyboardMacKeys: Set<UInt64> = []
    private var heldConsumerUsage: UInt32?

    func start() {
        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [[String: Any]] = [[
            kIOHIDVendorIDKey as String: 0x005D,
            kIOHIDProductIDKey as String: 0x0001,
        ]]
        IOHIDManagerSetDeviceMatchingMultiple(m, matching as CFArray)

        IOHIDManagerRegisterInputReportCallback(m, { _, result, _, _, reportID, report, length in
            guard result == kIOReturnSuccess, length > 0 else { return }
            ButtonMonitor.handle(reportID: UInt8(truncatingIfNeeded: reportID),
                                 data: Data(bytes: report, count: length))
        }, nil)

        IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        let status = IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone))
        guard status == kIOReturnSuccess else {
            NSLog("斐讯麦: HID monitor open failed (0x%x). Grant 输入监控 to see button presses.", status)
            return
        }
        manager = m
    }

    private static func handle(reportID: UInt8, data: Data) {
        var bytes = Array(data)
        if reportID == 1 {
            if bytes.first == UInt8(reportID) { bytes.removeFirst() }
            guard bytes.count >= 7 else { return }
            let pressed = bytes[2..<8].filter { $0 != 0 }
            if pressed.isEmpty {
                // 全零 = 松开：给所有按住中的键码补一个短布防窗口覆盖随后的 keyUp
                for mac in KeyInterceptor.sharedHeldKeyboardKeys() {
                    KeyInterceptor.armKeyboard(mac, seconds: 0.3)
                }
                KeyInterceptor.clearHeldKeyboardKeys()
                return
            }
            for keyCode in pressed {
                let name = ButtonMonitor.buttonNames[UInt32(0x07) << 16 | UInt32(keyCode)]
                if let name {
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(name: .remoteButtonPressed, object: name)
                    }
                }
                if keyCode == 0x66 {
                    // OTT 电源：没有标准 mac 键码，直接在 HID 层触发映射动作
                    DispatchQueue.main.async {
                        let model = BridgeModel.shared
                        model.rulesLock.lock()
                        let rules = model.eventRules
                        model.rulesLock.unlock()
                        KeyInterceptor.apply(button: .ott, isDown: true, rules: rules)
                    }
                    continue
                }
                if let mac = keyboardUsageToMac[keyCode] {
                    KeyInterceptor.armKeyboard(mac, seconds: 2.0)
                    KeyInterceptor.markHeldKeyboardKey(mac)
                }
            }
        } else if reportID == 2 {
            if bytes.first == UInt8(reportID) { bytes.removeFirst() }
            guard bytes.count >= 2 else { return }
            let usage = UInt32(bytes[0]) | UInt32(bytes[1]) << 8
            if usage != 0 {
                let name = ButtonMonitor.buttonNames[UInt32(0x0C) << 16 | usage]
                if let name {
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(name: .remoteButtonPressed, object: name)
                    }
                }
                if ButtonMonitor.consumerUsagesToArm.contains(usage) {
                    // 消费键 0x0223/0x0224/0x0040 不会生成任何 CGEvent
                    // （macOS 只给音量/亮度等媒体键合成事件），必须在 HID 层直接派发动作
                    if let mapped = MappedButton.consumerUsage[usage] {
                        NSLog("斐讯麦[CHAIN] HID consumer 0x%04x → apply %@", usage, mapped.rawValue)
                        DispatchQueue.main.async {
                            let model = BridgeModel.shared
                            model.rulesLock.lock()
                            let rules = model.eventRules
                            model.rulesLock.unlock()
                            KeyInterceptor.apply(button: mapped, isDown: true, rules: rules)
                        }
                    }
                    KeyInterceptor.armConsumer(usage, seconds: 2.0)
                    KeyInterceptor.setHeldConsumerUsage(usage)
                }
            } else if let held = KeyInterceptor.sharedHeldConsumerUsage() {
                KeyInterceptor.armConsumer(held, seconds: 0.3)
                KeyInterceptor.setHeldConsumerUsage(nil)
                if let mapped = MappedButton.consumerUsage[held] {
                    DispatchQueue.main.async {
                        let model = BridgeModel.shared
                        model.rulesLock.lock()
                        let rules = model.eventRules
                        model.rulesLock.unlock()
                        KeyInterceptor.apply(button: mapped, isDown: false, rules: rules)
                    }
                }
            }
        }
    }

    static let buttonNames: [UInt32: String] = [
        0x070052: "上",
        0x070051: "下",
        0x070050: "左",
        0x07004F: "右",
        0x070028: "OK",
        0x070066: "OTT 电源",
        0x07003E: "语音键",
        0x0C0024: "返回",
        0x0C0023: "主页",
        0x0C0040: "菜单",
        0x0C00E9: "音量 +",
        0x0C00EA: "音量 −",
    ]
}

extension Notification.Name {
    static let remoteButtonPressed = Notification.Name("feixunmai.remoteButtonPressed")
}
