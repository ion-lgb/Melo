import Foundation
import Compression

/// 原版备份格式（.lxmc = gzip(JSON)）的编解码与导出/导入。
/// 支持 `allData_v2` / `playList_v2` / `setting_v2`，并兼容旧版 `allData` / `playList` / `setting`（列表内旧结构歌曲会自动转换）。
@MainActor
public final class BackupService: BackupProviding {
    private let data: DataService
    private let settings: SettingsStore

    public init(data: DataService, settings: SettingsStore) {
        self.data = data
        self.settings = settings
    }

    // MARK: - 导出

    public func export(kind: BackupKind, to url: URL) throws {
        let payload: JSONValue
        switch kind {
        case .allData:
            payload = .object([
                "type": .string("allData_v2"),
                "setting": settings.exportJSON(),
                "playList": try data.exportPlaylistsBackup(),
            ])
        case .playlists:
            payload = .object([
                "type": .string("playList_v2"),
                "data": try data.exportPlaylistsBackup(),
            ])
        case .settings:
            payload = .object([
                "type": .string("setting_v2"),
                "data": settings.exportJSON(),
            ])
        }
        let bytes = try BackupCoder.encode(payload, pathExtension: url.pathExtension)
        try MeloUtils.atomicWrite(bytes, to: url)
    }

    // MARK: - 导入

    public func importBackup(from url: URL) throws -> BackupImportSummary {
        let bytes = try Data(contentsOf: url)
        let root = try BackupCoder.decode(bytes, pathExtension: url.pathExtension)
        guard let object = root.objectValue, let type = object["type"]?.stringValue else {
            throw BackupError.invalidFile("缺少 type 字段，不是有效的 Melo/LX 备份文件")
        }
        switch type {
        case "allData_v2", "allData":
            var summary = BackupImportSummary(sourceType: type)
            if let playlist = object["playList"] ?? object["playlist"] {
                summary = try importPlaylists(playlist, into: summary)
            }
            let settingObject = object["setting"] ?? object["settings"]
            if let settingObject {
                try settings.importSettings(settingObject)
                summary.settingsImported = true
            }
            return summary
        case "playList_v2", "playList", "defaultList", "defautlList":
            let listValue: JSONValue
            if type == "playList_v2" || type == "playList" {
                listValue = object["data"] ?? .array([])
            } else if let list = object["data"]?["list"] {
                listValue = .array([.object(["id": .string("default"), "name": .string("试听列表"), "list": list])])
            } else {
                listValue = .array([])
            }
            return try importPlaylists(listValue, into: BackupImportSummary(sourceType: type))
        case "setting_v2", "setting":
            let settingObject = object["data"] ?? object["setting"]
            guard let settingObject else {
                throw BackupError.invalidFile("设置备份缺少 data 字段")
            }
            try settings.importSettings(settingObject)
            return BackupImportSummary(settingsImported: true, sourceType: type)
        default:
            throw BackupError.invalidFile("不支持的备份类型：\(type)")
        }
    }

    private func importPlaylists(_ value: JSONValue, into summary: BackupImportSummary) throws -> BackupImportSummary {
        let lists = try Self.normalizePlaylists(value)
        var result = try data.importPlaylistsBackup(lists)
        result.settingsImported = summary.settingsImported
        result.sourceType = summary.sourceType
        return result
    }

    /// 兼容新版 `list: [MusicInfo]` 与旧版 `list: [oldMusicInfo]`，统一为新结构
    static func normalizePlaylists(_ value: JSONValue) throws -> JSONValue {
        guard let array = value.arrayValue else {
            throw BackupError.invalidFile("playList 不是数组")
        }
        let normalized: [JSONValue] = array.compactMap { item -> JSONValue? in
            guard var object = item.objectValue else { return nil }
            let rawList = object["list"]?.arrayValue ?? []
            let musics: [JSONValue] = rawList.compactMap { raw in
                guard let rawObject = raw.objectValue else { return nil }
                if rawObject["meta"] != nil, let id = rawObject["id"]?.stringValue, !id.isEmpty {
                    return .object(rawObject)
                }
                guard let legacy = MusicInfo(legacyJSON: .object(rawObject)) else { return nil }
                return legacy.jsonObject
            }
            object["list"] = .array(musics)
            if object["id"] == nil { object["id"] = .string(UUID().uuidString) }
            if object["name"] == nil { object["name"] = .string("导入列表") }
            return .object(object)
        }
        return .array(normalized)
    }
}

public enum BackupError: LocalizedError {
    case invalidFile(String)
    case gzipFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidFile(let message): return message
        case .gzipFailed(let message): return "备份文件解压失败：\(message)"
        }
    }
}

