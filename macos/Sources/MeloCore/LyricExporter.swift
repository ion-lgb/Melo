import Foundation

/// 下载时歌词合并/导出（对齐原版 worker/download/lrcTool.ts `buildLyrics`）。
public enum LyricExporter {
    /// 合并主歌词 + 翻译 + 罗马音 + 逐字（awlrc，base64）为单个 .lrc 文本
    public static func buildMergedLyric(_ info: LyricInfo,
                                        includeWordByWord: Bool,
                                        includeTranslation: Bool,
                                        includeRoman: Bool) -> String {
        let main = info.lyric
        guard !main.isEmpty else { return "" }

        // 没有可合并的扩展歌词时直接返回主歌词（与原版一致）
        if info.tlyric == nil && info.rlyric == nil && info.lxlyric == nil {
            return main
        }
        let timeLabels = parseTimeLabels(main)
        var merged = main
        if includeTranslation, let tlyric = info.tlyric, !tlyric.isEmpty {
            merged = merged.trimmingCharacters(in: .whitespacesAndNewlines)
                + "\n\n" + filterExtendedLyric(timeLabels, tlyric) + "\n"
        }
        if includeRoman, let rlyric = info.rlyric, !rlyric.isEmpty {
            merged = merged.trimmingCharacters(in: .whitespacesAndNewlines)
                + "\n\n" + filterExtendedLyric(timeLabels, rlyric) + "\n"
        }
        if includeWordByWord {
            let awlrc = buildAwLyric(info)
            if !awlrc.isEmpty {
                merged = merged.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n" + awlrc + "\n"
            }
        }
        return merged
    }

    // MARK: - 时间标签匹配（与原版 filterExtendedLyricLabel 一致）

    private static let timeFieldRegex = try! NSRegularExpression(pattern: #"^(?:\[[\d:.]+\])+"#)
    private static let timeRegex = try! NSRegularExpression(pattern: #"\d{1,3}(:\d{1,3}){0,2}(?:\.\d{1,3})"#)

    private static func formatTimeLabel(_ label: String) -> String {
        var value = label
        value = value.replacingOccurrences(of: #"^0+(\d+)"#, with: "$1", options: .regularExpression)
        value = value.replacingOccurrences(of: #":0+(\d+)"#, with: ":$1", options: .regularExpression)
        value = value.replacingOccurrences(of: #"\.0+(\d+)"#, with: ".$1", options: .regularExpression)
        return value
    }

    private static func parseTimeLabels(_ lrc: String) -> Set<String> {
        var labels: Set<String> = []
        for line in lrc.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let field = firstTimeField(trimmed) else { continue }
            let text = trimmed.replacingOccurrences(of: field, with: "").trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            for time in timeMatches(field) {
                labels.insert(formatTimeLabel(time))
            }
        }
        return labels
    }

    private static func filterExtendedLyric(_ timeLabels: Set<String>, _ extended: String) -> String {
        var lines: [String] = []
        for rawLine in extended.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let field = firstTimeField(line) else { continue }
            let text = line.replacingOccurrences(of: field, with: "").trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            let times = timeMatches(field)
            guard !times.isEmpty else { continue }
            let kept = times.filter { timeLabels.contains(formatTimeLabel($0)) }
            guard kept.count == times.count || !kept.isEmpty else { continue }
            let rebuilt = kept.count == times.count
                ? line
                : "[" + kept.joined(separator: "][") + "]" + text
            lines.append(rebuilt)
        }
        return lines.joined(separator: "\n")
    }

    private static func firstTimeField(_ line: String) -> String? {
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = timeFieldRegex.firstMatch(in: line, options: [], range: range) else { return nil }
        return Range(match.range, in: line).map { String(line[$0]) }
    }

    private static func timeMatches(_ field: String) -> [String] {
        let range = NSRange(field.startIndex..<field.endIndex, in: field)
        return timeRegex.matches(in: field, options: [], range: range).compactMap { match in
            Range(match.range, in: field).map { String(field[$0]) }
        }
    }

    /// 原版 `buildAwlyric`：`[awlrc:lrc:<base64>,tlrc:<base64>,rlrc:<base64>,awlrc:<base64>]`
    private static func buildAwLyric(_ info: LyricInfo) -> String {
        var parts: [String] = []
        func add(_ prefix: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            let base64 = Data(value.trimmingCharacters(in: .whitespacesAndNewlines).utf8).base64EncodedString()
            parts.append("\(prefix):\(base64)")
        }
        add("lrc", info.lyric)
        add("tlrc", info.tlyric)
        add("rlrc", info.rlyric)
        add("awlrc", info.lxlyric)
        return parts.isEmpty ? "" : "[awlrc:\(parts.joined(separator: ","))]"
    }
}
