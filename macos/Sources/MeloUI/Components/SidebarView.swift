import SwiftUI
import AppKit
import MeloCore

// MARK: - 侧边栏

struct SidebarView: View {
    let app: AppModel

    @Environment(\.meloColors) private var colors
    @State private var newListName = ""
    @State private var showNewListAlert = false
    @State private var renamingList: ListInfo?
    @State private var renameText = ""
    @State private var deletingList: ListInfo?
    @State private var sortingListID: String?
    @State private var sortingListName = ""
    @State private var showExportSheet = false

    var body: some View {
        VStack(spacing: 0) {
            brandHeader
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    sectionHeader("发现音乐")
                    row(icon: "magnifyingglass", title: app.localizer.t("search"), route: .search)
                    row(icon: "chart.bar.xaxis", title: app.localizer.t("leaderboard"), route: .leaderboard)
                    row(icon: "square.stack", title: app.localizer.t("song_list"), route: .songList)

                    sectionHeader("我的音乐")
                    ForEach(app.allLists) { list in
                        listRow(list)
                    }
                    newListRow

                    sectionHeader(Localizer.tr("setting__other"))
                    row(icon: "arrow.down.circle", title: app.localizer.t("download"), route: .download)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            Divider().overlay(colors.border)
            bottomBar
        }
        .background {
            ZStack {
                ThemeBackground(colors: colors, imageURL: app.theme.backgroundImageURL)
                colors.appBackground.opacity(colors.isDark ? 0.55 : 0.70)
            }
        }
        .alert(Localizer.tr("list__new_list_btn"), isPresented: $showNewListAlert) {
            TextField("列表名称", text: $newListName)
            Button(Localizer.tr("btn_cancel"), role: .cancel) { newListName = "" }
            Button("创建") {
                let name = newListName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty { app.createList(name: name) }
                newListName = ""
            }
        } message: {
            Text("列表将保存到本地曲库（与原版 lx.data.db 兼容）")
        }
        .alert("重命名列表", isPresented: Binding(
            get: { renamingList != nil },
            set: { if !$0 { renamingList = nil } }
        )) {
            TextField("列表名称", text: $renameText)
            Button(Localizer.tr("btn_cancel"), role: .cancel) { renamingList = nil }
            Button(Localizer.tr("btn_save")) {
                if let list = renamingList {
                    let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !name.isEmpty { app.renameList(id: list.id, name: name) }
                }
                renamingList = nil
            }
        } message: {
            Text("修改列表名称，不会改变列表内的歌曲")
        }
        .alert("删除列表", isPresented: Binding(
            get: { deletingList != nil },
            set: { if !$0 { deletingList = nil } }
        )) {
            Button(Localizer.tr("btn_cancel"), role: .cancel) { deletingList = nil }
            Button("删除", role: .destructive) {
                if let list = deletingList { app.removeList(id: list.id) }
                deletingList = nil
            }
        } message: {
            Text("将删除「\(deletingList?.name ?? "")」及列表内所有歌曲记录，此操作不可撤销。")
        }
        .sheet(isPresented: Binding(
            get: { sortingListID != nil },
            set: { if !$0 { sortingListID = nil } }
        )) {
            if let listID = sortingListID {
                ListSortSheet(app: app, listId: listID, listName: sortingListName)
            }
        }
        .sheet(isPresented: $showExportSheet) {
            ListExportSheet(app: app)
        }
    }

    // MARK: 品牌

