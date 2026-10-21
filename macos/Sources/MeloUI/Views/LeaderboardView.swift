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

            MeloIconButton(systemName: "arrow.clockwise", help: "重新加载榜单") {
                Task { await app.loadLeaderboards() }
            }
        }
        .padding(.horizontal, 20)
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
                .font(.system(size: 11))
                .foregroundStyle(colors.fontSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 榜单列表

    private var boardList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("全部榜单")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(colors.fontTertiary)
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 6)

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(app.leaderboards) { board in
                        boardRow(board)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 10)
            }
        }
        .frame(width: 230)
        .background(colors.mainBackground.opacity(colors.isDark ? 0.35 : 0.45))
    }

    private func boardRow(_ board: LeaderboardInfo) -> some View {
        let isSelected = app.selectedLeaderboardId == board.id
        return Button {
            guard app.selectedLeaderboardId != board.id else { return }
            Task { await app.selectLeaderboard(board) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isSelected ? "chart.bar.fill" : "chart.bar")
                    .font(.system(size: 11))
                    .foregroundStyle(isSelected ? colors.primary : colors.fontTertiary)
                    .frame(width: 16)
                Text(board.name)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(colors.font)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let total = board.total {
                    Text("\(total)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(colors.fontTertiary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                isSelected ? colors.selected : Color.clear,
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
        }
        .buttonStyle(.plain)
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
                        .font(.system(size: 11))
                        .foregroundStyle(colors.fontSecondary)
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
