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
            Divider().overlay(colors.border)
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(app.allLists) { list in
                        listRow(list)
                    }
                }
                .padding(8)
            }
            Divider().overlay(colors.border)
            newListBar
        }
        .frame(width: 420, height: 470)
        .background(colors.mainBackground)
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(colors.font)
                Text("选择目标列表；已收藏的歌曲可重复添加或加入「我的收藏」")
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
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func listRow(_ list: ListInfo) -> some View {
        Button {
            app.addMusics(musics, to: list.id)
            dismiss()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon(for: list.id))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(colors.primary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(list.name)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(colors.font)
                        .lineLimit(1)
                    Text(ListIDs.isBuiltin(list.id) ? "内置列表" : "用户列表")
                        .font(.system(size: 9.5))
                        .foregroundStyle(colors.fontTertiary)
                }
                Spacer(minLength: 8)
                Text("\(app.musicCounts[list.id] ?? 0)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(colors.fontTertiary)
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(colors.primary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var newListBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus")
                .font(.system(size: 10))
                .foregroundStyle(colors.fontTertiary)
            TextField("新建列表名称…", text: $newListName)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .onSubmit(createList)
            Button("新建并添加", action: createList)
                .buttonStyle(.borderedProminent)
                .tint(colors.primary)
                .controlSize(.small)
                .disabled(newListName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
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
