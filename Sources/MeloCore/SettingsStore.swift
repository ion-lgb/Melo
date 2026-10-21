import Foundation
import Observation

/// 应用设置。存储格式与原版 LX 兼容：
/// `~/Library/Application Support/lx-music-desktop/LxDatas/config_v2.json`
/// 文件结构为 `{ "setting": { "<key>": <value>, ... }, ...其他顶层键保留 }`
@MainActor
@Observable
public final class SettingsStore {
    public private(set) var values: [String: JSONValue]
    public let fileURL: URL
    private var extraTopLevel: [String: JSONValue] = [:]
    private var isLoading = false

    public init(dataDirectory: URL) {
        let fileURL = dataDirectory.appendingPathComponent("config_v2.json")
        self.fileURL = fileURL

        var defaults: [String: JSONValue] = [:]
        if let data = try? Data(contentsOf: ResourceLocator.defaultSettingsURL),
           let object = JSONValue(jsonData: data)?.objectValue {
            defaults = object.mapValues { value in
                if let text = value.stringValue, text.contains("$HOME") {
                    return .string(text.replacingOccurrences(of: "$HOME", with: NSHomeDirectory()))
                }
                return value
            }
        }

        var loaded: [String: JSONValue] = [:]
        var extras: [String: JSONValue] = [:]
        if let data = try? Data(contentsOf: fileURL),
           let root = JSONValue(jsonData: data)?.objectValue {
            if let setting = root["setting"]?.objectValue {
                loaded = setting
            } else {
                // 兼容极早期直接把设置平铺在根上的格式
                loaded = root.filter { $0.key != "setting" }
            }
            extras = root.filter { $0.key != "setting" }
        }
        self.values = defaults.merging(loaded) { _, new in new }
        self.extraTopLevel = extras
    }

    // MARK: - 读取

    public func value(_ key: String) -> JSONValue? { values[key] }

    public func string(_ key: String) -> String? { values[key]?.stringValue }

    public func bool(_ key: String, default def: Bool = false) -> Bool { values[key]?.boolValue ?? def }

    public func double(_ key: String, default def: Double) -> Double { values[key]?.doubleValue ?? def }

    public func int(_ key: String, default def: Int) -> Int { values[key]?.intValue ?? def }

    public var themeID: String { string(SettingKeys.themeId) ?? "green" }
    public var isAutoTheme: Bool { themeID == "auto" }
    public var languageID: String? { string(SettingKeys.langId) }

    // MARK: - 写入

    @discardableResult
    public func set(_ key: String, _ value: JSONValue) -> Bool {
        if values[key] == value { return false }
        values[key] = value
        save()
        return true
    }

    @discardableResult
    public func set(_ updates: [String: JSONValue]) -> Bool {
        var changed = false
        for (key, value) in updates where values[key] != value {
            values[key] = value
            changed = true
        }
        if changed { save() }
        return changed
    }

    public func save() {
        guard !isLoading else { return }
        var root = extraTopLevel
        root["setting"] = .object(values)
        guard let data = JSONValue.object(root).jsonData(pretty: true) else { return }
        do {
            try MeloUtils.atomicWrite(data, to: fileURL)
        } catch {
            MeloLog.error("保存设置失败: \(error.localizedDescription)")
        }
    }

    /// 导出为原版设置对象（用于调试/备份）
    public func exportJSON() -> JSONValue { .object(values) }

    /// 导入/恢复设置：传入原版扁平 setting 对象，合并到当前设置（缺失键保留默认值）
    public func importSettings(_ object: JSONValue) throws {
        guard let incoming = object.objectValue else {
            throw DataServiceError.unsupported("设置数据格式不正确")
        }
        var merged = values
        for (key, value) in incoming {
            merged[key] = value
        }
        values = merged
        save()
    }
}
