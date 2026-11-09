import SwiftUI
import AppKit

// MARK: - Button mapping

struct ButtonMappingView: View {
    let snapshot: VibeDeckSnapshot
    let actions: VibeDeckActions

    var body: some View {
        if snapshot.voiceSource == .phone {
            PhoneMappingView()
        } else {
            remoteBody
        }
    }

    private var remoteBody: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("按键")
                    .font(.system(size: 24, weight: .semibold))
                    .tracking(-0.4)
                Text("遥控器物理按键映射；VibePad 触控板不经过这里")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }

            DeckCard(minHeight: 0) {
                VStack(alignment: .leading, spacing: 14) {
                    CardHeader(title: "遥控器按键", icon: "av.remote")
                    ToggleRow(
                        title: "方向键当鼠标用（按住移动，越按越快）",
                        isOn: snapshot.arrowsAsMouse,
                        onChange: actions.setArrowsAsMouse
                    )
                    Divider().opacity(0.6)

                    HStack(alignment: .top, spacing: 26) {
                        RemoteDiagramRepresentable()
                            .frame(width: 170, height: 400)
                            .background(
                                Color.primary.opacity(0.03),
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                            )

                        VStack(spacing: 8) {
                            ForEach(MappedButton.allCases) { button in
                                HStack(spacing: 12) {
                                    Text(button.label)
                                        .font(.system(size: 14))
                                        .frame(width: 84, alignment: .leading)
                                    Menu {
                                        ForEach(KeyAction.allCases) { action in
                                            Button(action.label) {
                                                actions.setMapping(button, action)
                                            }
                                        }
                                    } label: {
                                        SelectRow(title: actionLabel(for: button))
                                    }
                                    .menuStyle(.borderlessButton)
                                    .menuIndicator(.hidden)
                                }
                            }
                            Spacer(minLength: 0)
                            Text("“系统默认”= 不拦截，macOS 原生处理；改动即时生效。")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                }
            }
        }
    }

    private func actionLabel(for button: MappedButton) -> String {
        let action = snapshot.mappings[button.rawValue]
            ?? KeyAction.recommendedDefault(for: button, mouseMode: snapshot.arrowsAsMouse)
        return action.label
    }
}

// MARK: - 手机按键（产品展示）

private enum CalloutSide { case left, right }

private struct GestureCallout: Identifiable {
    let id: String
    let title: String
    let detail: String
    let icon: String
    /// 目标点在手机截图里的归一化坐标。
    let target: CGPoint
    let side: CalloutSide
    /// 标签在展示面板里的纵向位置（0-1）。
    let labelY: CGFloat
    let hot: Bool
}

private struct KeyLegendItem: Identifiable {
    let id: String
    let title: String
    let detail: String
    let icon: String
    let tint: Color
    /// 目标键在手机截图里的归一化坐标。
    let target: CGPoint
    /// 图例横向中心（0-1）。
    let x: CGFloat
    let hot: Bool
}

