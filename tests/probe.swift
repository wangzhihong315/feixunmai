// 摸底探针：同时记录 Kehwin GATT 通知和 HID 原始报告，带单调时间戳。
// 用法: probe [秒数=60] [输出文件=/tmp/probe.log]
import Foundation
import CoreBluetooth
import IOKit.hid

setvbuf(stdout, nil, _IONBF, 0)
let duration = Double(CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "") ?? 60
let logPath = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "/tmp/probe.log"
let t0 = Date()
var fileHandle: FileHandle?

func log(_ line: String) {
    let t = Date().timeIntervalSince(t0)
    let stamped = String(format: "[%8.3f] %@", t, line)
    print(stamped)
    fileHandle?.write((stamped + "\n").data(using: .utf8)!)
}

fileHandle = FileHandle(forWritingAtPath: logPath) ?? FileHandle()
if fileHandle?.seekToEndOfFile() == nil { }
if FileManager.default.fileExists(atPath: logPath) {
    fileHandle = FileHandle(forUpdatingAtPath: logPath)
    _ = try? fileHandle?.seekToEnd()
} else {
    FileManager.default.createFile(atPath: logPath, contents: nil)
    fileHandle = FileHandle(forWritingAtPath: logPath)
}
log("=== probe start ===")

let KW_SERVICE = CBUUID(string: "00001920-0000-1000-8000-00805F9B34FB")
let KW_NOTIFY = CBUUID(string: "00002B00-0000-1000-8000-00805F9B34FB")

final class Gatt: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var central: CBCentralManager!
    var target: CBPeripheral?
    var audioPackets = 0
    var audioFrames = 0
    var lastAudioReport = Date.distantPast
    var streaming = false

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else { log("BT state \(central.state.rawValue)"); return }
        let services = [KW_SERVICE, CBUUID(string: "1812"), CBUUID(string: "1800"), CBUUID(string: "180F")]
        if let p = central.retrieveConnectedPeripherals(withServices: services)
            .first(where: { ($0.name ?? "").contains("斐讯") }) {
            log("GATT found system-connected \(p.name ?? "?")")
            target = p
            p.delegate = self
            central.connect(p, options: nil)
            return
        }
        log("GATT scanning ...")
        central.scanForPeripherals(withServices: nil)
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard target == nil, (peripheral.name ?? "").contains("斐讯") else { return }
        target = peripheral
        peripheral.delegate = self
        central.stopScan()
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        log("GATT connected")
        peripheral.discoverServices([KW_SERVICE])
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let s = peripheral.services?.first(where: { $0.uuid == KW_SERVICE }) else {
            log("GATT service 1920 NOT FOUND"); return
        }
        peripheral.discoverCharacteristics([KW_NOTIFY], for: s)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for c in service.characteristics ?? [] where c.uuid == KW_NOTIFY {
            peripheral.setNotifyValue(true, for: c)
            log("GATT subscribed 2B00")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == KW_NOTIFY, let d = characteristic.value else { return }
        if d.count == 20 {
            log("GATT CTRL \(d.map { String(format: "%02x", $0) }.joined(separator: " "))")
            return
        }
        // 音频包：只统计，刷屏用
        audioPackets += 1
        audioFrames += d.count / 60
        if !streaming {
            streaming = true
            log("GATT AUDIO first packet len=\(d.count) (流开始)")
        }
        lastAudioReport = Date()
        if audioPackets % 50 == 0 {
            log(String(format: "GATT AUDIO ... %d packets, %d frames (rate %.1f fps)",
                       audioPackets, audioFrames,
                       Double(audioPackets) / Date().timeIntervalSince(t0)))
        }
    }
}

let gatt = Gatt()
gatt.central = CBCentralManager(delegate: gatt, queue: .main)

// HID 原始报告
let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
IOHIDManagerSetDeviceMatchingMultiple(manager, [[
    kIOHIDVendorIDKey as String: 0x005D,
    kIOHIDProductIDKey as String: 0x0001,
]] as CFArray)
IOHIDManagerRegisterInputReportCallback(manager, { _, result, _, _, reportID, report, length in
    guard result == kIOReturnSuccess, length > 0 else { return }
    let hex = Data(bytes: report, count: length).map { String(format: "%02x", $0) }.joined(separator: " ")
    log("HID id=\(reportID) len=\(length) \(hex)")
}, nil)
IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
let openStatus = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
log("HID open status=\(openStatus)")

DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
    log("=== probe end: audio \(gatt.audioPackets) packets / \(gatt.audioFrames) frames ===")
    exit(0)
}
RunLoop.main.run()
