import Foundation
import SwiftUI
import AppKit
import Observation

// MARK: - 颜色

public struct RGBAColor: Hashable, Sendable {
    public var r: Double
    public var g: Double
    public var b: Double
    public var a: Double

    public init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    public var color: Color {
        Color(.sRGB, red: r / 255.0, green: g / 255.0, blue: b / 255.0, opacity: a)
    }

    public var nsColor: NSColor {
        NSColor(srgbRed: r / 255.0, green: g / 255.0, blue: b / 255.0, alpha: a)
    }

    /// 解析 `#rgb` / `#rrggbb` / `rgb(r, g, b)` / `rgba(r, g, b, a)`
    public init?(css: String) {
        var text = css.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty else { return nil }
        if text.hasPrefix("#") {
            var hex = String(text.dropFirst())
            if hex.count == 3 {
                hex = hex.map { "\($0)\($0)" }.joined()
            }
            guard hex.count == 6 || hex.count == 8, let value = UInt64(hex, radix: 16) else { return nil }
            if hex.count == 6 {
                self.init(
                    r: Double((value >> 16) & 0xFF),
                    g: Double((value >> 8) & 0xFF),
                    b: Double(value & 0xFF)
                )
            } else {
                self.init(
                    r: Double((value >> 24) & 0xFF),
                    g: Double((value >> 16) & 0xFF),
                    b: Double((value >> 8) & 0xFF),
                    a: Double(value & 0xFF) / 255.0
                )
            }
            return
        }
        guard text.hasPrefix("rgb") else { return nil }
        if let open = text.firstIndex(of: "("), let close = text.lastIndex(of: ")") {
            text = String(text[text.index(after: open)..<close])
        }
        let parts = text.split(whereSeparator: { $0 == "," || $0 == "/" }).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 3 else { return nil }
        func number(_ s: String) -> Double? {
            if s.hasSuffix("%") { return (Double(s.dropLast()) ?? 0) * 2.55 }
            return Double(s)
        }
        guard let r = number(parts[0]), let g = number(parts[1]), let b = number(parts[2]) else { return nil }
        let a = parts.count > 3 ? (Double(parts[3]) ?? 1) : 1
        self.init(r: r, g: g, b: b, a: a)
    }
}

// MARK: - 主题模型

public struct ThemeConfig: Codable, Hashable, Sendable {
    public var themeColors: [String: String]
    public var extInfo: [String: String]

    public init(themeColors: [String: String], extInfo: [String: String]) {
        self.themeColors = themeColors
        self.extInfo = extInfo
    }
}

public struct Theme: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var isDark: Bool
    public var isDarkFont: Bool
    public var isCustom: Bool?
    public var config: ThemeConfig

    public init(id: String, name: String, isDark: Bool, isDarkFont: Bool, isCustom: Bool? = nil, config: ThemeConfig) {
        self.id = id
        self.name = name
        self.isDark = isDark
        self.isDarkFont = isDarkFont
        self.isCustom = isCustom
        self.config = config
    }
}

// MARK: - 应用配色令牌

public struct AppColors {
    public var isDark: Bool
    public var primary: Color
    public var primaryOpacity: (Double) -> Color
    public var appBackground: Color
    public var mainBackground: Color
    public var navFont: Color
    public var font: Color
    public var fontSecondary: Color
    public var fontTertiary: Color
    public var border: Color
    public var hover: Color
    public var selected: Color
    public var badgePrimary: Color
    public var badgeSecondary: Color
    public var badgeTertiary: Color
    public var buttonHide: Color
    public var buttonMin: Color
    public var buttonClose: Color
    public var backgroundImageURL: URL?

