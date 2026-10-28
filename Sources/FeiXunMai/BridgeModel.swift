import Foundation
import CoreBluetooth
import AVFoundation
import Combine
import ApplicationServices
import CSBC

let KW_SERVICE = CBUUID(string: "00001920-0000-1000-8000-00805F9B34FB")
let KW_NOTIFY = CBUUID(string: "00002B00-0000-1000-8000-00805F9B34FB")
let KW_WRITE = CBUUID(string: "00002B01-0000-1000-8000-00805F9B34FB")

enum ConnectionState: String {
    case idle = "蓝牙未就绪"
    case searching = "正在搜索遥控器…"
    case connected = "已连接"
}

/// Central observable model: BLE bridge to the Phicomm remote, mSBC decode,
/// routing into the loopback mic, Fn voice-key emulation and usage stats.
final class BridgeModel: NSObject, ObservableObject {
    static let shared = BridgeModel()

    @Published var connectionState: ConnectionState = .searching
    @Published var remoteName: String = "斐讯遥控器"
    @Published var voiceActive = false
    @Published var lastButton: String = "—"
    @Published var audioDevices: [AudioDeviceInfo] = []
    @Published var selectedDeviceUID: String {
        didSet { UserDefaults.standard.set(selectedDeviceUID, forKey: "selectedDeviceUID"); restartSink() }
    }
    @Published var voiceKeyMode: VoiceKeyMode {
        didSet {
            UserDefaults.standard.set(voiceKeyMode.rawValue, forKey: "voiceKeyMode")
            voiceKeyDriver.mode = voiceKeyMode
        }
    }
    @Published var voiceKeyTapToggle: Bool {
        didSet {
            UserDefaults.standard.set(voiceKeyTapToggle, forKey: "voiceKeyTapToggle")
            voiceKeyDriver.tapToggle = voiceKeyTapToggle
        }
    }
    @Published var todayVoiceCount: Int
    @Published var todayVoiceSeconds: Double
    @Published var accessibilityGranted = AXIsProcessTrusted()
    @Published var interceptorActive = false
    /// 语音会话期间自动把系统默认输入切到虚拟麦克风，结束自动还原。
    @Published var autoSwitchInput: Bool {
        didSet { UserDefaults.standard.set(autoSwitchInput, forKey: "autoSwitchInput") }
    }
    @Published var monitorEnabled: Bool {
        didSet {
            UserDefaults.standard.set(monitorEnabled, forKey: "monitorEnabled")
            restartSink()
        }
    }
    private var savedInputDevice: AudioDeviceInfo?
    private var activityToken: NSObjectProtocol?
    let keepAliveLock = NSLock()
    var lastKeepAlive = Date.distantPast
    /// tap 线程读取的事件规则快照（主线程写，锁保护）
    let rulesLock = NSLock()
    var eventRules = EventRules()
    @Published var arrowsAsMouse: Bool {
        didSet { UserDefaults.standard.set(arrowsAsMouse, forKey: "arrowsAsMouse"); updateEventRules() }
    }
    @Published var mappings: [String: KeyAction] {
        didSet {
            let raw = mappings.mapValues { $0.rawValue }
            UserDefaults.standard.set(raw, forKey: "buttonMappings")
            updateEventRules()
        }
    }
    func updateEventRules() {
        let rules = EventRules(
            swallowVoiceKeyEcho: voiceKeyMode.needsEchoSwallow,
            arrowsAsMouse: arrowsAsMouse,
            mappings: mappings
        )
        rulesLock.lock()
        eventRules = rules
        rulesLock.unlock()
    }

