import Foundation
import AVFoundation
import Accelerate

/// 卷积混响渲染错误（全部提供可读中文，供 UI 回退/提示）。
public enum ConvolutionReverbError: LocalizedError, Equatable, Sendable {
    case cancelled
    case unreadableSource(String)
    case unreadableImpulseResponse(String)
    case emptyImpulseResponse
    case cannotCreateOutput(String)
    case renderFailed(String)

    public var errorDescription: String? {
        switch self {
        case .cancelled:
            return "混响处理已取消"
        case .unreadableSource(let detail):
            return "无法读取音频文件：\(detail)"
        case .unreadableImpulseResponse(let detail):
            return "无法读取混响 IR 文件：\(detail)"
        case .emptyImpulseResponse:
            return "混响 IR 文件为空"
        case .cannotCreateOutput(let detail):
            return "无法写入混响缓存文件：\(detail)"
        case .renderFailed(let detail):
            return "混响处理失败：\(detail)"
        }
    }
}

/// 一次卷积渲染的结果。
public struct ConvolutionRenderResult: Equatable, Sendable {
    /// 输出的 32-bit float WAV 缓存文件。
    public let outputURL: URL
    /// 输出帧数（= 输入帧数；混响尾巴在曲尾被截断，保持与原曲时长一致）。
    public let frameCount: AVAudioFramePosition
    public let sampleRate: Double
    public let channels: AVAudioChannelCount
    /// 音频时长（秒）。
    public let duration: TimeInterval
    /// 渲染耗时（秒），用于性能观测。
    public let renderSeconds: TimeInterval
}

/// 真实 IR 卷积混响（vDSP FFT 重叠相加 / overlap-add，分块流式）。
///
/// 算法：
/// 1. 读取 IR（AVAudioFile 解 WAV），必要时线性重采样到音频采样率；
/// 2. 选取 FFT 长度 `L = nextPowerOfTwo(blockSize + irLength - 1)`，
///    预先计算各 IR 声道的频域表示；
/// 3. 逐块（默认 16384 帧）读取音频 PCM：
///    - 每输入声道做一次正向实数 FFT；
///    - 每个输出声道按 IR 声道矩阵做频域乘加（真立体声 IR：4 声道矩阵
///      outL = inL*ir0 + inR*ir2，outR = inL*ir1 + inR*ir3）；
///    - 逆 FFT 得到该块卷积结果，做重叠相加（overlap-add）累加；
///    - 混音 `dry * mainGain + wet * sendGain` 写 32-bit float WAV；
/// 4. 输出帧数 = 输入帧数（曲尾混响尾音截断，保证时长/seek 与原曲一致）。
///
/// 内存：只缓存 IR 频谱 + 一个 FFT 长度的重叠缓冲，不随音频长度增长；
/// 音频数据按块读/写，长音频（5 分钟立体声）也不会整首爆内存。
///
/// 声道映射：
/// - 单声道输入 + 多声道 IR → 立体声输出（IR ch0/ch1）；
/// - 立体声输入 + 4 声道 IR → 真立体声矩阵卷积；
/// - 立体声输入 + 2 声道 IR → 每声道各用一个 IR 声道；
/// - 其余情况按「单 IR 声道应用于各输入声道」处理。
public enum ConvolutionReverb {
    /// 默认分块大小（帧）。
    ///
    /// 分块越大，FFT 次数越少、处理越快，但 FFT 长度/内存也随 IR 长度增长而增大。
    /// 实测 20s 立体声 + 4 声道 IR：16384→3.5s，32768→1.85s，65536→1.06s，131072→1.09s；
    /// 因此默认 65536（内存仍有界：只与「块大小 + IR 长度」有关，不随曲目长度增长）。
    public static let defaultBlockSize = 65_536

