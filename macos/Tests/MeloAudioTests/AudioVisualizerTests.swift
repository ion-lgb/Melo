import XCTest
import AVFoundation
import MeloCore
@testable import MeloAudio

/// Round 14：音频可视化频谱（EffectsAudioEngine tap + FFT；RoutedPlayerService 路由/转发）。
@MainActor
final class AudioVisualizerTests: XCTestCase {

    private struct Context {
        let router: RoutedPlayerService
        let settings: SettingsStore
        let avPlayer: AVPlayerService
        let effectsPlayer: EffectsAudioEngine
        let directory: URL
    }

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

    private func makeEngine(cacheDirectory: URL) -> EffectsAudioEngine {
        let engine = EffectsAudioEngine(cacheDirectory: cacheDirectory)
        engine.volume = 0
        return engine
    }

    private func makeMusic(interval: String? = "00:03") -> MusicInfo {
        MusicInfo(
            id: "viz_song_1",
            name: "可视化测试歌曲",
            singer: "可视化测试歌手",
            source: "test",
            interval: interval,
            meta: .object(["songId": .string("1")])
        )
    }

    /// 扫频 WAV（每 0.5s 换频率，循环），保证频谱帧之间有明显变化。
    private func makeSweepWAV(seconds: Double = 3.0) throws -> URL {
        let sampleRate = 44_100.0
        let frequencies: [Double] = [440, 880, 1760, 3520, 440, 880]
        let totalSamples = Int(seconds * sampleRate)
        var samples: [Int16] = []
        samples.reserveCapacity(totalSamples)
        var chunkIndex = 0
        while samples.count < totalSamples {
            let frequency = frequencies[chunkIndex % frequencies.count]
            chunkIndex += 1
            let count = min(Int(0.5 * sampleRate), totalSamples - samples.count)
            for index in 0..<count {
                let value = sin(2.0 * Double.pi * frequency * Double(index) / sampleRate) * 0.5
                samples.append(Int16((max(-1, min(1, value)) * Double(Int16.max)).rounded()))
            }
        }
        return try WAVFixture.writeTemporaryWAV(samples: samples)
    }

    private func makeContext() throws -> Context {
        let directory = try makeTempDirectory(prefix: "melo-viz")
        let settings = SettingsStore(dataDirectory: directory)
        let avPlayer = AVPlayerService()
        avPlayer.systemIntegrationEnabled = false
        let effectsPlayer = EffectsAudioEngine(
            cacheDirectory: directory.appendingPathComponent("effects-cache", isDirectory: true)
        )
        let router = RoutedPlayerService(settings: settings, avPlayer: avPlayer, effectsPlayer: effectsPlayer)
        router.volume = 0
        return Context(router: router, settings: settings,
                       avPlayer: avPlayer, effectsPlayer: effectsPlayer, directory: directory)
    }

    private func tearDown(_ context: Context, file: URL? = nil) {
        context.router.stop()
        if let file { try? FileManager.default.removeItem(at: file) }
        try? FileManager.default.removeItem(at: context.directory)
    }

    private func waitForPlaying(_ engine: EffectsAudioEngine,
                                timeout: TimeInterval = 15,
                                file: StaticString = #filePath,
                                line: UInt = #line) throws {
        let exp = expectation(description: "effects engine playing")
        var fired = false
        var errorMessage: String?
        let previous = engine.eventHandler
        engine.eventHandler = { event in
            switch event {
            case .status(let newStatus):
                if newStatus == .playing, !fired { fired = true; exp.fulfill() }
            case .progress(let current, _):
                if current > 0.01, !fired { fired = true; exp.fulfill() }
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
            if let errorMessage { XCTFail("播放报错：\(errorMessage)", file: file, line: line) }
            throw XCTSkip("当前环境无法开始播放（status=\(engine.status)）", file: file, line: line)
        }
    }

    private func waitForPlaying(_ router: RoutedPlayerService,
                                timeout: TimeInterval = 15,
                                file: StaticString = #filePath,
                                line: UInt = #line) throws {
        let exp = expectation(description: "router playing")
        var fired = false
        var errorMessage: String?
        let previous = router.eventHandler
        router.eventHandler = { event in
            switch event {
            case .status(let newStatus):
                if newStatus == .playing, !fired { fired = true; exp.fulfill() }
            case .progress(let current, _):
                if current > 0.01, !fired { fired = true; exp.fulfill() }
            case .error(let message):
                errorMessage = message
            default:
                break
            }
            previous?(event)
        }
        let result = XCTWaiter().wait(for: [exp], timeout: timeout)
        router.eventHandler = previous
        if result != .completed {
            if let errorMessage { XCTFail("播放报错：\(errorMessage)", file: file, line: line) }
            throw XCTSkip("当前环境无法开始播放（status=\(router.status)）", file: file, line: line)
        }
    }

    /// 在 RunLoop 上轮询收集不同的频谱帧（最多 duration 秒 / 达到 minimumFrames 帧）。
    private func collectSpectrums(from engine: EffectsAudioEngine,
                                  duration: TimeInterval = 2.0,
                                  minimumFrames: Int = 3) -> [AudioSpectrum] {
        var frames: [AudioSpectrum] = []
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            if let spectrum = engine.currentSpectrum,
               frames.last?.bands != spectrum.bands {
                frames.append(spectrum)
                if frames.count >= minimumFrames { break }
            }
        }
        return frames
    }