    let voiceKeyDriver: VoiceKeyDriver
    private let buttonMonitor = ButtonMonitor()
    private var central: CBCentralManager?
    private var target: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var notifyCharacteristic: CBCharacteristic?
    private var sink: AudioSink?
    private let decoder = msbc_new()
    private var voiceActiveInternal = false
    /// 按键模拟挂在音频流上并设最短时长门槛（E1 实测：点按也有 ~0.2 s 毛刺流，
    /// 不应触发语音工具）。门槛期间的样本先缓存，触发后一起灌进输出设备。
    private var sessionFirstAudio: Date?
    private var keySent = false
    private var gateBuffer: [[Int16]] = []
    private var lastAudioDate = Date()
    private var watchdog: Timer?
    private var rescanWork: DispatchWorkItem?
    private var pcm = [Int16](repeating: 0, count: 1024)
    private var sessionStart: Date?
    private var todayKey: String

    private override init() {
        let defaults = UserDefaults.standard
        let mode: VoiceKeyMode
        if let raw = defaults.string(forKey: "voiceKeyMode") {
            mode = VoiceKeyMode(rawValue: raw) ?? .nativeF5
        } else if defaults.string(forKey: "voiceKeyMode") == nil,
                  defaults.object(forKey: "voiceKeyFnHold") != nil {
            // 老版本迁移：只有 Fn 开关
            mode = defaults.object(forKey: "voiceKeyFnHold") as? Bool ?? true ? .fnHold : .none
        } else {
            mode = .nativeF5
        }
        voiceKeyMode = mode
        selectedDeviceUID = defaults.string(forKey: "selectedDeviceUID") ?? ""
        let tapToggle = defaults.bool(forKey: "voiceKeyTapToggle")
        voiceKeyTapToggle = tapToggle
        voiceKeyDriver = VoiceKeyDriver(mode: mode, tapToggle: tapToggle)
        todayVoiceCount = defaults.integer(forKey: "voiceCount")
        todayVoiceSeconds = defaults.double(forKey: "voiceSeconds")
        todayKey = Self.dayKey()
        arrowsAsMouse = defaults.bool(forKey: "arrowsAsMouse")
        autoSwitchInput = defaults.object(forKey: "autoSwitchInput") as? Bool ?? true
        monitorEnabled = defaults.object(forKey: "monitorEnabled") as? Bool ?? false
        let rawMappings = defaults.dictionary(forKey: "buttonMappings") as? [String: String] ?? [:]
        mappings = rawMappings.compactMapValues { KeyAction(rawValue: $0) }
        super.init()
        normalizeDailyStats()
    }