    public static let fallback = AppColors(
        isDark: false,
        primary: Color(red: 0.30, green: 0.69, blue: 0.49),
        primaryOpacity: { Color(red: 0.30, green: 0.69, blue: 0.49).opacity($0) },
        appBackground: Color.white,
        mainBackground: Color.white,
        navFont: Color(red: 0.30, green: 0.69, blue: 0.49),
        font: Color(red: 0.13, green: 0.13, blue: 0.13),
        fontSecondary: Color(red: 0.13, green: 0.13, blue: 0.13).opacity(0.65),
        fontTertiary: Color(red: 0.13, green: 0.13, blue: 0.13).opacity(0.4),
        border: Color.black.opacity(0.08),
        hover: Color.black.opacity(0.05),
        selected: Color(red: 0.30, green: 0.69, blue: 0.49).opacity(0.14),
        badgePrimary: Color(red: 0.30, green: 0.69, blue: 0.49),
        badgeSecondary: Color(red: 0.29, green: 0.68, blue: 0.84),
        badgeTertiary: Color(red: 0.91, green: 0.67, blue: 0.21),
        buttonHide: Color(red: 0.23, green: 0.76, blue: 0.70),
        buttonMin: Color(red: 0.52, green: 0.77, blue: 0.23),
        buttonClose: Color(red: 0.98, green: 0.71, blue: 0.63),
        backgroundImageURL: nil
    )
}

// MARK: - 主题管理

@MainActor
@Observable
public final class ThemeManager {
    public private(set) var builtinThemes: [Theme] = []
    public private(set) var userThemes: [Theme] = []
    public private(set) var current: Theme = Theme(
        id: "green", name: "绿意盎然", isDark: false, isDarkFont: false,
        config: ThemeConfig(themeColors: [:], extInfo: [:])
    )
    public private(set) var colors: AppColors = .fallback
    public private(set) var systemIsDark: Bool = false
    public private(set) var backgroundImageURL: URL?

    private let settings: SettingsStore
    private let resourcesDirectory: URL
    private let userThemeImagesDirectory: URL
    private var appearanceObservation: NSKeyValueObservation?

