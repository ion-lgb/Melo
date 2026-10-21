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
            Divider().overlay(colors.border)
            content
            Divider().overlay(colors.border)
            footer
        }
        .frame(width: 430)
        .background(colors.mainBackground)
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(colors.primary.opacity(0.12))
                Image(systemName: "timer")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(colors.primary)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text(Localizer.tr("play_timeout"))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(colors.font)
                Text("到时间后自动暂停播放；可等待当前歌曲播放完毕再暂停")
                    .font(.system(size: 10))
                    .foregroundStyle(colors.fontTertiary)
            }
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(colors.fontSecondary)
                    .frame(width: 24, height: 24)
                    .background(colors.fontTertiary.opacity(0.10), in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Text("暂停时长")
                    .font(.system(size: 12))
                    .frame(width: 64, alignment: .leading)
                TextField(Localizer.tr("play_timeout_unit"), text: $minutesText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(width: 70)
                    .onSubmit { startTimeout() }
                Text("分钟（1–180）")
                    .font(.system(size: 10))
                    .foregroundStyle(colors.fontTertiary)
                Spacer()
            }

            HStack(spacing: 6) {
                Text("")
                    .frame(width: 64, alignment: .leading)
                ForEach([15, 30, 60, 90], id: \.self) { value in
                    Button("\(value) 分钟") {
                        minutesText = String(value)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                Spacer()
            }

            HStack(alignment: .top, spacing: 10) {
                Text("")
                    .frame(width: 64, alignment: .leading)
                Toggle("等待当前歌曲播放完毕再暂停", isOn: $waitSongEnd)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .font(.system(size: 11))
                Spacer()
            }

            if let remaining {
                HStack(spacing: 8) {
                    Image(systemName: "hourglass")
                        .font(.system(size: 10))
                        .foregroundStyle(colors.primary)
                    Text(remaining <= 0
                         ? "等待当前歌曲播放完毕后暂停"
                         : "当前定时：剩余 \(formatDuration(remaining))\(waitsForSongEnd ? "（等待本曲结束）" : "")")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(colors.primary)
                    Spacer()
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(colors.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }

            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "info.circle")
                    .font(.system(size: 9))
                    .foregroundStyle(colors.fontTertiary)
                    .padding(.top, 1)
                Text("定时暂停只在本次运行内计时，关闭应用后自动取消；「等待当前歌曲结束」会在倒计时结束后等本曲播完再暂停。设置会写入原版 player.waitPlayEndStop / waitPlayEndStopTime 键。")
                    .font(.system(size: 9.5))
                    .foregroundStyle(colors.fontTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if remaining != nil {
                Button(Localizer.tr("play_timeout_stop"), role: .destructive) {
                    app.cancelPlayTimeout()
                    dismiss()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            Spacer()
            Button(Localizer.tr("btn_cancel")) { dismiss() }
                .keyboardShortcut(.cancelAction)
                .controlSize(.small)
            Button {
                startTimeout()
            } label: {
                Text(remaining == nil ? "开始定时" : Localizer.tr("play_timeout_update"))
                    .frame(minWidth: 72)
            }
            .buttonStyle(.borderedProminent)
            .tint(colors.primary)
            .controlSize(.small)
            .disabled(!isValidMinutes)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
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
