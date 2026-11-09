import Foundation
import CoreBluetooth
import Combine
import ApplicationServices

/// BLE central for the Android phone's dedicated voice service.
///
/// The phone is a peripheral: it advertises PhoneProtocol.service, streams
/// 16 kHz ADPCM on the audio characteristic and sends start/stop/ready control
/// packets. This bridge only handles voice; the trackpad is a separate HID
/// device and does not go through here.
final class PhoneAudioBridge: NSObject, ObservableObject {
    enum LinkState: Equatable {
        case stopped
        case bluetoothOff
        case scanning
        case connecting
        case discovering
        case subscribing
        case ready
        case reconnecting
        case error(String)

        var text: String {
            switch self {
            case .stopped: return "未启用"
            case .bluetoothOff: return "蓝牙未开启"
            case .scanning: return "扫描手机…"
            case .connecting: return "连接中…"
            case .discovering: return "发现服务…"
            case .subscribing: return "订阅音频…"
            case .ready: return "已连接"
            case .reconnecting: return "等待重连…"
            case .error(let message): return message
            }
        }
    }

    static let shared = PhoneAudioBridge()

    @Published private(set) var state: LinkState = .stopped
    @Published private(set) var deviceName: String = ""

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var audioChar: CBCharacteristic?
    private var controlChar: CBCharacteristic?

    private var parser = PhoneAudioParser()

    private var reconnectAttempt = 0
    private var pendingReconnect: DispatchWorkItem?
    private var controlSeq: UInt8 = 0
    private var lastStatusFlags: UInt8?
    private var linkWatchdog: Timer?
    private var statsTimer: Timer?
    private var rxCount = 0
    /// 手机每 2 秒发一条 OP_HEARTBEAT，用来判断订阅是否还有效。
    private var lastPhoneRx = Date()

    // 每秒一次的音频统计，写进 ~/Library/Logs/VibeDeck.log。
    private var statPackets = 0
    private var statSamples = 0
    private var statPeak: Int32 = 0
    private var statWindowStart = Date()

    private override init() {
        super.init()
    }

    var stateText: String {
        if deviceName.isEmpty { return state.text }
        return "\(state.text) · \(deviceName)"
    }

    func start() {
        guard central == nil else { return }
        state = .scanning
        FileLog.write("phone start (source=\(BridgeModel.shared.voiceSource.rawValue))")
        central = CBCentralManager(delegate: self, queue: .main)
        startLinkWatchdog()
    }

    /// Wi-Fi 语音已经在线时停掉 BLE 扫描，避免界面一直"扫描手机…"并白耗电。
    func suspendForWifi() {
        guard BridgeModel.shared.voiceSource == .phone, central != nil else { return }
        FileLog.write("phone ble suspended (wifi link active)")
        stop()
    }

    func resumeAfterWifi() {
        guard BridgeModel.shared.voiceSource == .phone, central == nil else { return }
        FileLog.write("phone ble resumed (wifi link gone)")
        start()
    }

    func stop() {
        FileLog.write("phone stop")
        linkWatchdog?.invalidate()
        linkWatchdog = nil
        pendingReconnect?.cancel()
        pendingReconnect = nil
        PhoneVoiceSession.shared.end(force: true, from: .ble)
        statsTimer?.invalidate()
        statsTimer = nil
        if let peripheral {
            central?.cancelPeripheralConnection(peripheral)
        }
        central?.stopScan()
        central = nil
        peripheral = nil
        audioChar = nil
        controlChar = nil
        deviceName = ""
        lastStatusFlags = nil
        state = .stopped
    }

    func rescan() {
        guard let central else {
            start()
            return
        }
        pendingReconnect?.cancel()
        pendingReconnect = nil
        if let peripheral {
            central.cancelPeripheralConnection(peripheral)
            self.peripheral = nil
            audioChar = nil
            controlChar = nil
        }
        guard central.state == .poweredOn else {
            state = central.state == .poweredOff ? .bluetoothOff : .error("蓝牙未就绪")
            return
        }
        beginScan()
    }

