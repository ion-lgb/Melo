import SwiftUI
import AppKit
import MeloCore

// MARK: - 主题环境

private struct MeloColorsKey: EnvironmentKey {
    static let defaultValue: AppColors = .fallback
}

extension EnvironmentValues {
    /// 当前主题配色（由 RootWindowView 在根节点注入）
    var meloColors: AppColors {
        get { self[MeloColorsKey.self] }
        set { self[MeloColorsKey.self] = newValue }
    }
}

// MARK: - 派生令牌

extension AppColors {
    /// 卡片/分组行底色（浅色为白，浮在浅灰分组背景上）
    var cardFill: Color {
        isDark ? Color(.sRGB, red: 0.110, green: 0.110, blue: 0.118) : .white
    }
    /// 分组页面底色（设置类页面）
    var groupedBackground: Color {
        isDark ? Color(.sRGB, red: 0.055, green: 0.055, blue: 0.059)
               : Color(.sRGB, red: 0.957, green: 0.957, blue: 0.965)
    }
    /// 卡片投影
    var cardShadow: Color {
        isDark ? .black.opacity(0.45) : .black.opacity(0.07)
    }
    /// 次级按钮 / 输入框 / 药丸底色
    var chipFill: Color {
        isDark ? .white.opacity(0.10) : .black.opacity(0.055)
    }
}

// MARK: - 页面背景

/// 内容区背景：Apple Music 风格不使用主题背景图，只铺纯色底。
struct ThemeBackground: View {
    let colors: AppColors

    var body: some View {
        colors.mainBackground
            .ignoresSafeArea()
    }
}

// MARK: - 卡片

/// 设置/详情页通用卡片容器
struct MeloCard<Content: View>: View {
    let title: String
    let subtitle: String?
    let systemImage: String?
    let content: Content

    init(title: String,
         subtitle: String? = nil,
         systemImage: String? = nil,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.content = content()
    }

    @Environment(\.meloColors) private var colors

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(colors.primary)
                }
                Text(title)
                    .font(MeloFont.sectionTitle)
                    .foregroundStyle(colors.font)
                Spacer(minLength: 0)
            }
            if let subtitle {
                Text(subtitle)
                    .font(MeloFont.caption)
                    .foregroundStyle(colors.fontSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: MeloMetrics.cardRadius, style: .continuous)
                .fill(colors.cardFill)
        )
        .shadow(color: colors.cardShadow, radius: 6, x: 0, y: 2)
    }
}

// MARK: - 页面标题

struct PageTitle: View {
    let title: String
    let subtitle: String?

    init(_ title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
    }

    @Environment(\.meloColors) private var colors

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(MeloFont.pageTitle)
                .foregroundStyle(colors.font)
            if let subtitle {
                Text(subtitle)
                    .font(MeloFont.secondary)
                    .foregroundStyle(colors.fontSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 质感辅助

extension View {
    /// 卡片内分隔线
    func meloDivider(_ colors: AppColors) -> some View {
        overlay(alignment: .bottom) {
            Rectangle().fill(colors.border).frame(height: 1)
        }
    }
}

// MARK: - 窗口辅助

enum MeloUIWindow {
    static let desktopLyricID = "desktop-lyric"

    /// 尝试关闭桌面歌词窗口（窗口由 MeloApp 创建，id 为 `desktop-lyric`）
    @MainActor
    static func closeDesktopLyric() {
        for window in NSApp.windows {
            let identifier = window.identifier?.rawValue ?? ""
            if identifier.contains(desktopLyricID) || window.title == "桌面歌词" {
                window.close()
            }
        }
    }

    /// 把主窗口带到前台（桌面歌词里点击「打开主窗口」）
    @MainActor
    static func activateMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let main = NSApp.windows.first(where: { $0.title != "桌面歌词" && $0.isVisible }) {
            main.makeKeyAndOrderFront(nil)
        }
    }
}

// MARK: - 搜索历史辅助

@MainActor
enum MeloUIActions {
    // MARK: 内置元数据辅助

    /// 音源展示名（内置源 id → 中文名；未知 id 回退为大写 id）
    static func sourceName(_ id: String, app: AppModel? = nil) -> String {
        switch id {
        case "all": return "聚合"
        case "kw": return "酷我"
        case "kg": return "酷狗"
        case "tx": return "QQ"
        case "wy": return "网易"
        case "mg": return "咪咕"
        case "local": return "本地"
        default:
            if let app, let info = app.builtinSources.first(where: { $0.id == id }) {
                return info.name
            }
            return id.uppercased()
        }
    }

    /// 播放量：数字字符串格式化为「万 / 亿」，其余原样返回（原版接口有的已格式化）
    static func formatPlayCount(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        guard let value = Int(raw) else { return raw }
        if value >= 100_000_000 {
            return String(format: "%.1f亿", Double(value) / 100_000_000)
        }
        if value >= 10_000 {
            return String(format: "%.1f万", Double(value) / 10_000)
        }
        return "\(value)"
    }

    /// 打开歌单详情：切换路由并触发加载（幂等，详情页自身也会做兜底加载）
    static func openSongList(id: String, source: String, app: AppModel) {
        app.route = .songListDetail(id: id, source: source)
        Task { @MainActor in
            await app.openSongListDetail(id: id, source: source)
        }
    }

    static func openSongList(item: SongListItem, app: AppModel) {
        openSongList(id: item.id, source: item.source, app: app)
    }
}
