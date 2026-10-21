import SwiftUI
import MeloCore

// MARK: - 歌单广场（Phase 1：内置元数据）

struct SongListView: View {
    let app: AppModel

    @Environment(\.meloColors) private var colors
    @State private var selectedSongListID: String?
    @State private var showTagPopover = false

    private var hubSources: [MusicSourceInfo] {
        app.builtinSources.isEmpty
            ? app.metadataSourcesWithAll.filter { $0.id != "all" }
            : app.builtinSources
    }

    private var currentSourceName: String {
        hubSources.first(where: { $0.id == app.songListSource })?.name ?? app.songListSource
    }

    private var currentTagName: String {
        if app.selectedSongListTagId.isEmpty { return "全部标签" }
        let tags = app.songListTags
        if let tag = tags.hot.first(where: { $0.id == app.selectedSongListTagId }) {
            return tag.name
        }
        for group in tags.groups {
            if let tag = group.tags.first(where: { $0.id == app.selectedSongListTagId }) {
                return tag.name
            }
        }
        return "全部标签"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            filterBar
            content
        }
        .task(id: app.metadataReady) {
            if app.metadataReady && app.songListSorts.isEmpty {
                await app.loadSongListHub()
            }
        }
    }

    // MARK: 头部

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            PageTitle("歌单广场", subtitle: subtitle)
            Spacer()

            Menu {
                ForEach(hubSources) { source in
                    Button {
                        Task { await app.loadSongListHub(source: source.id) }
                    } label: {
                        if source.id == app.songListSource {
                            Label(source.name, systemImage: "checkmark")
                        } else {
                            Text(source.name)
                        }
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Text(currentSourceName)
                        .font(.system(size: 11, weight: .medium))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                }
                .foregroundStyle(colors.fontSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(colors.fontTertiary.opacity(0.08), in: Capsule())
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Button {
                showTagPopover = true
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "tag")
                        .font(.system(size: 10))
                    Text(currentTagName)
                        .font(.system(size: 11, weight: .medium))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                }
                .foregroundStyle(colors.fontSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(colors.fontTertiary.opacity(0.08), in: Capsule())
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showTagPopover, arrowEdge: .bottom) {
                tagPopover
            }

            MeloIconButton(systemName: "arrow.clockwise", help: "重新加载歌单") {
                Task { await app.loadSongListHub() }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 8)
    }

    private var subtitle: String {
        if !app.metadataReady { return "内置音源加载中…" }
        if let error = app.songListError {
            return "加载异常：\(error)"
        }
        let page = app.songListPage
        return "\(currentSourceName) · \(page.total) 个歌单 · 最多显示 \(page.allPage) 页"
    }

    // MARK: 排序 / 筛选

    private var filterBar: some View {
        HStack(spacing: 8) {
            if !app.songListSorts.isEmpty {
                HStack(spacing: 2) {
                    ForEach(app.songListSorts) { sort in
                        Button {
                            guard app.selectedSongListSortId != sort.id else { return }
                            Task { await app.selectSongListSort(sort.id) }
                        } label: {
                            Text(sort.name)
                                .font(.system(size: 11, weight: app.selectedSongListSortId == sort.id ? .semibold : .regular))
                                .foregroundStyle(app.selectedSongListSortId == sort.id ? colors.primary : colors.fontSecondary)
                                .padding(.horizontal, 11)
                                .padding(.vertical, 4)
                                .background(
                                    app.selectedSongListSortId == sort.id ? colors.mainBackground : Color.clear,
                                    in: Capsule()
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(2)
                .background(colors.fontTertiary.opacity(0.08), in: Capsule())
            }

            if !app.selectedSongListTagId.isEmpty {
                HStack(spacing: 4) {
                    Text("标签：\(currentTagName)")
                        .font(.system(size: 10))
                        .foregroundStyle(colors.primary)
                    Button {
                        Task { await app.selectSongListTag("") }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(colors.fontTertiary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(colors.primaryOpacity(0.10), in: Capsule())
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 10)
    }

    // MARK: 内容

    @ViewBuilder
    private var content: some View {
        if !app.metadataReady {
            MetadataUnavailableView(app: app)
        } else if app.isLoadingSongList && app.songListPage.list.isEmpty {
            VStack(spacing: 10) {
                ProgressView()
                Text("正在加载歌单…")
                    .font(.system(size: 11))
                    .foregroundStyle(colors.fontSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = app.songListError, app.songListPage.list.isEmpty {
            EmptyStateView(
                systemImage: "exclamationmark.square.stack",
                title: "歌单加载失败",
                message: error,
                actionTitle: "重试",
                action: {
                    Task { await app.loadSongLists() }
                }
            )
        } else if app.songListPage.list.isEmpty {
            EmptyStateView(
                systemImage: "square.stack",
                title: "暂无歌单",
                message: "切换音源、排序或标签试试。"
            )
        } else {
            VStack(spacing: 0) {
                if let error = app.songListError {
                    InlineErrorBar(message: error) {
                        Task { await app.loadSongLists() }
                    }
                }
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 172), spacing: 14)],
                        alignment: .leading,
                        spacing: 14
                    ) {
                        ForEach(app.songListPage.list) { item in
                            SongListCard(item: item) {
                                selectedSongListID = item.id
                                MeloUIActions.openSongList(item: item, app: app)
                            }
                            .overlay(
                                RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    .strokeBorder(
                                        selectedSongListID == item.id ? colors.primary : Color.clear,
                                        lineWidth: 1.5
                                    )
                            )
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 2)
                }
                LoadMoreBar(
                    page: app.songListPage.page,
                    allPage: app.songListPage.allPage,
                    total: app.songListPage.total,
                    isLoading: app.isLoadingSongList
                ) {
                    Task { await app.loadMoreSongLists() }
                }
            }
        }
    }

    // MARK: 标签面板

    private var tagPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("选择标签")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(colors.font)
                Spacer()
                Button(Localizer.tr("close")) { showTagPopover = false }
                    .buttonStyle(.plain)
                    .font(.system(size: 10))
                    .foregroundStyle(colors.fontTertiary)
            }

            if app.songListTags.isEmpty {
                Text(app.isLoadingSongList ? "标签加载中…" : "当前音源没有提供标签")
                    .font(.system(size: 11))
                    .foregroundStyle(colors.fontSecondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if !app.songListTags.hot.isEmpty {
                            tagSection(title: Localizer.tr("songlist__tag_info_hot_tag"), tags: app.songListTags.hot)
                        }
                        ForEach(Array(app.songListTags.groups.enumerated()), id: \.offset) { _, group in
                            tagSection(title: group.name, tags: group.tags)
                        }
                    }
                    .padding(.bottom, 4)
                }
            }
        }
        .padding(14)
        .frame(width: 460, height: 360)
    }

    private func tagSection(title: String, tags: [SongListTag]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(colors.fontTertiary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 86), spacing: 6)], alignment: .leading, spacing: 6) {
                ForEach(tags) { tag in
                    Button {
                        showTagPopover = false
                        Task { await app.selectSongListTag(tag.id) }
                    } label: {
                        Text(tag.name)
                            .font(.system(size: 10.5, weight: app.selectedSongListTagId == tag.id ? .semibold : .regular))
                            .foregroundStyle(app.selectedSongListTagId == tag.id ? colors.primary : colors.fontSecondary)
                            .lineLimit(1)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .background(
                                app.selectedSongListTagId == tag.id
                                    ? colors.primaryOpacity(0.14)
                                    : colors.fontTertiary.opacity(0.08),
                                in: Capsule()
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
