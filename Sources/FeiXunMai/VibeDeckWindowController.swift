import AppKit
import SwiftUI
import Combine
import CoreBluetooth

/// AppKit host for the SwiftUI tree.
///
/// SwiftUI property wrappers are macros and are unavailable in this
/// Command Line Tools-only toolchain, so the views are pure functions of an
/// immutable snapshot. This controller subscribes to the two observable
/// models and rebuilds the root view whenever they change.
final class VibeDeckWindowController: NSWindowController {
    private let host: NSHostingController<VibeDeckRootView>
    private var section: VibeDeckSection = VibeDeckSection(
        rawValue: UserDefaults.standard.string(forKey: "deckSection") ?? ""
    ) ?? .overview
    private var cancellables: Set<AnyCancellable> = []
    private let capsuleTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter
    }()

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1020, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "VibeDeck"
        window.minSize = NSSize(width: 900, height: 640)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("VibeDeckMainWindow")

        let initial = VibeDeckRootView(
            snapshot: .placeholder(section: .overview),
            actions: .placeholder
        )
        self.host = NSHostingController(rootView: initial)
        super.init(window: window)
        window.contentViewController = host
        // Assigning a hosting controller can shrink the window to its fitting
        // size; restore the designed 1020x720 content size explicitly.
        window.setContentSize(NSSize(width: 1020, height: 760))
        window.center()
        bind()
        refresh()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func bind() {
        BridgeModel.shared.objectWillChange
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.refresh() }
            }
            .store(in: &cancellables)
        PhoneAudioBridge.shared.objectWillChange
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.refresh() }
            }
            .store(in: &cancellables)
        // 胶囊转写和落盘不在两个 model 里，用一个轻量定时器把列表刷出来。
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    private func refresh() {
        host.rootView = VibeDeckRootView(
            snapshot: makeSnapshot(),
            actions: makeActions()
        )
    }

    private func makeSnapshot() -> VibeDeckSnapshot {
        let model = BridgeModel.shared
        let phone = PhoneAudioBridge.shared
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        model.normalizeDailyStats()
        return VibeDeckSnapshot(
            section: section,
            voiceSource: model.voiceSource,
            sourceName: model.sourceDisplayName,
            sourceConnectionText: model.sourceConnectionText,
            sourceTransportLabel: model.sourceTransportLabel,
            isVoiceReady: model.isVoiceReady,
            voiceActive: model.voiceActive,
            outputDeviceName: model.outputDeviceName,
            selectedDeviceUID: model.selectedDeviceUID,
            audioDevices: model.audioDevices,
            autoSwitchInput: model.autoSwitchInput,
            monitorEnabled: model.monitorEnabled,
            voiceKeyMode: model.voiceKeyMode,
            voiceKeyShort: model.voiceKeyMode.shortLabel,
            voiceKeyTapToggle: model.voiceKeyTapToggle,
            accessibilityGranted: model.accessibilityGranted,
            bluetoothAuthorized: CBManager.authorization == .allowedAlways,
            phoneStateText: phone.stateText,
            phoneReady: model.isVoiceReady,
            phoneStateLabel: model.sourceConnectionText,
            remoteName: model.remoteName,
            remoteConnected: model.connectionState == .connected,
            remoteStateText: model.connectionState.rawValue,
            arrowsAsMouse: model.arrowsAsMouse,
            mappings: model.mappings,
            todayCount: model.todayVoiceCount,
            todaySeconds: model.todayVoiceSeconds,
            micProbeRunning: MicProbe.shared.isRunning,
            showDiagnostics: UserDefaults.standard.bool(forKey: "showDiagnostics"),
            capsules: makeCapsuleRows(),
            capsulePendingCount: makeCapsuleRows().filter { $0.text == nil }.count,
            capsuleAutoEnabled: (UserDefaults.standard.object(
                forKey: "capsuleAutoTranscribe"
            ) as? Bool) ?? true,
            capsuleIdleSeconds: {
                let value = UserDefaults.standard.double(forKey: "capsuleIdleSeconds")
                return value > 0 ? value : 8
            }(),
            version: version ?? "0.5.0"
        )
    }

    private func makeCapsuleRows() -> [CapsuleRowModel] {
        CapsuleStoreMac.shared.all().map { meta in
            let seconds = max(1, Int((Double(meta.durationMs) / 1000).rounded()))
            let text = (meta.text ?? "").isEmpty ? nil : meta.text
            return CapsuleRowModel(
                id: meta.id,
                timeLabel: capsuleTimeFormatter.string(
                    from: Date(timeIntervalSince1970: Double(meta.createdAt) / 1000)
                ),
                durationLabel: "\(seconds) 秒",
                text: text,
                attempts: meta.attempts ?? 0
            )
        }
    }

    private func makeActions() -> VibeDeckActions {
        let model = BridgeModel.shared
        let phone = PhoneAudioBridge.shared
        return VibeDeckActions(
            selectSection: { [weak self] section in
                self?.section = section
                UserDefaults.standard.set(section.rawValue, forKey: "deckSection")
                self?.refresh()
            },
            setVoiceSource: { [weak self] source in
                model.voiceSource = source
                self?.refresh()
            },
            rescanSource: { [weak self] in
                if model.voiceSource == .phone {
                    phone.rescan()
                } else {
                    model.rescanRemote()
                }
                self?.refresh()
            },
            rescanPhone: { [weak self] in
                phone.rescan()
                self?.refresh()
            },
            rescanRemote: { [weak self] in
                model.rescanRemote()
                self?.refresh()
            },
            selectDevice: { [weak self] uid in
                model.selectedDeviceUID = uid
                self?.refresh()
            },
            setAutoSwitch: { [weak self] on in
                model.autoSwitchInput = on
                self?.refresh()
            },
            setMonitor: { [weak self] on in
                model.monitorEnabled = on
                self?.refresh()
            },
            setVoiceKeyMode: { [weak self] mode in
                model.voiceKeyMode = mode
                self?.refresh()
            },
            setTapToggle: { [weak self] on in
                model.voiceKeyTapToggle = on
                self?.refresh()
            },
            setArrowsAsMouse: { [weak self] on in
                model.arrowsAsMouse = on
                self?.refresh()
            },
            setMapping: { [weak self] button, action in
                model.mappings[button.rawValue] = action
                self?.refresh()
            },
            openAccessibility: {
                VoiceKeyDriver.openAccessibilitySettings()
            },
            openBluetooth: {
                if let url = URL(
                    string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth"
                ) {
                    NSWorkspace.shared.open(url)
                }
            },
            probeMic: { [weak self] in
                MicProbe.shared.start(device: model.chosenDevice())
                self?.refresh()
                DispatchQueue.main.asyncAfter(deadline: .now() + 12.5) {
                    self?.refresh()
                }
            },
            loopbackTest: { [weak self] in
                MicProbe.shared.start(device: model.chosenDevice(), seconds: 5)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    AudioSinkRouter.shared.playTone(seconds: 1.5)
                }
                self?.refresh()
                DispatchQueue.main.asyncAfter(deadline: .now() + 5.5) {
                    self?.refresh()
                }
            },
            recordVirtualMic: { [weak self] in
                MicProbe.shared.start(device: model.chosenDevice(), seconds: 8, record: true)
                self?.refresh()
                DispatchQueue.main.asyncAfter(deadline: .now() + 8.5) {
                    self?.refresh()
                }
            },
            transcribeCapsule: { id in
                CapsuleTranscriber.shared.transcribeNow(id: id)
            },
            transcribeNextCapsule: {
                CapsuleTranscriber.shared.transcribeNow()
            },
            revealCapsules: {
                NSWorkspace.shared.activateFileViewerSelecting(
                    [CapsuleStoreMac.shared.rootURL]
                )
            },
            setCapsuleAuto: { [weak self] on in
                UserDefaults.standard.set(on, forKey: "capsuleAutoTranscribe")
                self?.refresh()
            }
        )
    }
}
