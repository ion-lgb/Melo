import Foundation
import MeloCore

/// `user_api.json` 读写（兼容原版 LX Music 格式）：
///
/// ```json
/// { "userApis": [ { "id", "name", "description", "author", "homepage",
///                   "version", "allowShowUpdateAlert", "script": "gz_<base64(zlib)>" } ] }
/// ```
///
/// 说明：
/// - 文件位于 `<LxDatas>/user_api.json`（原版 `global.lxDataPath` 下的同名 store）；
/// - `script` 为 `gz_` + base64(zlib deflate)；读取时兼容明文脚本（原版 inflateScript 行为）；
/// - 旧版无 `version` 字段的条目会从脚本头部注释补全并回写（对应原版 requiredUpdate 逻辑）。
final class UserSourceStore {

    struct Record {
        var id: String
        var name: String
        var description: String
        var author: String
        var homepage: String
        var version: String
        var allowShowUpdateAlert: Bool
        var compressedScript: String
        /// 原版未来可能新增字段：原样保留，避免读写丢字段
        var extra: [String: Any]

        var plainScript: String? { ZlibCodec.decompressScript(compressedScript) }
    }

    enum StoreError: LocalizedError {
        case invalidFile(String)
        case invalidScript(String)
        case duplicate(String)
        case notFound(String)

        var errorDescription: String? {
            switch self {
            case .invalidFile(let message): return message
            case .invalidScript(let message): return message
            case .duplicate(let name): return "导入失败，脚本内容与已有的源「\(name)」相同"
            case .notFound(let id): return "自定义源不存在：\(id)"
            }
        }
    }

    let fileURL: URL
    private(set) var records: [Record] = []
    private(set) var didLoad = false

    private static let knownKeys: Set<String> = [
        "id", "name", "description", "author", "homepage", "version",
        "allowShowUpdateAlert", "script",
    ]

    init(lxDatasDirectory: URL) {
        self.fileURL = lxDatasDirectory.appendingPathComponent("user_api.json")
    }

    // MARK: - 读取

    func load() throws {
        didLoad = true
        records = []
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw StoreError.invalidFile("读取 user_api.json 失败：\(error.localizedDescription)")
        }
        guard !data.isEmpty,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw StoreError.invalidFile("user_api.json 格式无效")
        }
        let rawList = (root["userApis"] as? [[String: Any]]) ?? []
        var migrated = false
        var loaded: [Record] = []
        for raw in rawList {
            guard let id = raw["id"] as? String, !id.isEmpty,
                  let script = raw["script"] as? String, !script.isEmpty else {
                MeloLog.warn("user_api.json: 跳过缺少 id/script 的条目")
                continue
            }
            var extra = raw
            for key in Self.knownKeys { extra.removeValue(forKey: key) }

            var name = raw["name"] as? String
            var description = raw["description"] as? String
            var author = raw["author"] as? String
            var homepage = raw["homepage"] as? String
            var version = raw["version"] as? String
            // 旧版条目（无 version 字段 / 为 null）→ 从脚本头部注释补全缺失字段
            // （对齐原版 `{ ...parseScriptInfo(script), ...api }` 的合并语义）
            if version == nil, let plain = ZlibCodec.decompressScript(script),
               let parsed = try? ScriptInfoParser.parse(plain) {
                name = name ?? parsed.name
                description = description ?? parsed.description
                author = author ?? parsed.author
                homepage = homepage ?? parsed.homepage
                version = parsed.version
                migrated = true
                MeloLog.info("user_api.json: 已从脚本头部补全旧条目 \(id)")
            }
            loaded.append(Record(
                id: id,
                name: name ?? "",
                description: description ?? "",
                author: author ?? "",
                homepage: homepage ?? "",
                version: version ?? "",
                allowShowUpdateAlert: (raw["allowShowUpdateAlert"] as? Bool) ?? false,
                compressedScript: script,
                extra: extra
            ))
        }
        records = loaded
        if migrated {
            try save()
        }
    }

    func ensureLoaded() throws {
        if !didLoad { try load() }
    }

    // MARK: - 保存

    func save() throws {
        let list: [[String: Any]] = records.map { record in
            var object = record.extra
            object["id"] = record.id
            object["name"] = record.name
            object["description"] = record.description
            object["author"] = record.author
            object["homepage"] = record.homepage
            object["version"] = record.version
            object["allowShowUpdateAlert"] = record.allowShowUpdateAlert
            object["script"] = record.compressedScript
            return object
        }
        let root: [String: Any] = ["userApis": list]
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        do {
            try MeloUtils.atomicWrite(data, to: fileURL)
        } catch {
            throw StoreError.invalidFile("写入 user_api.json 失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 查询

    func record(id: String) -> Record? {
        records.first { $0.id == id }
    }

    func index(id: String) -> Int? {
        records.firstIndex { $0.id == id }
    }

    /// 协议模型（`script` 使用压缩存储原文；`isActive` 标记当前活动源）
    func userSourceInfos(activeId: String?) -> [UserSourceInfo] {
        records.map { record in
            UserSourceInfo(
                id: record.id,
                name: record.name,
                description: record.description,
                version: record.version,
                author: record.author,
                homepage: record.homepage,
                script: record.compressedScript,
                isActive: record.id == activeId
            )
        }
    }

    func plainScript(id: String) throws -> String {
        guard let record = record(id: id) else { throw StoreError.notFound(id) }
        guard let plain = record.plainScript else {
            throw StoreError.invalidScript("自定义源脚本解压失败：\(record.name)")
        }
        return plain
    }

    // MARK: - 导入 / 删除

    @discardableResult
    func importScript(_ raw: String, extra: [String: Any] = [:]) throws -> Record {
        let info: ScriptInfoParser.Info
        do {
            info = try ScriptInfoParser.parse(raw)
        } catch {
            throw StoreError.invalidScript(error.localizedDescription)
        }
        guard let compressed = ZlibCodec.compressScript(raw) else {
            throw StoreError.invalidScript("自定义源脚本压缩失败")
        }
        // 去重：既比较压缩串（与原版一致），也比较解压后的脚本（兼容原版 Node zlib 压缩产物），
        // 以及导入方附带的 scriptMd5（URL 导入与文件导入共用）。
        let incomingMd5 = extra["scriptMd5"] as? String
        if let duplicate = records.first(where: { record in
            if record.compressedScript == compressed || record.plainScript == raw { return true }
            if let incomingMd5, let existingMd5 = record.extra["scriptMd5"] as? String {
                return existingMd5 == incomingMd5
            }
            return false
        }) {
            throw StoreError.duplicate(duplicate.name)
        }
        let record = Record(
            id: MeloUtils.makeUserSourceID(),
            name: info.name,
            description: info.description,
            author: info.author,
            homepage: info.homepage,
            version: info.version,
            allowShowUpdateAlert: true,
            compressedScript: compressed,
            extra: extra
        )
        records.append(record)
        try save()
        return record
    }

    @discardableResult
    func remove(ids: Set<String>) -> [Record] {
        let removed = records.filter { ids.contains($0.id) }
        records.removeAll { ids.contains($0.id) }
        return removed
    }

    func setAllowShowUpdateAlert(id: String, enabled: Bool) {
        guard let index = index(id: id) else { return }
        records[index].allowShowUpdateAlert = enabled
    }
}