    public init(resourcesDirectory: URL, settings: SettingsStore, dataDirectory: URL) {
        self.resourcesDirectory = resourcesDirectory
        self.settings = settings
        self.userThemeImagesDirectory = dataDirectory.appendingPathComponent("theme_images", isDirectory: true)
        loadThemes()
        self.systemIsDark = NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        refreshCurrent()
        appearanceObservation = NSApp?.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in
                guard let self else { return }
                let isDark = NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                if isDark != self.systemIsDark {
                    self.systemIsDark = isDark
                    self.refreshCurrent()
                }
            }
        }
    }

    public var allThemes: [Theme] { builtinThemes + userThemes }

    public var isAutoMode: Bool { settings.themeID == "auto" }

    public func theme(id: String) -> Theme? { allThemes.first { $0.id == id } }

    private func loadThemes() {
        if let data = try? Data(contentsOf: ResourceLocator.themesURL),
           let list = try? JSONDecoder().decode([Theme].self, from: data) {
            builtinThemes = list
        } else {
            MeloLog.error("加载内置主题失败: \(ResourceLocator.themesURL.path)")
        }
        // 原版用户主题：LxDatas/theme.json -> { "themes": [Theme] }
        let themeStoreURL = settings.fileURL.deletingLastPathComponent().appendingPathComponent("theme.json")
        if let data = try? Data(contentsOf: themeStoreURL),
           let root = JSONValue(jsonData: data),
           let themes = root["themes"]?.arrayValue {
            userThemes = themes.compactMap { value -> Theme? in
                guard let json = value.jsonString() else { return nil }
                return try? JSONDecoder().decode(Theme.self, from: Data(json.utf8))
            }
        }
    }

    /// 重新加载用户主题（主题编辑器/导入后调用）
    public func reloadUserThemes() {
        loadThemes()
        refreshCurrent()
    }

    // MARK: - 用户主题（LxDatas/theme.json，原版格式 `{ "themes": [Theme] }`）

    private var themeStoreURL: URL {
        settings.fileURL.deletingLastPathComponent().appendingPathComponent("theme.json")
    }

    private func persistUserThemes() throws {
        let encoder = JSONEncoder()
        let data = try encoder.encode(userThemes)
        guard let list = JSONValue(jsonData: data),
              let text = JSONValue.object(["themes": list]).jsonString() else {
            throw NSError(domain: "MeloTheme", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "主题序列化失败"])
        }
        let url = themeStoreURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    /// 基于现有主题派生一个用户主题（只覆盖传入的颜色变量）
    public func createUserTheme(name: String, baseThemeID: String, overrides: [String: String]) -> Theme? {
        guard let base = theme(id: baseThemeID) ?? builtinThemes.first else { return nil }
        var colors = base.config.themeColors
        var ext = base.config.extInfo
        for (key, value) in overrides {
            if key.hasPrefix("--color") {
                colors[key] = value
            } else {
                ext[key] = value
                colors.removeValue(forKey: key)
            }
        }
        // 记录基础主题，便于主题编辑器回显（原版会忽略未知 extInfo 键）
        ext["baseThemeId"] = base.id
        let timestamp = Int(Date().timeIntervalSince1970)
        let id = "custom_\(timestamp)_\(Int.random(in: 100...999))"
        return Theme(
            id: id,
            name: name,
            isDark: base.isDark,
            isDarkFont: base.isDarkFont,
            isCustom: true,
            config: ThemeConfig(themeColors: colors, extInfo: ext)
        )
    }

    public func saveUserTheme(_ theme: Theme) throws {
        var value = theme
        value.isCustom = true
        if let index = userThemes.firstIndex(where: { $0.id == value.id }) {
            userThemes[index] = value
        } else {
            userThemes.append(value)
        }
        try persistUserThemes()
        reloadUserThemes()
    }

    public func removeUserTheme(id: String) throws {
        guard userThemes.contains(where: { $0.id == id }) else { return }
        userThemes.removeAll { $0.id == id }
        try persistUserThemes()
        reloadUserThemes()
    }

    public func exportThemeJSON(id: String) -> String? {
        guard let target = theme(id: id) else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(target) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func importThemeJSON(_ text: String) throws -> Theme {
        guard let data = text.data(using: .utf8) else {
            throw NSError(domain: "MeloTheme", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "主题 JSON 编码无效"])
        }
        var imported = try JSONDecoder().decode(Theme.self, from: data)
        imported.isCustom = true
        // id 冲突（内置或已有用户主题）时生成新 id，避免覆盖
        if allThemes.contains(where: { $0.id == imported.id }) {
            imported.id = "custom_\(Int(Date().timeIntervalSince1970))_\(Int.random(in: 100...999))"
        }
        userThemes.append(imported)
        try persistUserThemes()
        reloadUserThemes()
        return imported
    }

    public func refreshCurrent() {
        let resolvedID: String
        if isAutoMode {
            let light = settings.string(SettingKeys.lightThemeId) ?? "green"
            let dark = settings.string(SettingKeys.darkThemeId) ?? "black"
            resolvedID = systemIsDark ? dark : light
        } else {
            resolvedID = settings.themeID
        }
        let theme = theme(id: resolvedID)
            ?? theme(id: systemIsDark ? "black" : "green")
            ?? builtinThemes.first
        guard let theme else { return }
        current = theme
        colors = buildColors(theme)
        resolveBackgroundImage(theme)
    }

    public func selectTheme(id: String) {
        settings.set(SettingKeys.themeId, .string(id))
        if id == "auto" {
            // auto 模式下保证亮/暗主题有值
            if settings.string(SettingKeys.lightThemeId) == nil {
                settings.set(SettingKeys.lightThemeId, .string("green"))
            }
            if settings.string(SettingKeys.darkThemeId) == nil {
                settings.set(SettingKeys.darkThemeId, .string("black"))
            }
        }
        refreshCurrent()
    }

    public func setAutoTheme(lightId: String, darkId: String) {
        settings.set([
            SettingKeys.themeId: .string("auto"),
            SettingKeys.lightThemeId: .string(lightId),
            SettingKeys.darkThemeId: .string(darkId),
        ])
        refreshCurrent()
    }

    // MARK: - 颜色解析

    private func mergedVariables(_ theme: Theme) -> [String: String] {
        var vars = theme.config.themeColors
        for (key, value) in theme.config.extInfo {
            vars[key] = value
        }
        return vars
    }

    private func buildColors(_ theme: Theme) -> AppColors {
        let vars = mergedVariables(theme)
        func parse(_ key: String, depth: Int = 0) -> RGBAColor? {
            guard let raw = vars[key], depth < 8 else { return nil }
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasPrefix("var(") {
                let inner = value.dropFirst(4).dropLast(value.hasSuffix(")") ? 1 : 0)
                let name = String(inner).trimmingCharacters(in: .whitespaces)
                return parse(name, depth: depth + 1)
            }
            return RGBAColor(css: value)
        }

        let isDark = theme.isDark
        let primaryRGBA = parse("--color-primary") ?? (isDark ? RGBAColor(r: 255, g: 255, b: 255) : RGBAColor(r: 77, g: 175, b: 124))
        let primary = primaryRGBA.color
        let appBackground = (parse("--color-app-background") ?? RGBAColor(r: isDark ? 0 : 255, g: isDark ? 0 : 255, b: isDark ? 0 : 255, a: isDark ? 0.8 : 1)).color
        let mainBackground = (parse("--color-main-background") ?? RGBAColor(r: isDark ? 19 : 255, g: isDark ? 19 : 255, b: isDark ? 19 : 255, a: 1)).color
        let navFont = (parse("--color-nav-font") ?? primaryRGBA).color
        let fontRGBA = parse("--color-1000") ?? (isDark ? RGBAColor(r: 229, g: 229, b: 229) : RGBAColor(r: 33, g: 33, b: 33))
        let font = fontRGBA.color
        let fontSecondary = font.opacity(0.65)
        let fontTertiary = font.opacity(0.42)
        let border = font.opacity(isDark ? 0.14 : 0.08)
        let hover = font.opacity(0.06)
        let selected = primary.opacity(isDark ? 0.22 : 0.14)
        let badgePrimary = (parse("--color-badge-primary") ?? primaryRGBA).color
        let badgeSecondary = (parse("--color-badge-secondary") ?? RGBAColor(r: 75, g: 174, b: 213)).color
        let badgeTertiary = (parse("--color-badge-tertiary") ?? RGBAColor(r: 231, g: 170, b: 54)).color
        let buttonHide = (parse("--color-btn-hide") ?? RGBAColor(r: 59, g: 194, b: 178)).color
        let buttonMin = (parse("--color-btn-min") ?? RGBAColor(r: 133, g: 196, b: 59)).color
        let buttonClose = (parse("--color-btn-close") ?? RGBAColor(r: 250, g: 180, b: 160)).color

        return AppColors(
            isDark: isDark,
            primary: primary,
            primaryOpacity: { primary.opacity($0) },
            appBackground: appBackground,
            mainBackground: mainBackground,
            navFont: navFont,
            font: font,
            fontSecondary: fontSecondary,
            fontTertiary: fontTertiary,
            border: border,
            hover: hover,
            selected: selected,
            badgePrimary: badgePrimary,
            badgeSecondary: badgeSecondary,
            badgeTertiary: badgeTertiary,
            buttonHide: buttonHide,
            buttonMin: buttonMin,
            buttonClose: buttonClose,
            backgroundImageURL: nil
        )
    }

    private func resolveBackgroundImage(_ theme: Theme) {
        guard let raw = theme.config.extInfo["--background-image"],
              raw != "none", !raw.isEmpty else {
            backgroundImageURL = nil
            return
        }
        var path = raw
        if let range = raw.range(of: "url(") {
            path = String(raw[range.upperBound...])
            if path.hasSuffix(")") { path = String(path.dropLast()) }
            path = path.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
        }
        // 内置主题: ./theme_images/xxx.png；用户主题: 文件名（存于 LxDatas/theme_images）
        let lastComponent = (path as NSString).lastPathComponent
        if path.contains("theme_images") {
            let builtin = ResourceLocator.themeImagesDirectory.appendingPathComponent(lastComponent)
            if FileManager.default.fileExists(atPath: builtin.path) {
                backgroundImageURL = builtin
                return
            }
        }
        let user = userThemeImagesDirectory.appendingPathComponent(lastComponent)
        backgroundImageURL = FileManager.default.fileExists(atPath: user.path) ? user : nil
    }
}
