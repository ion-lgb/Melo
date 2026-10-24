import SwiftUI
import AppKit
import MeloCore

// MARK: - 不喜欢规则编辑

struct DislikeRulesSheet: View {
    let app: AppModel

    @Environment(\.meloColors) private var colors
    @Environment(\.dismiss) private var dismiss

    @State private var text: String
    @State private var showClearConfirm = false

    init(app: AppModel) {
        self.app = app
        _text = State(initialValue: app.dislikeRules.rulesText)
    }

    private var ruleCount: Int {
        text.components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .count
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(colors.border)
            content
            Divider().overlay(colors.border)
            footer
        }
        .frame(width: 520, height: 520)
        .background(colors.mainBackground)
        .alert("清空不喜欢规则", isPresented: $showClearConfirm) {
            Button(Localizer.tr("btn_cancel"), role: .cancel) {}
            Button("清空", role: .destructive) {
                app.clearDislikes()
                text = ""
                dismiss()
            }
        } message: {
            Text("将清空全部 \(app.dislikeRules.count) 条不喜欢规则（含通过右键添加的歌曲），此操作不可撤销。")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: MeloMetrics.controlRadius, style: .continuous)
                    .fill(colors.primary.opacity(0.12))
                Image(systemName: "hand.raised.slash")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(colors.primary)
            }
            .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text("不喜欢规则")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(colors.font)
                Text("播放时会自动跳过匹配规则的歌曲（当前 \(ruleCount) 条）")
                    .font(MeloFont.caption)
                    .foregroundStyle(colors.fontTertiary)
            }
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(colors.fontSecondary)
                    .frame(width: 26, height: 26)
                    .background(colors.chipFill, in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(colors.fontTertiary)
                    .padding(.top, 1)
                Text("每行一条规则，支持三种写法：\n· `歌曲名@艺术家`（同时匹配歌名与歌手）\n· `歌曲名`（只匹配歌名）\n· `@艺术家`（只匹配歌手）\n歌曲名或艺术家本身包含 @ 时，用 # 代替（例如 `A#B@歌手`）。规则会保存到原版 dislike_list 表。")
                    .font(MeloFont.caption)
                    .foregroundStyle(colors.fontSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(colors.chipFill, in: RoundedRectangle(cornerRadius: MeloMetrics.controlRadius, style: .continuous))

            TextEditor(text: $text)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(colors.chipFill, in: RoundedRectangle(cornerRadius: MeloMetrics.controlRadius, style: .continuous))

            HStack(spacing: 6) {
                Text("共 \(ruleCount) 条规则")
                    .font(MeloFont.caption)
                    .foregroundStyle(colors.fontTertiary)
                Spacer()
                Text("示例：晴天@周杰伦 / 起风了 / @买辣椒也用券")
                    .font(MeloFont.caption)
                    .foregroundStyle(colors.fontTertiary)
            }
        }
        .padding(18)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                showClearConfirm = true
            } label: {
                Label("清空规则", systemImage: "trash")
                    .foregroundStyle(colors.primary)
            }
            .buttonStyle(.meloSecondary)
            .disabled(app.dislikeRules.isEmpty && text.isEmpty)
            .opacity(app.dislikeRules.isEmpty && text.isEmpty ? 0.5 : 1)

            Spacer()

            Button(Localizer.tr("btn_cancel")) { dismiss() }
                .buttonStyle(.meloSecondary)
                .keyboardShortcut(.cancelAction)

            Button {
                app.saveDislikeRulesText(text)
                dismiss()
            } label: {
                Text("保存规则")
                    .frame(minWidth: 72)
            }
            .buttonStyle(.meloPrimary)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }
}
