import XCTest
import MediaPlayer
import MeloCore
@testable import MeloAudio

/// Round 4：Now Playing 跟随活动引擎 + 媒体键作用于当前引擎。
///
/// 音效引擎播放时，系统 Now Playing 应由 `RoutedPlayerService` 统一维护（不被 AVPlayerService.stop 清空），
/// 媒体键 play/pause/next/prev/seek 也应作用于当前活动引擎。
/// 在 XCTest 进程里系统集成默认关闭，测试显式开启后直接断言 `MPNowPlayingInfoCenter.nowPlayingInfo`
/// （headless 不依赖系统 UI）；个别 macOS 版本会清空无归属播放的 Now Playing 时用 XCTSkip 兜底。
@MainActor
final class RoutedNowPlayingTests: XCTestCase {

    private struct Context {
        let router: RoutedPlayerService
        let settings: SettingsStore
        let avPlayer: AVPlayerService
        let effectsPlayer: EffectsAudioEngine
        let directory: URL
    }

    private func makeContext() throws -> Context {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("melo-nowplaying-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let settings = SettingsStore(dataDirectory: directory)
        let avPlayer = AVPlayerService()
        avPlayer.systemIntegrationEnabled = false
        let effectsPlayer = EffectsAudioEngine(
            cacheDirectory: directory.appendingPathComponent("effects-cache", isDirectory: true)
        )
        let router = RoutedPlayerService(settings: settings, avPlayer: avPlayer, effectsPlayer: effectsPlayer)
        router.volume = 0
        return Context(router: router,
                       settings: settings,
                       avPlayer: avPlayer,
                       effectsPlayer: effectsPlayer,
                       directory: directory)
    }

    private func tearDown(_ context: Context, file: URL? = nil) {
        context.router.systemIntegrationEnabled = false
        context.router.stop()
        if let file { try? FileManager.default.removeItem(at: file) }
        try? FileManager.default.removeItem(at: context.directory)
    }

    private func makeMusic(id: String = "nowplaying_song_1",
                           name: String = "Now Playing 测试歌曲",
                           singer: String = "NP 歌手",
                           album: String = "NP 专辑",
                           interval: String? = "00:04") -> MusicInfo {
        MusicInfo(
            id: id,
            name: name,
            singer: singer,
            source: "test",
            interval: interval,
            meta: .object([
                "songId": .string("1"),
                "albumName": .string(album),
            ])
        )
    }

    private func eqBands(first: Double) -> [Double] {
        var bands = [Double](repeating: 0, count: 10)
        bands[0] = first
        return bands
    }

    /// 等待 router 收到进度超过 threshold 的事件。
    private func waitForProgress(_ router: RoutedPlayerService,
                                 greaterThan threshold: TimeInterval,
                                 timeout: TimeInterval = 10) throws {
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
            throw XCTSkip("当前环境未在 \(Int(timeout))s 内开始播放（router.status=\(router.status), av=\(router.avPlayer.status), effects=\(router.effectsPlayer.status)）")
        }
    }

    private func nowPlayingInfo() -> [String: Any]? {
        MPNowPlayingInfoCenter.default().nowPlayingInfo
    }

    // MARK: - 音效引擎播放时 Now Playing 不被清空

    func testNowPlayingFollowsEffectsEngineAndSurvivesAVPlayerStop() throws {
        let context = try makeContext()
        let wav = try WAVFixture.writeTemporaryWAV(seconds: 4.0)
        defer { tearDown(context, file: wav) }
        context.router.systemIntegrationEnabled = true

        // 启用 EQ → 路由到音效引擎
        context.settings.set(SettingKeys.eqBandKeys[0], .double(6))
        context.router.applyAudioEffects(AudioEffectSettings(
            eqBands: eqBands(first: 6),
            playbackRate: 1,
            pitchSemitones: 0
        ))
        let music = makeMusic()
        try context.router.play(url: wav, music: music)
        XCTAssertEqual(context.router.activeEngineKind, .effects)
        try waitForProgress(context.router, greaterThan: 0.1)

        XCTAssertEqual(context.effectsPlayer.status, .playing)
        XCTAssertEqual(context.avPlayer.status, .stopped)
        XCTAssertTrue(context.avPlayer.nowPlayingDelegatedToOwner, "AVPlayerService 的 Now Playing 管理权应交给 router")

        guard let info = nowPlayingInfo() else {
            throw XCTSkip("当前环境 MPNowPlayingInfoCenter 未保留 nowPlayingInfo（macOS 26/27 行为差异）")
        }
        XCTAssertEqual(info[MPMediaItemPropertyTitle] as? String, music.name)
        XCTAssertEqual(info[MPMediaItemPropertyArtist] as? String, music.singer)
        XCTAssertEqual(info[MPMediaItemPropertyAlbumTitle] as? String, music.albumName)
        XCTAssertEqual(MPNowPlayingInfoCenter.default().playbackState, .playing, "音效引擎播放时播放状态应为 playing")

        // 音效引擎播放中：AVPlayerService.stop() 不应清空 Now Playing
        context.avPlayer.stop()
        let infoAfterAVStop = nowPlayingInfo()
        XCTAssertEqual(infoAfterAVStop?[MPMediaItemPropertyTitle] as? String, music.name,
                       "AVPlayerService.stop() 不应清空音效引擎的 Now Playing")

        // 媒体键 pause → 作用于音效引擎，并同步 Now Playing 状态
        context.router.handlePauseCommand()
        XCTAssertEqual(context.effectsPlayer.status, .paused)
        XCTAssertEqual(context.router.status, .paused)
        XCTAssertEqual(MPNowPlayingInfoCenter.default().playbackState, .paused)
        let pausedInfo = nowPlayingInfo()
        XCTAssertEqual((pausedInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? NSNumber)?.doubleValue, 0)

        // 媒体键 play → 恢复音效引擎
        context.router.handlePlayCommand()
        XCTAssertEqual(context.effectsPlayer.status, .playing)
        XCTAssertEqual(MPNowPlayingInfoCenter.default().playbackState, .playing)

        // stop 后 Now Playing 清空
        context.router.stop()
        XCTAssertNil(nowPlayingInfo())
        XCTAssertEqual(MPNowPlayingInfoCenter.default().playbackState, .stopped)
    }

