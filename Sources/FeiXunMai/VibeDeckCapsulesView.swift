import SwiftUI
import AppKit

// MARK: - 闪念胶囊（备忘录式卡片）

struct CapsulesView: View {
    let snapshot: VibeDeckSnapshot
    let actions: VibeDeckActions

    private let columns = [
        GridItem(.adaptive(minimum: 200, maximum: 280), spacing: 14, alignment: .top)
    ]

    private var transcribedCount: Int {
        max(0, snapshot.capsules.count - snapshot.capsulePendingCount)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("闪念胶囊")
                    .font(.system(size: 24, weight: .semibold))
                    .tracking(-0.4)
                Text("手机上按住「胶囊」随手录；Mac 空闲时自动用豆包转成文字")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 14)

            toolbar
                .padding(.bottom, 14)

            if snapshot.capsules.isEmpty {
                emptyState
            } else {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                    ForEach(snapshot.capsules) { row in
                        CapsuleNoteCard(row: row) {
                            actions.transcribeCapsule(row.id)
                        }
                    }
                }
            }

            HStack(spacing: 7) {
                Image(systemName: "folder")
                    .font(.system(size: 11))
                Text("录音与转写文本保存在 ~/Library/Application Support/VibeDeck/capsules")
                    .font(.system(size: 11))
            }
            .foregroundStyle(.tertiary)
            .padding(.top, 14)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 14) {
            HStack(spacing: 6) {
                Circle()
                    .fill(Color.orange)
                    .frame(width: 6, height: 6)
                Text("\(snapshot.capsulePendingCount) 条待转写")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 6, height: 6)
                Text("\(transcribedCount) 条已转写")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            Button {
                actions.setCapsuleAuto(!snapshot.capsuleAutoEnabled)
            } label: {
                HStack(spacing: 8) {
                    Text("空闲自动转写")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    DeckSwitch(isOn: snapshot.capsuleAutoEnabled)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("约 \(Int(snapshot.capsuleIdleSeconds)) 秒无键鼠输入后自动开始")

            Button("立即转写") {
                actions.transcribeNextCapsule()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(snapshot.capsulePendingCount == 0)

            Button("打开目录") {
                actions.revealCapsules()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.bottom, 10)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.07))
                .frame(height: 1)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "capsule")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(.tertiary)
            Text("还没有胶囊")
                .font(.system(size: 15, weight: .semibold))
            Text("在 VibePad 触控板下方按住「胶囊」说一句，松手即存；\n手机连上 Mac 后会自动同步过来。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 320)
    }
}

private struct CapsuleNoteCard: View {
    let row: CapsuleRowModel
    let onTranscribe: () -> Void

    private var pending: Bool { row.text == nil }

    /// 便签式卡片：不放标题，正文直接铺在格子里。
    private var displayText: String {
        guard let text = row.text, !text.isEmpty else {
            return "等待转写…"
        }
        return text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(displayText)
                .font(.system(size: 13))
                .lineSpacing(2)
                .foregroundStyle(pending ? Color.secondary : Color.primary)
                .lineLimit(7)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 10)

            HStack(spacing: 6) {
                Text(row.timeLabel)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                Text("·")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.quaternary)
                Text(row.durationLabel)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)

                Spacer(minLength: 6)

                if pending {
                    Button("立即转写") { onTranscribe() }
                        .buttonStyle(.plain)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                } else {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 5, height: 5)
                        .help("已转写")
                }
            }
        }
        .padding(13)
        .frame(minHeight: 136, alignment: .topLeading)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.04), radius: 6, y: 2)
        .textSelection(.enabled)
    }
}
