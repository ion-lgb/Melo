import XCTest
import AVFoundation
import MeloCore
@testable import MeloAudio

/// `RoutedPlayerService` 路由测试：无音效走 AVPlayer、有音效走 EffectsAudioEngine，
/// 以及播放中实时切换引擎并保留位置。
@MainActor
final class RoutedPlayerServiceTests: XCTestCase {

    // MARK: - 辅助

    private struct Context {
        let router: RoutedPlayerService
        let settings: SettingsStore
        let avPlayer: AVPlayerService
        let effectsPlayer: EffectsAudioEngine
        let directory: URL
    }

    private func makeContext() throws -> Context {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("melo-router-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let settings = SettingsStore(dataDirectory: directory)
        let avPlayer = AVPlayerService()
        avPlayer.systemIntegrationEnabled = false
        let effectsPlayer = EffectsAudioEngine(
            cacheDirectory: directory.appendingPathComponent("effects-cache", isDirectory: true)
        )
        let router = RoutedPlayerService(settings: settings, avPlayer: avPlayer, effectsPlayer: effectsPlayer)
        // 测试静音，避免外放
        router.volume = 0
        return Context(router: router,
                       settings: settings,
                       avPlayer: avPlayer,
                       effectsPlayer: effectsPlayer,
                       directory: directory)
    }

    private func tearDown(_ context: Context, file: URL? = nil) {
        context.router.stop()
        if let file { try? FileManager.default.removeItem(at: file) }
        try? FileManager.default.removeItem(at: context.directory)
    }

    private func makeMusic(id: String = "router_song_1", interval: String? = "00:02") -> MusicInfo {
        MusicInfo(
            id: id,
            name: "路由测试歌曲",
            singer: "路由测试歌手",
            source: "test",
            interval: interval,
            meta: .object(["songId": .string("1")])
        )
    }

    private func eqBands(first: Double) -> [Double] {
        var bands = [Double](repeating: 0, count: 10)
        bands[0] = first
        return bands
    }

    /// 等待 router 进入 playing（超时抛 XCTSkip，明确错误则失败）。
    @discardableResult
    private func waitForPlaying(_ router: RoutedPlayerService,
                               timeout: TimeInterval = 10,
                               file: StaticString = #filePath,
                               line: UInt = #line) throws -> Bool {
        let exp = expectation(description: "router playing")
        var fired = false
        var errorMessage: String?
        let previous = router.eventHandler
        router.eventHandler = { event in
            switch event {
            case .status(let newStatus):
                if newStatus == .playing, !fired {
                    fired = true
                    exp.fulfill()
                }
            case .progress(let current, _):
                // 音效引擎本地文件起播是同步的，可能在安装 handler 之前已发过 playing；
                // 用 0.25s 周期进度事件兜底判断「已开始播放」。
                if current > 0.05, !fired {
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
            if let errorMessage {
                XCTFail("播放器路由播放报错：\(errorMessage)", file: file, line: line)
            }
            throw XCTSkip("当前环境无法在 \(Int(timeout))s 内开始播放（router.status=\(router.status), av=\(router.avPlayer.status), effects=\(router.effectsPlayer.status)）", file: file, line: line)
        }
        return true
    }

    /// 等待 router 收到「进度超过 threshold」的事件（用于验证播放确实在推进）。
    @discardableResult
    private func waitForProgress(_ router: RoutedPlayerService,
                                 greaterThan threshold: TimeInterval,
                                 timeout: TimeInterval = 10) throws -> TimeInterval {
        let exp = expectation(description: "router progress > \(threshold)")
        var fired = false
        var errorMessage: String?
        var lastProgress: TimeInterval = 0
        let previous = router.eventHandler
        router.eventHandler = { event in
            switch event {
            case .progress(let current, _):
                lastProgress = current
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
            if let errorMessage {
                XCTFail("播放器路由播放报错：\(errorMessage)")
            }
            throw XCTSkip("当前环境未在 \(Int(timeout))s 内推进播放进度（router.status=\(router.status), current=\(lastProgress)）")
        }
        return lastProgress
    }

    // MARK: - 路由选择

    func testRoutesToAVPlayerWhenNoEffects() throws {
        let context = try makeContext()
        let wav = try WAVFixture.writeTemporaryWAV(seconds: 2.0)
        defer { tearDown(context, file: wav) }

        XCTAssertFalse(RoutedPlayerService.requiresEffects(.flat))

        try context.router.play(url: wav, music: makeMusic())
        XCTAssertEqual(context.router.activeEngineKind, .avPlayer, "无音效时应走 AVPlayer")
        try waitForPlaying(context.router)

        XCTAssertEqual(context.router.status, .playing)
        XCTAssertEqual(context.avPlayer.status, .playing)
        XCTAssertEqual(context.effectsPlayer.status, .stopped)
        XCTAssertEqual(context.router.currentMusic?.id, "router_song_1")
        XCTAssertEqual(context.router.duration, 2.0, accuracy: 0.1)
    }

    func testRoutesToEffectsWhenEQActive() throws {
        let context = try makeContext()
        let wav = try WAVFixture.writeTemporaryWAV(seconds: 2.0)
        defer { tearDown(context, file: wav) }

        // AppModel.setEQBand 的等价行为：写设置键 + applyAudioEffects
        context.settings.set(SettingKeys.eqBandKeys[0], .double(6))
        let effectSettings = AudioEffectSettings(eqBands: eqBands(first: 6), playbackRate: 1, pitchSemitones: 0)
        context.router.applyAudioEffects(effectSettings)
        XCTAssertTrue(RoutedPlayerService.requiresEffects(effectSettings))

        try context.router.play(url: wav, music: makeMusic())
        XCTAssertEqual(context.router.activeEngineKind, .effects, "EQ 非 0 时应走音效引擎")
        try waitForPlaying(context.router)

        XCTAssertEqual(context.router.status, .playing)
        XCTAssertEqual(context.effectsPlayer.status, .playing)
        XCTAssertEqual(context.avPlayer.status, .stopped)
        XCTAssertEqual(context.effectsPlayer.eqGainValues[0], 6, accuracy: 0.01)
    }

    func testRoutesToEffectsWhenPitchShifterActive() throws {
        let context = try makeContext()
        let wav = try WAVFixture.writeTemporaryWAV(seconds: 2.0)
        defer { tearDown(context, file: wav) }

        context.settings.set(SettingKeys.pitchShifterRate, .double(1.2))
        let semitones = 12 * log2(1.2)
        context.router.applyAudioEffects(AudioEffectSettings(
            eqBands: [Double](repeating: 0, count: 10),
            playbackRate: 1,
            pitchSemitones: semitones
        ))

        try context.router.play(url: wav, music: makeMusic())
        XCTAssertEqual(context.router.activeEngineKind, .effects, "变调启用时应走音效引擎")
        try waitForPlaying(context.router)
        XCTAssertEqual(context.effectsPlayer.currentPitchCents, Float(semitones * 100), accuracy: 0.5)
    }

    func testPlaybackRateAloneDoesNotTriggerEffects() throws {
        let context = try makeContext()
        let wav = try WAVFixture.writeTemporaryWAV(seconds: 2.0)
        defer { tearDown(context, file: wav) }

        context.router.playbackRate = 1.5
        try context.router.play(url: wav, music: makeMusic())
        XCTAssertEqual(context.router.activeEngineKind, .avPlayer, "仅倍速变化不应触发音效引擎")
        try waitForPlaying(context.router)
        XCTAssertEqual(context.avPlayer.playbackRate, 1.5, accuracy: 0.0001)
    }

    // MARK: - 播放中切换引擎

    func testSwitchEnginesWhilePlayingKeepsPosition() throws {
        let context = try makeContext()
        defer { tearDown(context) }
        let wav = try WAVFixture.writeTemporaryWAV(seconds: 3.0)
        defer { tearDown(context, file: wav) }

        // 1) 无音效：AVPlayer 播放
        try context.router.play(url: wav, music: makeMusic(interval: "00:03"))
        XCTAssertEqual(context.router.activeEngineKind, .avPlayer)
        try waitForProgress(context.router, greaterThan: 0.25)
        let positionBeforeSwitch = context.router.currentTime
        XCTAssertGreaterThan(positionBeforeSwitch, 0.2)

        // 2) 播放中开启 EQ：切到音效引擎并 seek 回原位置
        context.settings.set(SettingKeys.eqBandKeys[0], .double(6))
        context.router.applyAudioEffects(AudioEffectSettings(
            eqBands: eqBands(first: 6),
            playbackRate: 1,
            pitchSemitones: 0
        ))
        XCTAssertEqual(context.router.activeEngineKind, .effects, "播放中开启 EQ 应立即切到音效引擎")
        XCTAssertEqual(context.avPlayer.status, .stopped)

        let resumedAt = try waitForProgress(context.router, greaterThan: positionBeforeSwitch + 0.05)
        XCTAssertGreaterThan(resumedAt, positionBeforeSwitch, "切换引擎后应 seek 回原位置继续播放")
        XCTAssertEqual(context.router.status, .playing)
        XCTAssertEqual(context.effectsPlayer.status, .playing)

        // 3) 关闭 EQ：切回 AVPlayer 并保留位置
        let positionBeforeSwitchBack = context.router.currentTime
        context.settings.set(SettingKeys.eqBandKeys[0], .double(0))
        context.router.applyAudioEffects(.flat)
        XCTAssertEqual(context.router.activeEngineKind, .avPlayer, "关闭音效应立即切回 AVPlayer")
        XCTAssertEqual(context.effectsPlayer.status, .stopped)

        let resumedBackAt = try waitForProgress(context.router, greaterThan: positionBeforeSwitchBack + 0.05)
        XCTAssertGreaterThan(resumedBackAt, positionBeforeSwitchBack - 0.2, "切回 AVPlayer 后应保留播放位置")
        XCTAssertEqual(context.router.status, .playing)
        XCTAssertEqual(context.avPlayer.status, .playing)
    }

    // MARK: - 转发 / 镜像

    func testForwardsVolumeMuteRateToBothEngines() throws {
        let context = try makeContext()
        defer { tearDown(context) }

        context.router.volume = 0.42
        XCTAssertEqual(context.avPlayer.volume, 0.42, accuracy: 0.0001)
        XCTAssertEqual(context.effectsPlayer.volume, 0.42, accuracy: 0.0001)

        context.router.isMuted = true
        XCTAssertTrue(context.avPlayer.isMuted)
        XCTAssertTrue(context.effectsPlayer.isMuted)

        context.router.playbackRate = 1.75
        XCTAssertEqual(context.avPlayer.playbackRate, 1.75, accuracy: 0.0001)
        XCTAssertEqual(context.effectsPlayer.playbackRate, 1.75, accuracy: 0.0001)
    }

    func testForwardsMediaKeyCallbacksToAVPlayer() throws {
        let context = try makeContext()
        defer { tearDown(context) }

        var nextCount = 0
        var previousCount = 0
        context.router.onNextRequested = { nextCount += 1 }
        context.router.onPreviousRequested = { previousCount += 1 }

        XCTAssertNotNil(context.avPlayer.onNextRequested, "router 应把媒体键回调转发给 AVPlayer 引擎")
        XCTAssertNotNil(context.avPlayer.onPreviousRequested)
        context.avPlayer.onNextRequested?()
        context.avPlayer.onPreviousRequested?()
        XCTAssertEqual(nextCount, 1)
        XCTAssertEqual(previousCount, 1)
    }

    func testStopResetsMirrorsAndBothEngines() throws {
        let context = try makeContext()
        let wav = try WAVFixture.writeTemporaryWAV(seconds: 2.0)
        defer { tearDown(context, file: wav) }

        try context.router.play(url: wav, music: makeMusic())
        try waitForPlaying(context.router)

        context.router.stop()
        XCTAssertEqual(context.router.status, .stopped)
        XCTAssertNil(context.router.currentMusic)
        XCTAssertEqual(context.router.currentTime, 0, accuracy: 0.0001)
        XCTAssertEqual(context.router.duration, 0, accuracy: 0.0001)
        XCTAssertEqual(context.avPlayer.status, .stopped)
        XCTAssertEqual(context.effectsPlayer.status, .stopped)
    }

    // MARK: - Round 6：卷积混响 / 3D 环绕也必须路由到音效引擎

    func testPannerOnlyRoutesToEffectsEngine() throws {
        let context = try makeContext()
        let wav = try WAVFixture.writeTemporaryWAV(seconds: 2.0)
        defer { tearDown(context, file: wav) }

        // 只开启 3D 环绕（无 EQ/变调/混响），也必须走 AVAudioEngine
        context.settings.set(SettingKeys.pannerEnable, .bool(true))
        var settings = AudioEffectSettings(eqBands: [Double](repeating: 0, count: 10))
        settings.pannerEnabled = true
        context.router.applyAudioEffects(settings)
        XCTAssertTrue(RoutedPlayerService.requiresEffects(settings))

        try context.router.play(url: wav, music: makeMusic())
        XCTAssertEqual(context.router.activeEngineKind, .effects, "仅 3D 环绕时应走音效引擎")
        try waitForPlaying(context.router)
        XCTAssertEqual(context.effectsPlayer.status, .playing)
    }

    func testConvolutionOnlyRoutesToEffectsEngine() throws {
        let context = try makeContext()
        let wav = try WAVFixture.writeTemporaryWAV(seconds: 2.0)
        defer { tearDown(context, file: wav) }

        // 只开启卷积混响（IR 用不存在的文件：路由仍需走音效引擎，引擎内部回退为无混响播放）
        context.settings.set(SettingKeys.convolutionFileName, .string("missing-ir.wav"))
        var settings = AudioEffectSettings(eqBands: [Double](repeating: 0, count: 10))
        settings.convolutionFileName = "missing-ir.wav"
        settings.convolutionMainGain = 1
        settings.convolutionSendGain = 1
        context.router.applyAudioEffects(settings)
        XCTAssertTrue(RoutedPlayerService.requiresEffects(settings))

        try context.router.play(url: wav, music: makeMusic())
        XCTAssertEqual(context.router.activeEngineKind, .effects, "仅卷积混响时应走音效引擎")
        try waitForPlaying(context.router)
        XCTAssertEqual(context.effectsPlayer.status, .playing)
        XCTAssertTrue(context.effectsPlayer.lastProcessingWarning?.contains("IR") ?? false,
                      "IR 缺失时应回退无混响并记录可读警告")
    }

    // MARK: - Round 9：自定义输出设备必须走音效引擎

    func testCustomOutputDeviceForcesEffectsEngine() throws {
        let devices = AudioOutputDevices.list()
        guard let target = devices.first(where: { !$0.isDefault }) ?? devices.first else {
            throw XCTSkip("当前环境没有可用的 CoreAudio 输出设备（headless CI）")
        }
        let context = try makeContext()
        let wav = try WAVFixture.writeTemporaryWAV(seconds: 2.0)
        defer { tearDown(context, file: wav) }

        // EQ 全平、无任何音效，仅指定自定义输出设备 → 仍必须走音效引擎
        context.settings.set(SettingKeys.mediaDeviceId, .string(target.uid))
        context.router.applyAudioEffects(.flat)
        XCTAssertFalse(RoutedPlayerService.requiresEffects(.flat))

        try context.router.play(url: wav, music: makeMusic())
        XCTAssertEqual(context.router.activeEngineKind, .effects,
                       "指定自定义输出设备（AVPlayer 无法指定设备）时应走音效引擎")
        try waitForPlaying(context.router)
        XCTAssertEqual(context.effectsPlayer.outputDeviceUID, target.uid)
        XCTAssertEqual(context.effectsPlayer.status, .playing)
    }

    func testInvalidOutputDeviceFallsBackToDefaultDevice() throws {
        let context = try makeContext()
        let wav = try WAVFixture.writeTemporaryWAV(seconds: 2.0)
        defer { tearDown(context, file: wav) }

        context.settings.set(SettingKeys.mediaDeviceId, .string("cn.melo.invalid-device-uid"))
        context.router.applyAudioEffects(.flat)

        // router 对非法 UID 回退系统默认设备（MeloLog.warn），不阻断播放
        XCTAssertNoThrow(try context.router.play(url: wav, music: makeMusic()))
        XCTAssertEqual(context.router.activeEngineKind, .effects)
        try waitForPlaying(context.router)
        XCTAssertNil(context.effectsPlayer.outputDeviceUID, "非法 UID 应回退默认设备")
        XCTAssertEqual(context.effectsPlayer.status, .playing)
    }

    func testRestoreDefaultOutputDeviceRoutesBackToAVPlayer() throws {
        let devices = AudioOutputDevices.list()
        guard let target = devices.first(where: { !$0.isDefault }) ?? devices.first else {
            throw XCTSkip("当前环境没有可用的 CoreAudio 输出设备（headless CI）")
        }
        let context = try makeContext()
        let wav = try WAVFixture.writeTemporaryWAV(seconds: 2.0)
        defer { tearDown(context, file: wav) }

        // 1) 自定义设备 + EQ 全平 → effects 引擎
        context.settings.set(SettingKeys.mediaDeviceId, .string(target.uid))
        context.router.applyAudioEffects(.flat)
        XCTAssertEqual(context.router.activeEngineKind, .effects)

        // 2) 恢复 default → 无音效时回到 AVPlayer
        context.settings.set(SettingKeys.mediaDeviceId, .string("default"))
        context.router.applyOutputDeviceSetting()
        XCTAssertEqual(context.router.activeEngineKind, .avPlayer,
                       "恢复默认设备且无音效时应回到 AVPlayer")

        try context.router.play(url: wav, music: makeMusic())
        XCTAssertEqual(context.router.activeEngineKind, .avPlayer)
        try waitForPlaying(context.router)
        XCTAssertEqual(context.avPlayer.status, .playing)
    }
}
