import SwiftUI
import AppKit
import MeloCore

// MARK: - 内置元数据相关通用组件（搜索 / 榜单 / 歌单共用）

/// 音源选择 chips（all / 酷我 / 酷狗 / QQ / 网易 / 咪咕）
struct SourceChipBar: View {
    let app: AppModel
    let selected: String
    let onSelect: (String) -> Void

    private var sources: [MusicSourceInfo] {
        app.metadataSourcesWithAll.isEmpty ? app.builtinSources : app.metadataSourcesWithAll
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(sources) { source in
                    MeloChip(text: source.name, isSelected: selected == source.id) {
                        onSelect(source.id)
                    }
                }
            }
        }
    }
}

/// 分页/加载更多条
struct LoadMoreBar: View {
    let page: Int
    let allPage: Int
    let total: Int
    let isLoading: Bool
    let onLoadMore: () -> Void

    @Environment(\.meloColors) private var colors

    private var hasMore: Bool { allPage > page }

    var body: some View {
        HStack(spacing: 10) {
            Text(total > 0 ? "第 \(max(page, 1)) / \(max(allPage, page)) 页 · 共 \(total) 条" : "共 \(total) 条")
                .font(MeloFont.caption)
                .foregroundStyle(colors.fontTertiary)
            Spacer()
            if hasMore {
                Button(action: onLoadMore) {
                    HStack(spacing: 6) {
                        if isLoading { ProgressView().controlSize(.mini) }
                        Text(isLoading ? "加载中…" : "加载更多")
                            .font(MeloFont.controlLabel)
                    }
                }
                .buttonStyle(.meloSecondary)
                .disabled(isLoading)
            } else if total > 0 {
                Text("已全部加载")
                    .font(MeloFont.caption)
                    .foregroundStyle(colors.fontTertiary)
            }
        }
        .padding(.horizontal, MeloMetrics.pageInset)
        .padding(.vertical, 12)
    }
}

/// 内置音源未就绪时的整页状态
struct MetadataUnavailableView: View {
    let app: AppModel

    var body: some View {
        if let error = app.metadataError {
            EmptyStateView(
                systemImage: "exclamationmark.triangle",
                title: "内置音源初始化失败",
                message: "\(error)\n可尝试重启应用；若持续失败请检查内置音源资源是否完整。"
            )
        } else {
            VStack(spacing: 12) {
                ProgressView().controlSize(.regular)
                Text("内置音源加载中…")
                    .font(MeloFont.secondary)
                    .foregroundStyle(app.appColors.fontSecondary)
                Text("首次启动需要准备 JavaScriptCore 运行时与内置音源脚本")
                    .font(MeloFont.caption)
                    .foregroundStyle(app.appColors.fontTertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// 行内错误提示条（保留已有内容时可重试）
struct InlineErrorBar: View {
    let message: String
    var retryTitle: String = "重试"
    let onRetry: () -> Void

    @Environment(\.meloColors) private var colors

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(colors.badgeTertiary)
            Text(message)
                .font(MeloFont.secondary)
                .foregroundStyle(colors.fontSecondary)
                .lineLimit(2)
            Spacer(minLength: 8)
            Button(retryTitle, action: onRetry)
                .buttonStyle(.meloSecondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(colors.cardFill, in: RoundedRectangle(cornerRadius: MeloMetrics.controlRadius, style: .continuous))
        .padding(.horizontal, MeloMetrics.pageInset)
    }
}

/// Apple Music 式封面网格卡片：封面 + 下方两行文字（标题 13 semibold、副标题 12 次级）
struct MeloCoverCard: View {
    let title: String
    var subtitle: String?
    var cover: String?
    var isSelected: Bool = false
    let action: () -> Void

    @Environment(\.meloColors) private var colors
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                CoverImage(urlString: cover, width: nil, height: nil, cornerRadius: MeloMetrics.coverRadius, sizingHint: 140)
                    .aspectRatio(1, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .meloCoverShadow(intensity: hovering ? 1.4 : 1)
                    .overlay(
                        RoundedRectangle(cornerRadius: MeloMetrics.coverRadius, style: .continuous)
                            .strokeBorder(isSelected ? colors.primary : Color.clear, lineWidth: 2)
                    )

                Text(title)
                    .font(MeloFont.cardTitle)
                    .foregroundStyle(colors.font)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(MeloFont.secondary)
                        .foregroundStyle(colors.fontSecondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .offset(y: hovering ? -3 : 0)
            .animation(.easeOut(duration: 0.15), value: hovering)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(title)
    }
}

/// 歌单卡片（歌单广场网格 / 搜索结果）
struct SongListCard: View {
    let item: SongListItem
    let onOpen: () -> Void

    var body: some View {
        MeloCoverCard(
            title: item.name,
            subtitle: subtitleText,
            cover: item.cover,
            action: onOpen
        )
    }

    private var subtitleText: String? {
        if let creator = item.creator, !creator.isEmpty {
            if let playCount = MeloUIActions.formatPlayCount(item.playCount) {
                return "\(creator) · \(playCount)"
            }
            return creator
        }
        if let playCount = MeloUIActions.formatPlayCount(item.playCount) {
            return "播放 \(playCount)"
        }
        if let total = item.total {
            return "\(total) 首"
        }
        return nil
    }
}

/// 歌单列表行（紧凑列表场景使用）
struct SongListRow: View {
    let item: SongListItem
    let onOpen: () -> Void

    @Environment(\.meloColors) private var colors
    @State private var hovering = false

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 12) {
                CoverImage(urlString: item.cover, size: 56, cornerRadius: MeloMetrics.coverRadius)

                VStack(alignment: .leading, spacing: 4) {
                    Text(item.name)
                        .font(MeloFont.cardTitle)
                        .foregroundStyle(colors.font)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        if let creator = item.creator, !creator.isEmpty {
                            Text(creator)
                                .font(MeloFont.secondary)
                                .foregroundStyle(colors.fontSecondary)
                                .lineLimit(1)
                        }
                        if let playCount = MeloUIActions.formatPlayCount(item.playCount) {
                            Text("· 播放 \(playCount)")
                                .font(MeloFont.caption)
                                .foregroundStyle(colors.fontTertiary)
                        }
                        if item.total != nil {
                            Text("· \(item.total ?? 0) 首")
                                .font(MeloFont.caption)
                                .foregroundStyle(colors.fontTertiary)
                        }
                    }
                    if let description = item.description, !description.isEmpty {
                        Text(description)
                            .font(MeloFont.caption)
                            .foregroundStyle(colors.fontTertiary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                MeloBadge(MeloUIActions.sourceName(item.source, app: nil), color: colors.badgeTertiary)

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(colors.fontTertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovering ? colors.hover : Color.clear, in: RoundedRectangle(cornerRadius: MeloMetrics.controlRadius, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