private struct PhoneMappingView: View {
    private let gestures: [GestureCallout] = [
        GestureCallout(
            id: "move", title: "单指移动",
            detail: "拖动 Mac 指针，速度跟随手指",
            icon: "hand.point.up.left",
            target: CGPoint(x: 0.33, y: 0.24), side: .left, labelY: 0.175, hot: false
        ),
        GestureCallout(
            id: "scroll", title: "双指滚动",
            detail: "上下滚动页面，方向可设为自然",
            icon: "arrow.up.arrow.down",
            target: CGPoint(x: 0.55, y: 0.33), side: .left, labelY: 0.30, hot: false
        ),
        GestureCallout(
            id: "drag", title: "按住不动再拖",
            detail: "按住约 0.35 秒后移动 = 左键拖拽",
            icon: "hand.tap",
            target: CGPoint(x: 0.33, y: 0.66), side: .left, labelY: 0.425, hot: false
        ),
        GestureCallout(
            id: "voice", title: "按住说话",
            detail: "按住说，松手结束",
            icon: "mic",
            target: CGPoint(x: 0.39, y: 0.865), side: .left, labelY: 0.60, hot: true
        ),
        GestureCallout(
            id: "edge", title: "边缘滚动",
            detail: "拇指沿屏幕边缘滑动即滚动，左右手自动镜像",
            icon: "sidebar.leading",
            target: CGPoint(x: 0.90, y: 0.64), side: .right, labelY: 0.175, hot: false
        ),
        GestureCallout(
            id: "pan", title: "双指横向",
            detail: "左右滚动，横向长页面也能推",
            icon: "arrow.left.arrow.right",
            target: CGPoint(x: 0.67, y: 0.42), side: .right, labelY: 0.30, hot: false
        ),
        GestureCallout(
            id: "rightclick", title: "双指轻点",
            detail: "右键单击，等同于触控板双指点按",
            icon: "cursorarrow.click.2",
            target: CGPoint(x: 0.62, y: 0.57), side: .right, labelY: 0.425, hot: false
        ),
        GestureCallout(
            id: "confirm", title: "确认",
            detail: "点按发送 Return",
            icon: "return",
            target: CGPoint(x: 0.845, y: 0.865), side: .right, labelY: 0.60, hot: true
        )
    ]

    private let keys: [KeyLegendItem] = [
        KeyLegendItem(
            id: "capsule", title: "胶囊", detail: "按住录，松手存",
            icon: "capsule", tint: Color(red: 0.788, green: 0.204, blue: 0.0),
            target: CGPoint(x: 0.167, y: 0.945), x: 0.155, hot: false
        ),
        KeyLegendItem(
            id: "delete", title: "删除", detail: "点按退格 · 长按清空",
            icon: "delete.left", tint: Color(white: 0.29),
            target: CGPoint(x: 0.389, y: 0.945), x: 0.385, hot: false
        ),
        KeyLegendItem(
            id: "esc", title: "打断", detail: "发送 Esc",
            icon: "escape", tint: Color(white: 0.29),
            target: CGPoint(x: 0.611, y: 0.945), x: 0.615, hot: false
        ),
        KeyLegendItem(
            id: "switch", title: "切换", detail: "Cmd+Tab 上一个 App",
            icon: "rectangle.on.rectangle", tint: Color(white: 0.29),
            target: CGPoint(x: 0.833, y: 0.945), x: 0.845, hot: false
        )
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("VIBEPAD · PHONE")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.8)
                    .foregroundStyle(Color(white: 0.58))
                Text("按键")
                    .font(.system(size: 24, weight: .semibold))
                    .tracking(-0.5)
                Text("触控板手势在左，按键在图例里；布局跟随左右手设置镜像。")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }

            PhoneShowcasePanel(gestures: gestures, keys: keys)
                .frame(height: 700)

            HStack(spacing: 7) {
                Image(systemName: "info.circle")
                    .font(.system(size: 12))
                Text("手机是标准蓝牙 HID；切回斐讯遥控器后，原来的遥控器映射页才会生效。")
                    .font(.system(size: 11.5))
            }
            .foregroundStyle(Color(white: 0.55))
        }
    }
}

private struct PhoneShowcasePanel: View {
    let gestures: [GestureCallout]
    let keys: [KeyLegendItem]

    private static let phoneImage: NSImage? = {
        guard let url = Bundle.main.url(
            forResource: "PhoneShowcase",
            withExtension: "png"
        ) else { return nil }
        return NSImage(contentsOf: url)
    }()

    private let ink = Color(red: 0.11, green: 0.11, blue: 0.12)
    private let muted = Color(red: 0.43, green: 0.43, blue: 0.45)
    private let blue = Color(red: 0.039, green: 0.518, blue: 1.0)

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let phoneWidth = min(size.width * 0.335, 300)
            let phoneHeight = phoneWidth / 0.45
            let phoneRect = CGRect(
                x: (size.width - phoneWidth) / 2,
                y: 16,
                width: phoneWidth,
                height: phoneHeight
            )
            let gap = size.width * 0.081
            let labelWidth = max(150, phoneRect.minX - gap - 4)
            let legendY = size.height * 0.845

