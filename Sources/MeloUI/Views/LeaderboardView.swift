import SwiftUI
import MeloCore

// MARK: - 排行榜（Phase 1：内置元数据）

struct LeaderboardView: View {
    let app: AppModel

    @Environment(\.meloColors) private var colors

    private var boardSources: [MusicSourceInfo] {
        app.builtinSources.isEmpty
            ? app.metadataSourcesWithAll.filter { $0.id != "all" }
            : app.builtinSources
    }

    private var currentSourceName: String {
        boardSources.first(where: { $0.id == app.leaderboardSource })?.name ?? app.leaderboardSource
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if !app.metadataReady {
                MetadataUnavailableView(app: app)
            } else if app.leaderboards.isEmpty && app.isLoadingLeaderboard {
                loadingView
            } else if let error = app.leaderboardError, app.leaderboards.isEmpty {
                EmptyStateView(
                    systemImage: "exclamationmark.chart",
                    title: "榜单加载失败",
                    message: error,
                    actionTitle: "重试",
                    action: {
                        Task { await app.loadLeaderboards() }
                    }
                )
            } else if app.leaderboards.isEmpty {
                EmptyStateView(
                    systemImage: "chart.bar.xaxis",
                    title: "该音源暂无可用榜单",
                    message: "切换其他音源，或稍后重试。"
                )
            } else {
                HStack(spacing: 0) {
                    boardList
                    Rectangle().fill(colors.border).frame(width: 1)
                    songsPanel
                }
            }
        }
        .task(id: app.metadataReady) {
            if app.metadataReady && app.leaderboards.isEmpty {
                await app.loadLeaderboards()
            }
        }
    }

    // MARK: 头部

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            PageTitle(Localizer.tr("leaderboard"), subtitle: subtitle)
            Spacer()

            Menu {
                ForEach(boardSources) { source in
                    Button {
                        Task { await app.loadLeaderboards(source: source.id) }
                    } label: {
                        if source.id == app.leaderboardSource {
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
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()

            MeloIconButton(systemName: "arrow.clockwise", help: "重新加载榜单") {
                Task { await app.loadLeaderboards() }
            }
        }
        .padding(.horizontal, MeloMetrics.pageInset)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private var subtitle: String {
        if !app.metadataReady { return "内置音源加载中…" }
        if let board = app.leaderboards.first(where: { $0.id == app.selectedLeaderboardId }) {
            let total = board.total.map { " · \($0) 首" } ?? ""
            return "\(board.name)\(total)"
        }
        return "共 \(app.leaderboards.count) 个榜单"
    }

    private var loadingView: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("正在加载榜单…")
                .font(MeloFont.caption)
                .foregroundStyle(colors.fontTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 榜单列表

    private var boardList: some View {
        VStack(alignment: .leading, spacing: 0) {
            MeloSectionHeader(title: "全部榜单")
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 12)

            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 120), spacing: MeloMetrics.gridSpacing)],
                    alignment: .leading,
                    spacing: MeloMetrics.gridSpacing
                ) {
                    ForEach(app.leaderboards) { board in
                        MeloCoverCard(
                            title: board.name,
                            subtitle: board.total.map { "\($0) 首" },
                            cover: board.imgUrl,
                            isSelected: app.selectedLeaderboardId == board.id
                        ) {
                            guard app.selectedLeaderboardId != board.id else { return }
                            Task { await app.selectLeaderboard(board) }
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 16)
            }
        }
        .frame(width: 300)
        .background(colors.groupedBackground)
    }

    // MARK: 歌曲面板

    @ViewBuilder
    private var songsPanel: some View {
        let page = app.leaderboardPage
        VStack(alignment: .leading, spacing: 0) {
            if app.isLoadingLeaderboard && page.list.isEmpty {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("正在加载歌曲…")
                        .font(MeloFont.caption)
                        .foregroundStyle(colors.fontTertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = app.leaderboardError, page.list.isEmpty {
                EmptyStateView(
                    systemImage: "music.note.list",
                    title: "歌曲加载失败",
                    message: error,
                    actionTitle: "重试",
                    action: {
                        Task { await app.loadLeaderboardMusics() }
                    }
                )
            } else if page.list.isEmpty {
                EmptyStateView(
                    systemImage: "music.note.list",
                    title: "该榜单暂无歌曲",
                    message: "切换其他榜单试试。"
                )
            } else {
                if let error = app.leaderboardError {
                    InlineErrorBar(message: error) {
                        Task { await app.loadLeaderboardMusics() }
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
                                onSelect: { selectedMusicID = music.id },
                                onPlay: {
                                    selectedMusicID = music.id
                                    app.play(music, queue: page.list)
                                }
                            )
                        }
                    }
                    .padding(.vertical, 4)
                }
                LoadMoreBar(
                    page: page.page,
                    allPage: page.allPage,
                    total: page.total,
                    isLoading: app.isLoadingLeaderboard
                ) {
                    Task { await app.loadMoreLeaderboardMusics() }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @State private var selectedMusicID: String?
}