    func start() {
        // 禁止 AppNap：后台时主线程被挂起会导致切回前台头几秒点击全部丢失
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "斐讯麦持续监听遥控器"
        )
        if Diag.on { NSLog("斐讯麦[diag] chosen device: %@", chosenDevice()?.name ?? "系统默认") }
        if voiceKeyMode != .none {
            // 首次运行时让系统自动弹出"斐讯麦想控制你的电脑"授权弹窗
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
        refreshDevices()
        // 启动自愈：上次会话若没来得及还原系统输入（崩溃/强退），现在补上
        if UserDefaults.standard.string(forKey: "savedInputDeviceUID") != nil {
            switchDefaultInput(toBlackHole: false)
        }
        // 一次性迁移：老配置存的 BlackHole → 迁到 FeiXunV（豆包识别友好）
        if selectedDeviceUID.contains("BlackHole"),
           let feixunv = audioDevices.first(where: { $0.name.contains("FeiXunV") }) {
            selectedDeviceUID = feixunv.uid
            NSLog("斐讯麦[MIGRATE] output → FeiXunV")
        }
        updateEventRules()
        do {
            sink = try AudioSink(device: chosenDevice(), monitor: monitorEnabled)
            if Diag.on { NSLog("斐讯麦[diag] sink started → %@", chosenDevice()?.name ?? "系统默认") }
        } catch {
            if Diag.on { NSLog("斐讯麦[diag] sink FAILED at start: %@", String(describing: error)) }
            sink = nil
        }
        central = CBCentralManager(delegate: self, queue: .main)
        buttonMonitor.start()
        KeyInterceptor.shared.start()
        startWatchdog()
        let timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let axNow = AXIsProcessTrusted()
            if accessibilityGranted != axNow {
                accessibilityGranted = axNow
                voiceKeyDriver.refreshPermission()
            }
            let tapNow = KeyInterceptor.shared.tapActive
            if interceptorActive != tapNow {
                interceptorActive = tapNow
            }
            // 蓝牙重启/回连后 notify 订阅会静默失效（界面仍显示已连接），
            // 定期检查并补订，否则语音流永远收不到
            if let target = self.target,
               target.state == .connected,
               let notify = self.notifyCharacteristic,
               !notify.isNotifying {
                target.setNotifyValue(true, for: notify)
                NSLog("斐讯麦[SUB] notify resubscribed")
            }
            // 保活：遥控器会把语音通道空闲后自行关闭，定期重发开麦命令
            if let target = self.target,
               target.state == .connected,
               let write = self.writeCharacteristic {
                self.keepAliveLock.lock()
                let due = Date().timeIntervalSince(self.lastKeepAlive) > 30
                self.keepAliveLock.unlock()
                if due {
                    self.keepAliveLock.lock()
                    self.lastKeepAlive = Date()
                    self.keepAliveLock.unlock()
                    var packet = Data([0x08, 0x06, 0x01])
                    packet.append(Data(repeating: 0, count: 17))
                    target.writeValue(packet, for: write, type: .withoutResponse)
                }
            }
        }
        timer.tolerance = 1.0
    }

    // MARK: - Audio device selection

    func refreshDevices() {
        audioDevices = outputDevices()
    }

    func chosenDevice() -> AudioDeviceInfo? {
        if !selectedDeviceUID.isEmpty {
            if let match = audioDevices.first(where: { $0.uid == selectedDeviceUID }) {
                return match
            }
        }
        // 优先 FeiXunV（USB transport，豆包等应用能自动识别），其次 BlackHole
        return audioDevices.first { $0.name.localizedCaseInsensitiveContains("FeiXunV") }
            ?? audioDevices.first { $0.name.localizedCaseInsensitiveContains("BlackHole") }
            ?? defaultOutputDevice()
    }

    var blackHoleInstalled: Bool {
        audioDevices.contains { $0.name.localizedCaseInsensitiveContains("BlackHole") }
    }

    private func restartSink() {
        sink?.stop()
        let device = chosenDevice()
        do {
            sink = try AudioSink(device: device, monitor: monitorEnabled)
            if Diag.on { NSLog("斐讯麦[diag] sink rebuilt → %@ monitor=%d", device?.name ?? "系统默认", monitorEnabled ? 1 : 0) }
        } catch {
            if Diag.on { NSLog("斐讯麦[diag] sink FAILED for %@: %@", device?.name ?? "系统默认", String(describing: error)) }
            sink = nil
        }
    }

    // MARK: - Stats

    private static func dayKey() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        return formatter.string(from: Date())
    }

    private func normalizeDailyStats() {
        let key = Self.dayKey()
        if key != todayKey {
            todayKey = key
            todayVoiceCount = 0
            todayVoiceSeconds = 0
        }
    }

    private func finishVoiceSession() {
        guard let start = sessionStart else { return }
        normalizeDailyStats()
        todayVoiceCount += 1
        todayVoiceSeconds += Date().timeIntervalSince(start)
        UserDefaults.standard.set(todayVoiceCount, forKey: "voiceCount")
        UserDefaults.standard.set(todayVoiceSeconds, forKey: "voiceSeconds")
        sessionStart = nil
    }
}