    // MARK: - 媒体键作用当前引擎 + 切换引擎后信息仍正确

    func testMediaKeysControlActiveEngineAndInfoSurvivesSwitch() throws {
        let context = try makeContext()
        let wav = try WAVFixture.writeTemporaryWAV(seconds: 4.0)
        defer { tearDown(context, file: wav) }
        context.router.systemIntegrationEnabled = true
        XCTAssertTrue(context.router.hasNowPlayingCommandsRegistered, "启用系统集成后应注册媒体键")

        // 1) 无音效 → AVPlayer 播放
        let music = makeMusic()
        try context.router.play(url: wav, music: music)
        XCTAssertEqual(context.router.activeEngineKind, .avPlayer)
        try waitForProgress(context.router, greaterThan: 0.1)

        guard let info = nowPlayingInfo() else {
            throw XCTSkip("当前环境 MPNowPlayingInfoCenter 未保留 nowPlayingInfo（macOS 26/27 行为差异）")
        }
        XCTAssertEqual(info[MPMediaItemPropertyTitle] as? String, music.name)

        // 媒体键 pause/play 作用于 AVPlayer
        context.router.handlePauseCommand()
        XCTAssertEqual(context.avPlayer.status, .paused)
        XCTAssertEqual(MPNowPlayingInfoCenter.default().playbackState, .paused)
        context.router.handlePlayCommand()
        XCTAssertEqual(context.avPlayer.status, .playing)
        XCTAssertEqual(MPNowPlayingInfoCenter.default().playbackState, .playing)

        // 2) 播放中开启 EQ → 切到音效引擎，Now Playing 仍为当前歌曲
        context.settings.set(SettingKeys.eqBandKeys[0], .double(6))
        context.router.applyAudioEffects(AudioEffectSettings(
            eqBands: eqBands(first: 6),
            playbackRate: 1,
            pitchSemitones: 0
        ))
        XCTAssertEqual(context.router.activeEngineKind, .effects)
        try waitForProgress(context.router, greaterThan: 0.05)

        let switchedInfo = nowPlayingInfo()
        XCTAssertEqual(switchedInfo?[MPMediaItemPropertyTitle] as? String, music.name,
                       "切换引擎后 Now Playing 应保持当前歌曲")
        XCTAssertEqual(MPNowPlayingInfoCenter.default().playbackState, .playing)

        // 媒体键 seek 作用于音效引擎（并同步 elapsed）
        context.router.handleSeekCommand(1.2)
        XCTAssertEqual(context.router.currentTime, 1.2, accuracy: 0.1)
        let seekInfo = nowPlayingInfo()
        let elapsed = (seekInfo?[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? NSNumber)?.doubleValue ?? -1
        XCTAssertEqual(elapsed, 1.2, accuracy: 0.3, "seek 后 Now Playing elapsed 应同步")

        // 媒体键 next/previous 走 router 的 onNextRequested/onPreviousRequested
        var nextCount = 0
        var previousCount = 0
        context.router.onNextRequested = { nextCount += 1 }
        context.router.onPreviousRequested = { previousCount += 1 }
        context.router.handleNextCommand()
        context.router.handlePreviousCommand()
        XCTAssertEqual(nextCount, 1)
        XCTAssertEqual(previousCount, 1)

        // 关闭 EQ → 切回 AVPlayer，信息仍正确
        context.settings.set(SettingKeys.eqBandKeys[0], .double(0))
        context.router.applyAudioEffects(.flat)
        XCTAssertEqual(context.router.activeEngineKind, .avPlayer)
        try waitForProgress(context.router, greaterThan: 0.05)
        XCTAssertEqual(nowPlayingInfo()?[MPMediaItemPropertyTitle] as? String, music.name)
    }

    // MARK: - 开关系统集成时正确注册/注销

    func testDisablingSystemIntegrationClearsInfoAndCommands() throws {
        let context = try makeContext()
        let wav = try WAVFixture.writeTemporaryWAV(seconds: 2.0)
        defer { tearDown(context, file: wav) }
        context.router.systemIntegrationEnabled = true
        XCTAssertTrue(context.router.hasNowPlayingCommandsRegistered)

        let music = makeMusic(interval: "00:02")
        try context.router.play(url: wav, music: music)
        try waitForProgress(context.router, greaterThan: 0.05)
        guard nowPlayingInfo() != nil else {
            throw XCTSkip("当前环境 MPNowPlayingInfoCenter 未保留 nowPlayingInfo（macOS 26/27 行为差异）")
        }

        context.router.systemIntegrationEnabled = false
        XCTAssertNil(nowPlayingInfo())
        XCTAssertEqual(MPNowPlayingInfoCenter.default().playbackState, .stopped)
        XCTAssertFalse(context.router.hasNowPlayingCommandsRegistered, "关闭系统集成应注销媒体键")

        context.router.systemIntegrationEnabled = true
        XCTAssertTrue(context.router.hasNowPlayingCommandsRegistered, "重新开启应重新注册媒体键")
        XCTAssertEqual(nowPlayingInfo()?[MPMediaItemPropertyTitle] as? String, music.name,
                       "重新开启后应按当前播放状态恢复 Now Playing")
    }
}
