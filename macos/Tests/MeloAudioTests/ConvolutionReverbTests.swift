import XCTest
import AVFoundation
import MeloCore
@testable import MeloAudio

/// Round 6：真实 IR 卷积混响（vDSP FFT 重叠相加）+ 3D 环绕（mainMixer.pan LFO）测试。
///
/// - 渲染器测试不依赖音频设备（纯离线处理 + 读回 WAV），headless 稳定；
/// - 引擎集成测试依赖真实播放，超时用 XCTSkip（headless CI 兜底）。
@MainActor
final class ConvolutionReverbTests: XCTestCase {

    /// 仓库 `macos/Resources`（TestAssets 不进 app；IR 已在 Resources/SoundEffect/convolution）。
    static let repositoryResources: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // Tests/MeloAudioTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // macos
        .appendingPathComponent("Resources", isDirectory: true)

    private let repositoryResources = ConvolutionReverbTests.repositoryResources

    // MARK: - 辅助

    private func makeTempDirectory(prefix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func remove(_ url: URL?) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private func makeMusic(id: String = "conv_song_1", interval: String? = "00:01") -> MusicInfo {
        MusicInfo(
            id: id,
            name: "卷积测试歌曲",
            singer: "卷积测试歌手",
            source: "test",
            interval: interval,
            meta: .object(["songId": .string("1")])
        )
    }

    private func sineSamples(seconds: Double,
                             frequency: Double = 440,
                             amplitude: Double = 0.5,
                             sampleRate: Double = 44_100) -> [Int16] {
        let count = max(1, Int((seconds * sampleRate).rounded()))
        return (0..<count).map { index in
            let value = sin(2.0 * Double.pi * frequency * Double(index) / sampleRate) * amplitude
            return Int16((max(-1.0, min(1.0, value)) * Double(Int16.max)).rounded())
        }
    }

    private func writeWAV(samples: [Int16], name: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        let data = WAVFixture.makeWAVData(samples: samples)
        try data.write(to: url, options: .atomic)
        return url
    }

    /// 读回音频为 Float32 声道数组（用于断言卷积输出）。
    private func readFloatSamples(_ url: URL) throws -> (channels: [[Float]], sampleRate: Double) {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = AVAudioFrameCount(max(1, file.length))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames),
              let data = buffer.floatChannelData else {
            throw NSError(domain: "ConvolutionReverbTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "无法读取输出 WAV"])
        }
        try file.read(into: buffer)
        var channels: [[Float]] = []
        for channel in 0..<Int(file.processingFormat.channelCount) {
            channels.append(Array(UnsafeBufferPointer(start: data[channel], count: Int(buffer.frameLength))))
        }
        return (channels, file.processingFormat.sampleRate)
    }

    private func rms(_ samples: ArraySlice<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for value in samples { sum += value * value }
        return (sum / Float(samples.count)).squareRoot()
    }

    private func rms(_ samples: [Float], range: Range<Int>) -> Float {
        let lower = max(0, range.lowerBound)
        let upper = min(samples.count, range.upperBound)
        guard lower < upper else { return 0 }
        return rms(samples[lower..<upper])
    }

    /// 等待引擎进入 playing（超时 XCTSkip，明确错误 XCTFail）。
    private func waitForPlaying(_ engine: EffectsAudioEngine,
                                timeout: TimeInterval = 20,
                                file: StaticString = #filePath,
                                line: UInt = #line) throws {
        let exp = expectation(description: "effects engine playing")
        var fired = false
        var errorMessage: String?
        let previous = engine.eventHandler
        engine.eventHandler = { event in
            switch event {
            case .status(let newStatus):
                if newStatus == .playing, !fired {
                    fired = true
                    exp.fulfill()
                }
            case .progress(let current, _):
                // 回退无混响等同步起播路径可能在安装 handler 前已发过 playing，
                // 用 0.25s 周期进度事件兜底判断「已开始播放」。
                if current > 0.01, !fired {
                    fired = true
                    exp.fulfill()
                }
            case .error(let message):
                errorMessage = message
            default:
                break
            }
            previous?(event)
        }
        let result = XCTWaiter().wait(for: [exp], timeout: timeout)
        engine.eventHandler = previous
        if result != .completed {
            if let errorMessage {
                XCTFail("音效引擎播放报错：\(errorMessage)", file: file, line: line)
            }
            throw XCTSkip("当前环境无法在 \(Int(timeout))s 内开始播放（status=\(engine.status)）",
                          file: file, line: line)
        }
    }

    // MARK: - 渲染器：FFT 卷积正确性

    func testIdentityImpulseResponseReproducesInput() throws {
        let directory = try makeTempDirectory(prefix: "melo-conv-identity")
        defer { remove(directory) }

        let sourceSamples = sineSamples(seconds: 0.25)
        let sourceURL = try writeWAV(samples: sourceSamples, name: "source.wav", in: directory)
        let irURL = try writeWAV(samples: [Int16.max, 0, 0, 0], name: "delta.wav", in: directory)
        let outputURL = directory.appendingPathComponent("out.wav")
        defer { remove(outputURL) }

        // blockSize=1024 强制多块，覆盖 overlap-add 路径。
        let result = try ConvolutionReverb.render(
            sourceURL: sourceURL,
            impulseResponseURL: irURL,
            mainGain: 0,
            sendGain: 1,
            outputURL: outputURL,
            blockSize: 1024
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
        XCTAssertEqual(result.frameCount, AVAudioFramePosition(sourceSamples.count))
        XCTAssertEqual(result.sampleRate, 44_100, accuracy: 0.5)
        XCTAssertEqual(result.channels, 1, "单声道输入 + 单声道 IR → 单声道输出")

        let output = try readFloatSamples(outputURL)
        let input = try readFloatSamples(sourceURL)
        XCTAssertEqual(output.channels[0].count, input.channels[0].count)
        var maxDifference: Float = 0
        for index in 0..<min(output.channels[0].count, 2_000) {
            maxDifference = max(maxDifference, abs(output.channels[0][index] - input.channels[0][index]))
        }
        XCTAssertLessThan(maxDifference, 2e-3, "单位脉冲 IR 的湿声输出应≈输入（FFT 缩放/OLA 正确）")
    }

    func testDryOnlyScalesInput() throws {
        let directory = try makeTempDirectory(prefix: "melo-conv-dry")
        defer { remove(directory) }

        let sourceSamples = sineSamples(seconds: 0.2)
        let sourceURL = try writeWAV(samples: sourceSamples, name: "source.wav", in: directory)
        let outputURL = directory.appendingPathComponent("dry-out.wav")
        defer { remove(outputURL) }

        _ = try ConvolutionReverb.render(
            sourceURL: sourceURL,
            impulseResponseURL: repositoryResources.appendingPathComponent("SoundEffect/convolution/bright-hall.wav"),
            mainGain: 0.5,
            sendGain: 0,
            outputURL: outputURL,
            blockSize: 4096
        )

        let output = try readFloatSamples(outputURL)
        let input = try readFloatSamples(sourceURL)
        XCTAssertGreaterThanOrEqual(output.channels.count, 2, "单声道输入 + 4 声道 IR → 立体声输出")
        XCTAssertEqual(output.channels[0].count, input.channels[0].count, "输出时长应与输入一致")
        var maxDifference: Float = 0
        for index in 0..<min(output.channels[0].count, 1_000) {
            let expected = input.channels[0][index] * 0.5
            maxDifference = max(maxDifference, abs(output.channels[0][index] - expected))
        }
        XCTAssertLessThan(maxDifference, 2e-3, "sendGain=0 时输出应≈干声*mainGain")
        XCTAssertEqual(output.channels[0].count, output.channels[1].count)
    }

    func testWetOnlyProducesReverbTail() throws {
        let directory = try makeTempDirectory(prefix: "melo-conv-wet")
        defer { remove(directory) }

        // 0.25s 正弦 + 0.75s 静音：干声静音区没有能量，湿声应有混响尾音
        let sampleRate = 44_100.0
        let tone = sineSamples(seconds: 0.25, amplitude: 0.6)
        let silence = [Int16](repeating: 0, count: Int((0.75 * sampleRate).rounded()))
        let sourceURL = try writeWAV(samples: tone + silence, name: "tonetail.wav", in: directory)
        let outputURL = directory.appendingPathComponent("wet-out.wav")
        defer { remove(outputURL) }

        _ = try ConvolutionReverb.render(
            sourceURL: sourceURL,
            impulseResponseURL: repositoryResources.appendingPathComponent("SoundEffect/convolution/bright-hall.wav"),
            mainGain: 0,
            sendGain: 1,
            outputURL: outputURL,
            blockSize: 4096
        )

        let output = try readFloatSamples(outputURL)
        XCTAssertGreaterThanOrEqual(output.channels.count, 2)
        let channel = output.channels[0]
        XCTAssertEqual(channel.count, tone.count + silence.count)

        let toneRMS = rms(channel, range: 0..<Int(0.2 * sampleRate))
        let tailRMS = rms(channel, range: Int(0.35 * sampleRate)..<Int(0.95 * sampleRate))
        XCTAssertGreaterThan(toneRMS, 1e-3, "湿声主体应有信号")
        XCTAssertGreaterThan(tailRMS, 1e-4, "输入静音区应有混响尾音（true convolution）")
        XCTAssertLessThan(tailRMS, toneRMS, "混响尾音应随时间衰减")

        // 与干声对比：卷积后的波形应与输入明显不同
        let input = try readFloatSamples(sourceURL)
        var maxDifference: Float = 0
        for index in 0..<min(channel.count, 2_000) {
            maxDifference = max(maxDifference, abs(channel[index] - input.channels[0][index]))
        }
        XCTAssertGreaterThan(maxDifference, 1e-3, "卷积湿声应不同于原始波形")
    }

    func testInvalidImpulseResponseThrowsReadableError() throws {
        let directory = try makeTempDirectory(prefix: "melo-conv-bad-ir")
        defer { remove(directory) }

        let sourceURL = try writeWAV(samples: sineSamples(seconds: 0.1), name: "source.wav", in: directory)
        let badIR = directory.appendingPathComponent("bad.wav")
        try Data("this is not audio".utf8).write(to: badIR)
        let outputURL = directory.appendingPathComponent("out.wav")
        defer { remove(outputURL); remove(badIR) }

        XCTAssertThrowsError(try ConvolutionReverb.render(
            sourceURL: sourceURL,
            impulseResponseURL: badIR,
            mainGain: 1,
            sendGain: 1,
            outputURL: outputURL
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("IR"), "实际：\(error.localizedDescription)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
    }

    // MARK: - 引擎集成：缓存复用 / key 变化

    func testEngineConvolutionCacheReuseAndKeyChange() throws {
        let cacheDir = try makeTempDirectory(prefix: "melo-conv-engine-cache")
        defer { remove(cacheDir) }
        let engine = EffectsAudioEngine(cacheDirectory: cacheDir, resourcesDirectory: repositoryResources)
        engine.volume = 0
        defer { engine.stop() }

        let source = try WAVFixture.writeTemporaryWAV(seconds: 1.0)
        defer { remove(source) }

        let brightHall = AudioEffectSettings(
            eqBands: [Double](repeating: 0, count: 10),
            playbackRate: 1,
            pitchSemitones: 0,
            convolutionFileName: "bright-hall.wav",
            convolutionMainGain: 0.5,
            convolutionSendGain: 0.5
        )
        engine.applyAudioEffects(brightHall)
        try engine.play(url: source, music: makeMusic())
        try waitForPlaying(engine)
        XCTAssertNil(engine.lastProcessingWarning, "正常 IR 不应产生回退警告")

        let firstProcessedURL = try XCTUnwrap(engine.currentProcessedFileURL)
        XCTAssertTrue(firstProcessedURL.lastPathComponent.hasSuffix(".conv.wav"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstProcessedURL.path), "卷积输出应写入缓存")
        XCTAssertEqual(engine.loadedFileURL?.standardizedFileURL, firstProcessedURL.standardizedFileURL)
        XCTAssertEqual(engine.duration, 1.0, accuracy: 0.05, "混响输出时长应与原曲一致")

        // 缓存复用：stop 后同样设置再播，应直接命中处理缓存并同步起播
        engine.stop()
        try engine.play(url: source, music: makeMusic())
        XCTAssertEqual(engine.status, .playing, "第二次播放应复用卷积缓存并同步起播")
        XCTAssertEqual(engine.currentProcessedFileURL?.standardizedFileURL, firstProcessedURL.standardizedFileURL)

        // 切换 IR：key 变化 → 生成不同处理缓存
        let telephone = AudioEffectSettings(
            eqBands: [Double](repeating: 0, count: 10),
            playbackRate: 1,
            pitchSemitones: 0,
            convolutionFileName: "filter-telephone.wav",
            convolutionMainGain: 1.8,
            convolutionSendGain: 0.9
        )
        engine.stop()
        engine.applyAudioEffects(telephone)
        try engine.play(url: source, music: makeMusic())
        try waitForPlaying(engine)
        let secondProcessedURL = try XCTUnwrap(engine.currentProcessedFileURL)
        XCTAssertNotEqual(secondProcessedURL.standardizedFileURL, firstProcessedURL.standardizedFileURL,
                          "IR/增益变化应生成新的缓存文件")
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondProcessedURL.path))

        // 再改干/湿增益：再生成一个不同 key
        var changedGains = telephone
        changedGains.convolutionMainGain = 1.0
        changedGains.convolutionSendGain = 2.0
        engine.stop()
        engine.applyAudioEffects(changedGains)
        try engine.play(url: source, music: makeMusic())
        try waitForPlaying(engine)
        let thirdProcessedURL = try XCTUnwrap(engine.currentProcessedFileURL)
        XCTAssertNotEqual(thirdProcessedURL.standardizedFileURL, secondProcessedURL.standardizedFileURL)
    }

    func testEngineSwitchingIRWhilePlayingKeepsPosition() throws {
        let cacheDir = try makeTempDirectory(prefix: "melo-conv-switch-cache")
        defer { remove(cacheDir) }
        let engine = EffectsAudioEngine(cacheDirectory: cacheDir, resourcesDirectory: repositoryResources)
        engine.volume = 0
        defer { engine.stop() }

        let source = try WAVFixture.writeTemporaryWAV(seconds: 2.0)
        defer { remove(source) }

        let first = AudioEffectSettings(
            eqBands: [Double](repeating: 0, count: 10),
            playbackRate: 1,
            pitchSemitones: 0,
            convolutionFileName: "bright-hall.wav",
            convolutionMainGain: 1.0,
            convolutionSendGain: 0.5
        )
        engine.applyAudioEffects(first)
        try engine.play(url: source, music: makeMusic(interval: "00:02"))
        try waitForPlaying(engine)
        let firstProcessed = try XCTUnwrap(engine.currentProcessedFileURL)

        // 播到 ~0.5s 后切换到另一个 IR
        let progressExp = expectation(description: "progress > 0.4")
        var fired = false
        let previous = engine.eventHandler
        engine.eventHandler = { event in
            if case .progress(let current, _) = event, current > 0.4, !fired {
                fired = true
                progressExp.fulfill()
            }
            previous?(event)
        }
        if XCTWaiter().wait(for: [progressExp], timeout: 15) != .completed {
            throw XCTSkip("当前环境未在 15s 内推进播放（status=\(engine.status)）")
        }
        engine.eventHandler = previous
        let positionBeforeSwitch = engine.currentTime
        XCTAssertGreaterThan(positionBeforeSwitch, 0.3)

        var second = first
        second.convolutionFileName = "matrix-reverb1.wav"
        engine.applyAudioEffects(second)
        try waitForPlaying(engine)
        XCTAssertGreaterThanOrEqual(engine.currentTime, positionBeforeSwitch - 0.3,
                                    "切换 IR 后应回到切换前的位置附近继续播放")
        let secondProcessed = try XCTUnwrap(engine.currentProcessedFileURL)
        XCTAssertNotEqual(secondProcessed.standardizedFileURL, firstProcessed.standardizedFileURL)
    }

    // MARK: - 引擎集成：IR 缺失/非法回退

    func testEngineMissingIRFallsBackWithReadableWarning() throws {
        let cacheDir = try makeTempDirectory(prefix: "melo-conv-missing-cache")
        let emptyResources = try makeTempDirectory(prefix: "melo-conv-empty-resources")
        defer { remove(cacheDir); remove(emptyResources) }

        let engine = EffectsAudioEngine(cacheDirectory: cacheDir, resourcesDirectory: emptyResources)
        engine.volume = 0
        defer { engine.stop() }

        let source = try WAVFixture.writeTemporaryWAV(seconds: 1.0)
        defer { remove(source) }

        var settings = AudioEffectSettings(eqBands: [Double](repeating: 0, count: 10))
        settings.convolutionFileName = "not-exist.wav"
        settings.convolutionMainGain = 1
        settings.convolutionSendGain = 1
        engine.applyAudioEffects(settings)

        try engine.play(url: source, music: makeMusic())
        try waitForPlaying(engine)
        XCTAssertEqual(engine.status, .playing, "IR 缺失时应回退为无混响继续播放")
        let warning = try XCTUnwrap(engine.lastProcessingWarning)
        XCTAssertTrue(warning.contains("IR"), "警告应说明 IR 问题：\(warning)")
        XCTAssertTrue(warning.contains("不存在"), "警告应为可读中文：\(warning)")
        XCTAssertNil(engine.currentProcessedFileURL)
        XCTAssertEqual(engine.loadedFileURL?.standardizedFileURL, source.standardizedFileURL,
                       "回退时应播放原始音频文件")
    }

    func testEngineInvalidIRFallsBackWithReadableWarning() throws {
        let cacheDir = try makeTempDirectory(prefix: "melo-conv-invalid-cache")
        let resources = try makeTempDirectory(prefix: "melo-conv-invalid-resources")
        defer { remove(cacheDir); remove(resources) }

        let irDirectory = resources.appendingPathComponent("SoundEffect/convolution", isDirectory: true)
        try FileManager.default.createDirectory(at: irDirectory, withIntermediateDirectories: true)
        try Data("not a wav file".utf8).write(to: irDirectory.appendingPathComponent("broken.wav"))

        let engine = EffectsAudioEngine(cacheDirectory: cacheDir, resourcesDirectory: resources)
        engine.volume = 0
        defer { engine.stop() }

        let source = try WAVFixture.writeTemporaryWAV(seconds: 1.0)
        defer { remove(source) }

        var settings = AudioEffectSettings(eqBands: [Double](repeating: 0, count: 10))
        settings.convolutionFileName = "broken.wav"
        settings.convolutionMainGain = 1
        settings.convolutionSendGain = 1
        engine.applyAudioEffects(settings)

        try engine.play(url: source, music: makeMusic())
        try waitForPlaying(engine)
        let warning = try XCTUnwrap(engine.lastProcessingWarning)
        XCTAssertTrue(warning.contains("IR"), "警告应说明 IR 问题：\(warning)")
        XCTAssertTrue(warning.contains("无法读取") || warning.contains("无效"),
                      "警告应为可读中文：\(warning)")
        XCTAssertEqual(engine.status, .playing)
    }

    // MARK: - 3D 环绕 LFO

    func testPannerLFOAnimatedAndReset() throws {
        let cacheDir = try makeTempDirectory(prefix: "melo-panner-cache")
        defer { remove(cacheDir) }
        let engine = EffectsAudioEngine(cacheDirectory: cacheDir, resourcesDirectory: repositoryResources)
        engine.volume = 0
        defer { engine.stop() }

        let source = try WAVFixture.writeTemporaryWAV(seconds: 2.0)
        defer { remove(source) }

        try engine.play(url: source, music: makeMusic(interval: "00:02"))
        try waitForPlaying(engine)

        XCTAssertEqual(engine.mainMixerPanValue, 0, accuracy: 0.0001, "未开启环绕时 pan 应为 0")
        XCTAssertFalse(engine.isPannerTimerRunning)

        var settings = AudioEffectSettings(eqBands: [Double](repeating: 0, count: 10))
        settings.pannerEnabled = true
        settings.pannerSpeed = 30
        settings.pannerSoundR = 30
        engine.applyAudioEffects(settings)
        XCTAssertTrue(engine.isPannerTimerRunning, "开启环绕后 30Hz LFO 定时器应运行")

        // 采样 0.6 秒的 pan 值（RunLoop 让定时器生效）
        var samples: [Float] = []
        for _ in 0..<12 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            samples.append(engine.mainMixerPanValue)
        }
        XCTAssertTrue(samples.contains { abs($0) > 0.05 }, "pan 应出现明显非 0 值：\(samples)")
        let minimum = samples.min() ?? 0
        let maximum = samples.max() ?? 0
        XCTAssertGreaterThan(maximum - minimum, 0.05, "pan 应随时间变化：\(samples)")
        XCTAssertTrue(samples.allSatisfy { abs($0) <= 1.0 + 0.0001 }, "pan 必须在 [-1, 1] 范围")

        // 关闭环绕：pan 归零、定时器停止
        engine.applyAudioEffects(.flat)
        XCTAssertFalse(engine.isPannerTimerRunning)
        XCTAssertEqual(engine.mainMixerPanValue, 0, accuracy: 0.0001, "关闭环绕后 pan 应复位为 0")

        // 播放中暂停：pan 复位、定时器停止；恢复后重新运行
        engine.applyAudioEffects(settings)
        XCTAssertTrue(engine.isPannerTimerRunning)
        engine.pause()
        XCTAssertFalse(engine.isPannerTimerRunning, "暂停时应停止 LFO 定时器")
        XCTAssertEqual(engine.mainMixerPanValue, 0, accuracy: 0.0001, "暂停时 pan 应复位")
        engine.resume()
        XCTAssertTrue(engine.isPannerTimerRunning, "恢复播放后 LFO 应重新运行")
    }
}
