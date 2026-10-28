import Foundation
import CoreGraphics

/// 方向键按住期间持续移动鼠标指针，先慢后快（0.8 秒起步，越按越快）。
final class MouseMover {
    static let shared = MouseMover()

    enum Arrow {
        case up, down, left, right

        var delta: (dx: CGFloat, dy: CGFloat) {
            switch self {
            case .up: return (0, -1)
            case .down: return (0, 1)
            case .left: return (-1, 0)
            case .right: return (1, 0)
            }
        }
    }

    static let arrowKeyCodes: [Int64: Arrow] = [
        123: .left, 124: .right, 125: .down, 126: .up,
    ]

    private var pressed: Set<Arrow> = []
    private var timer: Timer?
    private var holdStart = Date()

    func press(_ arrow: Arrow) {
        if pressed.isEmpty { holdStart = Date() }
        pressed.insert(arrow)
        ensureTimer()
    }

    func release(_ arrow: Arrow) {
        pressed.remove(arrow)
        if pressed.isEmpty {
            timer?.invalidate()
            timer = nil
        }
    }

    private func ensureTimer() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 0.02, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        guard !pressed.isEmpty else { return }
        let held = Date().timeIntervalSince(holdStart)
        let speed: CGFloat = held < 0.8 ? 8 : held < 2.0 ? 18 : 32

        var dx: CGFloat = 0
        var dy: CGFloat = 0
        for arrow in pressed {
            dx += arrow.delta.dx * speed
            dy += arrow.delta.dy * speed
        }
        guard dx != 0 || dy != 0,
              let current = CGEvent(source: nil)?.location else { return }

        let bounds = screenBounds()
        let next = CGPoint(
            x: min(max(current.x + dx, bounds.minX + 2), bounds.maxX - 2),
            y: min(max(current.y + dy, bounds.minY + 2), bounds.maxY - 2)
        )
        CGEvent(
            mouseEventSource: nil,
            mouseType: .mouseMoved,
            mouseCursorPosition: next,
            mouseButton: .left
        )?.post(tap: .cghidEventTap)
    }

    private func screenBounds() -> CGRect {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(16, &ids, &count) == .success, count > 0 else {
            return CGRect(x: 0, y: 0, width: 1920, height: 1080)
        }
        var union = CGRect.null
        for index in 0..<Int(count) {
            union = union.union(CGDisplayBounds(ids[index]))
        }
        return union
    }
}