/// gzip 编解码（.lxmc 为 gzip 压缩的 JSON；.json 直接写明文）。
enum BackupCoder {
    static func encode(_ value: JSONValue, pathExtension: String) throws -> Data {
        let json = value.jsonData(pretty: true) ?? Data("{}".utf8)
        if pathExtension.lowercased() == "json" {
            return json
        }
        return try GzipCoder.compress(json)
    }

    static func decode(_ bytes: Data, pathExtension: String) throws -> JSONValue {
        let jsonBytes: Data
        if pathExtension.lowercased() == "json" {
            jsonBytes = bytes
        } else if bytes.count >= 2, bytes[bytes.startIndex] == 0x1f, bytes[bytes.startIndex + 1] == 0x8b {
            jsonBytes = try GzipCoder.decompress(bytes)
        } else {
            jsonBytes = bytes
        }
        guard let value = JSONValue(jsonData: jsonBytes) else {
            throw BackupError.invalidFile("备份内容不是有效 JSON")
        }
        // 兼容旧版被 JSON 二次序列化的问题
        if let string = value.stringValue, let nested = JSONValue(jsonString: string) {
            return nested
        }
        return value
    }
}

enum GzipCoder {
    static func compress(_ data: Data) throws -> Data {
        var output = Data([0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03])
        if !data.isEmpty {
            let capacity = max(64, data.count + data.count / 8 + 64 * 1024)
            var buffer = [UInt8](repeating: 0, count: capacity)
            let written = data.withUnsafeBytes { pointer -> Int in
                guard let base = pointer.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_encode_buffer(&buffer, capacity, base, data.count, nil, COMPRESSION_ZLIB)
            }
            guard written > 0 else { throw BackupError.gzipFailed("压缩失败") }
            output.append(contentsOf: buffer.prefix(written))
        } else {
            // 空数据的合法 deflate 空块（BFINAL=1, BTYPE=00, LEN=0, NLEN=0xFFFF）
            output.append(contentsOf: [0x03, 0x00])
        }
        var crc = crc32(data).littleEndian
        withUnsafeBytes(of: &crc) { output.append(contentsOf: $0) }
        var size = UInt32(truncatingIfNeeded: data.count).littleEndian
        withUnsafeBytes(of: &size) { output.append(contentsOf: $0) }
        return output
    }

    static func decompress(_ data: Data) throws -> Data {
        guard data.count >= 18 else { throw BackupError.gzipFailed("文件过短") }
        let bytes = [UInt8](data)
        guard bytes[0] == 0x1f, bytes[1] == 0x8b, bytes[2] == 0x08 else {
            throw BackupError.gzipFailed("不是 gzip 文件")
        }
        var offset = 10
        let flags = bytes[3]
        if flags & 0x04 != 0 { // FEXTRA
            guard offset + 2 <= bytes.count else { throw BackupError.gzipFailed("头部损坏") }
            let extraLength = Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8)
            offset += 2 + extraLength
        }
        if flags & 0x08 != 0 { // FNAME
            while offset < bytes.count, bytes[offset] != 0 { offset += 1 }
            offset += 1
        }
        if flags & 0x10 != 0 { // FCOMMENT
            while offset < bytes.count, bytes[offset] != 0 { offset += 1 }
            offset += 1
        }
        if flags & 0x02 != 0 { offset += 2 } // FHCRC
        guard offset < bytes.count - 8 else { throw BackupError.gzipFailed("数据区缺失") }
        let deflateData = Data(bytes[offset..<(bytes.count - 8)])
        let sizeBytes = bytes[(bytes.count - 4)...]
        let expectedSize = Int(UInt32(sizeBytes[sizeBytes.startIndex])
            | (UInt32(sizeBytes[sizeBytes.startIndex + 1]) << 8)
            | (UInt32(sizeBytes[sizeBytes.startIndex + 2]) << 16)
            | (UInt32(sizeBytes[sizeBytes.startIndex + 3]) << 24))
        guard expectedSize > 0 else { return Data() }
        var out = [UInt8](repeating: 0, count: expectedSize)
        let written = deflateData.withUnsafeBytes { pointer -> Int in
            guard let base = pointer.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_decode_buffer(&out, expectedSize, base, deflateData.count, nil, COMPRESSION_ZLIB)
        }
        guard written > 0 else { throw BackupError.gzipFailed("解压失败") }
        return Data(out.prefix(written))
    }

    private static let crcTable: [UInt32] = {
        (0..<256).map { index -> UInt32 in
            var value = UInt32(index)
            for _ in 0..<8 {
                value = (value & 1) != 0 ? (0xEDB88320 ^ (value >> 1)) : (value >> 1)
            }
            return value
        }
    }()

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFFFFFF
    }
}
