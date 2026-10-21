import Foundation
import MeloCore

// MARK: - LxDatas/data.json 应用数据存储

/// 原版 `LxDatas/data.json`（electron-store 根对象）的读写。
///
/// 原版文件结构（根对象，键可扩展）：
/// ```json
/// {
///   "playInfo": { "time": 12.3, "maxTime": 240, "listId": "default", ... },
///   "listUpdateInfo": { "userlist_xxx": { "updateTime": 1700000000000, "isAutoUpdate": true } },
///   "winLegacyMessageShown": true,
///   ...
/// }
/// ```
///
/// 兼容性约定：
/// - 只替换本次写入的键，**未知顶层键原样保留**（如 viewPrevState/searchHistoryList/ignoreVersion）；
/// - 文件缺失 → `loadPlayInfo` 返回 nil、`loadListUpdateInfo` 返回 [:]；
/// - JSON 损坏/根节点不是对象 → 原文件移动为 `data.json.bak`（已有 bak 先删）后按空数据处理；
/// - 写文件为 pretty JSON + 原子写；写失败只记录日志（协议方法不抛错）。
///
/// 线程模型：`@MainActor`（与 MeloCore `AppDataStore` 协议一致）。
@MainActor
public final class AppDataFileStore {
    public let dataDirectory: URL

    /// `<LxDatas>/data.json`
    public var fileURL: URL {
        dataDirectory.appendingPathComponent("data.json", isDirectory: false)
    }

    /// 损坏备份文件（不存在时返回 nil）
    public var backupFileURL: URL? {
        let url = fileURL.appendingPathExtension("bak")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private static let playInfoKey = "playInfo"
    private static let listUpdateInfoKey = "listUpdateInfo"

    /// - Parameter dataDirectory: 原版 `LxDatas` 目录（内部使用 `data.json`）
    public init(dataDirectory: URL) {
        self.dataDirectory = dataDirectory
    }

    // MARK: - 播放信息（PlayInfoSnapshot）

    /// 读取上次播放信息；文件缺失/无 playInfo/解析失败时返回 nil。
    public func loadPlayInfo() -> PlayInfoSnapshot? {
        guard let root = loadRoot(), let value = root[Self.playInfoKey], !value.isNull else { return nil }
        guard let data = value.jsonData(), let snapshot = try? JSONDecoder().decode(PlayInfoSnapshot.self, from: data) else {
            MeloLog.warn("data.json 的 playInfo 解析失败，已忽略")
            return nil
        }
        return snapshot
    }

    /// 保存播放信息（musicInfo 完整 meta 保真）；写失败只记录日志。
    public func savePlayInfo(_ snapshot: PlayInfoSnapshot) {
        do {
            let data = try JSONEncoder().encode(snapshot)
            guard let value = JSONValue(jsonData: data) else {
                throw MeloDataError.corruptedData("playInfo 序列化失败")
            }
            try updateRoot { root in
                root[Self.playInfoKey] = value
            }
        } catch {
            MeloLog.error("保存 data.json(playInfo) 失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 列表更新信息（[String: ListUpdateInfo]）

    /// 读取列表更新信息；文件缺失/无对应键返回 [:]；单个条目损坏时跳过。
    public func loadListUpdateInfo() -> [String: ListUpdateInfo] {
        guard let root = loadRoot(), let dict = root[Self.listUpdateInfoKey]?.objectValue else { return [:] }
        var result: [String: ListUpdateInfo] = [:]
        for (listID, value) in dict {
            guard !listID.isEmpty else { continue }
            if let data = value.jsonData(),
               let info = try? JSONDecoder().decode(ListUpdateInfo.self, from: data) {
                result[listID] = info
                continue
            }
            // 兼容字段缺失/带未知字段的历史数据：尽力提取，缺失用默认值
            if let object = value.objectValue {
                result[listID] = ListUpdateInfo(
                    updateTime: Int64(object["updateTime"]?.intValue ?? 0),
                    isAutoUpdate: object["isAutoUpdate"]?.boolValue ?? false
                )
            }
        }
        return result
    }

    /// 保存列表更新信息（整字典替换，空字典写 `{}`）；未知顶层键保留。
    public func saveListUpdateInfo(_ info: [String: ListUpdateInfo]) {
        do {
            let data = try JSONEncoder().encode(info)
            guard let value = JSONValue(jsonData: data) else {
                throw MeloDataError.corruptedData("listUpdateInfo 序列化失败")
            }
            try updateRoot { root in
                root[Self.listUpdateInfoKey] = value
            }
        } catch {
            MeloLog.error("保存 data.json(listUpdateInfo) 失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 根对象读写

    /// 读取整个根对象；文件不存在返回 nil；损坏时备份 .bak 并按 nil 处理。
    private func loadRoot() -> [String: JSONValue]? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
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

    private func updateRoot(_ mutate: (inout [String: JSONValue]) -> Void) throws {
        var root = loadRoot() ?? [:]
        mutate(&root)
        try writeRoot(root)
    }

    /// pretty JSON + 原子写（key 排序，便于查看/对比，也保证重复保存字节稳定）。
    private func writeRoot(_ root: [String: JSONValue]) throws {
        let value = JSONValue.object(root)
        var payload: Data?
        // 优先 JSONSerialization（sortedKeys），失败时回退 JSONValue 编码器
        if let serialized = try? JSONSerialization.data(
            withJSONObject: value.anyValue,
            options: [.prettyPrinted, .sortedKeys]
        ) {
            payload = serialized
        }
        if payload == nil {
            payload = value.jsonData(pretty: true)
        }
        guard let data = payload else {
            throw MeloDataError.corruptedData("data.json 序列化失败")
        }
        do {
            try MeloUtils.atomicWrite(data, to: fileURL)
        } catch {
            throw MeloDataError.ioError("保存 data.json 失败：\(error.localizedDescription)")
        }
    }

    private func backUpCorruptedFile(reason: String) {
        let backupURL = fileURL.appendingPathExtension("bak")
        do {
            if FileManager.default.fileExists(atPath: backupURL.path) {
                try? FileManager.default.removeItem(at: backupURL)
            }
            try FileManager.default.moveItem(at: fileURL, to: backupURL)
            MeloLog.warn("data.json 已损坏（\(reason)），已备份到 \(backupURL.lastPathComponent)")
        } catch {
            MeloLog.error("备份损坏的 data.json 失败：\(error.localizedDescription)")
        }
    }
}
