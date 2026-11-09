import SwiftUI
import AppKit

// MARK: - Overview

struct OverviewView: View {
    let snapshot: VibeDeckSnapshot
    let actions: VibeDeckActions

    var body: some View {
        VStack(spacing: 16) {
            HeroCard(snapshot: snapshot)
            SettingsGrid(snapshot: snapshot, actions: actions)
        }
    }
}

struct SettingsGrid: View {
    let snapshot: VibeDeckSnapshot
    let actions: VibeDeckActions

    var body: some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: 16),
                GridItem(.flexible(), spacing: 16)
            ],
            alignment: .leading,
            spacing: 16
        ) {
            SourceCard(snapshot: snapshot, actions: actions)
            RoutingCard(snapshot: snapshot, actions: actions)
            VoiceKeyCard(snapshot: snapshot, actions: actions)
            PermissionsCard(snapshot: snapshot, actions: actions)
        }
    }
}

// MARK: - Hero

struct HeroCard: View {
    let snapshot: VibeDeckSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        StatusDot(color: statusColor, size: 10)
                        Text(heroTitle)
                            .font(.system(size: 24, weight: .semibold))
                            .tracking(-0.4)
                    }
                    Text(heroSubtitle)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 12)
                Text(badge)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(badgeColor)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(badgeColor.opacity(0.12), in: Capsule())
                    .overlay {
                        Capsule().stroke(badgeColor.opacity(0.16), lineWidth: 1)
                    }
            }

            HStack(spacing: 8) {
                PathNode(
                    title: snapshot.sourceName,
                    subtitle: snapshot.sourceTransportLabel,
                    active: snapshot.isVoiceReady
                )
                Image(systemName: "arrow.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.tertiary)
                PathNode(
                    title: snapshot.outputDeviceName,
                    subtitle: "虚拟麦克风",
                    active: false
                )
                Image(systemName: "arrow.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.tertiary)
                PathNode(
                    title: "语音输入法",
                    subtitle: "系统默认麦克风",
                    active: false
                )
            }
            .padding(.top, 18)

            WaveformView(active: snapshot.voiceActive)
                .padding(.top, 16)
                .opacity(snapshot.isVoiceReady ? 1 : 0.42)
        }
        .padding(22)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.04), radius: 10, y: 2)
    }

    private var heroTitle: String {
        if snapshot.voiceActive { return "正在收音" }
        return snapshot.isVoiceReady ? "语音通路就绪" : "等待连接"
    }

    private var heroSubtitle: String {
        "\(snapshot.sourceName) \(snapshot.sourceConnectionText)，输出 \(snapshot.outputDeviceName)，触发 \(snapshot.voiceKeyShort)"
    }

    private var badge: String {
        if snapshot.voiceActive { return "说话中" }
        return snapshot.isVoiceReady ? "待机" : "未就绪"
    }

    private var badgeColor: Color {
        if snapshot.voiceActive { return .accentColor }
        return snapshot.isVoiceReady ? .green : .orange
    }

    private var statusColor: Color {
        if snapshot.voiceActive { return .accentColor }
        return snapshot.isVoiceReady ? .green : .orange
    }
}

private struct PathNode: View {
    let title: String
    let subtitle: String
    let active: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(active ? Color.accentColor : Color.primary)
                .lineLimit(1)
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            active ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.04),
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(
                    active ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.05),
                    lineWidth: 1
                )
        }
    }
}

// MARK: - Source

private struct SourceCard: View {
    let snapshot: VibeDeckSnapshot
    let actions: VibeDeckActions

    var body: some View {
        DeckCard {
            VStack(alignment: .leading, spacing: 12) {
                CardHeader(title: "语音来源", icon: "iphone")
                SourceSegment(snapshot: snapshot, actions: actions)
                HStack(spacing: 7) {
                    StatusDot(color: snapshot.isVoiceReady ? .green : .orange, size: 6)
                    Text(snapshot.sourceConnectionText)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                LinkButton(title: rescanTitle, action: actions.rescanSource)
            }
        }
    }

    private var rescanTitle: String {
        snapshot.voiceSource == .phone ? "重新扫描 VibePad" : "重新连接遥控器"
    }
}

private struct SourceSegment: View {
    let snapshot: VibeDeckSnapshot
    let actions: VibeDeckActions

