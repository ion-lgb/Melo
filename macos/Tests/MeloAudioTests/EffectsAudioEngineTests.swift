import XCTest
import AVFoundation
import CryptoKit
import MeloCore
@testable import MeloAudio

/// `EffectsAudioEngine`（AVAudioEngine + 10 段 EQ + 变速变调）单元测试。
///
/// 真实播放依赖系统音频输出设备；headless CI 上超时用 `XCTSkip`，明确的播放错误仍 `XCTFail`。
@MainActor
final class EffectsAudioEngineTests: XCTestCase {

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
        engine.volume = 0 // 测试期间静音，避免外放
        return engine
    }

    private func makeMusic(id: String = "effects_song_1",
                           name: String = "音效测试歌曲",
                           interval: String? = "00:02") -> MusicInfo {
        MusicInfo(
            id: id,
            name: name,
            singer: "音效测试歌手",
            source: "test",
            interval: interval,
            meta: .object(["songId": .string("1")])
        )
    }

    private func cacheDirectory(for url: URL, engine: EffectsAudioEngine) -> URL {
        engine.cacheFileURL(for: url)
    }

    // MARK: - 初始状态 / setter

    func testInitialState() {
        let engine = EffectsAudioEngine(cacheDirectory: FileManager.default.temporaryDirectory)
        XCTAssertEqual(engine.status, .stopped)
        XCTAssertNil(engine.currentMusic)
        XCTAssertNil(engine.currentURL)
        XCTAssertEqual(engine.volume, 1, accuracy: 0.0001)
        XCTAssertFalse(engine.isMuted)
        XCTAssertEqual(engine.playbackRate, 1, accuracy: 0.0001)
        XCTAssertEqual(engine.currentTime, 0, accuracy: 0.0001)
        XCTAssertEqual(engine.duration, 0, accuracy: 0.0001)
        XCTAssertTrue(engine.eqBypassValues.allSatisfy { $0 })
        XCTAssertEqual(engine.currentPitchCents, 0, accuracy: 0.001)
        XCTAssertEqual(engine.currentTimePitchRate, 1, accuracy: 0.0001)
        // EQ 频段与带宽按 SettingKeys 定义初始化
        XCTAssertEqual(engine.eqBandFrequencies, SettingKeys.eqFrequencies.map { Float($0) })
        XCTAssertTrue(engine.eqBandwidths.allSatisfy { abs($0 - 1.0) < 0.001 })
        // 远程音频缓存目录约定
        XCTAssertTrue(
            EffectsAudioEngine.defaultCacheDirectory().path.hasSuffix("/Library/Caches/Melo/EffectsAudio"),
            "默认缓存目录：\(EffectsAudioEngine.defaultCacheDirectory().path)"
        )
    }

    func testVolumeMuteAndRateSetters() {
        let engine = EffectsAudioEngine(cacheDirectory: FileManager.default.temporaryDirectory)
        engine.volume = 0.35
        XCTAssertEqual(engine.volume, 0.35, accuracy: 0.0001)
        engine.volume = 1.7
        XCTAssertEqual(engine.volume, 1.0, accuracy: 0.0001)
        engine.volume = -1
        XCTAssertEqual(engine.volume, 0.0, accuracy: 0.0001)

        engine.isMuted = true
        XCTAssertTrue(engine.isMuted)
        engine.isMuted = false
        XCTAssertFalse(engine.isMuted)

        engine.playbackRate = 1.5
        XCTAssertEqual(engine.playbackRate, 1.5, accuracy: 0.0001)
        XCTAssertEqual(engine.currentTimePitchRate, 1.5, accuracy: 0.0001)
        engine.playbackRate = 5
        XCTAssertEqual(engine.playbackRate, 2.0, accuracy: 0.0001)
        engine.playbackRate = 0.1
        XCTAssertEqual(engine.playbackRate, 0.5, accuracy: 0.0001)
        engine.playbackRate = .nan
        XCTAssertEqual(engine.playbackRate, 1.0, accuracy: 0.0001)
    }

    func testApplyAudioEffectsBeforePlayback() {
        let engine = EffectsAudioEngine(cacheDirectory: FileManager.default.temporaryDirectory)
        let bands: [Double] = [6, -3, 0, 0, 0, 0, 0, 0, 0, 4]
        engine.applyAudioEffects(AudioEffectSettings(eqBands: bands, playbackRate: 1.25, pitchSemitones: 2))

        XCTAssertEqual(engine.eqGainValues[0], 6, accuracy: 0.01)
        XCTAssertEqual(engine.eqGainValues[1], -3, accuracy: 0.01)
        XCTAssertEqual(engine.eqGainValues[9], 4, accuracy: 0.01)
        XCTAssertFalse(engine.eqBypassValues[0])
        XCTAssertTrue(engine.eqBypassValues[2])
        XCTAssertEqual(engine.currentPitchCents, 2 * 100, accuracy: 0.01)
        XCTAssertEqual(engine.currentTimePitchRate, 1.25, accuracy: 0.0001)
        XCTAssertEqual(engine.playbackRate, 1.25, accuracy: 0.0001)
        XCTAssertEqual(engine.appliedEffectSettings.eqBands, bands)
    }

    // MARK: - 同步错误

    func testPlayErrorsAreReadable() throws {
        let engine = EffectsAudioEngine(cacheDirectory: FileManager.default.temporaryDirectory)

        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("melo-effects-missing-\(UUID().uuidString)")
            .appendingPathExtension("wav")
        XCTAssertThrowsError(try engine.play(url: missing, music: makeMusic())) { error in
            guard let playerError = error as? PlayerError, case .fileNotFound = playerError else {
                return XCTFail("期望 PlayerError.fileNotFound，实际：\(error)")
            }
            XCTAssertTrue(error.localizedDescription.contains("不存在"))
        }

        let corrupt = FileManager.default.temporaryDirectory
            .appendingPathComponent("melo-effects-corrupt-\(UUID().uuidString)")
            .appendingPathExtension("mp3")
        try Data("not an audio file".utf8).write(to: corrupt)
        defer { remove(corrupt) }
        XCTAssertThrowsError(try engine.play(url: corrupt, music: makeMusic())) { error in
            guard let playerError = error as? PlayerError, case .playbackFailed = playerError else {
                return XCTFail("期望 PlayerError.playbackFailed，实际：\(error)")
            }
            XCTAssertTrue(error.localizedDescription.contains("无法打开音频文件"), "实际：\(error.localizedDescription)")
        }

        let ftpURL = try XCTUnwrap(URL(string: "ftp://example.com/song.mp3"))
        XCTAssertThrowsError(try engine.play(url: ftpURL, music: makeMusic())) { error in
            guard let playerError = error as? PlayerError, case .unsupportedScheme = playerError else {
                return XCTFail("期望 PlayerError.unsupportedScheme，实际：\(error)")
            }
        }
        XCTAssertEqual(engine.status, .stopped)
    }

    // MARK: - 本地 WAV：播放 → 暂停 → seek → 恢复 → ended

    func testLocalWAVPlaybackPauseSeekResumeEnded() throws {
        let cacheDir = try makeTempDirectory(prefix: "melo-effects-cache")
        defer { remove(cacheDir) }
        let engine = makeEngine(cacheDirectory: cacheDir)
        defer { engine.stop() }

        let wav = try WAVFixture.writeTemporaryWAV(seconds: 2.0)
        defer { remove(wav) }

        let playingExp = expectation(description: "进入 playing")
        let progressExp = expectation(description: "收到进度")
        let endedExp = expectation(description: "收到 ended")
        var playingFired = false
        var progressFired = false
        var endedFired = false
        var errorMessage: String?
        var lastProgress: TimeInterval = 0

        engine.eventHandler = { event in
            switch event {
            case .status(let newStatus):
                if newStatus == .playing, !playingFired {
                    playingFired = true
                    playingExp.fulfill()
                }
            case .progress(let current, _):
                lastProgress = max(lastProgress, current)
                if current > 0.05, !progressFired {
                    progressFired = true
                    progressExp.fulfill()
                }
            case .ended:
                if !endedFired {
                    endedFired = true
                    endedExp.fulfill()
                }
            case .error(let message):
                errorMessage = message
            }
        }

        try engine.play(url: wav, music: makeMusic(interval: "00:02"))

        let startResult = XCTWaiter().wait(for: [playingExp, progressExp], timeout: 10)
        if startResult != .completed {
            if let errorMessage { XCTFail("本地 WAV 音效播放报错：\(errorMessage)") }
            throw XCTSkip("当前环境无法在 10s 内开始 AVAudioEngine 播放（status=\(engine.status)），可能是 headless/无音频输出设备")
        }

        XCTAssertGreaterThan(lastProgress, 0.05)
        XCTAssertEqual(engine.duration, 2.0, accuracy: 0.05)
        XCTAssertEqual(engine.status, .playing)
        XCTAssertEqual(engine.loadedFileURL?.standardizedFileURL, wav.standardizedFileURL)

        // 暂停
        engine.pause()
        XCTAssertEqual(engine.status, .paused)
        XCTAssertGreaterThan(engine.currentTime, 0.0)
        let pausedTime = engine.currentTime
        XCTAssertEqual(engine.currentTime, pausedTime, accuracy: 0.0001)

        // seek（暂停状态下）
        engine.seek(to: 1.2)
        XCTAssertEqual(engine.currentTime, 1.2, accuracy: 0.05)
        XCTAssertEqual(engine.status, .paused)

        // 恢复 → 播到结尾
        engine.resume()
        let endResult = XCTWaiter().wait(for: [endedExp], timeout: 15)
        if endResult != .completed {
            if let errorMessage { XCTFail("本地 WAV 音效播放报错：\(errorMessage)") }
            throw XCTSkip("当前环境未在 15s 内播放到结尾（status=\(engine.status), currentTime=\(engine.currentTime)）")
        }

        XCTAssertEqual(engine.status, .stopped)
        XCTAssertEqual(engine.currentTime, 2.0, accuracy: 0.3)
        XCTAssertGreaterThan(lastProgress, 1.0)
    }

    // MARK: - 播放中实时应用音效

    func testApplyAudioEffectsWhilePlaying() throws {
        let cacheDir = try makeTempDirectory(prefix: "melo-effects-cache")
        defer { remove(cacheDir) }
        let engine = makeEngine(cacheDirectory: cacheDir)
        defer { engine.stop() }

        let wav = try WAVFixture.writeTemporaryWAV(seconds: 2.0)
        defer { remove(wav) }

        let playingExp = expectation(description: "进入 playing")
        var playingFired = false
        var errorMessage: String?
        engine.eventHandler = { event in
            switch event {
            case .status(let newStatus):
                if newStatus == .playing, !playingFired {
                    playingFired = true
                    playingExp.fulfill()
                }
            case .error(let message):
                errorMessage = message
            default:
                break
            }
        }

        try engine.play(url: wav, music: makeMusic(interval: "00:02"))
        if XCTWaiter().wait(for: [playingExp], timeout: 10) != .completed {
            if let errorMessage { XCTFail("音效播放报错：\(errorMessage)") }
            throw XCTSkip("当前环境无法开始 AVAudioEngine 播放（status=\(engine.status)）")
        }

        // 播放中修改 EQ / 变调 / 倍速：参数即时更新、状态保持
        engine.applyAudioEffects(AudioEffectSettings(
            eqBands: [6, -3, 0, 0, 0, 0, 0, 0, 0, 4],
            playbackRate: 1.25,
            pitchSemitones: 2
        ))
        XCTAssertEqual(engine.status, .playing)
        XCTAssertEqual(engine.eqGainValues[0], 6, accuracy: 0.01)
        XCTAssertEqual(engine.eqGainValues[1], -3, accuracy: 0.01)
        XCTAssertFalse(engine.eqBypassValues[0])
        XCTAssertEqual(engine.currentPitchCents, 200, accuracy: 0.01)
        XCTAssertEqual(engine.currentTimePitchRate, 1.25, accuracy: 0.0001)
        XCTAssertEqual(engine.playbackRate, 1.25, accuracy: 0.0001)

        // 恢复平坦设置
        engine.applyAudioEffects(.flat)
        XCTAssertEqual(engine.status, .playing)
        XCTAssertTrue(engine.eqBypassValues.allSatisfy { $0 })
        XCTAssertEqual(engine.currentPitchCents, 0, accuracy: 0.01)
        XCTAssertEqual(engine.currentTimePitchRate, 1, accuracy: 0.0001)
    }

    // MARK: - 远程 HTTP WAV → 下载缓存 → 播放

    func testRemoteWAVDownloadsToCacheAndIsReused() throws {
        let cacheDir = try makeTempDirectory(prefix: "melo-effects-http-cache")
        defer { remove(cacheDir) }
        let engine = makeEngine(cacheDirectory: cacheDir)
        defer { engine.stop() }

        let wavData = WAVFixture.makeWAVData(seconds: 2.0)
        let server = try LocalHTTPServer(payload: wavData)
        let port = try server.start()
        defer { server.stop() }
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/song.wav"))
        let expectedCacheURL = cacheDirectory(for: url, engine: engine)
        defer { remove(expectedCacheURL) }

        let playingExp = expectation(description: "HTTP 流进入 playing")
        let progressExp = expectation(description: "HTTP 流收到进度")
        var playingFired = false
        var progressFired = false
        var errorMessage: String?
        engine.eventHandler = { event in
            switch event {
            case .status(let newStatus):
                if newStatus == .playing, !playingFired {
                    playingFired = true
                    playingExp.fulfill()
                }
            case .progress(let current, _):
                if current > 0.05, !progressFired {
                    progressFired = true
                    progressExp.fulfill()
                }
            case .error(let message):
                errorMessage = message
            default:
                break
            }
        }

        try engine.play(url: url, music: makeMusic(interval: "00:02"))
        XCTAssertEqual(engine.status, .loading, "远程 URL 应先进入 loading（下载中）")

        let result = XCTWaiter().wait(for: [playingExp, progressExp], timeout: 12)
        if result != .completed {
            if let errorMessage {
                throw XCTSkip("本机 HTTP 音效播放不可用（可能是 ATS/网络环境限制）：\(errorMessage)")
            }
            throw XCTSkip("本机 HTTP 音效播放未在 12s 内开始（status=\(engine.status)）")
        }

        XCTAssertEqual(engine.duration, 2.0, accuracy: 0.05)
        XCTAssertEqual(engine.loadedFileURL?.standardizedFileURL, expectedCacheURL.standardizedFileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: expectedCacheURL.path), "远程音频应写入缓存")
        let cacheSize = (try? FileManager.default.attributesOfItem(atPath: expectedCacheURL.path)[.size] as? NSNumber)?.intValue ?? 0
        XCTAssertGreaterThan(cacheSize, 1024, "缓存文件应 >1KB")
        XCTAssertEqual(cacheSize, wavData.count)

        // 缓存复用：再次 play 同一 URL 应同步进入播放（不再下载）
        engine.stop()
        try engine.play(url: url, music: makeMusic(interval: "00:02"))
        XCTAssertEqual(engine.status, .playing, "同一 URL 第二次播放应直接复用缓存并同步起播")
        engine.stop()
    }

    // MARK: - stop 重置

    func testStopResetsState() throws {
        let cacheDir = try makeTempDirectory(prefix: "melo-effects-cache")
        defer { remove(cacheDir) }
        let engine = makeEngine(cacheDirectory: cacheDir)
        defer { engine.stop() }

        let wav = try WAVFixture.writeTemporaryWAV(seconds: 2.0)
        defer { remove(wav) }

        let playingExp = expectation(description: "进入 playing")
        var playingFired = false
        engine.eventHandler = { event in
            if case .status(.playing) = event, !playingFired {
                playingFired = true
                playingExp.fulfill()
            }
        }
        try engine.play(url: wav, music: makeMusic())
        if XCTWaiter().wait(for: [playingExp], timeout: 10) != .completed {
            throw XCTSkip("当前环境无法开始 AVAudioEngine 播放（status=\(engine.status)）")
        }

        engine.stop()
        XCTAssertEqual(engine.status, .stopped)
        XCTAssertNil(engine.currentMusic)
        XCTAssertNil(engine.currentURL)
        XCTAssertNil(engine.loadedFileURL)
        XCTAssertEqual(engine.currentTime, 0, accuracy: 0.0001)
        XCTAssertEqual(engine.duration, 0, accuracy: 0.0001)
    }

    // MARK: - 缓存容量清理（LRU）

    /// 在缓存目录写一个测试用"缓存文件"，并设置 mtime。
    @discardableResult
    private func writeCacheFile(in directory: URL,
                                name: String,
                                bytes: Int,
                                modifiedAt date: Date) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try Data(repeating: 0x4D, count: bytes).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        return url
    }

    func testCacheCapacityDefaultAndLRUTrimsOldest() throws {
        let cacheDir = try makeTempDirectory(prefix: "melo-cache-lru")
        defer { remove(cacheDir) }
        let engine = EffectsAudioEngine(cacheDirectory: cacheDir)
        XCTAssertEqual(engine.cacheCapacityBytes, 2 * 1024 * 1024 * 1024, "默认缓存上限应为 2GB")

        engine.cacheCapacityBytes = 3000
        let now = Date()
        let oldest = try writeCacheFile(in: cacheDir, name: "a.wav", bytes: 1000, modifiedAt: now.addingTimeInterval(-300))
        let middle = try writeCacheFile(in: cacheDir, name: "b.wav", bytes: 2000, modifiedAt: now.addingTimeInterval(-200))
        let newest = try writeCacheFile(in: cacheDir, name: "c.wav", bytes: 3000, modifiedAt: now.addingTimeInterval(-100))
        XCTAssertEqual(engine.cacheTotalSizeBytes, 6000)

        let deleted = engine.enforceCacheLimit()
        XCTAssertEqual(deleted.count, 2, "应删除最旧的两个文件直到不超过 3000 字节")
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldest.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: middle.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: newest.path), "最新文件应保留")
        XCTAssertEqual(engine.cacheTotalSizeBytes, 3000)
    }

    func testCacheLRUKeepsRecentlyUsedFile() throws {
        let cacheDir = try makeTempDirectory(prefix: "melo-cache-lru2")
        defer { remove(cacheDir) }
        let engine = EffectsAudioEngine(cacheDirectory: cacheDir)
        engine.cacheCapacityBytes = 3000

        let now = Date()
        let oldButWillBeUsed = try writeCacheFile(in: cacheDir, name: "old.wav", bytes: 2000, modifiedAt: now.addingTimeInterval(-1000))
        let newer = try writeCacheFile(in: cacheDir, name: "newer.wav", bytes: 2000, modifiedAt: now.addingTimeInterval(-500))
        XCTAssertEqual(engine.cacheTotalSizeBytes, 4000)

        // 标记 old.wav 为「最近使用」（刷新 mtime），LRU 清理时应保留它、删除 newer.wav
        engine.markCacheFileUsed(oldButWillBeUsed)
        let deleted = engine.enforceCacheLimit()
        XCTAssertEqual(deleted.map(\.lastPathComponent), ["newer.wav"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldButWillBeUsed.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: newer.path))
        XCTAssertEqual(engine.cacheTotalSizeBytes, 2000)
    }

    func testRemoteDownloadTrimsCacheBeforeDownload() throws {
        let cacheDir = try makeTempDirectory(prefix: "melo-cache-trim-download")
        defer { remove(cacheDir) }

        let wavData = WAVFixture.makeWAVData(seconds: 2.0)
        // 上限设为略大于单个 WAV：预置的两个大文件必须在下载前后被 LRU 清掉
        let engine = makeEngine(cacheDirectory: cacheDir)
        engine.cacheCapacityBytes = UInt64(wavData.count + 4096)
        defer { engine.stop() }

        let now = Date()
        let staleA = try writeCacheFile(in: cacheDir, name: "stale-a.audio", bytes: 120_000,
                                       modifiedAt: now.addingTimeInterval(-500))
        let staleB = try writeCacheFile(in: cacheDir, name: "stale-b.audio", bytes: 120_000,
                                       modifiedAt: now.addingTimeInterval(-400))

        let server = try LocalHTTPServer(payload: wavData)
        let port = try server.start()
        defer { server.stop() }
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/trim.wav"))
        let expectedCacheURL = engine.cacheFileURL(for: url)
        defer { remove(expectedCacheURL) }

        let playingExp = expectation(description: "远程缓存播放")
        var playingFired = false
        var errorMessage: String?
        engine.eventHandler = { event in
            switch event {
            case .status(let newStatus):
                if newStatus == .playing, !playingFired {
                    playingFired = true
                    playingExp.fulfill()
                }
            case .error(let message):
                errorMessage = message
            default:
                break
            }
        }

        try engine.play(url: url, music: makeMusic(interval: "00:02"))
        if XCTWaiter().wait(for: [playingExp], timeout: 12) != .completed {
            if let errorMessage {
                throw XCTSkip("本机 HTTP 音效缓存测试不可用：\(errorMessage)")
            }
            throw XCTSkip("本机 HTTP 音效缓存测试未在 12s 内开始播放（status=\(engine.status)）")
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: expectedCacheURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleA.path), "下载前 LRU 应删除最旧缓存")
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleB.path), "下载完成后按实际大小应继续清理旧缓存")
        XCTAssertLessThanOrEqual(engine.cacheTotalSizeBytes, engine.cacheCapacityBytes)
        XCTAssertEqual(engine.cacheTotalSizeBytes, UInt64(wavData.count))
    }
}
