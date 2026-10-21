import SwiftUI
import AppKit
import MeloCore

// MARK: - 搜索页（Phase 1：接入内置元数据 API）

struct SearchView: View {
    let app: AppModel
    @Binding var keyword: String

    @Environment(\.meloColors) private var colors
    @State private var selectedMusicID: String?
    @State private var selectedSongListID: String?
    @FocusState private var resultsFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            searchBar
            if app.metadataReady {
                controls
            }
            content
        }
        .task(id: app.metadataReady) {
            if app.metadataReady && app.hotSearchWords.isEmpty {
                await app.loadHotSearch()
            }
        }
    }

    // MARK: 头部

    private var header: some View {
        HStack(alignment: .top) {
            PageTitle(Localizer.tr("search"), subtitle: subtitle)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 10)
    }

    private var subtitle: String {
        if !app.metadataReady {
            return "内置音源加载中…"
        }
        if let error = app.searchError, !app.searchKeyword.isEmpty {
            return "搜索「\(app.searchKeyword)」时出错：\(error)"
        }
        if app.searchKeyword.isEmpty {
            return "多源聚合搜索（酷我 / 酷狗 / QQ / 网易 / 咪咕），支持单曲与歌单"
        }
        let total = app.searchTab == .music ? app.searchMusicPage.total : app.searchSongListPage.total
        return "「\(app.searchKeyword)」· 共 \(total) 条结果"
    }

    // MARK: 搜索框

    private var searchBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(colors.fontTertiary)
                TextField("搜索歌曲、歌手、歌单…", text: $keyword)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .onSubmit(submit)
                if !keyword.isEmpty {
                    Button {
                        keyword = ""
                        selectedMusicID = nil
                        selectedSongListID = nil
                        Task { await app.performSearch("") }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(colors.fontTertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                colors.fontTertiary.opacity(0.10),
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(colors.border, lineWidth: 1)
            )

            Button(action: submit) {
                if app.isSearching {
                    ProgressView().controlSize(.small)
                } else {
                    Text(Localizer.tr("search"))
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(colors.primary)
            .disabled(keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 10)
    }

    // MARK: Tab + 音源

    private var controls: some View {
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                tabButton("单曲", tab: .music)
                tabButton(Localizer.tr("song_list"), tab: .songList)
            }
            .padding(2)
            .background(colors.fontTertiary.opacity(0.08), in: Capsule())

            SourceChipBar(app: app, selected: app.searchSource) { source in
                Task { await app.setSearchSource(source) }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 10)
    }

    private func tabButton(_ title: String, tab: SearchTab) -> some View {
        Button {
            guard app.searchTab != tab else { return }
            selectedMusicID = nil
            selectedSongListID = nil
            Task { await app.setSearchTab(tab) }
        } label: {
            Text(title)
                .font(.system(size: 11, weight: app.searchTab == tab ? .semibold : .regular))
                .foregroundStyle(app.searchTab == tab ? colors.primary : colors.fontSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(
                    app.searchTab == tab ? colors.mainBackground : Color.clear,
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: 内容

    @ViewBuilder
    private var content: some View {
        if !app.metadataReady {
            MetadataUnavailableView(app: app)
        } else if app.searchKeyword.isEmpty {
            discoveryView
        } else if app.searchTab == .music {
            musicResults
        } else {
            songListResults
        }
    }

    // MARK: 空态：历史 + 热搜

    private var discoveryView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if !app.searchHistory.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("搜索历史")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(colors.fontSecondary)
                            Spacer()
                            Button("清空") {
                                app.clearSearchHistory()
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 10))
                            .foregroundStyle(colors.fontTertiary)
                        }
                        chipFlow(app.searchHistory, icon: "clock")
                    }
                }

                if !app.hotSearchWords.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(Localizer.tr("search__hot_search"))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(colors.fontSecondary)
                        chipFlow(app.hotSearchWords, icon: "flame")
                    }
                }

                EmptyStateView(
                    systemImage: "sparkle.magnifyingglass",
                    title: "输入关键词开始搜索",
                    message: "支持歌曲 / 歌单搜索、多音源聚合，搜索历史保存在本地设置中。"
                )
                .frame(height: 220)
            }
            .padding(20)
        }
    }

    private func chipFlow(_ words: [String], icon: String) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], alignment: .leading, spacing: 8) {
            ForEach(words, id: \.self) { word in
                Button {
                    keyword = word
                    submit()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: icon)
                            .font(.system(size: 8))
                            .foregroundStyle(colors.fontTertiary)
                        Text(word)
                            .font(.system(size: 11))
                            .foregroundStyle(colors.fontSecondary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(colors.fontTertiary.opacity(0.08), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: 单曲结果

    @ViewBuilder
    private var musicResults: some View {
        let page = app.searchMusicPage
        if app.isSearching && page.list.isEmpty {
            loadingView
        } else if let error = app.searchError, page.list.isEmpty {
            searchErrorView(error)
        } else if page.list.isEmpty {
            EmptyStateView(
                systemImage: "music.note.list",
                title: "未找到相关单曲",
                message: "换个关键词，或切换音源 / 搜索类型试试。"
            )
        } else {
            VStack(spacing: 0) {
                if let error = app.searchError {
                    InlineErrorBar(message: error) {
                        Task { await app.performSearch(app.searchKeyword) }
                    }
                }
                SongTableHeader()
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(page.list.enumerated()), id: \.element.id) { index, music in
                            SongRow(
                                app: app,
                                music: music,
                                index: index,
                                isSelected: selectedMusicID == music.id,
                                onSelect: {
                                    selectedMusicID = music.id
                                    resultsFocused = true
                                },
                                onPlay: { playSearchMusic(at: index) }
                            )
                        }
                    }
                    .padding(.vertical, 4)
                }
                .focusable()
                .focused($resultsFocused)
                .onKeyPress(.return) {
                    playSelectedSearchMusic()
                    return .handled
                }
                LoadMoreBar(
                    page: page.page,
                    allPage: page.allPage,
                    total: page.total,
                    isLoading: app.isSearching
                ) {
                    Task { await app.loadMoreSearch() }
                }
            }
        }
    }

    // MARK: 歌单结果

    @ViewBuilder
    private var songListResults: some View {
        let page = app.searchSongListPage
        if app.isSearching && page.list.isEmpty {
            loadingView
        } else if let error = app.searchError, page.list.isEmpty {
            searchErrorView(error)
        } else if page.list.isEmpty {
            EmptyStateView(
                systemImage: "square.stack",
                title: "未找到相关歌单",
                message: "换个关键词，或切换音源试试。"
            )
        } else {
            VStack(spacing: 0) {
                if let error = app.searchError {
                    InlineErrorBar(message: error) {
                        Task { await app.performSearch(app.searchKeyword) }
                    }
                }
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(page.list) { item in
                            SongListRow(item: item) {
                                selectedSongListID = item.id
                                MeloUIActions.openSongList(item: item, app: app)
                            }
                            .background(
                                selectedSongListID == item.id ? colors.selected : Color.clear,
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                            )
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
                LoadMoreBar(
                    page: page.page,
                    allPage: page.allPage,
                    total: page.total,
                    isLoading: app.isSearching
                ) {
                    Task { await app.loadMoreSearch() }
                }
            }
        }
    }

    // MARK: 公共状态

    private var loadingView: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("正在搜索…")
                .font(.system(size: 11))
                .foregroundStyle(colors.fontSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func searchErrorView(_ error: String) -> some View {
        EmptyStateView(
            systemImage: "exclamationmark.magnifyingglass",
            title: "搜索失败",
            message: error,
            actionTitle: "重试",
            action: {
                let text = app.searchKeyword.isEmpty ? keyword : app.searchKeyword
                Task { await app.performSearch(text) }
            }
        )
    }

    // MARK: 动作

    private func submit() {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard app.metadataReady else {
            app.showToast("内置音源加载中，请稍候…")
            return
        }
        app.route = .search
        selectedMusicID = nil
        selectedSongListID = nil
        Task { await app.performSearch(trimmed) }
    }

    private func playSearchMusic(at index: Int) {
        let list = app.searchMusicPage.list
        guard list.indices.contains(index) else { return }
        selectedMusicID = list[index].id
        app.play(list[index], queue: list)
    }

    private func playSelectedSearchMusic() {
        let list = app.searchMusicPage.list
        guard !list.isEmpty else { return }
        if let selectedMusicID, let index = list.firstIndex(where: { $0.id == selectedMusicID }) {
            playSearchMusic(at: index)
        } else {
            playSearchMusic(at: 0)
        }
    }
}
