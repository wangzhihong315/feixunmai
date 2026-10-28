import AppKit

/// 遥控器精确示意图（AppKit 矢量绘制，对照实物照片：
/// 顶部双电源、大圆导航环+OK、两排三圆键、底部 PHICOMM）。
/// 按键实时高亮。
final class RemoteDiagramView: NSView {
    private var pressedName: String? {
        didSet { needsDisplay = true }
    }
    private var clearWork: DispatchWorkItem?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        NotificationCenter.default.addObserver(
            forName: .remoteButtonPressed, object: nil, queue: .main
        ) { [weak self] note in
            guard let name = note.object as? String else { return }
            self?.pressedName = name
            self?.clearWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.pressedName = nil }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
            self?.clearWork = work
        }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 170, height: 400)
    }

    // MARK: 布局常量（比例参照照片）
    private enum Layout {
        static let bodyRect = NSRect(x: 10, y: 0, width: 150, height: 400)
        static let topRowY: CGFloat = 352          // 双电源
        static let ringCenter = NSPoint(x: 85, y: 272)  // 导航环中心
        static let ringRadius: CGFloat = 50        // 环带外半径
        static let ringHole: CGFloat = 34          // 环带内半径
        static let okRadius: CGFloat = 24
        static let rowAY: CGFloat = 172            // 返回/语音/音量+
        static let rowBY: CGFloat = 108            // 主页/菜单/音量−
        static let buttonRadius: CGFloat = 18
        static let columnX: [CGFloat] = [40, 85, 130]
    }

    override func draw(_ dirtyRect: NSRect) {
        // 遥控器机身
        let body = NSBezierPath(roundedRect: Layout.bodyRect, xRadius: 26, yRadius: 26)
        NSColor(calibratedWhite: 0.13, alpha: 1).setFill()
        body.fill()

        // 顶部双电源
        drawButton(center: NSPoint(x: Layout.columnX[0] + 4, y: Layout.topRowY), radius: 15,
                   glyph: "⏻", glyphColor: .white, name: nil, label: nil)
        let ottRing = NSBezierPath(ovalIn: NSRect(
            x: Layout.columnX[0] + 4 - 12, y: Layout.topRowY - 12, width: 24, height: 24
        ))
        NSColor.systemRed.setStroke()
        ottRing.lineWidth = 1.5
        ottRing.stroke()
        drawButton(center: NSPoint(x: Layout.columnX[2] - 4, y: Layout.topRowY), radius: 15,
                   glyph: "⏻", glyphColor: .white, name: nil, label: "TV·红外")

        // 大圆导航环：环带（外圆填灰、内圆填机身色形成圆环）
        let outer = NSBezierPath(ovalIn: NSRect(
            x: Layout.ringCenter.x - Layout.ringRadius,
            y: Layout.ringCenter.y - Layout.ringRadius,
            width: Layout.ringRadius * 2, height: Layout.ringRadius * 2
        ))
        NSColor(calibratedWhite: 0.21, alpha: 1).setFill()
        outer.fill()
        let hole = NSBezierPath(ovalIn: NSRect(
            x: Layout.ringCenter.x - Layout.ringHole,
            y: Layout.ringCenter.y - Layout.ringHole,
            width: Layout.ringHole * 2, height: Layout.ringHole * 2
        ))
        NSColor(calibratedWhite: 0.13, alpha: 1).setFill()
        hole.fill()

        // 环带上的四个方向（箭头字符，高亮时画键帽底色）
        drawRingKey(name: "上", center: NSPoint(x: Layout.ringCenter.x, y: Layout.ringCenter.y + (Layout.ringRadius + Layout.ringHole) / 2), glyph: "↑")
        drawRingKey(name: "下", center: NSPoint(x: Layout.ringCenter.x, y: Layout.ringCenter.y - (Layout.ringRadius + Layout.ringHole) / 2), glyph: "↓")
        drawRingKey(name: "左", center: NSPoint(x: Layout.ringCenter.x - (Layout.ringRadius + Layout.ringHole) / 2, y: Layout.ringCenter.y), glyph: "←")
        drawRingKey(name: "右", center: NSPoint(x: Layout.ringCenter.x + (Layout.ringRadius + Layout.ringHole) / 2, y: Layout.ringCenter.y), glyph: "→")

        // OK 中心（独立圆）
        drawButton(center: Layout.ringCenter, radius: Layout.okRadius,
                   glyph: "OK", glyphColor: .white, name: "OK", fontSize: 12)

        // 第一排：返回 / 语音 / 音量+
        drawButton(center: NSPoint(x: Layout.columnX[0], y: Layout.rowAY), radius: Layout.buttonRadius,
                   glyph: "↩", glyphColor: .white, name: "返回")
        drawButton(center: NSPoint(x: Layout.columnX[1], y: Layout.rowAY), radius: Layout.buttonRadius,
                   glyph: "", glyphColor: .systemYellow, name: "语音键")
        drawMic(center: NSPoint(x: Layout.columnX[1], y: Layout.rowAY),
                color: pressedName == "语音键" ? .white : .systemYellow)
        drawButton(center: NSPoint(x: Layout.columnX[2], y: Layout.rowAY), radius: Layout.buttonRadius,
                   glyph: "+", glyphColor: .white, name: "音量 +")

        // 第二排：主页 / 菜单 / 音量−
        drawButton(center: NSPoint(x: Layout.columnX[0], y: Layout.rowBY), radius: Layout.buttonRadius,
                   glyph: "⌂", glyphColor: .white, name: "主页")
        drawButton(center: NSPoint(x: Layout.columnX[1], y: Layout.rowBY), radius: Layout.buttonRadius,
                   glyph: "☰", glyphColor: .white, name: "菜单")
        drawButton(center: NSPoint(x: Layout.columnX[2], y: Layout.rowBY), radius: Layout.buttonRadius,
                   glyph: "−", glyphColor: .white, name: "音量 −")

        // 底部品牌
        let phicomm = "PHICOMM" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor(calibratedWhite: 0.55, alpha: 1),
        ]
        let size = phicomm.size(withAttributes: attrs)
        phicomm.draw(
            at: NSPoint(x: Layout.bodyRect.midX - size.width / 2, y: 22),
            withAttributes: attrs
        )
    }

    private func drawMic(center: NSPoint, color: NSColor) {
        // 简笔麦克风：胶囊头 + 支架弧 + 底座
        let head = NSBezierPath(roundedRect: NSRect(x: center.x - 3.5, y: center.y - 2, width: 7, height: 12),
                                xRadius: 3.5, yRadius: 3.5)
        color.setFill()
        head.fill()
        let arc = NSBezierPath()
        arc.appendArc(withCenter: center, radius: 6.5,
                      startAngle: 200, endAngle: 340, clockwise: false)
        color.setStroke()
        arc.lineWidth = 1.5
        arc.stroke()
        let stem = NSBezierPath(rect: NSRect(x: center.x - 0.75, y: center.y - 6.5, width: 1.5, height: 5))
        stem.fill()
        let base = NSBezierPath(rect: NSRect(x: center.x - 4, y: center.y - 7.5, width: 8, height: 1.5))
        base.fill()
    }

    private func drawRingKey(name: String, center: NSPoint, glyph: String) {
        let isDown = pressedName == name
        if isDown {
            let rect = NSRect(x: center.x - 12, y: center.y - 11, width: 24, height: 22)
            let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
            NSColor.controlAccentColor.setFill()
            path.fill()
        }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: isDown ? NSColor.white : NSColor(calibratedWhite: 0.75, alpha: 1),
        ]
        let s = glyph as NSString
        let size = s.size(withAttributes: attrs)
        s.draw(at: NSPoint(x: center.x - size.width / 2, y: center.y - size.height / 2), withAttributes: attrs)
    }

    private func drawButton(center: NSPoint, radius: CGFloat, glyph: String,
                            glyphColor: NSColor, name: String?, label: String? = nil, fontSize: CGFloat = 11) {
        let isDown = name.map { pressedName == $0 } ?? false
        let rect = NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        let circle = NSBezierPath(ovalIn: rect)
        if isDown {
            NSColor.controlAccentColor.setFill()
        } else {
            NSColor(calibratedWhite: 0.24, alpha: 1).setFill()
        }
        circle.fill()
        NSColor(calibratedWhite: 0.35, alpha: 1).setStroke()
        circle.lineWidth = 1
        circle.stroke()

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
            .foregroundColor: isDown ? NSColor.white : glyphColor,
        ]
        let s = glyph as NSString
        let size = s.size(withAttributes: attrs)
        s.draw(at: NSPoint(x: center.x - size.width / 2, y: center.y - size.height / 2), withAttributes: attrs)

        if let label {
            let la: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 8),
                .foregroundColor: NSColor(calibratedWhite: 0.7, alpha: 1),
            ]
            let ls = label as NSString
            let lsize = ls.size(withAttributes: la)
            ls.draw(at: NSPoint(x: center.x - lsize.width / 2, y: center.y - radius - 12), withAttributes: la)
        }
    }
}