            ZStack(alignment: .topLeading) {
                backdrop

                if let image = Self.phoneImage {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: phoneWidth, height: phoneHeight)
                        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 26, style: .continuous)
                                .stroke(Color.black.opacity(0.12), lineWidth: 1)
                        }
                        .shadow(color: .black.opacity(0.22), radius: 30, y: 14)
                        .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
                        .position(x: phoneRect.midX, y: phoneRect.midY)
                } else {
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .fill(Color.white)
                        .frame(width: phoneWidth, height: phoneHeight)
                        .overlay {
                            Text("把手机主界面截图放到\nResources/PhoneShowcase.png")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .position(x: phoneRect.midX, y: phoneRect.midY)
                }

                Canvas { context, _ in
                    for callout in gestures {
                        let target = point(callout.target, in: phoneRect)
                        let labelY = callout.labelY * size.height
                        let anchorX = callout.side == .left
                            ? phoneRect.minX - gap
                            : phoneRect.maxX + gap
                        var path = Path()
                        path.move(to: CGPoint(x: anchorX, y: labelY))
                        let cp1 = CGPoint(
                            x: callout.side == .left
                                ? anchorX + size.width * 0.07
                                : anchorX - size.width * 0.05,
                            y: labelY
                        )
                        let cp2 = CGPoint(
                            x: callout.side == .left
                                ? target.x - size.width * 0.05
                                : target.x + size.width * 0.05,
                            y: target.y
                        )
                        path.addCurve(to: target, control1: cp1, control2: cp2)
                        context.stroke(
                            path,
                            with: .color(Color(red: 0.16, green: 0.24, blue: 0.35).opacity(0.30)),
                            style: StrokeStyle(lineWidth: 1.1, lineCap: .round)
                        )
                        drawMarker(target, in: &context, big: callout.hot)
                    }

                    for item in keys {
                        let target = point(item.target, in: phoneRect)
                        let start = CGPoint(x: item.x * size.width, y: legendY)
                        var path = Path()
                        path.move(to: start)
                        path.addCurve(
                            to: target,
                            control1: CGPoint(x: start.x, y: start.y - 60),
                            control2: CGPoint(x: target.x, y: target.y + 60)
                        )
                        context.stroke(
                            path,
                            with: .color(
                                item.hot
                                    ? blue.opacity(0.48)
                                    : Color(red: 0.16, green: 0.24, blue: 0.35).opacity(0.26)
                            ),
                            style: StrokeStyle(lineWidth: 1.1, lineCap: .round)
                        )
                        drawMarker(target, in: &context, big: item.hot)
                    }
                }

                ForEach(gestures) { callout in
                    gestureLabel(callout, size: size, phoneRect: phoneRect, gap: gap, labelWidth: labelWidth)
                }

                ForEach(keys) { item in
                    keyLabel(item, size: size, y: legendY + 10)
                }
            }
        }
    }

    private func point(_ normalized: CGPoint, in rect: CGRect) -> CGPoint {
        CGPoint(
            x: rect.minX + normalized.x * rect.width,
            y: rect.minY + normalized.y * rect.height
        )
    }

    private func drawMarker(_ point: CGPoint, in context: inout GraphicsContext, big: Bool) {
        let ring = big ? 8.0 : 7.0
        context.fill(
            Path(ellipseIn: CGRect(x: point.x - ring, y: point.y - ring, width: ring * 2, height: ring * 2)),
            with: .color(blue.opacity(0.12))
        )
        context.stroke(
            Path(ellipseIn: CGRect(x: point.x - ring, y: point.y - ring, width: ring * 2, height: ring * 2)),
            with: .color(blue.opacity(0.28)),
            lineWidth: 1
        )
        let core = big ? 2.8 : 2.6
        context.fill(
            Path(ellipseIn: CGRect(x: point.x - core, y: point.y - core, width: core * 2, height: core * 2)),
            with: .color(blue)
        )
    }

    private var backdrop: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.984, green: 0.988, blue: 0.996),
                    Color(red: 0.933, green: 0.945, blue: 0.965)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            RadialGradient(
                colors: [blue.opacity(0.09), .clear],
                center: .top,
                startRadius: 0,
                endRadius: 320
            )
            Canvas { context, size in
                let step: CGFloat = 26
                var x = step / 2
                while x < size.width {
                    var y = step / 2
                    while y < size.height {
                        context.fill(
                            Path(ellipseIn: CGRect(x: x, y: y, width: 2.2, height: 2.2)),
                            with: .color(Color(red: 0.16, green: 0.24, blue: 0.35).opacity(0.10))
                        )
                        y += step
                    }
                    x += step
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.black.opacity(0.08), lineWidth: 1)
        }
    }

    private func gestureLabel(
        _ callout: GestureCallout,
        size: CGSize,
        phoneRect: CGRect,
        gap: CGFloat,
        labelWidth: CGFloat
    ) -> some View {
        let centerX: CGFloat = callout.side == .left
            ? phoneRect.minX - gap - labelWidth / 2
            : phoneRect.maxX + gap + labelWidth / 2
        return VStack(
            alignment: callout.side == .left ? .trailing : .leading,
            spacing: 3
        ) {
            HStack(spacing: 7) {
                iconChip(callout.icon, tint: callout.hot ? blue : Color(white: 0.29), size: 22)
                Text(callout.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(ink)
            }
            Text(callout.detail)
                .font(.system(size: 11))
                .foregroundStyle(muted)
                .multilineTextAlignment(callout.side == .left ? .trailing : .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: labelWidth, alignment: callout.side == .left ? .trailing : .leading)
        .position(x: centerX, y: callout.labelY * size.height)
    }

    private func keyLabel(_ item: KeyLegendItem, size: CGSize, y: CGFloat) -> some View {
        VStack(spacing: 2) {
            HStack(spacing: 6) {
                iconChip(item.icon, tint: item.tint, size: 20)
                Text(item.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(ink)
            }
            Text(item.detail)
                .font(.system(size: 10.5))
                .foregroundStyle(muted)
                .lineLimit(1)
        }
        .frame(width: min(150, size.width / 6))
        .position(x: item.x * size.width, y: y)
    }

    private func iconChip(_ name: String, tint: Color, size: CGFloat) -> some View {
        Image(systemName: name)
            .font(.system(size: size * 0.55, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.black.opacity(0.10), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.06), radius: 1, y: 1)
    }
}

struct RemoteDiagramRepresentable: NSViewRepresentable {
    func makeNSView(context: Context) -> RemoteDiagramView {
        RemoteDiagramView(frame: NSRect(x: 0, y: 0, width: 170, height: 400))
    }

    func updateNSView(_ nsView: RemoteDiagramView, context: Context) {}
}

// MARK: - Stats

struct StatsView: View {
    let snapshot: VibeDeckSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("统计")
                    .font(.system(size: 24, weight: .semibold))
                    .tracking(-0.4)
                Text("只保存在本机，不上传语音")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 16) {
                StatCard(
                    title: "今日语音次数",
                    value: "\(snapshot.todayCount)",
                    unit: "次",
                    subtitle: "每次按住说话算一次",
                    icon: "waveform.path.ecg"
                )
                StatCard(
                    title: "今日语音时长",
                    value: durationText,
                    unit: "",
                    subtitle: "从按下到松开累计",
                    icon: "timer"
                )
            }

            DeckCard(minHeight: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "lock")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                    Text("语音只在本机解码和转发；统计只写入本机偏好设置。")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var durationText: String {
        let total = Int(snapshot.todaySeconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct StatCard: View {
    let title: String
    let value: String
    let unit: String
    let subtitle: String
    let icon: String

    var body: some View {
        DeckCard(minHeight: 160) {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(title: title, icon: icon)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(value)
                        .font(.system(size: 42, weight: .semibold))
                        .monospacedDigit()
                    if !unit.isEmpty {
                        Text(unit)
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
