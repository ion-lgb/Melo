import SwiftUI
import AppKit
import MeloCore

// MARK: - 导出列表（文本 / CSV，合并或分开）

struct ListExportSheet: View {
    let app: AppModel

    @Environment(\.meloColors) private var colors
    @Environment(\.dismiss) private var dismiss

    @State private var kind: ListExportKind = .text
    @State private var merge = true

    private var formatLabel: String { kind == .text ? ".txt" : ".csv" }
    private var mergeLabel: String { merge ? "合并为单个文件" : "每个列表一个文件" }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    section("导出格式") {
                        Picker("导出格式", selection: $kind) {
                            ForEach(ListExportKind.allCases, id: \.rawValue) { item in
                                Text(item.label).tag(item)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                    section("组织方式") {
                        Picker("组织方式", selection: $merge) {
                            Text("合并为单个文件").tag(true)
                            Text("每个列表一个文件").tag(false)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                    previewNote
                }
                .padding(MeloMetrics.pageInset)
            }
            .background(colors.groupedBackground)
            footer
        }
        .frame(width: 460)
        .background(colors.mainBackground)
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(Localizer.tr("setting__backup_part_export_list"))
                    .font(MeloFont.sectionTitle)
                    .foregroundStyle(colors.font)
                Text("将全部列表导出为文本 / CSV（UTF-8 BOM，可直接用 Excel 打开）")
                    .font(MeloFont.caption)
                    .foregroundStyle(colors.fontTertiary)
            }
            Spacer(minLength: 8)
            Button(action: { dismiss() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(colors.fontSecondary)
                    .frame(width: 22, height: 22)
                    .background(colors.chipFill, in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, MeloMetrics.pageInset)
        .padding(.top, 18)
        .padding(.bottom, 14)
        .background(colors.mainBackground)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(MeloFont.controlLabel)
                .foregroundStyle(colors.fontSecondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var previewNote: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "info.circle")
                .font(.system(size: 10))
                .foregroundStyle(colors.fontTertiary)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text("导出预览：全部列表 · \(kind == .text ? "纯文本" : "CSV")（\(formatLabel)）· \(mergeLabel) · 含歌名/歌手/专辑等字段")
                    .font(MeloFont.secondary)
                    .foregroundStyle(colors.fontSecondary)
                Text("导出后不会修改任何列表数据；选择目标文件夹后立即写入。")
                    .font(MeloFont.caption)
                    .foregroundStyle(colors.fontTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(colors.chipFill, in: RoundedRectangle(cornerRadius: MeloMetrics.controlRadius, style: .continuous))
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Spacer()
            Button(Localizer.tr("btn_cancel")) { dismiss() }
                .buttonStyle(.meloSecondary)
                .keyboardShortcut(.cancelAction)

            Button {
                chooseDirectoryAndExport()
            } label: {
                Label("选择目录并导出", systemImage: "folder")
                    .frame(minWidth: 96)
            }
            .buttonStyle(.meloPrimary)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, MeloMetrics.pageInset)
        .padding(.vertical, 16)
        .background(colors.mainBackground)
    }

    private func chooseDirectoryAndExport() {
        let panel = NSOpenPanel()
        panel.title = "选择列表导出目录"
        panel.message = "将全部列表导出为 \(kind == .text ? "文本" : "CSV")（\(mergeLabel)）"
        panel.prompt = "导出到此目录"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        _ = app.exportLists(kind: kind, merge: merge, to: directory)
        dismiss()
    }
}
