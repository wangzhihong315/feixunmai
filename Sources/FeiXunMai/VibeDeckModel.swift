import Foundation
import AppKit
import CoreBluetooth

/// Immutable render state. The AppKit controller rebuilds it whenever
/// BridgeModel or PhoneAudioBridge publishes a change; the SwiftUI tree has no
/// property wrappers and therefore no SwiftUI macro dependency.
struct VibeDeckSnapshot {
    var section: VibeDeckSection = .overview
    var voiceSource: VoiceSource = .remote
    var sourceName: String = "VibePad"
    var sourceConnectionText: String = "未连接"
    var sourceTransportLabel: String = "Android BLE"
    var isVoiceReady: Bool = false
    var voiceActive: Bool = false
    var outputDeviceName: String = "跟随系统默认"
    var selectedDeviceUID: String = ""
    var audioDevices: [AudioDeviceInfo] = []
    var autoSwitchInput: Bool = true
    var monitorEnabled: Bool = false
    var voiceKeyMode: VoiceKeyMode = .fnHold
    var voiceKeyShort: String = "Fn 长按"
    var voiceKeyTapToggle: Bool = false
    var accessibilityGranted: Bool = false
    var bluetoothAuthorized: Bool = false
    var phoneStateText: String = "未启用"
    var phoneReady: Bool = false
    var phoneStateLabel: String = "未启用"
    var remoteName: String = "斐讯遥控器"
    var remoteConnected: Bool = false
    var remoteStateText: String = "蓝牙未就绪"
    var arrowsAsMouse: Bool = false
    var mappings: [String: KeyAction] = [:]
    var todayCount: Int = 0
    var todaySeconds: Double = 0
    var micProbeRunning: Bool = false
    /// 诊断/自检按钮只在调试开关打开时显示。
    var showDiagnostics: Bool = false
    var capsules: [CapsuleRowModel] = []
    var capsulePendingCount: Int = 0
    var capsuleAutoEnabled: Bool = true
    var capsuleIdleSeconds: Double = 8
    var version: String = "0.5.0"

    static func placeholder(section: VibeDeckSection) -> VibeDeckSnapshot {
        VibeDeckSnapshot(section: section)
    }
}

/// 一条胶囊在 Mac 界面里的展示数据。
struct CapsuleRowModel: Identifiable {
    let id: String
    let timeLabel: String
    let durationLabel: String
    let text: String?
    let attempts: Int
}

/// Every user action is a closure over the real models. The controller owns
/// the sidebar selection; the views only read it from the snapshot.
struct VibeDeckActions {
    var selectSection: (VibeDeckSection) -> Void = { _ in }
    var setVoiceSource: (VoiceSource) -> Void = { _ in }
    var rescanSource: () -> Void = {}
    var rescanPhone: () -> Void = {}
    var rescanRemote: () -> Void = {}
    var selectDevice: (String) -> Void = { _ in }
    var setAutoSwitch: (Bool) -> Void = { _ in }
    var setMonitor: (Bool) -> Void = { _ in }
    var setVoiceKeyMode: (VoiceKeyMode) -> Void = { _ in }
    var setTapToggle: (Bool) -> Void = { _ in }
    var setArrowsAsMouse: (Bool) -> Void = { _ in }
    var setMapping: (MappedButton, KeyAction) -> Void = { _, _ in }
    var openAccessibility: () -> Void = {}
    var openBluetooth: () -> Void = {}
    var probeMic: () -> Void = {}
    var loopbackTest: () -> Void = {}
    var recordVirtualMic: () -> Void = {}
    var transcribeCapsule: (String) -> Void = { _ in }
    var transcribeNextCapsule: () -> Void = {}
    var revealCapsules: () -> Void = {}
    var setCapsuleAuto: (Bool) -> Void = { _ in }

    static let placeholder = VibeDeckActions()
}
