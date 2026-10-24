import SwiftUI
import MeloCore

// MARK: - 添加到列表（可复用 Sheet）

/// 把单首/多首歌曲加入某个列表。内置列表（试听/收藏/临时）+ 用户列表，显示当前歌曲数。
struct ListPickerSheet: View {
    let app: AppModel
    let musics: [MusicInfo]

    @Environment(\.meloColors) private var colors
    @Environment(\.dismiss) private var dismiss

    @State private var newListName: String = ""

    private var title: String {
        musics.count == 1 ? "添加到列表" : "添加 \(musics.count) 首到列表"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(app.allLists.enumerated()), id: \.element.id) { index, list in
                        ListPickerRow(
                            name: list.name,
                            subtitle: ListIDs.isBuiltin(list.id) ? "内置列表" : "用户列表",
                            count: app.musicCounts[list.id] ?? 0,
                            symbol: icon(for: list.id)
                        ) {
                            app.addMusics(musics, to: list.id)
                            dismiss()
                        }
                        if index < app.allLists.count - 1 {
                            colors.border.frame(height: 1).padding(.leading, 54)
                        }
                    }
                }
                .padding(.vertical, 6)
            }
            .background(colors.groupedBackground)
            newListBar
        }
        .frame(width: 420, height: 470)
        .background(colors.mainBackground)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(MeloFont.sectionTitle)
                    .foregroundStyle(colors.font)
                Text("选择目标列表；已收藏的歌曲可重复添加或加入「我的收藏」")
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

    private var newListBar: some View {
        HStack(spacing: 8) {
            TextField("新建列表名称…", text: $newListName)
                .textFieldStyle(.plain)
                .font(MeloFont.body)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(colors.chipFill, in: RoundedRectangle(cornerRadius: MeloMetrics.controlRadius, style: .continuous))
                .onSubmit(createList)
            Button("新建并添加", action: createList)
                .buttonStyle(.meloPrimary)
                .disabled(newListName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, MeloMetrics.pageInset)
        .padding(.vertical, 14)
        .background(colors.mainBackground)
    }

    private func createList() {
        let name = newListName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        app.createList(name: name)
        if let created = app.userLists.last(where: { $0.name == name }) {
            app.addMusics(musics, to: created.id)
        }
        dismiss()
    }

    private func icon(for listId: String) -> String {
        switch listId {
        case ListIDs.default: return "music.note.list"
        case ListIDs.love: return "heart"
        case ListIDs.temp: return "clock"
        default: return "list.bullet"
        }
    }
}

private struct ListPickerRow: View {
    let name: String
    let subtitle: String
    let count: Int
    let symbol: String
    let action: () -> Void

    @Environment(\.meloColors) private var colors
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(colors.font)
                    .frame(width: 28, height: 28)
                    .background(colors.chipFill, in: RoundedRectangle(cornerRadius: MeloMetrics.controlRadius, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(MeloFont.body)
                        .foregroundStyle(colors.font)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(MeloFont.microCaption)
                        .foregroundStyle(colors.fontTertiary)
                }
                Spacer(minLength: 10)
                Text("\(count)")
                    .font(MeloFont.caption)
                    .foregroundStyle(colors.fontTertiary)
                    .monospacedDigit()
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(colors.primary)
                    .opacity(hovering ? 1 : 0)
                    .frame(width: 16)
            }
            .padding(.horizontal, MeloMetrics.pageInset)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovering ? colors.hover : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