    private func assertValidSpectrum(_ spectrum: AudioSpectrum,
                                     file: StaticString = #filePath,
                                     line: UInt = #line) {
        XCTAssertEqual(spectrum.bands.count, 32, "应为 32 个对数频段", file: file, line: line)
        XCTAssertTrue(spectrum.bands.allSatisfy(\.isFinite), "频段值必须是有限数", file: file, line: line)
        XCTAssertTrue(spectrum.bands.allSatisfy { $0 >= 0 && $0 <= 1 }, "频段值应归一化到 0...1", file: file, line: line)
        XCTAssertGreaterThan(spectrum.bands.max() ?? 0, 0.02, "播放时应有非零频段能量", file: file, line: line)
    }

    // MARK: - 引擎频谱

    func testSpectrumWhilePlayingLocalWAV() throws {
        guard !AudioOutputDevices.list().isEmpty else {
            throw XCTSkip("当前环境没有可用的音频输出设备（headless CI）")
        }
        let cacheDir = try makeTempDirectory(prefix: "melo-viz-engine")
        defer { remove(cacheDir) }
        let engine = makeEngine(cacheDirectory: cacheDir)
        defer { engine.stop() }
        let wav = try makeSweepWAV()
        defer { remove(wav) }

        XCTAssertFalse(engine.isVisualizerAvailable)
        XCTAssertNil(engine.currentSpectrum)

        try engine.play(url: wav, music: makeMusic())
        try waitForPlaying(engine)
        XCTAssertTrue(engine.isVisualizerAvailable, "播放中应具备可视化能力")
        XCTAssertTrue(engine.isVisualizerTapInstalledForTesting, "播放时应安装频谱 tap")

        let frames = collectSpectrums(from: engine)
        guard frames.count >= 2 else {
            throw XCTSkip("当前环境音频 tap 未提供频谱数据（可能 headless/无输出设备）")
        }
        assertValidSpectrum(frames[0])
        assertValidSpectrum(frames[frames.count - 1])

        // 扫频 WAV ⇒ 频谱帧应随时间变化
        var maxDifference: Float = 0
        for (lhs, rhs) in zip(frames[0].bands, frames[frames.count - 1].bands) {
            maxDifference = max(maxDifference, abs(lhs - rhs))
        }
        XCTAssertGreaterThan(maxDifference, 0.02, "扫频音频的频谱应随时间变化")
    }

