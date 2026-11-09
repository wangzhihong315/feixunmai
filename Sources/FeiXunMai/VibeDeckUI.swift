import SwiftUI
import AppKit

// MARK: - Navigation

enum VibeDeckSection: String, CaseIterable, Identifiable {
    case overview
    case voice
    case capsules
    case buttons
    case stats

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "概览"
        case .voice: return "语音"
        case .capsules: return "闪念胶囊"
        case .buttons: return "按键"
        case .stats: return "统计"
        }
    }

    var icon: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .voice: return "mic"
        case .capsules: return "capsule"
        case .buttons: return "keyboard"
        case .stats: return "chart.bar"
        }
    }
}

// MARK: - Root

struct VibeDeckRootView: View {
    let snapshot: VibeDeckSnapshot
    let actions: VibeDeckActions

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(snapshot: snapshot, actions: actions)
                .frame(width: 236)
            Divider()
            ScrollView {
                Group {
                    switch snapshot.section {
                    case .overview:
                        OverviewView(snapshot: snapshot, actions: actions)
                    case .voice:
                        VoiceSettingsView(snapshot: snapshot, actions: actions)
                    case .capsules:
                        CapsulesView(snapshot: snapshot, actions: actions)
                    case .buttons:
                        ButtonMappingView(snapshot: snapshot, actions: actions)
                    case .stats:
                        StatsView(snapshot: snapshot)
                    }
                }
                .padding(.horizontal, 30)
                .padding(.top, 24)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 900, minHeight: 620)
    }
}

// MARK: - Sidebar

/// 侧边栏的闪念胶囊图标：斜放的药丸，下半截实心。
struct PillMark: View {
    var color: Color

    var body: some View {
        Canvas { context, size in
            let w = size.width
            let h = size.height
            let transform = CGAffineTransform(translationX: w / 2, y: h / 2)
                .rotated(by: -26 * .pi / 180)
                .translatedBy(x: -w / 2, y: -h / 2)
            let bodyRect = CGRect(
                x: w * 0.33,
                y: h * 0.05,
                width: w * 0.34,
                height: h * 0.90
            )
            let radius = bodyRect.width / 2
            let body = Path(roundedRect: bodyRect, cornerRadius: radius)
                .applying(transform)
            let half = Path(CGRect(
                x: bodyRect.minX,
                y: bodyRect.midY,
                width: bodyRect.width,
                height: bodyRect.height / 2
            )).applying(transform)
            context.drawLayer { layer in
                layer.clip(to: body)
                layer.fill(half, with: .color(color.opacity(0.85)))
            }
            context.stroke(body, with: .color(color), lineWidth: max(1.1, w * 0.07))
        }
    }
}

private struct SidebarView: View {
    let snapshot: VibeDeckSnapshot
    let actions: VibeDeckActions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary)
                    .frame(width: 44, height: 44)
                    .overlay {
                        Image(systemName: "waveform")
                            .font(.system(size: 24, weight: .medium))
                            .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                    }
                VStack(alignment: .leading, spacing: 2) {
                    Text("VibeDeck")
                        .font(.system(size: 15, weight: .semibold))
                    Text("语音控制台")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 18)

            ForEach(VibeDeckSection.allCases) { section in
                Button {
                    actions.selectSection(section)
                } label: {
                    HStack(spacing: 10) {
                        if section == .capsules {
                            PillMark(
                                color: snapshot.section == section
                                    ? Color.primary
                                    : Color.secondary
                            )
                            .frame(width: 16, height: 16)
                            .frame(width: 18)
                        } else {
                            Image(systemName: section.icon)
                                .font(.system(size: 15, weight: .medium))
                                .frame(width: 18)
                        }
                        Text(section.title)
                            .font(.system(size: 14, weight: snapshot.section == section ? .semibold : .regular))
                        Spacer()
                    }
                    .foregroundStyle(snapshot.section == section ? Color.primary : Color.secondary)
                    .padding(.horizontal, 10)
                    .frame(height: 34)
                    .background(
                        snapshot.section == section ? Color.primary.opacity(0.07) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.bottom, 2)
            }

            Spacer()

            VStack(alignment: .leading, spacing: 8) {
                Divider().opacity(0.6)
                HStack(spacing: 7) {
                    StatusDot(color: statusColor, size: 7)
                    Text(statusLine)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text("v\(snapshot.version)，本机运行")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
        }
        .padding(.top, 20)
        .padding(.horizontal, 14)
        .padding(.bottom, 24)
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private var statusColor: Color {
        snapshot.isVoiceReady ? .green : .orange
    }

    private var statusLine: String {
        if snapshot.voiceSource == .phone {
            return snapshot.phoneReady ? "VibePad 已连接" : snapshot.phoneStateLabel
        }
        return snapshot.remoteConnected ? "遥控器已连接" : snapshot.remoteStateText
    }
}

// MARK: - Shared components

struct DeckCard<Content: View>: View {
    var minHeight: CGFloat = 180
    @ViewBuilder var content: Content

    init(minHeight: CGFloat = 180, @ViewBuilder content: () -> Content) {
        self.minHeight = minHeight
        self.content = content()
    }

    var body: some View {
        content
            .padding(18)
            .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .topLeading)
            .background(
                Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.04), radius: 8, y: 2)
    }
}