    /// 对 `sourceURL` 的 PCM 与 `impulseResponseURL` 做实时 FFT 卷积 + dry/wet 混音，
    /// 输出 32-bit float WAV 到 `outputURL`。
    ///
    /// - Parameters:
    ///   - mainGain: 干声倍率（原版设置值 / 10）。
    ///   - sendGain: 湿声（卷积结果）倍率。
    ///   - shouldCancel: 周期性调用，返回 true 时中止（用于切歌/切换 IR 时取消）。
    public static func render(sourceURL: URL,
                              impulseResponseURL: URL,
                              mainGain: Double,
                              sendGain: Double,
                              outputURL: URL,
                              blockSize: Int = defaultBlockSize,
                              shouldCancel: @escaping () -> Bool = { Task.isCancelled }) throws -> ConvolutionRenderResult {
        let startDate = Date()
        let effectiveBlockSize = max(1024, blockSize)

        // MARK: 输入音频（AVAudioFile 直接解出 Float32 非交错 PCM，支持 wav/mp3/flac/m4a 等）

        let sourceFile: AVAudioFile
        do {
            sourceFile = try AVAudioFile(forReading: sourceURL,
                                          commonFormat: .pcmFormatFloat32,
                                          interleaved: false)
        } catch {
            throw ConvolutionReverbError.unreadableSource(
                "\(sourceURL.lastPathComponent)（\(error.localizedDescription)）"
            )
        }
        let sourceFormat = sourceFile.processingFormat
        let sampleRate = sourceFormat.sampleRate
        let inputChannelCount = Int(sourceFormat.channelCount)
        let totalFrames = Int(min(sourceFile.length, AVAudioFramePosition(Int.max)))
        guard sampleRate > 0, inputChannelCount > 0, totalFrames > 0 else {
            throw ConvolutionReverbError.unreadableSource("\(sourceURL.lastPathComponent)（文件中没有音频帧）")
        }

        // MARK: IR（整段读入内存；IR 文件都很短，2 声道/4 声道均可）

        let irChannels = try readImpulseResponse(impulseResponseURL, targetSampleRate: sampleRate)
        guard let firstIR = irChannels.first, !firstIR.isEmpty else {
            throw ConvolutionReverbError.emptyImpulseResponse
        }
        let irLength = firstIR.count
        let plan = OutputPlan.make(inputChannels: inputChannelCount, irChannels: irChannels.count)

        // MARK: FFT 准备

        let fftSize = nextPowerOfTwo(effectiveBlockSize + irLength - 1)
        let halfSize = fftSize / 2
        guard let forwardSetup = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(fftSize), .FORWARD),
              let inverseSetup = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(fftSize), .INVERSE) else {
            throw ConvolutionReverbError.renderFailed("无法创建 FFT 计划（size=\(fftSize)）")
        }
        defer {
            vDSP_DFT_DestroySetup(forwardSetup)
            vDSP_DFT_DestroySetup(inverseSetup)
        }

        // 所有工作缓冲都用 UnsafeMutablePointer 管理，避免 Swift Array 的独占访问问题。
        var allocations: [UnsafeMutablePointer<Float>] = []
        func allocate(_ count: Int) -> UnsafeMutablePointer<Float> {
            let pointer = UnsafeMutablePointer<Float>.allocate(capacity: count)
            pointer.initialize(repeating: 0, count: count)
            allocations.append(pointer)
            return pointer
        }
        defer {
            for pointer in allocations { pointer.deallocate() }
        }

        // IR 频域（每个 IR 声道一份）
        var irSpectraReal: [UnsafeMutablePointer<Float>] = []
        var irSpectraImag: [UnsafeMutablePointer<Float>] = []
        for channel in 0..<plan.usedIRChannels {
            let real = allocate(halfSize)
            let imag = allocate(halfSize)
            let samples = irChannels[channel]
            for index in 0..<halfSize {
                let sampleIndex = index * 2
                real[index] = sampleIndex < samples.count ? samples[sampleIndex] : 0
                imag[index] = sampleIndex + 1 < samples.count ? samples[sampleIndex + 1] : 0
            }
            // 原地实数 FFT：输入为「偶数样本在 real、奇数样本在 imag」的拆分格式。
            vDSP_DFT_Execute(forwardSetup, real, imag, real, imag)
            irSpectraReal.append(real)
            irSpectraImag.append(imag)
        }

        // 输入频域工作区（最多前 2 个声道）
        let usedInputChannels = plan.usedInputChannels
        var inputSpectraReal: [UnsafeMutablePointer<Float>] = []
        var inputSpectraImag: [UnsafeMutablePointer<Float>] = []
        for _ in 0..<usedInputChannels {
            inputSpectraReal.append(allocate(halfSize))
            inputSpectraImag.append(allocate(halfSize))
        }

        let productReal = allocate(halfSize)
        let productImag = allocate(halfSize)
        let inverseReal = allocate(halfSize)
        let inverseImag = allocate(halfSize)
        let convolutionTime = allocate(fftSize)
        var accumulators: [UnsafeMutablePointer<Float>] = []
        for _ in 0..<plan.outputChannels {
            accumulators.append(allocate(fftSize))
        }

        // MARK: 输入 / 输出缓冲

        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat,
                                                  frameCapacity: AVAudioFrameCount(effectiveBlockSize)),
              let inputData = inputBuffer.floatChannelData else {
            throw ConvolutionReverbError.renderFailed("无法分配音频读取缓冲")
        }
        guard let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                sampleRate: sampleRate,
                                                channels: AVAudioChannelCount(plan.outputChannels),
                                                interleaved: false),
              let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat,
                                                   frameCapacity: AVAudioFrameCount(effectiveBlockSize)),
              let outputData = outputBuffer.floatChannelData else {
            throw ConvolutionReverbError.renderFailed("无法分配音频写入缓冲")
        }

        let outputFile: AVAudioFile
        do {
            try FileManager.default.createDirectory(
                at: outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: outputURL.path) {
                try? FileManager.default.removeItem(at: outputURL)
            }
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: plan.outputChannels,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
            outputFile = try AVAudioFile(forWriting: outputURL,
                                         settings: settings,
                                         commonFormat: .pcmFormatFloat32,
                                         interleaved: false)
        } catch let error as ConvolutionReverbError {
            throw error
        } catch {
            throw ConvolutionReverbError.cannotCreateOutput(
                "\(outputURL.lastPathComponent)（\(error.localizedDescription)）"
            )
        }

        // MARK: 逐块卷积

        let dryGain = Float(mainGain)
        let wetGain = Float(sendGain)
        // 正向实数 FFT 输出放大 2 倍、逆变换无缩放；两次相乘后需除以 4N。
        let inverseScale = 1.0 / (4.0 * Float(fftSize))
        let shiftCount = fftSize - effectiveBlockSize
        var remainingFrames = totalFrames
        var renderedFrames: AVAudioFramePosition = 0

        while remainingFrames > 0 {
            if shouldCancel() { throw ConvolutionReverbError.cancelled }

            let requestFrames = min(effectiveBlockSize, remainingFrames)
            inputBuffer.frameLength = 0
            do {
                try sourceFile.read(into: inputBuffer, frameCount: AVAudioFrameCount(requestFrames))
            } catch {
                throw ConvolutionReverbError.unreadableSource(
                    "\(sourceURL.lastPathComponent)（\(error.localizedDescription)）"
                )
            }
            let validFrames = Int(inputBuffer.frameLength)
            if validFrames == 0 { break }

            // 1) 输入声道 → 频域
            for channel in 0..<usedInputChannels {
                let samples = inputData[channel]
                let real = inputSpectraReal[channel]
                let imag = inputSpectraImag[channel]
                for index in 0..<halfSize {
                    let sampleIndex = index * 2
                    real[index] = sampleIndex < validFrames ? samples[sampleIndex] : 0
                    imag[index] = sampleIndex + 1 < validFrames ? samples[sampleIndex + 1] : 0
                }
                vDSP_DFT_Execute(forwardSetup, real, imag, real, imag)
            }

            // 2) 每个输出声道：频域乘加 → 逆 FFT → overlap-add → dry/wet 混音
            for outputChannel in 0..<plan.outputChannels {
                let contributions = plan.contributions[outputChannel]
                var dc: Float = 0
                var nyquist: Float = 0
                for index in 1..<halfSize {
                    productReal[index] = 0
                    productImag[index] = 0
                }
                for contribution in contributions {
                    let xReal = inputSpectraReal[contribution.inputChannel]
                    let xImag = inputSpectraImag[contribution.inputChannel]
                    let hReal = irSpectraReal[contribution.irChannel]
                    let hImag = irSpectraImag[contribution.irChannel]
                    dc += xReal[0] * hReal[0]
                    nyquist += xImag[0] * hImag[0]
                    for index in 1..<halfSize {
                        productReal[index] += xReal[index] * hReal[index] - xImag[index] * hImag[index]
                        productImag[index] += xReal[index] * hImag[index] + xImag[index] * hReal[index]
                    }
                }
                productReal[0] = dc
                productImag[0] = nyquist

                vDSP_DFT_Execute(inverseSetup, productReal, productImag, inverseReal, inverseImag)
                for index in 0..<halfSize {
                    convolutionTime[index * 2] = inverseReal[index] * inverseScale
                    convolutionTime[index * 2 + 1] = inverseImag[index] * inverseScale
                }

                let accumulator = accumulators[outputChannel]
                vDSP_vadd(accumulator, 1, convolutionTime, 1, accumulator, 1, vDSP_Length(fftSize))

                let drySamples = inputData[plan.dryInputChannels[outputChannel]]
                let outputSamples = outputData[outputChannel]
                for index in 0..<validFrames {
                    outputSamples[index] = accumulator[index] * wetGain + drySamples[index] * dryGain
                }

                // 重叠相加：左移 blockSize，尾部清零
                if shiftCount > 0 {
                    memmove(accumulator,
                            accumulator.advanced(by: effectiveBlockSize),
                            shiftCount * MemoryLayout<Float>.size)
                    memset(accumulator.advanced(by: shiftCount), 0,
                           effectiveBlockSize * MemoryLayout<Float>.size)
                }
            }

            outputBuffer.frameLength = AVAudioFrameCount(validFrames)
            do {
                try outputFile.write(from: outputBuffer)
            } catch {
                throw ConvolutionReverbError.renderFailed("写入输出文件失败（\(error.localizedDescription)）")
            }
            renderedFrames += AVAudioFramePosition(validFrames)
            remainingFrames -= validFrames
        }

        return ConvolutionRenderResult(
            outputURL: outputURL,
            frameCount: renderedFrames,
            sampleRate: sampleRate,
            channels: AVAudioChannelCount(plan.outputChannels),
            duration: sampleRate > 0 ? Double(renderedFrames) / sampleRate : 0,
            renderSeconds: Date().timeIntervalSince(startDate)
        )
    }

    // MARK: - IR 读取 / 重采样

    /// 读取 IR 为 Float32 声道数组；采样率与音频不同时做线性重采样。
    static func readImpulseResponse(_ url: URL, targetSampleRate: Double) throws -> [[Float]] {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url,
                                   commonFormat: .pcmFormatFloat32,
                                   interleaved: false)
        } catch {
            throw ConvolutionReverbError.unreadableImpulseResponse(
                "\(url.lastPathComponent)（\(error.localizedDescription)）"
            )
        }

        let frameLength = Int(min(file.length, AVAudioFramePosition(Int.max)))
        guard frameLength > 0 else { throw ConvolutionReverbError.emptyImpulseResponse }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                             frameCapacity: AVAudioFrameCount(frameLength)),
              let channelData = buffer.floatChannelData else {
            throw ConvolutionReverbError.unreadableImpulseResponse("\(url.lastPathComponent)（无法分配缓冲）")
        }
        do {
            try file.read(into: buffer)
        } catch {
            throw ConvolutionReverbError.unreadableImpulseResponse(
                "\(url.lastPathComponent)（\(error.localizedDescription)）"
            )
        }

        let frames = Int(buffer.frameLength)
        guard frames > 0 else { throw ConvolutionReverbError.emptyImpulseResponse }
        let channels = Int(file.processingFormat.channelCount)
        guard channels > 0 else { throw ConvolutionReverbError.emptyImpulseResponse }

        var result: [[Float]] = []
        result.reserveCapacity(channels)
        for channel in 0..<channels {
            let start = channelData[channel]
            result.append(Array(UnsafeBufferPointer(start: start, count: frames)))
        }

        let sourceSampleRate = file.processingFormat.sampleRate
        if abs(sourceSampleRate - targetSampleRate) > 0.5 {
            result = resample(result, from: sourceSampleRate, to: targetSampleRate)
        }
        return result
    }

    /// 线性插值重采样（IR 很短，线性足够；避免引入第三方依赖）。
    static func resample(_ channels: [[Float]], from sourceRate: Double, to targetRate: Double) -> [[Float]] {
        guard sourceRate > 0, targetRate > 0, abs(sourceRate - targetRate) > 0.5 else { return channels }
        let ratio = sourceRate / targetRate
        return channels.map { input in
            guard !input.isEmpty else { return [] }
            let outputCount = max(1, Int((Double(input.count) * targetRate / sourceRate).rounded()))
            var output = [Float](repeating: 0, count: outputCount)
            let lastIndex = input.count - 1
            for index in 0..<outputCount {
                let position = Double(index) * ratio
                let base = Int(position)
                let fraction = Float(position - Double(base))
                let a = input[min(base, lastIndex)]
                let b = input[min(base + 1, lastIndex)]
                output[index] = a + (b - a) * fraction
            }
            return output
        }
    }

    // MARK: - 工具

    static func nextPowerOfTwo(_ value: Int) -> Int {
        var result = 1
        while result < value { result <<= 1 }
        return result
    }

    /// 声道映射计划。
    struct OutputPlan {
        struct Contribution {
            let inputChannel: Int
            let irChannel: Int
        }

        let outputChannels: Int
        let usedInputChannels: Int
        let usedIRChannels: Int
        /// 每个输出声道的卷积贡献列表（真立体声时每声道 2 个）。
        let contributions: [[Contribution]]
        /// 每个输出声道的干声来源输入声道。
        let dryInputChannels: [Int]

        static func make(inputChannels: Int, irChannels: Int) -> OutputPlan {
            let inChannels = max(1, min(inputChannels, 2))
            let ir = max(1, min(irChannels, 4))

            if inChannels >= 2, ir >= 4 {
                // 真立体声（4 声道 IR）：outL = inL*ir0 + inR*ir2，outR = inL*ir1 + inR*ir3
                return OutputPlan(
                    outputChannels: 2,
                    usedInputChannels: 2,
                    usedIRChannels: 4,
                    contributions: [
                        [Contribution(inputChannel: 0, irChannel: 0),
                         Contribution(inputChannel: 1, irChannel: 2)],
                        [Contribution(inputChannel: 0, irChannel: 1),
                         Contribution(inputChannel: 1, irChannel: 3)],
                    ],
                    dryInputChannels: [0, 1]
                )
            }
            if inChannels == 1, ir >= 2 {
                // 单声道输入 + 立体声 IR → 立体声输出
                return OutputPlan(
                    outputChannels: 2,
                    usedInputChannels: 1,
                    usedIRChannels: min(ir, 2),
                    contributions: [
                        [Contribution(inputChannel: 0, irChannel: 0)],
                        [Contribution(inputChannel: 0, irChannel: 1)],
                    ],
                    dryInputChannels: [0, 0]
                )
            }
            if inChannels >= 2 {
                // 立体声输入 + 单/双声道 IR：各声道分别卷积
                return OutputPlan(
                    outputChannels: 2,
                    usedInputChannels: 2,
                    usedIRChannels: min(ir, 2),
                    contributions: [
                        [Contribution(inputChannel: 0, irChannel: 0)],
                        [Contribution(inputChannel: 1, irChannel: min(1, ir - 1))],
                    ],
                    dryInputChannels: [0, 1]
                )
            }
            // 单声道输入 + 单声道 IR
            return OutputPlan(
                outputChannels: 1,
                usedInputChannels: 1,
                usedIRChannels: 1,
                contributions: [[Contribution(inputChannel: 0, irChannel: 0)]],
                dryInputChannels: [0]
            )
        }
    }
}