    var body: some View {
        HStack(spacing: 2) {
            segment(source: .phone, title: "VibePad（BLE）")
            segment(source: .remote, title: "斐讯遥控器")
        }
        .padding(3)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func segment(source: VoiceSource, title: String) -> some View {
        Button {
            actions.setVoiceSource(source)
        } label: {
            Text(title)
                .font(.system(size: 13.5, weight: snapshot.voiceSource == source ? .semibold : .regular))
                .foregroundStyle(snapshot.voiceSource == source ? Color.primary : Color.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(
                    snapshot.voiceSource == source
                        ? Color(nsColor: .controlBackgroundColor)
                        : Color.clear,
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
                .shadow(
                    color: snapshot.voiceSource == source ? .black.opacity(0.08) : .clear,
                    radius: 2,
                    y: 1
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Routing

private struct RoutingCard: View {
    let snapshot: VibeDeckSnapshot
    let actions: VibeDeckActions

    var body: some View {
        DeckCard {
            VStack(alignment: .leading, spacing: 12) {
                CardHeader(title: "声音路由", icon: "hifispeaker")
                Menu {
                    Button("跟随系统默认") { actions.selectDevice("") }
                    Divider()
                    ForEach(snapshot.audioDevices) { device in
                        Button(device.name) { actions.selectDevice(device.uid) }
                    }
                } label: {
                    SelectRow(title: snapshot.outputDeviceName)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)

                ToggleRow(
                    title: "语音时切换系统麦克风",
                    isOn: snapshot.autoSwitchInput,
                    onChange: actions.setAutoSwitch
                )
                ToggleRow(
                    title: "本机同时出声",
                    isOn: snapshot.monitorEnabled,
                    onChange: actions.setMonitor
                )
                Spacer(minLength: 0)
                Text("说话时切换，松开还原。")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                if snapshot.showDiagnostics {
                    HStack(spacing: 14) {
                        LinkButton(
                            title: snapshot.micProbeRunning
                                ? "自检中…（对着手机说话）"
                                : "麦克风自检 12 秒",
                            action: actions.probeMic
                        )
                        LinkButton(title: "回环自检 1kHz", action: actions.loopbackTest)
                        LinkButton(title: "录虚拟麦 8 秒", action: actions.recordVirtualMic)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }
}

// MARK: - Voice key

private struct VoiceKeyCard: View {
    let snapshot: VibeDeckSnapshot
    let actions: VibeDeckActions

    var body: some View {
        DeckCard {
            VStack(alignment: .leading, spacing: 12) {
                CardHeader(title: "语音键", icon: "keyboard")
                Menu {
                    ForEach(VoiceKeyMode.allCases) { mode in
                        Button(mode.rawValue) {
                            actions.setVoiceKeyMode(mode)
                        }
                    }
                } label: {
                    SelectRow(title: snapshot.voiceKeyShort)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)

                ToggleRow(
                    title: "点按切换（开始 / 结束各按一下）",
                    isOn: snapshot.voiceKeyTapToggle,
                    onChange: actions.setTapToggle
                )
                Spacer(minLength: 0)
                Text("VibePad 来源下自动回退 Fn 长按。")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Permissions

private struct PermissionsCard: View {
    let snapshot: VibeDeckSnapshot
    let actions: VibeDeckActions

    var body: some View {
        DeckCard {
            VStack(alignment: .leading, spacing: 12) {
                CardHeader(title: "权限", icon: "lock.shield")
                PermissionRow(title: "辅助功能", granted: snapshot.accessibilityGranted)
                PermissionRow(title: "蓝牙", granted: snapshot.bluetoothAuthorized)
                Spacer(minLength: 0)
                Menu("打开系统设置") {
                    Button("辅助功能") { actions.openAccessibility() }
                    Button("蓝牙") { actions.openBluetooth() }
                }
                .menuStyle(.borderlessButton)
                .font(.system(size: 13))
                .foregroundStyle(Color.accentColor)
            }
        }
    }
}

private struct PermissionRow: View {
    let title: String
    let granted: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(granted ? .green : .orange)
            Text(title)
                .font(.system(size: 14))
            Spacer()
            Text(granted ? "已授权" : "未授权")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Voice settings page

struct VoiceSettingsView: View {
    let snapshot: VibeDeckSnapshot
    let actions: VibeDeckActions

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("语音")
                    .font(.system(size: 24, weight: .semibold))
                    .tracking(-0.4)
                Text("来源、路由和触发键")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            SettingsGrid(snapshot: snapshot, actions: actions)
            ConnectionDetailCard(snapshot: snapshot, actions: actions)
        }
    }
}

private struct ConnectionDetailCard: View {
    let snapshot: VibeDeckSnapshot
    let actions: VibeDeckActions

    var body: some View {
        DeckCard(minHeight: 0) {
            VStack(alignment: .leading, spacing: 14) {
                CardHeader(title: "连接详情", icon: "antenna.radiowaves.left.and.right")
                connectionRow(
                    name: "VibePad",
                    status: snapshot.phoneStateText,
                    ready: snapshot.phoneReady,
                    actionTitle: "重新扫描",
                    action: actions.rescanPhone
                )
                Divider().opacity(0.6)
                connectionRow(
                    name: snapshot.remoteName,
                    status: snapshot.remoteStateText,
                    ready: snapshot.remoteConnected,
                    actionTitle: "重新连接",
                    action: actions.rescanRemote
                )
            }
        }
    }

    private func connectionRow(
        name: String,
        status: String,
        ready: Bool,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 10) {
            StatusDot(color: ready ? .green : .orange, size: 7)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: 14, weight: .semibold))
                Text(status)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            LinkButton(title: actionTitle, action: action)
        }
    }
}