    private var brandHeader: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(LinearGradient(
                        colors: [colors.primary, colors.primary.opacity(0.72)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                Text("M")
                    .font(.system(size: 16, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 0) {
                Text("Melo")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(colors.font)
                Text("LX Music · macOS")
                    .font(.system(size: 9))
                    .foregroundStyle(colors.fontTertiary)
            }
            Spacer(minLength: 0)
            Text("macOS")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(colors.primary)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(colors.primaryOpacity(0.12), in: Capsule())
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 12)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(colors.fontTertiary)
            .padding(.horizontal, 10)
            .padding(.top, 12)
            .padding(.bottom, 4)
    }

    // MARK: 行

    private func row(icon: String, title: String, route: AppRoute) -> some View {
        let isSongListSection: Bool = {
            if route == .songList, case .songListDetail = app.route { return true }
            return app.route == route
        }()
        return SidebarRow(
            icon: icon,
            title: title,
            count: nil,
            isActive: isSongListSection
        ) {
            app.route = route
        }
    }

    private func listRow(_ list: ListInfo) -> some View {
        SidebarRow(
            icon: icon(for: list.id),
            title: list.name,
            count: app.musicCounts[list.id] ?? 0,
            isActive: app.route == .myList(listId: list.id),
            isUpdating: app.updatingListIds.contains(list.id)
        ) {
            app.selectList(list.id)
        }
        .contextMenu {
            if list.id == ListIDs.default || list.id == ListIDs.love || list.id == ListIDs.temp {
                Button("播放全部") { playAll(list.id) }
                Divider()
                Button("排序…") { openSortSheet(list) }
                Button("复制列表") { app.duplicateList(id: list.id) }
                Button("导出列表…") { showExportSheet = true }
            } else {
                let index = app.userLists.firstIndex(where: { $0.id == list.id }) ?? 0
                Button("重命名…") {
                    renameText = list.name
                    renamingList = list
                }
                Button("播放全部") { playAll(list.id) }
                Divider()
                if list.source != nil, list.sourceListId != nil {
                    if app.updatingListIds.contains(list.id) {
                        Button("更新中…") {}
                            .disabled(true)
                    } else {
                        Button("更新列表") {
                            Task { await app.updateSourceList(id: list.id) }
                        }
                    }
                    Divider()
                }
                Button("排序…") { openSortSheet(list) }
                Button("复制列表") { app.duplicateList(id: list.id) }
                Button("导出列表…") { showExportSheet = true }
                Divider()
                Button(Localizer.tr("list__moveup")) {
                    app.moveUserList(id: list.id, direction: -1)
                }
                .disabled(index == 0)
                Button(Localizer.tr("list__movedown")) {
                    app.moveUserList(id: list.id, direction: 1)
                }
                .disabled(index >= app.userLists.count - 1)
                Divider()
                Button("删除列表", role: .destructive) {
                    deletingList = list
                }
            }
        }
    }

    private func openSortSheet(_ list: ListInfo) {
        sortingListName = list.name
        sortingListID = list.id
    }

    private func icon(for listId: String) -> String {
        switch listId {
        case ListIDs.default: return "music.note.list"
        case ListIDs.love: return "heart"
        case ListIDs.temp: return "clock"
        default: return "list.bullet"
        }
    }

    private var newListRow: some View {
        Button {
            newListName = ""
            showNewListAlert = true
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 16)
                Text(Localizer.tr("list__new_list_btn"))
                    .font(.system(size: 12))
                Spacer(minLength: 0)
            }
            .foregroundStyle(colors.fontSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func playAll(_ listId: String) {
        let musics = (try? app.data.loadMusics(listId: listId)) ?? []
        guard !musics.isEmpty else {
            app.showToast("「\(app.listName(listId))」还没有歌曲")
            return
        }
        app.selectList(listId)
        app.playList(musics, startAt: 0)
    }

    // MARK: 底栏

    private var bottomBar: some View {
        VStack(spacing: 2) {
            SidebarRow(
                icon: "testtube.2",
                title: "自定义源测试",
                count: nil,
                isActive: app.route == .test
            ) {
                app.route = .test
            }
            SidebarRow(
                icon: "gearshape",
                title: app.localizer.t("setting"),
                count: nil,
                isActive: app.route == .settings
            ) {
                app.route = .settings
            }
            HStack {
                Text("Melo · Native SwiftUI")
                    .font(.system(size: 9))
                    .foregroundStyle(colors.fontTertiary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 8)
        }
        .padding(.horizontal, 8)
        .padding(.top, 6)
    }
}

// MARK: - 侧边栏行

private struct SidebarRow: View {
    let icon: String
    let title: String
    let count: Int?
    let isActive: Bool
    var isUpdating: Bool = false
    let action: () -> Void

    @Environment(\.meloColors) private var colors
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 16)
                    .foregroundStyle(isActive ? colors.primary : colors.fontSecondary)
                Text(title)
                    .font(.system(size: 12.5, weight: isActive ? .semibold : .regular))
                    .foregroundStyle(colors.font)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if isUpdating {
                    ProgressView().controlSize(.mini)
                }
                if let count, count > 0 {
                    Text("\(count)")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(colors.fontTertiary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                isActive ? colors.selected : (hovering ? colors.hover : Color.clear),
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