    private func beginScan() {
        guard let central, central.state == .poweredOn else { return }
        central.stopScan()
        state = .scanning
        central.scanForPeripherals(
            withServices: [PhoneProtocol.service],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        if Diag.on { NSLog("VibeDeck[phone] scanning") }
    }

    private func scheduleReconnect() {
        pendingReconnect?.cancel()
        reconnectAttempt = min(reconnectAttempt + 1, 4)
        let delay: TimeInterval
        switch reconnectAttempt {
        case 1: delay = 1
        case 2: delay = 2
        case 3: delay = 5
        default: delay = 10
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingReconnect = nil
            self.beginScan()
        }
        pendingReconnect = work
        state = .reconnecting
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        FileLog.write("phone reconnect in \(Int(delay))s (attempt \(reconnectAttempt))")
        if Diag.on { NSLog("VibeDeck[phone] reconnect in %.0fs", delay) }
    }

    private func markReady() {
        state = .ready
        lastPhoneRx = Date()
        startWatchdog()
        sendControl(PhoneProtocol.opReady)
        lastStatusFlags = nil
        publishStatus()
        FileLog.write(
            "phone ready · sink=\(AudioSinkRouter.shared.describe) · key=\(BridgeModel.shared.voiceKeyMode.rawValue)"
        )
        if Diag.on { NSLog("VibeDeck[phone] ready") }
    }

    /// Sends the Mac-side permission state to the phone. The phone uses it
    /// for the "Mac 授权" indicator; the confirm button covers ZCode's own
    /// permission dialogs, which this app cannot inspect.
    func publishStatus() {
        guard let peripheral, let controlChar else { return }
        let flags: UInt8 =
            (BridgeModel.shared.accessibilityGranted ? 0x01 : 0) |
            (KeyInterceptor.shared.tapActive ? 0x02 : 0)
        guard flags != lastStatusFlags else { return }
        lastStatusFlags = flags
        let packet = Data([
            PhoneProtocol.version,
            PhoneProtocol.typeControl,
            controlSeq,
            PhoneProtocol.opStatus,
            flags
        ])
        controlSeq &+= 1
        peripheral.writeValue(packet, for: controlChar, type: .withResponse)
        if Diag.on { NSLog("VibeDeck[phone] status flags=0x%02x", flags) }
    }

    /// CoreBluetooth 有时收不到 `didDisconnectPeripheral`（典型场景：手机上
    /// 覆盖安装新包，GATT server 随进程重建）。此时 central 还停在旧的
    /// `.ready` 状态，不会再订阅，手机端 `audioSubscribed` 永远是 false，
    /// 一按语音就报「Mac 还没订阅音频」并卡在「语音等待」。
    /// 每 2 秒核对一次 `CBPeripheral.state`，发现链路已断就重新扫描。
    private func startLinkWatchdog() {
        linkWatchdog?.invalidate()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            guard let self, let central = self.central, central.state == .poweredOn else {
                return
            }
            // 心跳断了就说明手机端进程/订阅已经没了，而 macOS 可能还挂着
            // 旧的 LE 链路（`peripheral.state` 依然 connected）。主动断开
            // 再重新扫，才能拿到一次干净的订阅。
            if self.state == .ready,
               Date().timeIntervalSince(self.lastPhoneRx) > 6 {
                FileLog.write("no heartbeat for 6s — dropping stale link")
                if let peripheral = self.peripheral {
                    central.cancelPeripheralConnection(peripheral)
                }
                self.peripheral = nil
                self.audioChar = nil
                self.controlChar = nil
                self.lastStatusFlags = nil
                self.deviceName = ""
                PhoneVoiceSession.shared.end(force: true, from: .ble)
                self.reconnectAttempt = 0
                self.beginScan()
                return
            }
            if let peripheral = self.peripheral {
                // `.connecting`/`.disconnecting` are transient; only a firmly
                // disconnected peripheral means the delegate callbacks were lost.
                guard peripheral.state == .disconnected else { return }
                FileLog.write(
                    "link watchdog: peripheral.state=\(peripheral.state.rawValue) → rescan"
                )
                self.peripheral = nil
                self.audioChar = nil
                self.controlChar = nil
                self.lastStatusFlags = nil
                self.deviceName = ""
                PhoneVoiceSession.shared.end(force: true, from: .ble)
                self.reconnectAttempt = 0
                self.beginScan()
            } else if self.state != .scanning, self.pendingReconnect == nil {
                self.beginScan()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        linkWatchdog = timer
    }

    private func startWatchdog() {
        statsTimer?.invalidate()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.flushAudioStats()
        }
        RunLoop.main.add(timer, forMode: .common)
        statsTimer = timer
    }

    /// 每秒把手机音频的真实到达情况写一行：包数、解码样本数、峰值、落地电平。
    private func flushAudioStats() {
        let elapsed = Date().timeIntervalSince(statWindowStart)
        guard elapsed >= 1.0 else { return }
        if statPackets > 0 || PhoneVoiceSession.shared.active {
            let level = AudioSinkRouter.shared.meterLevel
            FileLog.write(
                "audio \(statPackets)pkt/s samples=\(statSamples) peak=\(statPeak)"
                    + " sink=\(AudioSinkRouter.shared.describe)"
                    + " level=\(String(format: "%.2f", level))"
                    + " active=\(PhoneVoiceSession.shared.active ? 1 : 0)"
                    + " \(AudioSinkRouter.shared.takeStats())"
            )
        }
        statPackets = 0
        statSamples = 0
        statPeak = 0
        statWindowStart = Date()
    }

    // MARK: - Voice session

    private func handleAudio(_ samples: [Int16]) {
        guard !samples.isEmpty else { return }
        statPackets += 1
        statSamples += samples.count
        for sample in samples {
            let magnitude = abs(Int32(sample))
            if magnitude > statPeak { statPeak = magnitude }
        }
        PhoneVoiceSession.shared.ingest(samples, from: .ble)
    }

    private func sendControl(_ op: UInt8) {
        guard let peripheral, let controlChar else { return }
        let packet = Data([
            PhoneProtocol.version,
            PhoneProtocol.typeControl,
            controlSeq,
            op
        ])
        controlSeq &+= 1
        peripheral.writeValue(packet, for: controlChar, type: .withResponse)
    }

    private func handleControl(_ data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count >= 4,
              bytes[0] == PhoneProtocol.version,
              bytes[1] == PhoneProtocol.typeControl else { return }
        let op = bytes[3]
        FileLog.write(String(format: "control op=0x%02x", op))
        if Diag.on { NSLog("VibeDeck[phone] control op=0x%02x", op) }
        switch op {
        case PhoneProtocol.opStart:
            PhoneVoiceSession.shared.begin(from: .ble)
        case PhoneProtocol.opStop:
            PhoneVoiceSession.shared.end(force: false, from: .ble)
        case PhoneProtocol.opReady:
            break
        default:
            break
        }
    }
}

extension PhoneAudioBridge: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            beginScan()
        case .poweredOff:
            PhoneVoiceSession.shared.end(force: true, from: .ble)
            state = .bluetoothOff
        case .unauthorized:
            state = .error("蓝牙权限被拒绝")
        case .unsupported:
            state = .error("设备不支持 BLE")
        default:
            state = .error("蓝牙未就绪")
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard self.peripheral == nil else { return }
        self.peripheral = peripheral
        peripheral.delegate = self
        central.stopScan()
        state = .connecting
        central.connect(peripheral, options: nil)
        FileLog.write("phone discovered \(peripheral.name ?? "?") rssi=\(RSSI)")
        if Diag.on { NSLog("VibeDeck[phone] discovered %@", peripheral.name ?? "?") }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        reconnectAttempt = 0
        deviceName = peripheral.name ?? "VibePad"
        lastPhoneRx = Date()
        state = .discovering
        FileLog.write("phone connected \(deviceName)")
        peripheral.discoverServices([PhoneProtocol.service])
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        FileLog.write("phone connect failed: \(error?.localizedDescription ?? "?")")
        self.peripheral = nil
        scheduleReconnect()
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        FileLog.write("phone disconnected: \(error?.localizedDescription ?? "no error")")
        PhoneVoiceSession.shared.end(force: true, from: .ble)
        self.peripheral = nil
        audioChar = nil
        controlChar = nil
        lastStatusFlags = nil
        scheduleReconnect()
    }
}

