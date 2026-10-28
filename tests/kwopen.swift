// 测试：连接遥控器 → 订阅 2B00 → 发送 08 06 01（开麦）→ 记录所有通知
// 用法: kwopen [秒数=30]
import Foundation
import CoreBluetooth

setvbuf(stdout, nil, _IONBF, 0)
let duration = Double(CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "") ?? 30
let t0 = Date()
func log(_ s: String) { print(String(format: "[%6.2f]", Date().timeIntervalSince(t0)) + " " + s) }

let KW_SERVICE = CBUUID(string: "00001920-0000-1000-8000-00805F9B34FB")
let KW_NOTIFY = CBUUID(string: "00002B00-0000-1000-8000-00805F9B34FB")
let KW_WRITE = CBUUID(string: "00002B01-0000-1000-8000-00805F9B34FB")

final class G: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var central: CBCentralManager!
    var target: CBPeripheral?
    var writeChar: CBCharacteristic?
    var sent = false

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else { log("BT \(central.state.rawValue)"); return }
        let p = central.retrieveConnectedPeripherals(withServices: [KW_SERVICE])
            .first { ($0.name ?? "").contains("斐讯") }
        if let p {
            log("found \(p.name ?? "?")")
            target = p; p.delegate = self; central.connect(p)
        } else { log("not found; scanning"); central.scanForPeripherals(withServices: nil) }
    }
    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData: [String: Any], rssi: NSNumber) {
        guard target == nil, (p.name ?? "").contains("斐讯") else { return }
        target = p; p.delegate = self; c.stopScan(); c.connect(p)
    }
    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        log("connected"); p.discoverServices([KW_SERVICE])
    }
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard let s = p.services?.first(where: { $0.uuid == KW_SERVICE }) else { log("no svc"); return }
        p.discoverCharacteristics([KW_NOTIFY, KW_WRITE], for: s)
    }
    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        for ch in s.characteristics ?? [] {
            if ch.uuid == KW_NOTIFY { p.setNotifyValue(true, for: ch); log("subscribed") }
            if ch.uuid == KW_WRITE { writeChar = ch }
        }
    }
    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor ch: CBCharacteristic, error: Error?) {
        guard ch.uuid == KW_NOTIFY, ch.isNotifying, !sent, let w = writeChar else { return }
        sent = true
        var packet = Data([0x08, 0x06, 0x01])
        packet.append(Data(repeating: 0, count: 17))
        p.writeValue(packet, for: w, type: .withResponse)
        log(">>> sent OPEN (08 06 01)")
    }
    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        guard ch.uuid == KW_NOTIFY, let d = ch.value else { return }
        log("NOTIFY \(d.count)B: " + d.prefix(6).map { String(format: "%02x", $0) }.joined(separator: " ") + (d.count > 6 ? " …" : ""))
    }
    func peripheral(_ p: CBPeripheral, didWriteValueFor ch: CBCharacteristic, error: Error?) {
        log("write ack err=\(error?.localizedDescription ?? "nil")")
    }
}

let g = G()
g.central = CBCentralManager(delegate: g, queue: .main)
DispatchQueue.main.asyncAfter(deadline: .now() + duration) { exit(0) }
RunLoop.main.run()