extension BridgeModel: CBCentralManagerDelegate, CBPeripheralDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            if connectToSystemConnected() { return }
            connectionState = .searching
            central.scanForPeripherals(
                withServices: nil,
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
            )
        case .poweredOff:
            connectionState = .idle
        case .unauthorized:
            connectionState = .idle
        default:
            break
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard target == nil else { return }
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = peripheral.name ?? advertisedName ?? ""
        guard name.localizedCaseInsensitiveContains(remoteName) else { return }
        target = peripheral
        peripheral.delegate = self
        central.stopScan()
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices(nil)
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        scheduleRescan()
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        endVoice()
        scheduleRescan()
    }

    private func connectToSystemConnected() -> Bool {
        let services = [
            KW_SERVICE,
            CBUUID(string: "1812"),
            CBUUID(string: "180F"),
            CBUUID(string: "180A"),
            CBUUID(string: "1800"),
        ]
        for peripheral in central?.retrieveConnectedPeripherals(withServices: services) ?? [] {
            guard (peripheral.name ?? "").localizedCaseInsensitiveContains(remoteName) else { continue }
            target = peripheral
            peripheral.delegate = self
            if peripheral.state == .connected {
                peripheral.discoverServices(nil)
            } else {
                central?.connect(peripheral, options: nil)
            }
            return true
        }
        return false
    }

    private func scheduleRescan() {
        target = nil
        writeCharacteristic = nil
        notifyCharacteristic = nil
        voiceActiveInternal = false
        sessionFirstAudio = nil
        keySent = false
        gateBuffer.removeAll()
        connectionState = .searching
        rescanWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let central = self.central else { return }
            if self.connectToSystemConnected() { return }
            central.scanForPeripherals(
                withServices: nil,
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
            )
        }
        rescanWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == KW_SERVICE }) else {
            central?.cancelPeripheralConnection(peripheral)
            return
        }
        peripheral.discoverCharacteristics([KW_NOTIFY, KW_WRITE], for: service)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        for characteristic in service.characteristics ?? [] {
            if characteristic.uuid == KW_WRITE {
                writeCharacteristic = characteristic
            } else if characteristic.uuid == KW_NOTIFY {
                notifyCharacteristic = characteristic
                peripheral.setNotifyValue(true, for: characteristic)
            }
        }
        if writeCharacteristic != nil && notifyCharacteristic != nil {
            connectionState = .connected
            // 遥控器会把"关麦"锁存（可能由上次退出的 08 06 00 造成），
            // 订阅成功后显式开麦，否则语音键不推流
            if let write = writeCharacteristic, peripheral.state == .connected {
                var packet = Data([0x08, 0x06, 0x01])
                packet.append(Data(repeating: 0, count: 17))
                peripheral.writeValue(packet, for: write, type: .withResponse)
            }
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard characteristic.uuid == KW_NOTIFY,
              let data = characteristic.value else { return }

        // 07 fc 01 … = 按下，07 fc 07 … = 松开。按键模拟等音频流过门槛才触发。
        if data.count >= 3, data[0] == 0x07, data[1] == 0xfc {
            let active = data[2] == 0x01
            if Diag.on { NSLog("斐讯麦[diag] ctrl %@", active ? "start" : "stop") }
            voiceActiveInternal = active
            if !active { closeSession() }
            return
        }

        guard data.count >= 60 else { return }
        voiceActiveInternal = true

        var decodedSamples: [Int16] = []
        for offset in stride(from: 0, to: data.count - 59, by: 60) {
            let frame = data.subdata(in: offset..<(offset + 60))
            var decoded: Int32 = 0
            frame.withUnsafeBytes { raw in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
                decoded = pcm.withUnsafeMutableBufferPointer { buffer in
                    Int32(msbc_decode_frame(decoder, base, buffer.baseAddress, Int32(buffer.count)))
                }
            }
            if decoded > 0 {
                decodedSamples.append(contentsOf: pcm[0..<Int(decoded)])
            }
        }

        if Diag.on { NSLog("斐讯麦[diag] audio packet: %d samples, keySent=%d, buffer=%d", decodedSamples.count, keySent ? 1 : 0, gateBuffer.count) }
        guard !decodedSamples.isEmpty else { return }
        lastAudioDate = Date()

        if keySent {
            sink?.enqueue(decodedSamples)
            return
        }
        // 门槛期：缓存样本，流持续满 0.4 s 才触发语音键模拟
        if sessionFirstAudio == nil { sessionFirstAudio = Date() }
        gateBuffer.append(decodedSamples)
        if let first = sessionFirstAudio,
           Date().timeIntervalSince(first) >= 0.4 {
            keySent = true
            if Diag.on { NSLog("斐讯麦[diag] gate passed → press key, flush %d chunks", gateBuffer.count) }
            beginVoice()
            for chunk in gateBuffer { sink?.enqueue(chunk) }
            gateBuffer.removeAll()
        }
    }

    /// 语音会话期间把系统默认输入切到 BlackHole，结束时还原真实麦克风。
    private func switchDefaultInput(toBlackHole: Bool) {
        guard autoSwitchInput else { return }
        if toBlackHole {
            guard savedInputDevice == nil,
                  let virtual = audioDevices.first(where: { $0.name.contains("FeiXunV") })
                      ?? audioDevices.first(where: { $0.name.localizedCaseInsensitiveContains("BlackHole") }),
                  virtual != defaultInputDevice() else { return }
            savedInputDevice = defaultInputDevice()
            UserDefaults.standard.set(savedInputDevice?.uid, forKey: "savedInputDeviceUID")
            if setDefaultInputDevice(virtual) {
                if Diag.on { NSLog("斐讯麦[diag] default input → %@ (was %@)", virtual.name, savedInputDevice?.name ?? "?") }
            }
        } else {
            // 优先用持久化记录（应用重启后内存值会丢），其次内存值
            let savedUID = UserDefaults.standard.string(forKey: "savedInputDeviceUID")
                ?? savedInputDevice?.uid
            guard let savedUID,
                  let restore = audioDevices.first(where: { $0.uid == savedUID }) else { return }
            _ = setDefaultInputDevice(restore)
            if Diag.on { NSLog("斐讯麦[diag] default input restored → %@", restore.name) }
            savedInputDevice = nil
            UserDefaults.standard.removeObject(forKey: "savedInputDeviceUID")
        }
    }

    /// 会话收尾：没过门槛的（点按毛刺）静默丢弃；过了门槛的正常收尾。
    private func closeSession() {
        if Diag.on { NSLog("斐讯麦[diag] session closed, keySent=%d, buffered=%d", keySent ? 1 : 0, gateBuffer.count) }
        voiceActiveInternal = false
        sessionFirstAudio = nil
        gateBuffer.removeAll()
        if keySent {
            keySent = false
            endVoice()
        }
        switchDefaultInput(toBlackHole: false)
    }

    /// 音频流看门狗：遥控器松开后有时不发 07 fc 07，靠静音超时收尾。
    private func startWatchdog() {
        watchdog?.invalidate()
        let watchdogTimer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard self.voiceActiveInternal, self.sessionFirstAudio != nil else { return }
            if Date().timeIntervalSince(self.lastAudioDate) > 0.6 {
                self.closeSession()
            }
        }
        RunLoop.main.add(watchdogTimer, forMode: .common)
        watchdog = watchdogTimer
    }

    private func beginVoice() {
        voiceActive = true
        sessionStart = Date()
        voiceKeyDriver.voiceStarted()
    }

    private func endVoice() {
        guard voiceActive else { return }
        voiceActive = false
        voiceKeyDriver.voiceStopped()
        finishVoiceSession()
    }

    func shutdown() {
        if savedInputDevice != nil
            || UserDefaults.standard.string(forKey: "savedInputDeviceUID") != nil {
            switchDefaultInput(toBlackHole: false)
        }
        // 注意：不要发 08 06 00（关麦）——遥控器会锁存关麦状态，
        // 导致下次启动后语音键不推流。保持开麦即可。
        if let target {
            central?.cancelPeripheralConnection(target)
        }
        sink?.stop()
    }
}