extension PhoneAudioBridge: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == PhoneProtocol.service }) else {
            central?.cancelPeripheralConnection(peripheral)
            return
        }
        state = .subscribing
        peripheral.discoverCharacteristics(
            [PhoneProtocol.audio, PhoneProtocol.control],
            for: service
        )
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        FileLog.write(
            "chars: \((service.characteristics ?? []).map { $0.uuid.uuidString }.joined(separator: ","))"
        )
        for characteristic in service.characteristics ?? [] {
            switch characteristic.uuid {
            case PhoneProtocol.audio:
                audioChar = characteristic
                peripheral.setNotifyValue(true, for: characteristic)
            case PhoneProtocol.control:
                controlChar = characteristic
                peripheral.setNotifyValue(true, for: characteristic)
            default:
                break
            }
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        FileLog.write(
            "notify state \(characteristic.uuid.uuidString) on=\(characteristic.isNotifying) err=\(error?.localizedDescription ?? "-")"
        )
        if let error {
            state = .error("订阅失败：\(error.localizedDescription)")
            return
        }
        if characteristic.uuid == PhoneProtocol.audio, characteristic.isNotifying {
            markReady()
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        rxCount += 1
        lastPhoneRx = Date()
        if characteristic.uuid == PhoneProtocol.control || rxCount <= 5 {
            FileLog.write(
                "rx \(characteristic.uuid.uuidString) len=\(characteristic.value?.count ?? -1) err=\(error?.localizedDescription ?? "-")"
            )
        }
        guard let data = characteristic.value else { return }
        if characteristic.uuid == PhoneProtocol.audio {
            let samples = parser.append(data)
            handleAudio(samples)
        } else if characteristic.uuid == PhoneProtocol.control {
            handleControl(data)
        }
    }
}
