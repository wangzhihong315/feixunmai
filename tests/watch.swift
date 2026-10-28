// 客观验证工具：同时监听系统事件流和 BlackHole 回环音频。
// 用法: watch [秒数=40]
// 输出: 按键/鼠标事件流水 + 音频统计 + /tmp/loopback-test.wav
import Foundation
import CoreGraphics
import AppKit
import AVFoundation
import CoreAudio

let duration = Double(CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "") ?? 40
let start = Date()
let lock = NSLock()
var events: [(String, Double)] = []
var mouseMoveCount = 0

let eventMask: CGEventMask =
    (1 << CGEventType.keyDown.rawValue)
    | (1 << CGEventType.keyUp.rawValue)
    | (1 << CGEventType.flagsChanged.rawValue)
    | (1 << CGEventType.mouseMoved.rawValue)
    | (1 << 14)  // systemDefined

func logEvent(_ line: String) {
    lock.lock()
    events.append((line, Date().timeIntervalSince(start)))
    lock.unlock()
}

func tapCallback(_ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent, _ ctx: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if type.rawValue == 14, let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 {
        let usage = UInt32((ns.data1 & 0xFFFF0000) >> 16)
        let state = (ns.data1 & 0xFF00) >> 8
        if usage == 0x0C0061 || usage == 0x0C0058 || usage == 0x0C0054 || usage == 0x0C0055 || usage == 0x0C00E9 || usage == 0x0C00EA {
            logEvent("SYS consumer usage=0x\(String(usage, radix: 16)) \(state == 0x0A ? "down" : "up")")
        } else {
            logEvent("SYS consumer usage=0x\(String(usage, radix: 16)) \(state == 0x0A ? "down" : "up")")
        }
    } else {
        switch type {
        case .keyDown, .keyUp, .flagsChanged:
            let kc = event.getIntegerValueField(.keyboardEventKeycode)
            let flags = String(event.flags.rawValue, radix: 16)
            let kt = event.getIntegerValueField(.keyboardEventKeyboardType)
            logEvent("KEY \(type == .keyDown ? "down" : type == .keyUp ? "up" : "flags") kc=\(kc) kt=\(kt) flags=0x\(flags)")
        case .mouseMoved:
            let p = event.location
            lock.lock()
            mouseMoveCount += 1
            if mouseMoveCount % 10 == 1 {
                events.append(("MOUSE move (\(Int(p.x)),\(Int(p.y)))", Date().timeIntervalSince(start)))
            }
            lock.unlock()
        default:
            break
        }
    }
    return Unmanaged.passUnretained(event)
}

// 事件监听（listen-only，不拦截）
if let tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap,
                               options: .listenOnly, eventsOfInterest: eventMask,
                               callback: tapCallback, userInfo: nil) {
    let src = CFMachPortCreateRunLoopSource(nil, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
    CGEvent.tapEnable(tap: tap, enable: true)
    print("event tap active")
} else {
    print("event tap FAILED (缺少输入监控权限)")
}

print("audio capture handled by ffmpeg separately")

print("=== watching \(Int(duration))s — 现在操作遥控器 ===")
RunLoop.main.run(until: Date().addingTimeInterval(duration))

print("\n=== SUMMARY ===")
lock.lock()
var last = ""
for (line, t) in events where line != last {
    print(String(format: "[%6.2fs] %@", t, line))
    last = line
}
print("mouseMoveCount=\(mouseMoveCount)")
lock.unlock()
exit(0)