struct CardHeader: View {
    let title: String
    let icon: String

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
        }
    }
}

struct SelectRow: View {
    let title: String

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 14))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color.primary.opacity(0.05), lineWidth: 1)
        }
        .contentShape(Rectangle())
    }
}

struct ToggleRow: View {
    let title: String
    let isOn: Bool
    let onChange: (Bool) -> Void

    var body: some View {
        Button {
            onChange(!isOn)
        } label: {
            HStack(spacing: 12) {
                Text(title)
                    .font(.system(size: 14))
                Spacer(minLength: 8)
                DeckSwitch(isOn: isOn)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct DeckSwitch: View {
    let isOn: Bool

    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule()
                .fill(isOn ? Color.green : Color.secondary.opacity(0.28))
                .frame(width: 38, height: 22)
            Circle()
                .fill(Color.white)
                .frame(width: 18, height: 18)
                .padding(2)
                .shadow(color: .black.opacity(0.18), radius: 1, y: 1)
        }
        .frame(width: 38, height: 22)
    }
}

struct StatusDot: View {
    let color: Color
    var size: CGFloat = 7

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .shadow(color: color.opacity(0.35), radius: 2)
    }
}

struct WaveformView: View {
    let active: Bool

    var body: some View {
        LiveWaveform(active: active)
            .frame(height: 26)
    }
}

/// 真实电平条：直接读虚拟声卡链路里的信号峰值，说话时才会跳起来。
/// 用 AppKit 轮询是为了绕开 SwiftUI 状态（本机工具链没有宏，@State 不可用）。
private struct LiveWaveform: NSViewRepresentable {
    let active: Bool

    func makeNSView(context: Context) -> LiveWaveformView {
        let view = LiveWaveformView()
        view.active = active
        return view
    }

    func updateNSView(_ nsView: LiveWaveformView, context: Context) {
        nsView.active = active
    }
}

final class LiveWaveformView: NSView {
    var active = false {
        didSet { needsDisplay = true }
    }

    private let baseHeights: [CGFloat] = [
        4, 7, 12, 6, 18, 10, 4, 9, 22, 14,
        5, 8, 19, 11, 6, 15, 24, 9, 5, 13,
        20, 7, 4, 12, 17, 8, 6, 14, 10, 5
    ]
    private var level: CGFloat = 0
    private var timer: Timer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let target = CGFloat(min(1, AudioSinkRouter.shared.meterLevel))
            let factor: CGFloat = target > self.level ? 0.5 : 0.10
            self.level += (target - self.level) * factor
            self.needsDisplay = true
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        timer?.invalidate()
    }

    override func draw(_ dirtyRect: NSRect) {
        let count = baseHeights.count
        let gap: CGFloat = 3
        let barWidth = max(1, (bounds.width - gap * CGFloat(count - 1)) / CGFloat(count))
        let gain = 0.45 + (active ? 0.95 * level : 0)
        for (index, base) in baseHeights.enumerated() {
            let height = min(bounds.height, max(2, base * gain))
            let rect = NSRect(
                x: CGFloat(index) * (barWidth + gap),
                y: 0,
                width: barWidth,
                height: height
            )
            let radius = min(barWidth / 2, 1.5)
            let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
            let color: NSColor
            if index % 3 == 0 {
                color = NSColor.controlAccentColor
                    .withAlphaComponent(active ? 0.72 : 0.34)
            } else {
                color = NSColor.secondaryLabelColor
                    .withAlphaComponent(active ? 0.38 : 0.18)
            }
            color.setFill()
            path.fill()
        }
    }
}

struct LinkButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(Color.accentColor)
        }
        .buttonStyle(.plain)
    }
}

extension VoiceKeyMode {
    var shortLabel: String {
        switch self {
        case .nativeF5: return "F5 直连"
        case .fnHold: return "Fn 长按"
        case .leftCommand: return "左 Command"
        case .rightCommand: return "右 Command"
        case .leftOption: return "左 Option"
        case .rightOption: return "右 Option"
        case .none: return "不发送"
        }
    }
}

extension BridgeModel {
    var outputDeviceName: String {
        chosenDevice()?.name ?? "跟随系统默认"
    }

    /// Wi-Fi 语音链路是否在线（手机设置里选了 Wi-Fi 时才可能有）。
    var wifiVoiceConnected: Bool {
        voiceSource == .phone && VoiceTCPServer.shared.isConnected
    }

    var isVoiceReady: Bool {
        if voiceSource == .phone {
            return wifiVoiceConnected || PhoneAudioBridge.shared.state == .ready
        }
        return connectionState == .connected
    }

    var sourceDisplayName: String {
        voiceSource == .phone ? "VibePad" : remoteName
    }

    var sourceConnectionText: String {
        if voiceSource == .phone {
            if wifiVoiceConnected { return "Wi-Fi 已连接" }
            return PhoneAudioBridge.shared.state.text
        }
        return connectionState.rawValue
    }

    var sourceTransportLabel: String {
        if voiceSource == .phone, wifiVoiceConnected { return "局域网 TCP" }
        return voiceSource == .phone ? "Android BLE" : "蓝牙遥控器"
    }
}
