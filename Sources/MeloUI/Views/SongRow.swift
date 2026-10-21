import SwiftUI
import AppKit
import MeloCore

// MARK: - 歌曲表格（我的列表 / 搜索 / 榜单 / 歌单详情共用）

enum SongTableColumns {
    static let index: CGFloat = 46
    static let singer: CGFloat = 150
    static let album: CGFloat = 160
    static let duration: CGFloat = 62
    static let actions: CGFloat = 72
    static let rowHeight: CGFloat = 36
}

struct SongTableHeader: View {
    @Environment(\.meloColors) private var colors

    var body: some View {
        HStack(spacing: 0) {
            Text("#")
                .frame(width: SongTableColumns.index, alignment: .center)
            Text(Localizer.tr("search__type_music")).frame(maxWidth: .infinity, alignment: .leading)
            Text("歌手").frame(width: SongTableColumns.singer, alignment: .leading)
            Text("专辑").frame(width: SongTableColumns.album, alignment: .leading)
            Text(Localizer.tr("music_time")).frame(width: SongTableColumns.duration, alignment: .trailing)
            Text(Localizer.tr("action")).frame(width: SongTableColumns.actions, alignment: .center)
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(colors.fontTertiary)
        .padding(.horizontal, 20)
        .padding(.bottom, 6)
        .overlay(alignment: .bottom) {
            Rectangle().fill(colors.border).frame(height: 1)
        }
    }
}

/// 多选批量操作（我的列表）；当右键/ellipsis 点击的行属于多选区域时，菜单作用于整个选区。
struct SongRowBatchActions {
    var count: Int
    var play: () -> Void
    var playNext: () -> Void
    var favorite: () -> Void
    var addToList: () -> Void
    var download: () -> Void
    var remove: () -> Void
}

/// 通用歌曲行：当前播放高亮、双击播放、单击选中、右键菜单、收藏/更多操作。
struct SongRow: View {
    let app: AppModel
    let music: MusicInfo
    let index: Int
    let isSelected: Bool
    /// 非空时，右键菜单会显示「从该列表移除」
    var removeFromListId: String? = nil
    /// 非空且当前行被选中时，菜单切换为批量操作
    var batchActions: SongRowBatchActions? = nil
    /// ⌘ 点击（切换选择）
    var onCommandSelect: (() -> Void)? = nil
    /// Shift 点击（范围连选）
    var onShiftSelect: (() -> Void)? = nil
    let onSelect: () -> Void
    let onPlay: () -> Void

    @Environment(\.meloColors) private var colors
    @State private var hovering = false
    @State private var showListPicker = false

    private var isCurrent: Bool { app.currentMusic?.id == music.id }
    private var isPlayingRow: Bool { isCurrent && app.isPlaying }
    private var isFavorite: Bool { app.isFavorite(music) }

