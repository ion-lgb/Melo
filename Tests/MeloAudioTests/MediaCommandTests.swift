import XCTest
import AVFoundation
import MeloCore
@testable import MeloAudio

/// Round 10：系统媒体键快进/快退/进度拖动（skipForward/skipBackward/changePlaybackPosition）。
///
/// 通过 `RoutedPlayerService.handleMediaCommand(_:)`（internal）模拟系统媒体键，
/// 覆盖 AVPlayer / 音效引擎两条路径的边界与暂停状态行为。
@MainActor
final class MediaCommandTests: XCTestCase {

    private struct Context {
        let router: RoutedPlayerService
        let settings: SettingsStore
        let avPlayer: AVPlayerService
        let effectsPlayer: EffectsAudioEngine
        let directory: URL
    }

    private func makeContext() throws -> Context {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("melo-media-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

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

    private func makeMusic(interval: String? = "00:08") -> MusicInfo {
        MusicInfo(
            id: "media_song_1",
            name: "媒体键测试歌曲",
            singer: "媒体键测试歌手",
            source: "test",
            interval: interval,
            meta: .object(["songId": .string("1")])
        )
    }

    private func waitForProgress(_ router: RoutedPlayerService,
                                 greaterThan threshold: TimeInterval,
                                 timeout: TimeInterval = 15) throws {
        let exp = expectation(description: "router progress > \(threshold)")
        var fired = false
        var errorMessage: String?
        let previous = router.eventHandler
        router.eventHandler = { event in
            switch event {
            case .progress(let current, _):
                if current > threshold, !fired {
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
        router.eventHandler = previous
        if result != .completed {
            if let errorMessage { XCTFail("播放报错：\(errorMessage)") }
            throw XCTSkip("当前环境未在 \(Int(timeout))s 内开始播放（router.status=\(router.status)）")
        }
    }

    // MARK: - 两引擎路径公共断言

    private func runMediaCommandChecks(useEffectsEngine: Bool) throws {
        let context = try makeContext()
        let wav = try WAVFixture.writeTemporaryWAV(seconds: 8.0)
        defer { tearDown(context, file: wav) }

        if useEffectsEngine {
            context.settings.set(SettingKeys.eqBandKeys[0], .double(6))
            var effects = AudioEffectSettings(eqBands: [Double](repeating: 0, count: 10))
            effects.eqBands[0] = 6
            context.router.applyAudioEffects(effects)
        }

        try context.router.play(url: wav, music: makeMusic())
        XCTAssertEqual(context.router.activeEngineKind,
                       useEffectsEngine ? .effects : .avPlayer,
                       "媒体键应在预期引擎路径上测试")
        try waitForProgress(context.router, greaterThan: 0.4)

        let duration = context.router.duration
        XCTAssertEqual(duration, 8.0, accuracy: 0.3, "时长应已知（用于边界夹取）")
        XCTAssertGreaterThan(context.router.currentTime, 0.2)

        // 1) 快退边界：不低于 0（播放中）
        context.router.handleMediaCommand(.skipBackward(15))
        XCTAssertEqual(context.router.currentTime, 0, accuracy: 0.3, "快退不应小于 0")
        XCTAssertEqual(context.router.status, .playing)

        // 2) 暂停后：快进/快退/拖动位置都不改变暂停状态
        context.router.pause()
        XCTAssertEqual(context.router.status, .paused)

        context.router.handleMediaCommand(.skipForward(3))
        XCTAssertEqual(context.router.currentTime, 3.0, accuracy: 0.4)
        XCTAssertEqual(context.router.status, .paused, "暂停状态下快进应保持暂停")

        // 3) 快进超过 duration：应夹取到 duration
        context.router.handleMediaCommand(.changePlaybackPosition(6.0))
        XCTAssertEqual(context.router.currentTime, 6.0, accuracy: 0.4)
        context.router.handleMediaCommand(.skipForward(15))
        XCTAssertEqual(context.router.currentTime, duration, accuracy: 0.4, "快进不应超过 duration")
        XCTAssertEqual(context.router.status, .paused)

        // 4) 快退超过 0：夹取到 0
        context.router.handleMediaCommand(.skipBackward(15))
        XCTAssertEqual(context.router.currentTime, 0, accuracy: 0.3, "快退不应小于 0")
        XCTAssertEqual(context.router.status, .paused)

        // 5) 进度拖动（changePlaybackPosition）：负值→0，超大→duration
        context.router.handleMediaCommand(.changePlaybackPosition(2.5))
        XCTAssertEqual(context.router.currentTime, 2.5, accuracy: 0.4)
        XCTAssertEqual(context.router.status, .paused)
        context.router.handleMediaCommand(.changePlaybackPosition(-5))
        XCTAssertEqual(context.router.currentTime, 0, accuracy: 0.3)
        context.router.handleMediaCommand(.changePlaybackPosition(999))
        XCTAssertEqual(context.router.currentTime, duration, accuracy: 0.4)

        // 6) 默认步长（15s）的便捷入口
        context.router.handleMediaCommand(.changePlaybackPosition(1.0))
        context.router.handleSkipForwardCommand()
        XCTAssertEqual(context.router.currentTime, min(1.0 + RoutedPlayerService.defaultSkipInterval, duration),
                       accuracy: 0.4)
        context.router.handleSkipBackwardCommand()
        XCTAssertEqual(context.router.currentTime, 0, accuracy: 0.3)

        // 7) 非法间隔（NaN/0/负）回退默认 15s
        context.router.handleMediaCommand(.changePlaybackPosition(1.0))
        context.router.handleMediaCommand(.skipForward(.nan))
        XCTAssertEqual(context.router.currentTime, min(1.0 + RoutedPlayerService.defaultSkipInterval, duration),
                       accuracy: 0.4)
        context.router.handleMediaCommand(.skipBackward(0))
        XCTAssertEqual(context.router.currentTime, 0, accuracy: 0.3)

        // 8) 恢复播放后快进仍正常
        context.router.resume()
        XCTAssertEqual(context.router.status, .playing)
        context.router.handleMediaCommand(.skipForward(2))
        XCTAssertEqual(context.router.currentTime, 2.0, accuracy: 0.5)
    }

    // MARK: - 两引擎路径

    func testMediaCommandsOnAVPlayerPath() throws {
        try runMediaCommandChecks(useEffectsEngine: false)
    }

    func testMediaCommandsOnEffectsEnginePath() throws {
        try runMediaCommandChecks(useEffectsEngine: true)
    }

    // MARK: - next/previous / play/pause 保持原有语义

    func testNextPreviousAndPlayPauseCommands() throws {
        let context = try makeContext()
        defer { tearDown(context) }

        var nextCount = 0
        var previousCount = 0
        context.router.onNextRequested = { nextCount += 1 }
        context.router.onPreviousRequested = { previousCount += 1 }

        context.router.handleMediaCommand(.next)
        context.router.handleMediaCommand(.previous)
        XCTAssertEqual(nextCount, 1)
        XCTAssertEqual(previousCount, 1)

        // 没有播放内容时 play/pause/toggle 均安全忽略
        context.router.handleMediaCommand(.pause)
        XCTAssertEqual(context.router.status, .stopped)
        context.router.handleMediaCommand(.play)
        XCTAssertEqual(context.router.status, .stopped)
        context.router.handleMediaCommand(.togglePlayPause)
        XCTAssertEqual(context.router.status, .stopped)
    }
}
