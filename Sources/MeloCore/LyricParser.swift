import Foundation

/// LRC / 逐字歌词解析器
///
/// 兼容原版 `src/common/utils/lyric-font-player/line-player.js` 的核心规则：
/// - 支持 `[mm:ss.xxx]` / `[mm:ss.xx]` / `[mm:ss]` / `[hh:mm:ss.xxx]`，一行多个时间标签
/// - 标签：`[ti:] [ar:] [al:] [by:] [offset:]`
/// - 同一时间点的多行文本会合并进 `extended`（翻译/罗马音歌词即按此规则合并）
/// - 逐字歌词：`<start,duration>文本`（lxlyric，时间单位毫秒，相对行首）
public enum LyricParser {
    struct TagResult {
        var offsetMs = 0
        var title: String?
        var artist: String?
        var album: String?
        var by: String?
    }

    public static func parse(_ lyric: String,
                             translated: String? = nil,
                             roman: String? = nil,
                             wordByWord: String? = nil) -> LyricDocument {
        let tag = parseTags(lyric)
        var map: [Int: (text: String, extended: [String], raw: String?)] = [:]
        var order: [Int] = []

        func insertLine(timeMs: Int, text: String, raw: String?) {
            if let existing = map[timeMs] {
                map[timeMs] = (existing.text, existing.extended + [text], existing.raw)
            } else {
                map[timeMs] = (text, [], raw)
                order.append(timeMs)
            }
        }

        let isMillisecondPrecision = containsMillisecondTag(lyric)
        for rawLine in lyric.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let parsed = parseTimedLine(line, isMillisecondPrecision: isMillisecondPrecision) else { continue }
            guard !parsed.text.isEmpty else { continue }
            for time in parsed.times {
                insertLine(timeMs: time, text: parsed.text, raw: line)
            }
        }

        // 翻译 / 罗马音：按归一化后的时间标签合并
        for extended in [translated, roman].compactMap({ $0 }) {
            for rawLine in extended.components(separatedBy: .newlines) {
                let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let parsed = parseTimedLine(line, isMillisecondPrecision: containsMillisecondTag(extended)) else { continue }
                let text = parsed.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty, text != "//" else { continue }
                for time in parsed.times {
                    guard var existing = map[time] else { continue }
                    existing.extended.append(text)
                    map[time] = existing
                }
            }
        }

        // 逐字歌词：`[mm:ss.xxx]<0,500>字<500,300>...`
        var wordMap: [Int: [LyricWord]] = [:]
        if let wordByWord, !wordByWord.isEmpty {
            let isMs = containsMillisecondTag(wordByWord)
            for rawLine in wordByWord.components(separatedBy: .newlines) {
                let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let parsed = parseTimedLine(line, isMillisecondPrecision: isMs) else { continue }
                for time in parsed.times {
                    let words = parseWords(parsed.text)
                    if !words.isEmpty, wordMap[time] == nil { wordMap[time] = words }
                }
            }
        }

        var lines: [LyricLine] = []
        for time in order.sorted() {
            guard let entry = map[time] else { continue }
            let plainText = stripWordTags(entry.text)
            lines.append(LyricLine(
                timeMs: time,
                text: plainText,
                extended: entry.extended.filter { !$0.isEmpty },
                words: wordMap[time] ?? [],
                rawText: entry.raw
            ))
        }

