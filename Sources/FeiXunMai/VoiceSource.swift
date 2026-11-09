import Foundation

/// Where the current voice session comes from. The trackpad is a separate
/// pure-HID module and never appears here.
enum VoiceSource: String, CaseIterable, Identifiable {
    case remote
    case phone

    var id: String { rawValue }

    var label: String {
        switch self {
        case .remote: return "斐讯遥控器"
        case .phone: return "手机（BLE）"
        }
    }
}


/// 谁在占用系统默认输入（虚拟麦克风）。voice 的两种来源和胶囊转写互斥，
/// 最后一个 owner 退出时才恢复原输入。
enum InputOwner {
    case remote
    case phone
    case capsule
}
