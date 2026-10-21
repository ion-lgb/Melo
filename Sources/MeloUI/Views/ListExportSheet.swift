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
            Divider().overlay(colors.border)
            content
            Divider().overlay(colors.border)
            footer
        }
        .frame(width: 460)
        .background(colors.mainBackground)
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(colors.primary.opacity(0.12))
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(colors.primary)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text(Localizer.tr("setting__backup_part_export_list"))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(colors.font)
                Text("将全部列表导出为文本 / CSV（UTF-8 BOM，可直接用 Excel 打开）")
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
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 7) {
                Text("导出格式")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(colors.fontSecondary)
                Picker("导出格式", selection: $kind) {
                    ForEach(ListExportKind.allCases, id: \.rawValue) { item in
                        Text(item.label).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("组织方式")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(colors.fontSecondary)
                Picker("组织方式", selection: $merge) {
                    Text("合并为单个文件").tag(true)
                    Text("每个列表一个文件").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle")
                    .font(.system(size: 9))
                    .foregroundStyle(colors.fontTertiary)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text("导出预览：全部列表 · \(kind == .text ? "纯文本" : "CSV")（\(formatLabel)）· \(mergeLabel) · 含歌名/歌手/专辑等字段")
                        .font(.system(size: 10))
                        .foregroundStyle(colors.fontSecondary)
                    Text("导出后不会修改任何列表数据；选择目标文件夹后立即写入。")
                        .font(.system(size: 9.5))
                        .foregroundStyle(colors.fontTertiary)
                }
            }
        }
        .padding(18)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Spacer()
            Button(Localizer.tr("btn_cancel")) { dismiss() }
                .keyboardShortcut(.cancelAction)
                .controlSize(.small)

            Button {
                chooseDirectoryAndExport()
            } label: {
                Label("选择目录并导出", systemImage: "folder")
                    .frame(minWidth: 96)
            }
            .buttonStyle(.borderedProminent)
            .tint(colors.primary)
            .controlSize(.small)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
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