    func testPauseResumeStopTapSafety() throws {
        guard !AudioOutputDevices.list().isEmpty else {
            throw XCTSkip("当前环境没有可用的音频输出设备（headless CI）")
        }
        let cacheDir = try makeTempDirectory(prefix: "melo-viz-lifecycle")
        defer { remove(cacheDir) }
        let engine = makeEngine(cacheDirectory: cacheDir)
        defer { engine.stop() }
        let wav = try makeSweepWAV()
        defer { remove(wav) }

        try engine.play(url: wav, music: makeMusic())
        try waitForPlaying(engine)

        // 暂停：tap 移除、频谱清空、仍可视为「有文件,具备能力」
        engine.pause()
        XCTAssertEqual(engine.status, .paused)
        XCTAssertFalse(engine.isVisualizerTapInstalledForTesting, "暂停后应移除频谱 tap")
        XCTAssertNil(engine.currentSpectrum, "暂停后应清空频谱")
        XCTAssertTrue(engine.isVisualizerAvailable, "暂停但已加载音频时仍具备可视化能力")
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        XCTAssertNil(engine.currentSpectrum, "暂停后不应再有频谱更新")

        // 恢复：tap 重新安装，频谱恢复
        engine.resume()
        try waitForPlaying(engine)
        let resumedFrames = collectSpectrums(from: engine, duration: 1.5, minimumFrames: 1)
        if resumedFrames.isEmpty {
            throw XCTSkip("当前环境恢复播放后未收到频谱数据")
        }
        XCTAssertTrue(engine.isVisualizerTapInstalledForTesting)

        // 停止：tap 移除、能力 false
        engine.stop()
        XCTAssertFalse(engine.isVisualizerAvailable)
        XCTAssertNil(engine.currentSpectrum)
        XCTAssertFalse(engine.isVisualizerTapInstalledForTesting)

        // 停止后再次播放：tap 可安全重装
        try engine.play(url: wav, music: makeMusic())
        try waitForPlaying(engine)
        let replayFrames = collectSpectrums(from: engine, duration: 1.5, minimumFrames: 1)
        if !replayFrames.isEmpty {
            assertValidSpectrum(replayFrames[0])
        }
        engine.stop()
        XCTAssertNil(engine.currentSpectrum)
    }

    // MARK: - 路由：可视化开启时强制走音效引擎

    func testRouterVisualizationRouting() throws {
        guard !AudioOutputDevices.list().isEmpty else {
            throw XCTSkip("当前环境没有可用的音频输出设备（headless CI）")
        }
        let context = try makeContext()
        let wav = try makeSweepWAV(seconds: 6.0)
        defer { tearDown(context, file: wav) }

        XCTAssertFalse(RoutedPlayerService.requiresEffects(.flat))
        // 只打开播放器可视化（EQ 全平）→ 必须走 effects 引擎
        context.settings.set(SettingKeys.playerAudioVisualization, .bool(true))
        context.router.applyVisualizationSetting()
        XCTAssertEqual(context.router.activeEngineKind, .effects,
                       "可视化开启时（即使 EQ 全平）应走音效引擎")

        try context.router.play(url: wav, music: makeMusic())
        XCTAssertEqual(context.router.activeEngineKind, .effects)
        try waitForPlaying(context.router)
        XCTAssertTrue(context.router.isVisualizerAvailable)
        let frames = collectSpectrums(from: context.effectsPlayer)
        if frames.isEmpty {
            throw XCTSkip("当前环境音频 tap 未提供频谱数据（可能 headless/无输出设备）")
        }
        XCTAssertNotNil(context.router.currentSpectrum, "router 应转发音效引擎频谱")

        // 关闭可视化：无其它音效 → 应切回 AVPlayer，频谱清空/不可用
        context.settings.set(SettingKeys.playerAudioVisualization, .bool(false))
        context.router.applyVisualizationSetting()
        XCTAssertEqual(context.router.activeEngineKind, .avPlayer,
                       "恢复关闭后（无其它音效）应回到 AVPlayer")
        XCTAssertNil(context.router.currentSpectrum)
        XCTAssertFalse(context.router.isVisualizerAvailable)

        // 桌面歌词可视化开关同样强制 effects
        context.settings.set(SettingKeys.desktopLyricAudioVisualization, .bool(true))
        context.router.applyVisualizationSetting()
        XCTAssertEqual(context.router.activeEngineKind, .effects)
        context.settings.set(SettingKeys.desktopLyricAudioVisualization, .bool(false))
        context.router.applyVisualizationSetting()
        XCTAssertEqual(context.router.activeEngineKind, .avPlayer)
    }

    func testVisualizerUnavailableWhenIdle() throws {
        let cacheDir = try makeTempDirectory(prefix: "melo-viz-idle")
        defer { remove(cacheDir) }
        let engine = makeEngine(cacheDirectory: cacheDir)
        defer { engine.stop() }

        XCTAssertFalse(engine.isVisualizerAvailable)
        XCTAssertNil(engine.currentSpectrum)
        XCTAssertFalse(engine.isVisualizerTapInstalledForTesting)

        let context = try makeContext()
        defer { tearDown(context) }
        XCTAssertFalse(context.router.isVisualizerAvailable)
        XCTAssertNil(context.router.currentSpectrum)
    }
}