    var body: some View {
        HStack(spacing: 0) {
            indexCell
                .frame(width: SongTableColumns.index, alignment: .center)

            HStack(spacing: 6) {
                Text(music.name)
                    .font(.system(size: 12, weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? colors.primary : colors.font)
                    .lineLimit(1)
                QualityBadges(music: music)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(music.singer)
                .font(.system(size: 12))
                .foregroundStyle(colors.fontSecondary)
                .lineLimit(1)
                .frame(width: SongTableColumns.singer, alignment: .leading)

            Text(music.albumName.isEmpty ? "—" : music.albumName)
                .font(.system(size: 12))
                .foregroundStyle(colors.fontTertiary)
                .lineLimit(1)
                .frame(width: SongTableColumns.album, alignment: .leading)

            Text(music.displayInterval)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(colors.fontTertiary)
                .frame(width: SongTableColumns.duration, alignment: .trailing)

            HStack(spacing: 6) {
                Button {
                    app.toggleFavorite(music)
                } label: {
                    Image(systemName: isFavorite ? "heart.fill" : "heart")
                        .font(.system(size: 11))
                        .foregroundStyle(isFavorite ? colors.primary : colors.fontTertiary)
                }
                .buttonStyle(.plain)
                .help(isFavorite ? Localizer.tr("setting__hot_key_player_music_unlove") : Localizer.tr("love_list"))

                Menu {
                    rowMenuContent
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(colors.fontTertiary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("更多操作")
            }
            .frame(width: SongTableColumns.actions, alignment: .center)
        }
        .padding(.horizontal, 20)
        .frame(height: SongTableColumns.rowHeight)
        .background(rowBackground)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { onPlay() }
        .modifier(RowSelectionGestures(onPlain: onSelect, onCommand: onCommandSelect, onShift: onShiftSelect))
        .contextMenu { rowMenuContent }
        .sheet(isPresented: $showListPicker) {
            ListPickerSheet(app: app, musics: [music])
        }
        .help("\(music.name) - \(music.singer)")
    }

    private var indexCell: some View {
        Group {
            if isCurrent {
                Image(systemName: isPlayingRow ? "speaker.wave.2.fill" : "speaker.fill")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(colors.primary)
            } else {
                Text("\(index + 1)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(colors.fontTertiary)
            }
        }
    }

    private var rowBackground: Color {
        if isCurrent { return colors.primaryOpacity(0.10) }
        if isSelected { return colors.selected }
        if hovering { return colors.hover }
        return .clear
    }

    private var usesBatchMenu: Bool {
        guard let batchActions else { return false }
        return isSelected && batchActions.count > 1
    }

    @ViewBuilder
    private var rowMenuContent: some View {
        if usesBatchMenu, let batch = batchActions {
            Button("播放选中 \(batch.count) 首") { batch.play() }
            Button("下一首播放（\(batch.count) 首）") { batch.playNext() }
            Button("收藏选中") { batch.favorite() }
            Button("添加到列表…") { batch.addToList() }
            Button("下载选中 \(batch.count) 首") { batch.download() }
            if removeFromListId != nil {
                Button("从列表移除 \(batch.count) 首…", role: .destructive) { batch.remove() }
            }
            Divider()
            Button("取消选择") { onSelect() }
        } else {
            singleMenuContent
        }
    }

    @ViewBuilder
    private var singleMenuContent: some View {
        Button(Localizer.tr("list__play")) { onPlay() }
        Button("下一首播放") { app.playNext(music) }
        Divider()
        Button(isFavorite ? Localizer.tr("setting__hot_key_player_music_unlove") : "收藏到「我的收藏」") {
            app.toggleFavorite(music)
        }
        Button("添加到列表…") { showListPicker = true }
        Button(Localizer.tr("download")) {
            Task { await app.startDownload(music) }
        }
        .disabled(music.isLocal)
        Button("不喜欢这首歌曲") {
            app.dislike(music)
        }
        if let listId = removeFromListId {
            Divider()
            Button("从「\(app.listName(listId))」移除", role: .destructive) {
                app.removeMusic(music, from: listId)
            }
        }
        Divider()
        Button("复制歌名") {
            copyToPasteboard(music.name)
            app.showToast("已复制歌名")
        }
        Button("复制歌曲信息") {
            copyToPasteboard("\(music.name) - \(music.singer)")
            app.showToast("已复制歌曲信息")
        }
    }

    private func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}


// MARK: - 行选择手势（普通 / ⌘ / Shift）

private struct RowSelectionGestures: ViewModifier {
    let onPlain: () -> Void
    let onCommand: (() -> Void)?
    let onShift: (() -> Void)?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let onShift, let onCommand {
            content
                .highPriorityGesture(TapGesture().modifiers(.shift).onEnded { onShift() })
                .highPriorityGesture(TapGesture().modifiers(.command).onEnded { onCommand() })
                .onTapGesture(perform: onPlain)
        } else if let onShift {
            content
                .highPriorityGesture(TapGesture().modifiers(.shift).onEnded { onShift() })
                .onTapGesture(perform: onPlain)
        } else if let onCommand {
            content
                .highPriorityGesture(TapGesture().modifiers(.command).onEnded { onCommand() })
                .onTapGesture(perform: onPlain)
        } else {
            content.onTapGesture(perform: onPlain)
        }
    }
}
