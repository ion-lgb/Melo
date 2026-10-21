import Foundation

/// 解析自定义源脚本头部注释（对齐原版 `src/main/modules/userApi/utils.ts`）：
/// - 文件必须以 `/* ... */` 注释块开头，否则视为无效自定义源文件
/// - 逐行匹配 `* @key value`，支持 name/description/author/homepage/version
/// - 字段超长时截断并追加 `...`（与原版一致）
enum ScriptInfoParser {

    struct Info {
        var name: String
        var description: String
        var author: String
        var homepage: String
        var version: String
    }

    static let maxLengths: [String: Int] = [
        "name": 24,
        "description": 36,
        "author": 56,
        "homepage": 1024,
        "version": 36,
    ]

    enum ParseError: LocalizedError {
        case invalidSourceFile
        case emptyScript

        var errorDescription: String? {
            switch self {
            case .invalidSourceFile: return "无效的自定义源文件"
            case .emptyScript: return "自定义源脚本内容为空"
            }
        }
    }

    static func parse(_ script: String) throws -> Info {
        guard !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ParseError.emptyScript
        }
        guard let header = headerComment(in: script) else {
            throw ParseError.invalidSourceFile
        }

        var values: [String: String] = [:]
        let regex = try! NSRegularExpression(pattern: #"^\s?\*\s?@(\w+)\s(.+)$"#)
        for line in header.components(separatedBy: .newlines) {
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            guard let match = regex.firstMatch(in: line, range: range),
                  match.numberOfRanges == 3,
                  let keyRange = Range(match.range(at: 1), in: line),
                  let valueRange = Range(match.range(at: 2), in: line) else { continue }
            let key = String(line[keyRange])
            guard maxLengths[key] != nil else { continue }
            values[key] = String(line[valueRange]).trimmingCharacters(in: .whitespaces)
        }

        var info = Info(name: "", description: "", author: "", homepage: "", version: "")
        for (key, limit) in maxLengths {
            var value = values[key] ?? ""
            if value.count > limit {
                value = String(value.prefix(limit)) + "..."
            }
            switch key {
            case "name": info.name = value
            case "description": info.description = value
            case "author": info.author = value
            case "homepage": info.homepage = value
            case "version": info.version = value
            default: break
            }
        }
        if info.name.isEmpty {
            info.name = "user_api_\(Int(Date().timeIntervalSince1970 * 1000))"
        }
        return info
    }

    /// 原版正则：`/^\/\*[\S|\s]+?\*\//`（必须是文件开头的第一个块注释）
    static func headerComment(in script: String) -> String? {
        guard script.hasPrefix("/*") else { return nil }
        guard let end = script.range(of: "*/", range: script.startIndex..<script.endIndex) else { return nil }
        return String(script[script.startIndex..<end.upperBound])
    }
}
