import SwiftUI
import MeloCore

// MARK: - 歌单详情（Phase 1：内置元数据）

struct SongListDetailView: View {
    let app: AppModel
    let id: String
    let source: String

    @Environment(\.meloColors) private var colors
    @State private var selectedMusicID: String?

    private var detail: SongListDetail? {
        guard let detail = app.songListDetail,
              detail.info.id == id,
              detail.info.source == source else { return nil }
        return detail
    }

    private var isCurrentDetailLoaded: Bool {
        app.songListDetail?.info.id == id && app.songListDetail?.info.source == source
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            content
        }
        .task(id: "\(id)|\(source)|\(app.metadataReady)") {
            guard app.metadataReady else { return }
            if !isCurrentDetailLoaded {
                await app.openSongListDetail(id: id, source: source)
            }
        }
        .onExitCommand { goBack() }
        .onKeyPress(.delete) {
            goBack()
            return .handled
        }
    }

    // MARK: 顶栏

    private var topBar: some View {
        HStack(spacing: 10) {
            Button(action: goBack) {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 10, weight: .semibold))
                    Text("返回歌单广场")
                        .font(.system(size: 11))
                }
                .foregroundStyle(colors.fontSecondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(colors.fontTertiary.opacity(0.08), in: Capsule())
            }
            .buttonStyle(.plain)
            .help("返回歌单广场（Esc / Delete）")

            Text(detail?.info.name ?? "歌单详情")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(colors.fontTertiary)
                .lineLimit(1)

            Spacer()

            if app.isLoadingSongListDetail {
                ProgressView().controlSize(.mini)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 8)
    }

    // MARK: 内容

    @ViewBuilder
    private var content: some View {
        if !app.metadataReady {
            MetadataUnavailableView(app: app)
        } else if detail == nil {
            if let error = app.songListError {
                EmptyStateView(
                    systemImage: "exclamationmark.square.stack",
                    title: "歌单加载失败",
                    message: error,
                    actionTitle: "重试",
                    action: {
                        Task { await app.openSongListDetail(id: id, source: source) }
                    }
                )
            } else {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("正在加载歌单详情…")
                        .font(.system(size: 11))
                        .foregroundStyle(colors.fontSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else if let detail {
            VStack(spacing: 0) {
                infoHeader(detail.info)
                songsSection(detail)
            }
        }
    }

    // MARK: 歌单信息

    private func infoHeader(_ info: SongListItem) -> some View {
        HStack(alignment: .top, spacing: 16) {
            CoverImage(urlString: info.cover, size: 132, cornerRadius: 10)

            VStack(alignment: .leading, spacing: 7) {
                Text(info.name)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(colors.font)
                    .lineLimit(2)

                HStack(spacing: 8) {
                    MeloBadge(MeloUIActions.sourceName(info.source, app: app), color: colors.badgeTertiary)
                    if let creator = info.creator, !creator.isEmpty {
                        Text(creator)
                            .font(.system(size: 11))
                            .foregroundStyle(colors.fontSecondary)
                            .lineLimit(1)
                    }
                    if let playCount = MeloUIActions.formatPlayCount(info.playCount) {
                        Text("· 播放 \(playCount)")
                            .font(.system(size: 10.5))
                            .foregroundStyle(colors.fontTertiary)
                    }
                    if let total = info.total {
                        Text("· \(total) 首")
                            .font(.system(size: 10.5))
                            .foregroundStyle(colors.fontTertiary)
                    }
                }

                if let description = info.description, !description.isEmpty {
                    Text(description)
                        .font(.system(size: 10.5))
                        .foregroundStyle(colors.fontTertiary)
                        .lineLimit(3)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 8) {
                    Button {
                        playAll()
                    } label: {
                        Label("播放全部", systemImage: "play.fill")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(colors.primary)
                    .disabled(detail?.page.list.isEmpty ?? true)

                    if let detail, detail.page.hasMore {
                        Button {
                            Task { await app.loadMoreSongListDetail() }
                        } label: {
                            Label("加载更多歌曲", systemImage: "arrow.down")
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.bordered)
                        .disabled(app.isLoadingSongListDetail)
                    }

                    Spacer()
                }
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 10)
    }

    // MARK: 歌曲列表

    @ViewBuilder
    private func songsSection(_ detail: SongListDetail) -> some View {
        if detail.page.list.isEmpty {
            EmptyStateView(
                systemImage: "music.note.list",
                title: "该歌单暂无歌曲",
                message: "可能受版权限制，或歌单为空。"
            )
        } else {
            VStack(spacing: 0) {
                SongTableHeader()
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(detail.page.list.enumerated()), id: \.element.id) { index, music in
                            SongRow(
                                app: app,
                                music: music,
                                index: index,
                                isSelected: selectedMusicID == music.id,
                                onSelect: { selectedMusicID = music.id },
                                onPlay: {
                                    selectedMusicID = music.id
                                    app.play(music, queue: detail.page.list)
                                }
                            )
                        }
                    }
                    .padding(.vertical, 4)
                }
                LoadMoreBar(
                    page: detail.page.page,
                    allPage: detail.page.allPage,
                    total: detail.page.total,
                    isLoading: app.isLoadingSongListDetail
                ) {
                    Task { await app.loadMoreSongListDetail() }
                }
            }
        }
    }

    // MARK: 动作

    private func playAll() {
        guard let detail, !detail.page.list.isEmpty else { return }
        app.playList(detail.page.list, startAt: 0)
    }

    private func goBack() {
        app.route = .songList
    }
}
