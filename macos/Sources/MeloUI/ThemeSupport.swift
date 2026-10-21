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

// MARK: - 主题背景

/// 主题背景：纯色 + 可选的背景图（内置主题 5 张 / 用户主题来自 LxDatas/theme_images）。
struct ThemeBackground: View {
    let colors: AppColors
    let imageURL: URL?

    var body: some View {
        ZStack {
            // 兜底底色：部分主题 --color-app-background 为全透明（如 black/mid_autumn），
            // 若不铺底色会透出窗口默认白色，深色主题下文字不可读。
            colors.isDark ? Color(white: 0.045) : Color.white
            colors.appBackground
            if let imageURL, let image = NSImage(contentsOf: imageURL) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .opacity(colors.isDark ? 0.62 : 0.72)
            }
        }
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
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(colors.primary)
                }
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(colors.font)
                Spacer(minLength: 0)
            }
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(colors.fontSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            colors.mainBackground.opacity(colors.isDark ? 0.62 : 0.78),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(colors.border, lineWidth: 1)
        )
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
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(colors.font)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(colors.fontSecondary)
            }
        }
    }
}

// MARK: - 主题预览色解析

/// 从主题 JSON 的 CSS 变量里解析出预览色（支持一层/多层 `var(...)` 引用）。
enum ThemePreview {
    static func variables(_ theme: Theme) -> [String: String] {
        var vars = theme.config.themeColors
        for (key, value) in theme.config.extInfo {
            vars[key] = value
        }
        return vars
    }

    static func color(_ key: String, in theme: Theme, depth: Int = 0) -> Color? {
        guard depth < 8 else { return nil }
        let vars = variables(theme)
        guard let raw = vars[key] else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("var(") {
            var inner = String(value.dropFirst(4))
            if inner.hasSuffix(")") { inner = String(inner.dropLast()) }
            inner = inner.trimmingCharacters(in: .whitespaces)
            return color(inner, in: theme, depth: depth + 1)
        }
        return RGBAColor(css: value)?.color
    }

    static func primary(_ theme: Theme) -> Color {
        color("--color-primary", in: theme) ?? .accentColor
    }

    static func background(_ theme: Theme) -> Color {
        color("--color-main-background", in: theme)
            ?? color("--color-app-background", in: theme)
            ?? (theme.isDark ? Color(red: 0.09, green: 0.09, blue: 0.09) : Color.white)
    }

    static func badge(_ theme: Theme) -> Color {
        color("--color-badge-secondary", in: theme) ?? primary(theme)
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
