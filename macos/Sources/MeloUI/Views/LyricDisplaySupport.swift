import SwiftUI
import AppKit
import MeloCore

// MARK: - 歌词显示辅助（翻译/罗马音筛选、繁简转换、颜色互转）

enum LyricDisplaySupport {
    // MARK: 翻译 / 罗马音按时间标签解析

    /// 解析 LRC/翻译/罗马音文本为 [timeMs: text]
    static func timedMap(_ raw: String?) -> [Int: String] {
        guard let raw, !raw.isEmpty else { return [:] }
        var result: [Int: String] = [:]
        for rawLine in raw.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            var times: [Int] = []
            var rest = line[...]
            while let open = rest.firstIndex(of: "["), let close = rest[open...].firstIndex(of: "]") {
                let tag = String(rest[rest.index(after: open)..<close])
                if let ms = parseTag(tag) { times.append(ms) }
                rest = rest[rest.index(after: close)...]
            }
            let text = rest.trimmingCharacters(in: .whitespaces)
            guard !times.isEmpty, !text.isEmpty, text != "//" else { continue }
            for time in times { result[time] = text }
        }
        return result
    }

    private static func parseTag(_ tag: String) -> Int? {
        let parts = tag.split(separator: ":").map(String.init)
        if parts.count == 3,
           let hours = Int(parts[0]),
           let minutes = Int(parts[1]),
           let seconds = Double(parts[2]) {
            return hours * 3_600_000 + minutes * 60_000 + Int((seconds * 1000).rounded())
        }
        if parts.count == 2,
           let minutes = Int(parts[0]),
           let seconds = Double(parts[1]) {
            return minutes * 60_000 + Int((seconds * 1000).rounded())
        }
        return nil
    }

    /// 依据显示开关筛选某行的扩展行（翻译/罗马音）。
    /// 优先使用 app.lyric 中 tlyric/rlyric 原文按时间精确匹配；匹配不到时回退到解析器合并的 extended。
    static func extendedLines(for line: LyricLine,
                              lyric: LyricInfo,
                              showTranslation: Bool,
                              showRoma: Bool,
                              swapTranslationAndRoma: Bool) -> [String] {
        guard showTranslation || showRoma else { return [] }
        let translationMap = timedMap(lyric.tlyric)
        let romanMap = timedMap(lyric.rlyric)
        let translation = translationMap[line.timeMs]
        let roman = romanMap[line.timeMs]

        var result: [String] = []
        if showTranslation, let translation { result.append(translation) }
        if showRoma, let roman { result.append(roman) }
        if swapTranslationAndRoma { result.reverse() }
        if !result.isEmpty { return result }

        // 回退：无法区分时按开关数量启发式显示
        if showTranslation && showRoma { return line.extended }
        if showTranslation { return line.extended.first.map { [$0] } ?? [] }
        if showRoma { return line.extended.last.map { [$0] } ?? [] }
        return []
    }

    // MARK: 繁简转换（内置常用字映射，未覆盖字符保持原样）

    private static let s2tTable: [Character: Character] = [
        "爱": "愛", "见": "見", "说": "說", "时": "時", "间": "間", "车": "車", "门": "門",
        "后": "後", "发": "發", "头": "頭", "里": "裡", "为": "為", "与": "與", "这": "這",
        "个": "個", "们": "們", "来": "來", "过": "過", "还": "還", "让": "讓", "对": "對",
        "开": "開", "关": "關", "无": "無", "风": "風", "云": "雲", "听": "聽", "声": "聲",
        "写": "寫", "认": "認", "识": "識", "记": "記", "忆": "憶", "梦": "夢", "应": "應",
        "该": "該", "谁": "誰", "吗": "嗎", "么": "麼", "样": "樣", "觉": "覺", "点": "點",
        "线": "線", "恋": "戀", "飞": "飛", "鸟": "鳥", "鱼": "魚", "马": "馬", "龙": "龍",
        "欢": "歡", "乐": "樂", "泪": "淚", "戏": "戲", "别": "別", "画": "畫", "电": "電",
        "话": "話", "视": "視", "区": "區", "医": "醫", "书": "書", "读": "讀", "长": "長",
        "东": "東", "伤": "傷", "痛": "痛", "远": "遠", "边": "邊", "变": "變", "难": "難",
        "岁": "歲", "离": "離", "寻": "尋", "找": "找", "丽": "麗", "亲": "親", "尽": "盡",
        "体": "體", "铁": "鐵", "银": "銀", "钱": "錢", "买": "買", "卖": "賣", "贵": "貴",
        "费": "費", "进": "進", "连": "連", "双": "雙", "单": "單", "静": "靜", "动": "動",
        "灵": "靈", "阳": "陽", "阴": "陰", "旧": "舊", "思": "思", "笔": "筆", "墙": "牆",
    ]

    static func s2t(_ text: String) -> String {
        String(text.map { s2tTable[$0] ?? $0 })
    }

    static func displayText(_ text: String, convertS2T: Bool) -> String {
        convertS2T ? s2t(text) : text
    }

    static func displayExtended(_ lines: [String], convertS2T: Bool) -> [String] {
        convertS2T ? lines.map(s2t) : lines
    }

    // MARK: 颜色互转

    static func color(fromCSS css: String?) -> Color? {
        guard let css, let rgba = RGBAColor(css: css) else { return nil }
        return rgba.color
    }

    static func cssString(from color: Color) -> String {
        guard let ns = NSColor(color).usingColorSpace(.sRGB) else { return "rgba(255, 255, 255, 1)" }
        let r = Int((ns.redComponent * 255).rounded())
        let g = Int((ns.greenComponent * 255).rounded())
        let b = Int((ns.blueComponent * 255).rounded())
        let a = ns.alphaComponent
        if a >= 0.999 {
            return "rgba(\(r), \(g), \(b), 1)"
        }
        return String(format: "rgba(%d, %d, %d, %.2f)", r, g, b, a)
    }
}
