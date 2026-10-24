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

    /// Apple Music 风格固定配色：外观不再跟随 LX 主题（主题仅用于数据兼容与导入导出），
    /// 明暗只由系统外观决定。
    public static func appleMusic(isDark: Bool) -> AppColors {
        let accent = isDark
            ? Color(.sRGB, red: 0.984, green: 0.227, blue: 0.298)   // #FB3A4C
            : Color(.sRGB, red: 0.980, green: 0.141, blue: 0.235)   // #FA243C
        let neutralGray = isDark
            ? Color(.sRGB, red: 0.596, green: 0.596, blue: 0.624)   // #98989F
            : Color(.sRGB, red: 0.525, green: 0.525, blue: 0.545)   // #86868B
        let amber = isDark
            ? Color(.sRGB, red: 0.941, green: 0.651, blue: 0.227)   // #F0A63A
            : Color(.sRGB, red: 0.631, green: 0.384, blue: 0.027)   // #A16207
        let font = isDark
            ? Color(.sRGB, red: 0.961, green: 0.961, blue: 0.969)   // #F5F5F7
            : Color(.sRGB, red: 0.114, green: 0.114, blue: 0.122)   // #1D1D1F
        let mainBackground = isDark
            ? Color(.sRGB, red: 0.082, green: 0.082, blue: 0.086)   // #151516
            : Color(.sRGB, red: 1, green: 1, blue: 1)
        let appBackground = isDark
            ? Color(.sRGB, red: 0.043, green: 0.043, blue: 0.047)   // #0B0B0C
            : Color(.sRGB, red: 0.969, green: 0.969, blue: 0.976)   // #F7F7F9

        return AppColors(
            isDark: isDark,
            primary: accent,
            primaryOpacity: { accent.opacity($0) },
            appBackground: appBackground,
            mainBackground: mainBackground,
            navFont: accent,
            font: font,
            fontSecondary: font.opacity(isDark ? 0.66 : 0.62),
            fontTertiary: font.opacity(isDark ? 0.42 : 0.38),
            border: font.opacity(isDark ? 0.12 : 0.09),
            hover: font.opacity(isDark ? 0.07 : 0.05),
            selected: accent.opacity(isDark ? 0.24 : 0.13),
            badgePrimary: accent,
            badgeSecondary: neutralGray,
            badgeTertiary: amber,
            buttonHide: neutralGray,
            buttonMin: neutralGray,
            buttonClose: neutralGray
        )
    }

    public static let fallback = AppColors.appleMusic(isDark: false)
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

    private let settings: SettingsStore
    private let resourcesDirectory: URL
    private let dataDirectory: URL
    private var appearanceObservation: NSKeyValueObservation?

    public init(resourcesDirectory: URL, settings: SettingsStore, dataDirectory: URL) {
        self.resourcesDirectory = resourcesDirectory
        self.settings = settings
        self.dataDirectory = dataDirectory
        loadThemes()
        self.systemIsDark = Self.detectSystemIsDark()
        refreshCurrent()
        appearanceObservation = NSApp?.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in
                guard let self else { return }
                let isDark = Self.detectSystemIsDark()
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
        dataDirectory.appendingPathComponent("theme.json")
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
        colors = buildColors()
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

    // MARK: - 颜色令牌

    /// 强制暗色仅用于开发期截图走查（`MELO_FORCE_DARK=1`）。
    private static func detectSystemIsDark() -> Bool {
        if ProcessInfo.processInfo.environment["MELO_FORCE_DARK"] == "1" { return true }
        return NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    /// 外观固定为 Apple Music 配色，只随系统明暗切换；`current` 主题仅用于数据兼容与主题编辑器。
    private func buildColors() -> AppColors {
        AppColors.appleMusic(isDark: systemIsDark)
    }
}
