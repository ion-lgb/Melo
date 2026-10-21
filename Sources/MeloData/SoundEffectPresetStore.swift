import Foundation
import MeloCore

// MARK: - 音效预设持久化（原版 LxDatas/sound_effect.json）

/// 读取/保存原版 `LxDatas/sound_effect.json` 中的用户音效预设。
///
/// 原版文件结构（electron-store 平铺存储，等价于下面这个 JSON 对象）：
/// ```json
/// {
///   "eqPreset": [ { "id": "...", "name": "...", "hz31": 0, ... "hz16000": 0 } ],
///   "convolutionPreset": [ { "id": "...", "name": "...", "source": "...", "mainGain": 0, "sendGain": 0 } ]
/// }
/// ```
///
/// 为了与原版数据完全兼容，本类用「通用 JSON」读写，不丢字段：
/// - 预设元素为 `[String: JSONValue]`，原版字段与未来新增字段原样保留；
/// - 顶层其它未知 key 在原文件存在时原样保留，只替换对应的 `eqPreset` / `convolutionPreset`；
/// - 写入使用原子写（先临时文件再 rename，避免半截 JSON）；
/// - 文件不存在返回空数组；文件损坏时备份为 `sound_effect.json.bak` 后返回空数组。
public final class SoundEffectPresetStore {
    public let fileURL: URL

    private static let eqPresetKey = "eqPreset"
    private static let convolutionPresetKey = "convolutionPreset"
    private static let backupExtension = "bak"

    public init(dataDirectory: URL) {
        self.fileURL = dataDirectory.appendingPathComponent("sound_effect.json", isDirectory: false)
    }

    // MARK: - 读取

    /// 用户 EQ 预设（原版字段：id/name/hz31...hz16000，其它字段原样保留）。
    public func loadEQPresets() -> [[String: JSONValue]] {
        loadPresets(key: Self.eqPresetKey)
    }

    /// 用户卷积混响预设（原版字段：id/name/source/mainGain/sendGain，其它字段原样保留）。
    public func loadConvolutionPresets() -> [[String: JSONValue]] {
        loadPresets(key: Self.convolutionPresetKey)
    }

    /// 备份文件 URL（损坏文件被移动到这里；不存在时返回 nil）
    public var backupFileURL: URL? {
        let url = fileURL.appendingPathExtension(Self.backupExtension)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - 写入

    /// 保存用户 EQ 预设（保留 convolutionPreset 与其它顶层字段）。
    public func saveEQPresets(_ presets: [[String: JSONValue]]) throws {
        try save(presets, key: Self.eqPresetKey)
    }

    /// 保存用户卷积混响预设（保留 eqPreset 与其它顶层字段）。
    public func saveConvolutionPresets(_ presets: [[String: JSONValue]]) throws {
        try save(presets, key: Self.convolutionPresetKey)
    }

    // MARK: - 内部实现

    private func loadPresets(key: String) -> [[String: JSONValue]] {
        guard let root = loadRoot() else { return [] }
        guard let array = root[key]?.arrayValue else { return [] }
        return array.compactMap { $0.objectValue }
    }

    private func save(_ presets: [[String: JSONValue]], key: String) throws {
        var root = loadRoot() ?? [:]
        root[key] = .array(presets.map { .object($0) })
        guard let data = JSONValue.object(root).jsonData(pretty: true) else {
            throw MeloDataError.ioError("无法序列化音效预设 JSON")
        }
        do {
            try MeloUtils.atomicWrite(data, to: fileURL)
        } catch {
            throw MeloDataError.ioError("保存 \(fileURL.lastPathComponent) 失败：\(error.localizedDescription)")
        }
    }

    /// 读取整个 JSON 对象；文件不存在返回 nil；损坏时备份 .bak 并返回 nil。
    private func loadRoot() -> [String: JSONValue]? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        do {
            let data = try Data(contentsOf: fileURL)
            guard let object = JSONValue(jsonData: data)?.objectValue else {
                backUpCorruptedFile(reason: "根节点不是 JSON 对象")
                return nil
            }
            return object
        } catch {
            backUpCorruptedFile(reason: error.localizedDescription)
            return nil
        }
    }

    private func backUpCorruptedFile(reason: String) {
        let backupURL = fileURL.appendingPathExtension(Self.backupExtension)
        do {
            if FileManager.default.fileExists(atPath: backupURL.path) {
                try? FileManager.default.removeItem(at: backupURL)
            }
            try FileManager.default.moveItem(at: fileURL, to: backupURL)
            MeloLog.warn("sound_effect.json 已损坏（\(reason)），已备份到 \(backupURL.lastPathComponent)")
        } catch {
            MeloLog.error("备份损坏的 sound_effect.json 失败：\(error.localizedDescription)")
        }
    }
}
