import SwiftUI
import AppKit
import MeloCore

// MARK: - 音频可视化频谱条（实验性；仅音效引擎播放时有数据）

/// 通用竖条频谱：按 0...1 的频段幅度绘制，低频→高频从左到右。
private struct SpectrumBarsView: View {
    let bands: [Float]
    var barCount: Int = 24
    var spacing: CGFloat = 2
    var minBarHeight: CGFloat = 2
    var maxBarHeight: CGFloat = 30
    var cornerRadius: CGFloat = 1
    var tint: Color
    var tintOpacity: Double = 0.85

    var body: some View {
        GeometryReader { geo in
            let values = Self.resample(bands, count: barCount)
            let totalSpacing = CGFloat(max(0, barCount - 1)) * spacing
            let barWidth = max((geo.size.width - totalSpacing) / CGFloat(max(barCount, 1)), 1)
            HStack(alignment: .bottom, spacing: spacing) {
                ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                    let height = max(minBarHeight, CGFloat(min(max(value, 0), 1)) * maxBarHeight)
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [tint.opacity(tintOpacity), tint.opacity(tintOpacity * 0.35)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(width: barWidth, height: height)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        .frame(height: maxBarHeight)
    }

    /// 把任意数量频段重采样为固定根数（分段取平均，保留峰值感觉）。
    static func resample(_ bands: [Float], count: Int) -> [Float] {
        guard count > 0 else { return [] }
        guard !bands.isEmpty else { return Array(repeating: 0, count: count) }
        if bands.count == count { return bands }
        var result: [Float] = []
        result.reserveCapacity(count)
        for index in 0..<count {
            let start = Int((Double(index) / Double(count)) * Double(bands.count))
            let end = max(start + 1, Int((Double(index + 1) / Double(count)) * Double(bands.count)))
            let slice = bands[start..<min(end, bands.count)]
            let average = slice.reduce(0, +) / Float(max(slice.count, 1))
            result.append(min(max(average, 0), 1))
        }
        return result
    }
}

/// 播放详情底部/封面附近的频谱条。
struct PlayDetailSpectrumView: View {
    let app: AppModel

    @Environment(\.meloColors) private var colors

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { _ in
            Group {
                if let spectrum = app.currentSpectrum, !spectrum.bands.isEmpty {
                    SpectrumBarsView(
                        bands: spectrum.bands,
                        barCount: 24,
                        spacing: 2,
                        minBarHeight: 2,
                        maxBarHeight: 30,
                        cornerRadius: 1.5,
                        tint: colors.primary,
                        tintOpacity: 0.9
                    )
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: "waveform")
                            .font(.system(size: 9))
                        Text(app.isVisualizerAvailable ? "正在等待频谱数据…" : "音频可视化在音效引擎播放时可用")
                            .font(.system(size: 9.5))
                    }
                    .foregroundStyle(.white.opacity(0.35))
                    .frame(height: 30)
                }
            }
        }
        .frame(width: 300, height: 30)
    }
}

/// 桌面歌词上方细频谱（幅度小，不抢歌词）。
struct DesktopLyricSpectrumView: View {
    let app: AppModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { _ in
            Group {
                if let spectrum = app.currentSpectrum, !spectrum.bands.isEmpty {
                    SpectrumBarsView(
                        bands: spectrum.bands,
                        barCount: 20,
                        spacing: 1.5,
                        minBarHeight: 1,
                        maxBarHeight: 12,
                        cornerRadius: 1,
                        tint: Color.white.opacity(0.65),
                        tintOpacity: 0.6
                    )
                } else {
                    Color.clear.frame(height: 12)
                }
            }
        }
        .frame(height: 12)
        .frame(maxWidth: 320)
        .allowsHitTesting(false)
    }
}
