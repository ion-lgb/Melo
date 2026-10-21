import Foundation

/// 列表导出（对齐原版 `exportPlayListToText` / `exportPlayListToCSV`）：
/// 文本行格式 `歌名  歌手  专辑`；CSV 表头 + `歌名,歌手,专辑`；UTF-8 带 BOM。
public enum ListTransferService {
    public static let csvHeader = "歌曲名,歌手,专辑\n"

    public static func export(playlists: JSONValue,
                              kind: ListExportKind,
                              merge: Bool,
                              to directory: URL) throws -> [URL] {
        let lists = playlists.arrayValue ?? []
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let stamp = formatter.string(from: Date())

        var written: [URL] = []
        if merge {
            var chunks: [String] = []
            for list in lists {
                let rows = rows(for: list)
                if rows.isEmpty { continue }
                chunks.append(rows.map { row(kind: kind, entry: $0) }.joined(separator: "\n"))
            }
            guard !chunks.isEmpty else { return [] }
            let ext = kind == .text ? "txt" : "csv"
            let url = directory.appendingPathComponent("lx_list_all_\(stamp).\(ext)")
            var content = kind == .csv ? csvHeader : ""
            content += chunks.joined(separator: "\n\n")
            try writeBOM(content, to: url)
            written.append(url)
        } else {
            for list in lists {
                let name = sanitizeFileName(list["name"]?.stringValue ?? "列表")
                let rows = rows(for: list)
                guard !rows.isEmpty else { continue }
                let ext = kind == .text ? "txt" : "csv"
                let url = directory.appendingPathComponent("lx_list_\(name).\(ext)")
                var content = kind == .csv ? csvHeader : ""
                content += rows.map { row(kind: kind, entry: $0) }.joined(separator: "\n")
                try writeBOM(content, to: url)
                written.append(url)
            }
        }
        return written
    }

    private struct Row {
        var name: String
        var singer: String
        var album: String
    }

    private static func rows(for list: JSONValue) -> [Row] {
        (list["list"]?.arrayValue ?? []).compactMap { item in
            guard let object = item.objectValue else { return nil }
            let name = object["name"]?.stringValue ?? ""
            guard !name.isEmpty else { return nil }
            let singer = object["singer"]?.stringValue ?? ""
            let album = object["meta"]?["albumName"]?.stringValue ?? ""
            return Row(name: name, singer: singer, album: album)
        }
    }

    private static func row(kind: ListExportKind, entry: Row) -> String {
        switch kind {
        case .text:
            return "\(entry.name)  \(entry.singer)  \(entry.album)"
        case .csv:
            return "\(escape(entry.name)),\(escape(entry.singer)),\(escape(entry.album))"
        }
    }

    private static func escape(_ value: String) -> String {
        guard !value.isEmpty else { return "" }
        let needsQuoting = value.contains(",") || value.contains("\n") || value.contains("\"")
        var text = value.replacingOccurrences(of: "\"", with: "\"\"")
        if needsQuoting { text = "\"\(text)\"" }
        return text
    }

    private static func sanitizeFileName(_ name: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|")
        let cleaned = name.components(separatedBy: illegal).joined(separator: "_")
        return cleaned.isEmpty ? "list" : String(cleaned.prefix(80))
    }

    private static func writeBOM(_ content: String, to url: URL) throws {
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(Data(content.utf8))
        try data.write(to: url, options: .atomic)
    }
}
