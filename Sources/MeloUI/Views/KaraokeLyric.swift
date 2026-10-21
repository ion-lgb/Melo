import SwiftUI
import AppKit
import MeloCore

// MARK: - 逐字歌词渲染

/// 当前歌词行：按 `LyricWord.startMs/durationMs` 计算每个字的播放进度，
/// 用「未播放色文本 + 已播放色遮罩」实现逐字双色扫光。
/// 无逐字数据（words 为空）时退化为整行高亮，由调用方决定颜色。
struct KaraokeLyricLine: View {
    let line: LyricLine
    let currentTime: TimeInterval
    let isPlaying: Bool
    let fontSize: CGFloat
    let fontWeight: Font.Weight
    let playedColor: Color
    let unplayedColor: Color
    var alignment: HorizontalAlignment = .center
    var shadowColor: Color?

    /// 播放器进度每 0.25s 回推一次；用时间轴在两次回推之间做平滑插值，让逐字扫光接近 60fps。
    @State private var baseTime: TimeInterval = 0
    @State private var baseDate: Date = .now

    /// 部分歌词引擎会把词间空格 trim 掉；对英文逐字歌词按字母数字邻接补空格。
    private var displayTexts: [String] {
        let words = line.words
        var result: [String] = []
        result.reserveCapacity(words.count)
        for (index, word) in words.enumerated() {
            var text = word.text
            if index + 1 < words.count, needsSpace(after: text, before: words[index + 1].text) {
                text += " "
            }
            result.append(text)
        }
        return result
    }

    private func needsSpace(after left: String, before right: String) -> Bool {
        guard let leftLast = left.last, let rightFirst = right.first else { return false }
        return isASCIIAlphanumeric(leftLast) && isASCIIAlphanumeric(rightFirst)
    }

    private func isASCIIAlphanumeric(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 else { return false }
        return (scalar.value >= 48 && scalar.value <= 57)
            || (scalar.value >= 65 && scalar.value <= 90)
            || (scalar.value >= 97 && scalar.value <= 122)
    }

