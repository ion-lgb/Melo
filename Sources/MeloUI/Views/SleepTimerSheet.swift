import SwiftUI
import AppKit
import MeloCore

// MARK: - 定时暂停（Sleep Timer）

struct SleepTimerSheet: View {
    let app: AppModel

    @Environment(\.meloColors) private var colors
    @Environment(\.dismiss) private var dismiss

    @State private var minutesText: String
    @State private var waitSongEnd: Bool

    /// 仅用于预览/自测
    private let previewRemaining: TimeInterval?
    private let previewWaitsForSongEnd: Bool?

    init(app: AppModel,
         previewRemaining: TimeInterval? = nil,
         previewWaitsForSongEnd: Bool? = nil,
         previewMinutes: Int? = nil) {
        self.app = app
        self.previewRemaining = previewRemaining
        self.previewWaitsForSongEnd = previewWaitsForSongEnd
        let minutes = previewMinutes ?? (app.playTimeoutMinutes > 0 ? app.playTimeoutMinutes : 30)
        _minutesText = State(initialValue: String(minutes))
        _waitSongEnd = State(initialValue: previewWaitsForSongEnd ?? app.playTimeoutWaitsForSongEnd)
    }

    private var remaining: TimeInterval? {
        previewRemaining ?? app.playTimeoutRemaining
    }

    private var waitsForSongEnd: Bool {
        previewWaitsForSongEnd ?? app.playTimeoutWaitsForSongEnd
    }

    private var minutes: Int? {
        Int(minutesText.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private var isValidMinutes: Bool {
        guard let minutes else { return false }
        return (1...180).contains(minutes)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            content
            Divider().overlay(colors.border)
            footer
        }
        .frame(width: 440)
        .presentationBackground(.regularMaterial)
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: MeloMetrics.controlRadius, style: .continuous)
                    .fill(colors.primaryOpacity(0.12))
                Image(systemName: "timer")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(colors.primary)
            }
            .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text(Localizer.tr("play_timeout"))
                    .font(MeloFont.sectionTitle)
                    .foregroundStyle(colors.font)
                Text("到时间后自动暂停播放；可等待当前歌曲播放完毕再暂停")
                    .font(MeloFont.caption)
                    .foregroundStyle(colors.fontSecondary)
            }
            Spacer()
            MeloCircleIconButton(systemName: "xmark", help: Localizer.tr("btn_cancel"), size: 12, frameSize: 28) {
                dismiss()
            }
        }
        .padding(.horizontal, MeloMetrics.pageInset)
        .padding(.vertical, 16)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Text("暂停时长")
                    .font(MeloFont.controlLabel)
                    .foregroundStyle(colors.fontSecondary)
                    .frame(width: 64, alignment: .leading)
                TextField(Localizer.tr("play_timeout_unit"), text: $minutesText)
                    .textFieldStyle(.plain)
                    .font(MeloFont.body.monospacedDigit())
                    .foregroundStyle(colors.font)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .frame(width: 88)
                    .background(colors.chipFill, in: RoundedRectangle(cornerRadius: MeloMetrics.controlRadius, style: .continuous))
                    .onSubmit { startTimeout() }
                Text("分钟（1–180）")
                    .font(MeloFont.caption)
                    .foregroundStyle(colors.fontTertiary)
                Spacer()
            }

            HStack(spacing: 8) {
                Text("")
                    .frame(width: 64, alignment: .leading)
                ForEach([15, 30, 60, 90], id: \.self) { value in
                    MeloChip(text: "\(value) 分钟", isSelected: minutes == value) {
                        minutesText = String(value)
                    }
                }
                Spacer()
            }

            HStack(alignment: .center, spacing: 10) {
                Text("")
                    .frame(width: 64, alignment: .leading)
                Toggle("等待当前歌曲播放完毕再暂停", isOn: $waitSongEnd)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .tint(colors.primary)
                    .font(MeloFont.body)
                Spacer()
            }

            if let remaining {
                HStack(spacing: 10) {
                    Image(systemName: "hourglass")
                        .font(.system(size: 12))
                        .foregroundStyle(colors.primary)
                    Text(remaining <= 0
                         ? "等待当前歌曲播放完毕后暂停"
                         : "当前定时：剩余 \(formatDuration(remaining))\(waitsForSongEnd ? "（等待本曲结束）" : "")")
                        .font(MeloFont.controlLabel.monospacedDigit())
                        .foregroundStyle(colors.primary)
                    Spacer()
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(colors.primaryOpacity(0.10), in: RoundedRectangle(cornerRadius: MeloMetrics.controlRadius, style: .continuous))
            }

            HStack(alignment: .top, spacing: 7) {
                Image(systemName: "info.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(colors.fontTertiary)
                    .padding(.top, 1)
                Text("定时暂停只在本次运行内计时，关闭应用后自动取消；「等待当前歌曲结束」会在倒计时结束后等本曲播完再暂停。设置会写入原版 player.waitPlayEndStop / waitPlayEndStopTime 键。")
                    .font(MeloFont.caption)
                    .foregroundStyle(colors.fontTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(MeloMetrics.pageInset)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if remaining != nil {
                Button(Localizer.tr("play_timeout_stop"), role: .destructive) {
                    app.cancelPlayTimeout()
                    dismiss()
                }
                .buttonStyle(.meloSecondary)
            }
            Spacer()
            Button(Localizer.tr("btn_cancel")) { dismiss() }
                .buttonStyle(.meloSecondary)
                .keyboardShortcut(.cancelAction)
            Button {
                startTimeout()
            } label: {
                Text(remaining == nil ? "开始定时" : Localizer.tr("play_timeout_update"))
                    .frame(minWidth: 72)
            }
            .buttonStyle(.meloPrimary)
            .disabled(!isValidMinutes)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, MeloMetrics.pageInset)
        .padding(.vertical, 14)
    }

    private func startTimeout() {
        guard let minutes, (1...180).contains(minutes) else {
            app.showToast("请输入 1–180 之间的分钟数")
            return
        }
        app.setPlayTimeout(minutes: minutes, waitSongEnd: waitSongEnd)
        dismiss()
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%02d:%02d", minutes, secs)
    }
}
