import Foundation
import AVFoundation
import Accelerate

/// 音频线程使用的 FFT 频谱分析器（32 个 20Hz–16kHz 对数频段，归一化 0...1）。
///
/// - 只应由单个音频 tap 线程调用（内部工作缓冲复用，非线程安全）；
/// - 使用 `vDSP_DFT_zrop` 实数 DFT（长度为偶数/power-of-two），Hann 窗；
/// - 幅度归一化后转 dB，按 `-60dB…0dB` 映射到 0...1；
/// - 帧间平滑：上一帧 0.6 / 新帧 0.4（约 21–23fps 的 tap 频率下足够顺滑）。
final class AudioSpectrumAnalyzer {
    static let bandCount = 32
    static let minFrequency: Double = 20
    static let maxFrequency: Double = 16_000
    /// 低于该 dB 视为静音（映射为 0）。
    static let minDecibels: Float = -60

    let sampleRate: Double
    let fftSize: Int

    private let halfSize: Int
    private let forwardSetup: vDSP_DFT_Setup
    private let window: [Float]
    private let bandRanges: [(start: Int, end: Int)]
    private var smoothed = [Float](repeating: 0, count: AudioSpectrumAnalyzer.bandCount)
    private var lastBands = [Float](repeating: 0, count: AudioSpectrumAnalyzer.bandCount)

    private let samples: UnsafeMutablePointer<Float>
    private let realp: UnsafeMutablePointer<Float>
    private let imagp: UnsafeMutablePointer<Float>
    private let magnitudes: UnsafeMutablePointer<Float>

    /// - Parameters:
    ///   - sampleRate: 音频输出采样率（来自 mixer output format）。
    ///   - fftSize: FFT 长度（建议 2048；tap 每约 2048 帧回调 ≈ 21–23fps）。
    init?(sampleRate: Double, fftSize: Int = 2048) {
        guard sampleRate > 0,
              fftSize >= 256,
              fftSize % 2 == 0,
              (fftSize & (fftSize - 1)) == 0 else { return nil }
        guard let setup = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(fftSize), .FORWARD) else {
            return nil
        }

        self.sampleRate = sampleRate
        self.fftSize = fftSize
        self.halfSize = fftSize / 2
        self.forwardSetup = setup

        // Hann 窗（周期窗：分母用 fftSize - 1 的对称窗即可）
        var window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        self.window = window

        // 32 个对数频段（20Hz…16kHz）
        let nyquistBin = fftSize / 2
        var ranges: [(start: Int, end: Int)] = []
        ranges.reserveCapacity(AudioSpectrumAnalyzer.bandCount)
        let ratio = AudioSpectrumAnalyzer.maxFrequency / AudioSpectrumAnalyzer.minFrequency
        for band in 0..<AudioSpectrumAnalyzer.bandCount {
            let lowFrequency = AudioSpectrumAnalyzer.minFrequency
                * pow(ratio, Double(band) / Double(AudioSpectrumAnalyzer.bandCount))
            let highFrequency = AudioSpectrumAnalyzer.minFrequency
                * pow(ratio, Double(band + 1) / Double(AudioSpectrumAnalyzer.bandCount))
            let rawStart = Int((lowFrequency / sampleRate * Double(fftSize)).rounded(.down))
            let rawEnd = Int((highFrequency / sampleRate * Double(fftSize)).rounded(.up))
            let startBin = min(max(rawStart, 1), nyquistBin - 1)
            let endBin = min(max(rawEnd, startBin + 1), nyquistBin)
            ranges.append((startBin, endBin))
        }
        self.bandRanges = ranges

        self.samples = .allocate(capacity: fftSize)
        self.samples.initialize(repeating: 0, count: fftSize)
        self.realp = .allocate(capacity: fftSize / 2)
        self.realp.initialize(repeating: 0, count: fftSize / 2)
        self.imagp = .allocate(capacity: fftSize / 2)
        self.imagp.initialize(repeating: 0, count: fftSize / 2)
        self.magnitudes = .allocate(capacity: fftSize / 2 + 1)
        self.magnitudes.initialize(repeating: 0, count: fftSize / 2 + 1)
    }

    deinit {
        vDSP_DFT_DestroySetup(forwardSetup)
        samples.deallocate()
        realp.deallocate()
        imagp.deallocate()
        magnitudes.deallocate()
    }

    /// 分析一块音频（多声道取平均），返回 32 个平滑后的频段幅度（0...1）。
    func analyze(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channelData = buffer.floatChannelData else { return lastBands }
        let frameLength = min(Int(buffer.frameLength), fftSize)
        guard frameLength > 0 else { return lastBands }
        let channelCount = max(Int(buffer.format.channelCount), 1)

        // 混为单声道 + 加窗 + 零填充
        for index in 0..<fftSize {
            guard index < frameLength else {
                samples[index] = 0
                continue
            }
            var sample: Float = 0
            for channel in 0..<channelCount {
                sample += channelData[channel][index]
            }
            samples[index] = sample / Float(channelCount) * window[index]
        }

        // 实数 DFT 输入拆分格式：偶数样本 → realp，奇数样本 → imagp
        for index in 0..<halfSize {
            realp[index] = samples[index * 2]
            imagp[index] = samples[index * 2 + 1]
        }
        vDSP_DFT_Execute(forwardSetup, realp, imagp, realp, imagp)

        // 正向实数 DFT 输出为 2×DFT：幅度归一化到「正弦幅度 ≈ 1」
        let amplitudeScale = 2.0 / Float(fftSize)
        magnitudes[0] = abs(realp[0]) * amplitudeScale
        magnitudes[halfSize] = abs(imagp[0]) * amplitudeScale
        for bin in 1..<halfSize {
            let real = realp[bin]
            let imag = imagp[bin]
            magnitudes[bin] = (real * real + imag * imag).squareRoot() * amplitudeScale
        }

        let decibelRange = 0 - AudioSpectrumAnalyzer.minDecibels
        for band in 0..<AudioSpectrumAnalyzer.bandCount {
            let range = bandRanges[band]
            var sum: Float = 0
            for bin in range.start..<range.end {
                sum += magnitudes[bin]
            }
            let average = sum / Float(max(range.end - range.start, 1))
            let decibels = Float(log10(Double(max(average, 1e-7))))
            let normalized = min(
                max((decibels * 20 - AudioSpectrumAnalyzer.minDecibels) / decibelRange, 0),
                1
            )
            // 简单平滑：上一帧 0.6 / 新帧 0.4
            smoothed[band] = smoothed[band] * 0.6 + normalized * 0.4
        }

        lastBands = smoothed
        return smoothed
    }
}