    private var font: Font { .system(size: fontSize, weight: fontWeight) }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let time = effectiveTime(at: context.date)
            Group {
                if line.words.isEmpty {
                    plainText(line.text)
                } else {
                    wordsFlow(at: time)
                }
            }
        }
        .onAppear {
            baseTime = currentTime
            baseDate = .now
        }
        .onChange(of: currentTime) { _, newValue in
            baseTime = newValue
            baseDate = .now
        }
        .onChange(of: isPlaying) { _, _ in
            baseTime = currentTime
            baseDate = .now
        }
    }

    private func effectiveTime(at date: Date) -> TimeInterval {
        guard isPlaying else { return currentTime }
        let delta = date.timeIntervalSince(baseDate)
        guard delta > 0, delta < 1.0 else { return baseTime }
        return baseTime + delta
    }

    private func plainText(_ text: String) -> some View {
        Text(text)
            .font(font)
            .foregroundStyle(playedColor)
            .multilineTextAlignment(alignment == .leading ? .leading : (alignment == .trailing ? .trailing : .center))
            .modifier(OptionalShadow(shadowColor: shadowColor))
    }

    private func wordsFlow(at time: TimeInterval) -> some View {
        KaraokeWordFlowLayout(
            horizontalSpacing: 0,
            verticalSpacing: max(2, fontSize * 0.16),
            alignment: alignment
        ) {
            ForEach(Array(line.words.enumerated()), id: \.offset) { index, word in
                KaraokeWordView(
                    text: displayTexts[index],
                    progress: progress(for: word, at: time),
                    font: font,
                    playedColor: playedColor,
                    unplayedColor: unplayedColor,
                    shadowColor: shadowColor
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : (alignment == .trailing ? .trailing : .center))
    }

    /// 词时间相对行首（`startMs` 为相对 ms）
    private func progress(for word: LyricWord, at time: TimeInterval) -> Double {
        let start = Double(line.timeMs + word.startMs) / 1000.0
        let duration = max(Double(word.durationMs) / 1000.0, 0.001)
        let ratio = (time - start) / duration
        if ratio <= 0 { return 0 }
        if ratio >= 1 { return 1 }
        return ratio
    }
}

// MARK: - 单词扫光

private struct KaraokeWordView: View {
    let text: String
    let progress: Double
    let font: Font
    let playedColor: Color
    let unplayedColor: Color
    let shadowColor: Color?

    var body: some View {
        Text(text)
            .font(font)
            .foregroundStyle(unplayedColor)
            .overlay {
                GeometryReader { proxy in
                    Text(text)
                        .font(font)
                        .foregroundStyle(playedColor)
                        .mask(alignment: .leading) {
                            Rectangle()
                                .frame(width: max(0, proxy.size.width * progress))
                        }
                }
            }
            .fixedSize()
            .modifier(OptionalShadow(shadowColor: shadowColor))
    }
}

private struct OptionalShadow: ViewModifier {
    let shadowColor: Color?

    func body(content: Content) -> some View {
        if let shadowColor {
            content.shadow(color: shadowColor, radius: 2, x: 0, y: 1)
        } else {
            content
        }
    }
}

// MARK: - 自动换行的逐字流式布局

/// 把逐字子视图从左到右排列，超出宽度自动换行，并按 alignment 在每行内对齐。
struct KaraokeWordFlowLayout: Layout {
    var horizontalSpacing: CGFloat = 0
    var verticalSpacing: CGFloat = 4
    var alignment: HorizontalAlignment = .center

    struct Cache {
        var sizes: [CGSize]
        var lines: [[Int]]
        var lineWidths: [CGFloat]
        var lineHeights: [CGFloat]
        var contentSize: CGSize
    }

    func makeCache(subviews: Subviews) -> Cache {
        build(subviews: subviews, maxWidth: .infinity)
    }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        cache = build(subviews: subviews, maxWidth: .infinity)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var result = build(subviews: subviews, maxWidth: maxWidth)
        result.sizes = cache.sizes
        cache = result
        return CGSize(width: proposal.width ?? result.contentSize.width, height: result.contentSize.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        var y = bounds.minY
        for (lineIndex, indices) in cache.lines.enumerated() {
            let lineWidth = cache.lineWidths[lineIndex]
            var x: CGFloat
            switch alignment {
            case .leading: x = bounds.minX
            case .trailing: x = bounds.maxX - lineWidth
            default: x = bounds.minX + (bounds.width - lineWidth) / 2
            }
            let lineHeight = cache.lineHeights[lineIndex]
            for index in indices {
                let size = cache.sizes[index]
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (lineHeight - size.height) / 2),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(size)
                )
                x += size.width + horizontalSpacing
            }
            y += lineHeight + verticalSpacing
        }
    }

    private func build(subviews: Subviews, maxWidth: CGFloat) -> Cache {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        var lines: [[Int]] = []
        var lineWidths: [CGFloat] = []
        var lineHeights: [CGFloat] = []
        var currentLine: [Int] = []
        var currentWidth: CGFloat = 0
        var currentHeight: CGFloat = 0

        for (index, size) in sizes.enumerated() {
            let addition = currentLine.isEmpty ? size.width : size.width + horizontalSpacing
            if !currentLine.isEmpty, currentWidth + addition > maxWidth, maxWidth.isFinite {
                lines.append(currentLine)
                lineWidths.append(currentWidth)
                lineHeights.append(currentHeight)
                currentLine = [index]
                currentWidth = size.width
                currentHeight = size.height
            } else {
                currentLine.append(index)
                currentWidth += addition
                currentHeight = max(currentHeight, size.height)
            }
        }
        if !currentLine.isEmpty {
            lines.append(currentLine)
            lineWidths.append(currentWidth)
            lineHeights.append(currentHeight)
        }

        let totalHeight = lineHeights.reduce(0, +) + CGFloat(max(0, lines.count - 1)) * verticalSpacing
        let totalWidth = lineWidths.max() ?? 0
        return Cache(
            sizes: sizes,
            lines: lines,
            lineWidths: lineWidths,
            lineHeights: lineHeights,
            contentSize: CGSize(width: totalWidth, height: totalHeight)
        )
    }
}