        return LyricDocument(lines: lines, offsetMs: tag.offsetMs)
    }

    // MARK: - 时间标签

    static func normalizeTimeLabel(_ label: String) -> String {
        var s = label
        // 去掉各段前导 0（保留最后一位），与原版 formatTimeLabel 一致
        s = replaceRegex(s, pattern: #"^0+(\d+)"#, template: "$1")
        s = replaceRegex(s, pattern: #":0+(\d+)"#, template: ":$1")
        s = replaceRegex(s, pattern: #"\.0+(\d+)"#, template: ".$1")
        return s
    }

    static func containsMillisecondTag(_ lyric: String) -> Bool {
        lyric.range(of: #"\[\d{1,3}(:\d{1,3}){0,2}\.\d{3}\]"#, options: .regularExpression) != nil
    }

    struct ParsedLine {
        var times: [Int]
        var text: String
    }

    /// 解析形如 `[00:12.34][00:15.00]文本` 的行；返回全部出现的时间（毫秒）
    static func parseTimedLine(_ line: String, isMillisecondPrecision: Bool) -> ParsedLine? {
        guard !line.isEmpty else { return nil }
        var rest = line
        var labels: [String] = []
        while rest.hasPrefix("[") {
            guard let close = rest.firstIndex(of: "]") else { break }
            let label = String(rest[rest.index(after: rest.startIndex)..<close])
            guard label.contains(":"), label.rangeOfCharacter(from: .decimalDigits) != nil else { break }
            labels.append(label)
            rest = String(rest[rest.index(after: close)...])
        }
        guard !labels.isEmpty else { return nil }
        var times: [Int] = []
        for label in labels {
            let normalized = normalizeTimeLabel(label)
            if let ms = parseTimeToMilliseconds(normalized, isMillisecondPrecision: isMillisecondPrecision) {
                times.append(ms)
            }
        }
        guard !times.isEmpty else { return nil }
        return ParsedLine(times: times, text: rest.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// label 形如 `m:s` / `m:s.ms` / `h:m:s.ms`
    static func parseTimeToMilliseconds(_ label: String, isMillisecondPrecision: Bool) -> Int? {
        var parts = label.split(separator: ":").map(String.init)
        guard parts.count >= 2, parts.count <= 3 else { return nil }
        while parts.count < 3 { parts.insert("0", at: 0) }
        let h = Int(parts[0]) ?? 0
        let m = Int(parts[1]) ?? 0
        var secondsPart = parts[2]
        var ms = 0
        if let dotIndex = secondsPart.firstIndex(of: ".") {
            let sec = String(secondsPart[..<dotIndex])
            let frac = String(secondsPart[secondsPart.index(after: dotIndex)...])
            secondsPart = sec
            if isMillisecondPrecision {
                ms = Int(frac.prefix(3)) ?? 0
            } else {
                var padded = frac
                while padded.count < 3 { padded += "0" }
                ms = Int(padded.prefix(3)) ?? 0
            }
        }
        let s = Int(secondsPart) ?? 0
        return ((h * 60 + m) * 60 + s) * 1000 + ms
    }

    static func parseTags(_ lyric: String) -> TagResult {
        var result = TagResult()
        let patterns: [(String, WritableKeyPath<TagResult, String?>)] = [
            ("ti", \.title), ("ar", \.artist), ("al", \.album), ("by", \.by),
        ]
        for (tag, keyPath) in patterns {
            if let value = capture(lyric, pattern: "\\[\(tag):([^\\]]*)]") {
                result[keyPath: keyPath] = value
            }
        }
        if let offsetText = capture(lyric, pattern: "\\[offset:([^\\]]*)]"),
           let offset = Int(offsetText.trimmingCharacters(in: .whitespaces)) {
            result.offsetMs = offset
        }
        return result
    }

    static func capture(_ text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges > 1 else { return nil }
        return ns.substring(with: match.range(at: 1))
    }

    static func replaceRegex(_ text: String, pattern: String, template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        return regex.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: ns.length), withTemplate: template)
    }

    // MARK: - 逐字

    /// 解析 `<start,duration>字` 序列；start/duration 为相对行首的毫秒
    static func parseWords(_ text: String) -> [LyricWord] {
        guard let regex = try? NSRegularExpression(pattern: "<(\\d+),(\\d+)>") else { return [] }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return [] }
        var words: [LyricWord] = []
        for (index, match) in matches.enumerated() {
            let start = Int(ns.substring(with: match.range(at: 1))) ?? 0
            let duration = Int(ns.substring(with: match.range(at: 2))) ?? 0
            let contentStart = match.range.location + match.range.length
            let contentEnd = index + 1 < matches.count ? matches[index + 1].range.location : ns.length
            guard contentEnd > contentStart else { continue }
            let content = ns.substring(with: NSRange(location: contentStart, length: contentEnd - contentStart))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if content.isEmpty { continue }
            words.append(LyricWord(startMs: start, durationMs: duration, text: content))
        }
        return words
    }

    static func stripWordTags(_ text: String) -> String {
        guard text.contains("<") else { return text }
        return replaceRegex(text, pattern: "<\\d+,\\d+>", template: "")
    }
}
