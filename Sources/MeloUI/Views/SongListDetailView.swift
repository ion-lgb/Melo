import SwiftUI
import MeloCore

// MARK: - 歌单详情（Phase 1：内置元数据）

struct SongListDetailView: View {
    let app: AppModel
    let id: String
    let source: String

    @Environment(\.meloColors) private var colors
    @State private var selectedMusicID: String?
    @State private var heroImage: NSImage?

    private var detail: SongListDetail? {
        guard let detail = app.songListDetail,
              detail.info.id == id,
              detail.info.source == source else { return nil }
        return detail
    }

    private var coverURL: String? {
        guard let cover = detail?.info.cover, !cover.isEmpty else { return nil }
        return cover
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
        .task(id: coverURL) {
            heroImage = await ArtworkImageLoader.shared.image(for: coverURL)
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
                        .font(.system(size: 11, weight: .semibold))
                    Text("返回歌单广场")
                        .font(MeloFont.secondary)
                }
                .foregroundStyle(colors.font)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(colors.chipFill, in: Capsule())
            }
            .buttonStyle(.plain)
            .help("返回歌单广场（Esc / Delete）")

            Text(detail?.info.name ?? "歌单详情")
                .font(MeloFont.controlLabel)
                .foregroundStyle(colors.fontTertiary)
                .lineLimit(1)

            Spacer()

            if app.isLoadingSongListDetail {
                ProgressView().controlSize(.mini)
            }
        }
        .padding(.horizontal, MeloMetrics.pageInset)
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
                        .font(MeloFont.caption)
                        .foregroundStyle(colors.fontTertiary)
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

    // MARK: 歌单信息（Apple Music 专辑页式 hero）

    private func infoHeader(_ info: SongListItem) -> some View {
        ZStack(alignment: .top) {
            ArtworkTintHeader(image: heroImage)

            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .bottom, spacing: 22) {
                    CoverImage(urlString: info.cover, size: 200, cornerRadius: MeloMetrics.heroCoverRadius)
                        .meloCoverShadow(intensity: 1.4)

                    VStack(alignment: .leading, spacing: 12) {
                        Text(info.name)
                            .font(MeloFont.heroTitle)
                            .foregroundStyle(colors.font)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)

                        HStack(spacing: 10) {
                            MeloBadge(MeloUIActions.sourceName(info.source, app: app), color: colors.badgePrimary)
                            if let creator = info.creator, !creator.isEmpty {
                                Text(creator)
                                    .font(MeloFont.secondary)
                                    .foregroundStyle(colors.fontSecondary)
                                    .lineLimit(1)
                            }
                        }

                        HStack(spacing: 6) {
                            if let playCount = MeloUIActions.formatPlayCount(info.playCount) {
                                Text("播放 \(playCount)")
                            }
                            if let total = info.total {
                                Text("· \(total) 首")
                            }
                        }
                        .font(MeloFont.caption)
                        .foregroundStyle(colors.fontTertiary)

                        if let description = info.description, !description.isEmpty {
                            Text(description)
                                .font(MeloFont.body)
                                .foregroundStyle(colors.fontSecondary)
                                .lineLimit(3)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        HStack(spacing: 12) {
                            Button {
                                playAll()
                            } label: {
                                Label("播放全部", systemImage: "play.fill")
                            }
                            .buttonStyle(.meloPrimary)
                            .disabled(detail?.page.list.isEmpty ?? true)

                            if let detail, detail.page.hasMore {
                                Button {
                                    Task { await app.loadMoreSongListDetail() }
                                } label: {
                                    Label("加载更多歌曲", systemImage: "arrow.down")
                                }
                                .buttonStyle(.meloSecondary)
                                .disabled(app.isLoadingSongListDetail)
                            }
                        }
                        .padding(.top, 4)
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(MeloMetrics.pageInset)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
