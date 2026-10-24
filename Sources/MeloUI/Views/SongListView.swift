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
                        .font(MeloFont.controlLabel)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                }
                .foregroundStyle(colors.font)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(colors.chipFill, in: Capsule())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()

            Button {
                showTagPopover = true
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "tag")
                        .font(.system(size: 11))
                    Text(currentTagName)
                        .font(MeloFont.controlLabel)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                }
                .foregroundStyle(colors.font)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(colors.chipFill, in: Capsule())
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showTagPopover, arrowEdge: .bottom) {
                tagPopover
            }

            MeloIconButton(systemName: "arrow.clockwise", help: "重新加载歌单") {
                Task { await app.loadSongListHub() }
            }
        }
        .padding(.horizontal, MeloMetrics.pageInset)
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
        HStack(spacing: 10) {
            if !app.songListSorts.isEmpty {
                HStack(spacing: 8) {
                    ForEach(app.songListSorts) { sort in
                        MeloChip(text: sort.name, isSelected: app.selectedSongListSortId == sort.id) {
                            guard app.selectedSongListSortId != sort.id else { return }
                            Task { await app.selectSongListSort(sort.id) }
                        }
                    }
                }
            }

            if !app.selectedSongListTagId.isEmpty {
                HStack(spacing: 6) {
                    Text("标签：\(currentTagName)")
                        .font(MeloFont.controlLabel)
                        .foregroundStyle(colors.primary)
                    Button {
                        Task { await app.selectSongListTag("") }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(colors.fontTertiary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(colors.primaryOpacity(0.10), in: Capsule())
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, MeloMetrics.pageInset)
        .padding(.bottom, 12)
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
                    .font(MeloFont.caption)
                    .foregroundStyle(colors.fontTertiary)
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
                        columns: [GridItem(.adaptive(minimum: 160), spacing: MeloMetrics.gridSpacing)],
                        alignment: .leading,
                        spacing: MeloMetrics.gridSpacing
                    ) {
                        ForEach(app.songListPage.list) { item in
                            SongListCard(item: item) {
                                selectedSongListID = item.id
                                MeloUIActions.openSongList(item: item, app: app)
                            }
                            .overlay(
                                RoundedRectangle(cornerRadius: MeloMetrics.cardRadius, style: .continuous)
                                    .strokeBorder(
                                        selectedSongListID == item.id ? colors.primary : Color.clear,
                                        lineWidth: 2
                                    )
                            )
                        }
                    }
                    .padding(MeloMetrics.pageInset)
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
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("选择标签")
                    .font(MeloFont.cardTitle)
                    .foregroundStyle(colors.font)
                Spacer()
                Button(Localizer.tr("close")) { showTagPopover = false }
                    .buttonStyle(.plain)
                    .font(MeloFont.caption)
                    .foregroundStyle(colors.fontTertiary)
            }

            if app.songListTags.isEmpty {
                Text(app.isLoadingSongList ? "标签加载中…" : "当前音源没有提供标签")
                    .font(MeloFont.secondary)
                    .foregroundStyle(colors.fontSecondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
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
        .padding(16)
        .frame(width: 460, height: 360)
    }

    private func tagSection(title: String, tags: [SongListTag]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(MeloFont.controlLabel)
                .foregroundStyle(colors.fontSecondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(tags) { tag in
                    MeloChip(text: tag.name, isSelected: app.selectedSongListTagId == tag.id) {
                        showTagPopover = false
                        Task { await app.selectSongListTag(tag.id) }
                    }
                }
            }
        }
    }
}
