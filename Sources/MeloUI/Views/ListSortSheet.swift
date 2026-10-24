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
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    section(Localizer.tr("list_sort_modal_by_field")) {
                        Picker(Localizer.tr("list_sort_modal_by_field"), selection: $field) {
                            ForEach(MusicSortField.allCases, id: \.rawValue) { item in
                                Text(item.label).tag(item)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                    section("排序方向") {
                        Picker("排序方向", selection: $direction) {
                            ForEach(MusicSortDirection.allCases, id: \.rawValue) { item in
                                Text(item.label).tag(item)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                    footnote
                }
                .padding(MeloMetrics.pageInset)
            }
            .background(colors.groupedBackground)
            footer
        }
        .frame(width: 440)
        .background(colors.mainBackground)
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("排序列表")
                    .font(MeloFont.sectionTitle)
                    .foregroundStyle(colors.font)
                Text("「\(listName)」· \(musicCount) 首歌曲")
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

    private var footnote: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "info.circle")
                .font(.system(size: 10))
                .foregroundStyle(colors.fontTertiary)
                .padding(.top, 1)
            Text("排序会直接调整该列表中的歌曲顺序（写入数据库）；「随机」会打乱当前顺序。排序后可在列表中继续手动拖拽调整。")
                .font(MeloFont.microCaption)
                .foregroundStyle(colors.fontTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(colors.chipFill, in: RoundedRectangle(cornerRadius: MeloMetrics.controlRadius, style: .continuous))
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Spacer()
            Button(Localizer.tr("btn_cancel")) { dismiss() }
                .buttonStyle(.meloSecondary)
                .keyboardShortcut(.cancelAction)
            Button {
                app.sortList(id: listId, field: field, direction: direction)
                dismiss()
            } label: {
                Label("开始排序", systemImage: "arrow.up.arrow.down")
                    .frame(minWidth: 64)
            }
            .buttonStyle(.meloPrimary)
            .disabled(musicCount == 0)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, MeloMetrics.pageInset)
        .padding(.vertical, 16)
        .background(colors.mainBackground)
    }
}
