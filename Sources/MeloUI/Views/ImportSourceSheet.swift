import SwiftUI
import AppKit
import MeloCore

// MARK: - 在线导入自定义源（从 http(s) 链接下载 .js 脚本）

struct ImportSourceSheet: View {
    let app: AppModel

    @Environment(\.meloColors) private var colors
    @Environment(\.dismiss) private var dismiss

    @State private var urlString: String
    @State private var errorText: String?
    @State private var requestStarted = false

    init(app: AppModel, initialURL: String = "") {
        self.app = app
        _urlString = State(initialValue: initialURL)
    }

    private var trimmedURL: String {
        urlString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSubmit: Bool {
        !trimmedURL.isEmpty && !app.isImportingSource
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(colors.border)
            content
            Divider().overlay(colors.border)
            footer
        }
        .frame(width: 540)
        .background(colors.mainBackground)
        .onChange(of: app.toastMessage) { _, newValue in
            guard requestStarted, let message = newValue else { return }
            if message.contains("已导入自定义源") {
                dismiss()
            } else if message.contains("失败") || message.contains("合法") {
                errorText = message
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: MeloMetrics.controlRadius, style: .continuous)
                    .fill(colors.primary.opacity(0.12))
                Image(systemName: "link")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(colors.primary)
            }
            .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text(Localizer.tr("user_api_import_online__title"))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(colors.font)
                Text("从链接下载 .js 源脚本，按原版 user_api.json 规则保存")
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
            Text("源链接（http / https）")
                .font(MeloFont.body)
                .foregroundStyle(colors.font)

            TextField("https://example.com/api/script/lx?key=...", text: $urlString)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .onSubmit(submit)
                .disabled(app.isImportingSource)

            Text("从 http(s) 链接下载 .js 脚本，按原版 user_api.json 规则保存；不会内置到 App。导入成功后会自动激活该源。")
                .font(MeloFont.caption)
                .foregroundStyle(colors.fontTertiary)
                .fixedSize(horizontal: false, vertical: true)

            if let errorText {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(colors.primary)
                        .padding(.top, 1)
                    Text(errorText)
                        .font(MeloFont.caption)
                        .foregroundStyle(colors.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(colors.primaryOpacity(0.08), in: RoundedRectangle(cornerRadius: MeloMetrics.controlRadius, style: .continuous))
            }

            if app.isImportingSource {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在下载并解析源脚本…")
                        .font(MeloFont.secondary)
                        .foregroundStyle(colors.fontSecondary)
                }
            }
        }
        .padding(18)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Spacer()
            Button(Localizer.tr("btn_cancel")) { dismiss() }
                .buttonStyle(.meloSecondary)
                .keyboardShortcut(.cancelAction)

            Button(action: submit) {
                HStack(spacing: 6) {
                    if app.isImportingSource {
                        ProgressView().controlSize(.mini)
                    }
                    Text(app.isImportingSource ? "导入中…" : Localizer.tr("import"))
                }
                .frame(minWidth: 64)
            }
            .buttonStyle(.meloPrimary)
            .disabled(!canSubmit)
            .opacity(canSubmit ? 1 : 0.5)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private func submit() {
        guard canSubmit else { return }
        let url = trimmedURL
        errorText = nil
        requestStarted = true
        let sourceCountBefore = app.sources.count
        Task {
            await app.importSourceFromURL(url)
            // 兜底：AppModel 无返回值，若来源数量增加视为成功
            try? await Task.sleep(nanoseconds: 350_000_000)
            if app.sources.count > sourceCountBefore {
                dismiss()
            } else if errorText == nil, !app.isImportingSource {
                if let toast = app.toastMessage, toast.contains("失败") || toast.contains("合法") {
                    errorText = toast
                }
            }
        }
    }
}
