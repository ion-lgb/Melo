import Foundation
import Observation

public struct LanguageOption: Hashable, Sendable {
    public var name: String
    public var locale: String
    public var country: String?
    public var fallback: Bool
}

/// 国际化：直接复用原版 `src/lang/*.json`（扁平 key → 文案），支持运行时切换。
@MainActor
@Observable
public final class Localizer {
    public private(set) var languageOptions: [LanguageOption] = []
    public private(set) var languageID: String = "zh-cn"
    private var tables: [String: [String: String]] = [:]
    private let fallbackID = "zh-cn"
    private weak var settings: SettingsStore?

    /// 全局访问点：供 SwiftUI 视图（无法拿到 AppModel 的地方）做静态文案国际化。
    @MainActor private static weak var sharedInstance: Localizer?

    @MainActor
    public static func install(_ localizer: Localizer) {
        sharedInstance = localizer
    }

    /// 静态文案翻译（视图内调用；未安装时回退 key）。
    /// 非隔离标记以便在静态预览数据等非 MainActor 上下文使用；运行时必须在主线程访问。
    public nonisolated static func tr(_ key: String) -> String {
        MainActor.assumeIsolated {
            sharedInstance?.t(key) ?? key
        }
    }

    public init(resourcesDirectory: URL, settings: SettingsStore) {
        self.settings = settings
        loadOptions()
        let initial = settings.languageID ?? Self.detectSystemLanguage() ?? fallbackID
        loadTable(initial)
        languageID = tables[initial] != nil ? initial : fallbackID
        if tables[languageID] == nil { loadTable(fallbackID) }
    }

    public func t(_ key: String) -> String {
        tables[languageID]?[key] ?? tables[fallbackID]?[key] ?? key
    }

    /// 支持原版 `{name}` 形式占位符的简单替换
    public func t(_ key: String, _ args: [String: String]) -> String {
        var text = t(key)
        for (name, value) in args {
            text = text.replacingOccurrences(of: "{\(name)}", with: value)
        }
        return text
    }

    public func setLanguage(_ id: String) {
        guard tables[id] != nil || id == fallbackID else { return }
        loadTable(id)
        languageID = id
        settings?.set(SettingKeys.langId, .string(id))
        if id == fallbackID { settings?.set(SettingKeys.langId, .string(fallbackID)) }
    }

    private func loadOptions() {
        let url = ResourceLocator.langDirectory.appendingPathComponent("languages.json")
        guard let data = try? Data(contentsOf: url),
              let array = JSONValue(jsonData: data)?.arrayValue else { return }
        languageOptions = array.compactMap { item in
            guard let locale = item["locale"]?.stringValue else { return nil }
            return LanguageOption(
                name: item["name"]?.stringValue ?? locale,
                locale: locale,
                country: item["country"]?.stringValue,
                fallback: item["fallback"]?.boolValue ?? false
            )
        }
    }

    private func loadTable(_ id: String) {
        guard tables[id] == nil else { return }
        let url = ResourceLocator.langDirectory.appendingPathComponent("\(id).json")
        guard let data = try? Data(contentsOf: url),
              let object = JSONValue(jsonData: data)?.objectValue else {
            MeloLog.warn("加载语言包失败: \(url.path)")
            return
        }
        tables[id] = object.compactMapValues { $0.stringValue }
    }

    private static func detectSystemLanguage() -> String? {
        guard let preferred = Locale.preferredLanguages.first?.lowercased() else { return nil }
        if preferred.hasPrefix("zh") {
            if preferred.contains("hant") || preferred.contains("tw") || preferred.contains("hk") {
                return "zh-tw"
            }
            return "zh-cn"
        }
        if preferred.hasPrefix("ko") { return "ko-kr" }
        if preferred.hasPrefix("en") { return "en-us" }
        return nil
    }
}
