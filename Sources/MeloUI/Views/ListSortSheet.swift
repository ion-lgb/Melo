import SwiftUI
import AppKit
import MeloCore

// MARK: - 列表排序（对齐原版 ListSortModal）

struct ListSortSheet: View {
    let app: AppModel
    let listId: String
    let listName: String

    @Environment(\.meloColors) private var colors
    @Environment(\.dismiss) private var dismiss

    @State private var field: MusicSortField = .name
    @State private var direction: MusicSortDirection = .up

    private var musicCount: Int {
        app.musicCounts[listId] ?? (app.selectedListId == listId ? app.currentMusics.count : 0)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(colors.border)
            content
            Divider().overlay(colors.border)
            footer
        }
        .frame(width: 440)
        .background(colors.mainBackground)
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(colors.primary.opacity(0.12))
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(colors.primary)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text("排序列表")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(colors.font)
                Text("「\(listName)」· \(musicCount) 首歌曲")
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
                Text(Localizer.tr("list_sort_modal_by_field"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(colors.fontSecondary)
                Picker(Localizer.tr("list_sort_modal_by_field"), selection: $field) {
                    ForEach(MusicSortField.allCases, id: \.rawValue) { item in
                        Text(item.label).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("排序方向")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(colors.fontSecondary)
                Picker("排序方向", selection: $direction) {
                    ForEach(MusicSortDirection.allCases, id: \.rawValue) { item in
                        Text(item.label).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle")
                    .font(.system(size: 9))
                    .foregroundStyle(colors.fontTertiary)
                    .padding(.top, 1)
                Text("排序会直接调整该列表中的歌曲顺序（写入数据库）；「随机」会打乱当前顺序。排序后可在列表中继续手动拖拽调整。")
                    .font(.system(size: 10))
                    .foregroundStyle(colors.fontTertiary)
                    .fixedSize(horizontal: false, vertical: true)
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
                app.sortList(id: listId, field: field, direction: direction)
                dismiss()
            } label: {
                Label("开始排序", systemImage: "arrow.up.arrow.down")
                    .frame(minWidth: 72)
            }
            .buttonStyle(.borderedProminent)
            .tint(colors.primary)
            .controlSize(.small)
            .disabled(musicCount == 0)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }
}
