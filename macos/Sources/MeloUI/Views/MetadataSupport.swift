import SwiftUI
import AppKit
import MeloCore

// MARK: - 内置元数据相关通用组件（搜索 / 榜单 / 歌单共用）

/// 音源选择 chips（all / 酷我 / 酷狗 / QQ / 网易 / 咪咕）
struct SourceChipBar: View {
    let app: AppModel
    let selected: String
    let onSelect: (String) -> Void

    @Environment(\.meloColors) private var colors

    private var sources: [MusicSourceInfo] {
        app.metadataSourcesWithAll.isEmpty ? app.builtinSources : app.metadataSourcesWithAll
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(sources) { source in
                    Button {
                        onSelect(source.id)
                    } label: {
                        Text(source.name)
                            .font(.system(size: 11, weight: selected == source.id ? .semibold : .regular))
                            .foregroundStyle(selected == source.id ? colors.primary : colors.fontSecondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                selected == source.id ? colors.primaryOpacity(0.14) : colors.fontTertiary.opacity(0.08),
                                in: Capsule()
                            )
                            .overlay(
                                Capsule().strokeBorder(
                                    selected == source.id ? colors.primaryOpacity(0.35) : Color.clear,
                                    lineWidth: 1
                                )
                            )
                    }
                    .buttonStyle(.plain)
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
                .font(.system(size: 10))
                .foregroundStyle(colors.fontTertiary)
            Spacer()
            if hasMore {
                Button(action: onLoadMore) {
                    HStack(spacing: 6) {
                        if isLoading { ProgressView().controlSize(.mini) }
                        Text(isLoading ? "加载中…" : "加载更多")
                            .font(.system(size: 11))
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isLoading)
            } else if total > 0 {
                Text("已全部加载")
                    .font(.system(size: 10))
                    .foregroundStyle(colors.fontTertiary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
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
                    .font(.system(size: 12))
                    .foregroundStyle(app.appColors.fontSecondary)
                Text("首次启动需要准备 JavaScriptCore 运行时与内置音源脚本")
                    .font(.system(size: 10))
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
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(colors.badgeTertiary)
            Text(message)
                .font(.system(size: 10.5))
                .foregroundStyle(colors.fontSecondary)
                .lineLimit(2)
            Spacer(minLength: 8)
            Button(retryTitle, action: onRetry)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(colors.badgeTertiary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(colors.badgeTertiary.opacity(0.22), lineWidth: 1)
        )
        .padding(.horizontal, 20)
    }
}

/// 歌单卡片（歌单广场网格 / 搜索结果）
struct SongListCard: View {
    let item: SongListItem
    let onOpen: () -> Void

    @Environment(\.meloColors) private var colors
    @State private var hovering = false

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 8) {
                CoverImage(urlString: item.cover, width: nil, height: nil, cornerRadius: 8, sizingHint: 64)
                    .aspectRatio(1, contentMode: .fit)
                    .frame(maxWidth: .infinity)

                Text(item.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(colors.font)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 5) {
                    if let creator = item.creator, !creator.isEmpty {
                        Text(creator)
                            .font(.system(size: 10))
                            .foregroundStyle(colors.fontTertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if let playCount = MeloUIActions.formatPlayCount(item.playCount) {
                        HStack(spacing: 2) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 7))
                            Text(playCount)
                                .font(.system(size: 9, design: .monospaced))
                        }
                        .foregroundStyle(colors.fontTertiary)
                    }
                }
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                colors.mainBackground.opacity(colors.isDark ? 0.55 : 0.72),
                in: RoundedRectangle(cornerRadius: 11, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(hovering ? colors.primaryOpacity(0.4) : colors.border, lineWidth: 1)
            )
            .opacity(hovering ? 0.95 : 1)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(item.name)
    }
}

/// 歌单列表行（搜索「歌单」Tab 使用）
struct SongListRow: View {
    let item: SongListItem
    let onOpen: () -> Void

    @Environment(\.meloColors) private var colors
    @State private var hovering = false

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 12) {
                CoverImage(urlString: item.cover, size: 56, cornerRadius: 7)

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(colors.font)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        if let creator = item.creator, !creator.isEmpty {
                            Text(creator)
                                .font(.system(size: 11))
                                .foregroundStyle(colors.fontSecondary)
                                .lineLimit(1)
                        }
                        if let playCount = MeloUIActions.formatPlayCount(item.playCount) {
                            Text("· 播放 \(playCount)")
                                .font(.system(size: 10))
                                .foregroundStyle(colors.fontTertiary)
                        }
                        if item.total != nil {
                            Text("· \(item.total ?? 0) 首")
                                .font(.system(size: 10))
                                .foregroundStyle(colors.fontTertiary)
                        }
                    }
                    if let description = item.description, !description.isEmpty {
                        Text(description)
                            .font(.system(size: 10))
                            .foregroundStyle(colors.fontTertiary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                MeloBadge(MeloUIActions.sourceName(item.source, app: nil), color: colors.badgeTertiary)

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(colors.fontTertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovering ? colors.hover : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
