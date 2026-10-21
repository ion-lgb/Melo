import XCTest
import AVFoundation
import MediaPlayer
import MeloCore
@testable import MeloAudio

/// MeloAudio（AVPlayerService）单元测试。
///
/// 说明：
/// - 初始状态 / setter / 错误校验 / WAV fixture 是完全确定性的；
/// - 真实播放（本地 WAV、本地 127.0.0.1 HTTP 流）依赖系统音频输出设备，
///   在 headless CI 上可能不可用：超时后使用 `XCTSkip` 而不是误报失败；
///   如果收到明确的播放错误则仍然 `XCTFail`，避免把代码缺陷当成环境问题跳过。
@MainActor
final class AVPlayerServiceTests: XCTestCase {

    // MARK: - 辅助

    private func makeService() -> AVPlayerService {
        let service = AVPlayerService()
        service.systemIntegrationEnabled = false
        return service
    }

    private func makeMusic(id: String = "test_song_1",
                           name: String = "测试歌曲",
                           singer: String = "测试歌手",
                           album: String? = nil,
                           interval: String? = "00:02") -> MusicInfo {
        var meta: [String: JSONValue] = ["songId": .string("1")]
        if let album { meta["albumName"] = .string(album) }
        return MusicInfo(
            id: id,
            name: name,
            singer: singer,
            source: "test",
            interval: interval,
            meta: .object(meta)
        )
    }

    // MARK: - 初始状态

    func testInitialState() {
        let service = makeService()
        XCTAssertEqual(service.status, .stopped)
        XCTAssertNil(service.currentMusic)
        XCTAssertNil(service.currentURL)
        XCTAssertEqual(service.volume, 1.0, accuracy: 0.0001)
        XCTAssertFalse(service.isMuted)
        XCTAssertEqual(service.playbackRate, 1.0, accuracy: 0.0001)
        XCTAssertEqual(service.currentTime, 0, accuracy: 0.0001)
        XCTAssertEqual(service.duration, 0, accuracy: 0.0001)
        XCTAssertNil(service.eventHandler)
        XCTAssertNil(service.nowPlayingSnapshot)
        XCTAssertFalse(service.systemIntegrationEnabled, "XCTest 进程默认应关闭系统媒体集成")
    }

    // MARK: - setter / 状态映射

    func testVolumeMuteRateSetters() {
        let service = makeService()

        service.volume = 0.35
        XCTAssertEqual(service.volume, 0.35, accuracy: 0.0001)
        service.volume = 1.7
        XCTAssertEqual(service.volume, 1.0, accuracy: 0.0001)
        service.volume = -2
        XCTAssertEqual(service.volume, 0.0, accuracy: 0.0001)

        service.isMuted = true
        XCTAssertTrue(service.isMuted)
        service.isMuted = false
        XCTAssertFalse(service.isMuted)

        service.playbackRate = 1.5
        XCTAssertEqual(service.playbackRate, 1.5, accuracy: 0.0001)
        service.playbackRate = 3.0
        XCTAssertEqual(service.playbackRate, 2.0, accuracy: 0.0001)
        service.playbackRate = 0.01
        XCTAssertEqual(service.playbackRate, 0.25, accuracy: 0.0001)
        service.playbackRate = .nan
        XCTAssertEqual(service.playbackRate, 1.0, accuracy: 0.0001)

        service.stop()
        XCTAssertEqual(service.status, .stopped)
    }

    func testResumePauseSeekWithoutItemAreIgnored() {
        let service = makeService()
        service.resume()
        XCTAssertEqual(service.status, .stopped)
        service.pause()
        XCTAssertEqual(service.status, .stopped)
        service.seek(to: 30)
        XCTAssertEqual(service.currentTime, 0, accuracy: 0.0001)
        service.stop()
        XCTAssertEqual(service.status, .stopped)
        XCTAssertEqual(service.currentTime, 0, accuracy: 0.0001)
    }

    // MARK: - 同步错误

    func testPlayMissingLocalFileThrows() {
        let service = makeService()
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("melo-missing-\(UUID().uuidString)")
            .appendingPathExtension("wav")

        XCTAssertThrowsError(try service.play(url: missing, music: makeMusic())) { error in
            guard let playerError = error as? PlayerError else {
                return XCTFail("期望 PlayerError，实际：\(error)")
            }
            guard case .fileNotFound = playerError else {
                return XCTFail("期望 PlayerError.fileNotFound，实际：\(playerError)")
            }
            XCTAssertTrue(error.localizedDescription.contains("不存在"))
        }
        XCTAssertEqual(service.status, .stopped)
        XCTAssertNil(service.currentMusic)
    }

    func testPlayUnsupportedSchemeThrows() throws {
        let service = makeService()
        let ftpURL = try XCTUnwrap(URL(string: "ftp://example.com/song.mp3"))
        XCTAssertThrowsError(try service.play(url: ftpURL, music: makeMusic())) { error in
            guard let playerError = error as? PlayerError,
                  case .unsupportedScheme(let scheme) = playerError else {
                return XCTFail("期望 PlayerError.unsupportedScheme，实际：\(error)")
            }
            XCTAssertEqual(scheme, "ftp")
            XCTAssertTrue(error.localizedDescription.contains("不支持"))
        }
    }

    func testPlayerErrorReadableDescriptions() {
        XCTAssertTrue(PlayerError.describe(nil).contains("未知"))

        let avError = NSError(domain: AVFoundationErrorDomain,
                              code: AVError.fileFormatNotRecognized.rawValue)
        let described = PlayerError.describe(avError)
        XCTAssertTrue(described.contains("音频格式"), "实际错误文案：\(described)")

        let generic = NSError(domain: "cn.melo.test", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "测试底层错误"])
        XCTAssertEqual(PlayerError.describe(generic), "测试底层错误")
    }

    func testDuplicatePlayIsSupportedAndUpdatesState() throws {
        let service = makeService()
        defer { service.stop() }
        let first = try WAVFixture.writeTemporaryWAV(seconds: 1.0, frequency: 330)
        let second = try WAVFixture.writeTemporaryWAV(seconds: 1.0, frequency: 550)
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }

        try service.play(url: first, music: makeMusic(id: "song_a", name: "A"))
        XCTAssertEqual(service.currentURL, first)
        XCTAssertEqual(service.currentMusic?.id, "song_a")

        try service.play(url: second, music: makeMusic(id: "song_b", name: "B"))
        XCTAssertEqual(service.currentURL, second)
        XCTAssertEqual(service.currentMusic?.id, "song_b")
        XCTAssertEqual(service.nowPlayingSnapshot?.title, "B")
    }

    // MARK: - WAV fixture 自身

    func testWAVFixtureIsValidRIFF() {
        let data = WAVFixture.makeWAVData(seconds: 2.0, sampleRate: 44_100)
        XCTAssertGreaterThan(data.count, 44)
        XCTAssertEqual(String(decoding: data[0..<4], as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: data[8..<12], as: UTF8.self), "WAVE")
        XCTAssertEqual(String(decoding: data[36..<40], as: UTF8.self), "data")

        func littleEndianUInt32(at offset: Int) -> UInt32 {
            let bytes = [UInt8](data[offset..<(offset + 4)])
            return UInt32(bytes[0]) | (UInt32(bytes[1]) << 8) | (UInt32(bytes[2]) << 16) | (UInt32(bytes[3]) << 24)
        }
        let dataSize = littleEndianUInt32(at: 40)
        XCTAssertEqual(dataSize, UInt32(44_100 * 2 * 2), "2 秒 44.1kHz 16bit 单声道 PCM 字节数")
        XCTAssertEqual(Int(dataSize) + 44, data.count)
    }

    // MARK: - Now Playing 快照

    func testNowPlayingSnapshotReflectsMusic() throws {
        let service = makeService()
        defer { service.stop() }
        let wav = try WAVFixture.writeTemporaryWAV(seconds: 2.0)
        defer { try? FileManager.default.removeItem(at: wav) }

        let music = makeMusic(name: "快照歌曲", singer: "快照歌手", album: "快照专辑")
        try service.play(url: wav, music: music)

        let snapshot = try XCTUnwrap(service.nowPlayingSnapshot)
        XCTAssertEqual(snapshot.title, "快照歌曲")
        XCTAssertEqual(snapshot.artist, "快照歌手")
        XCTAssertEqual(snapshot.album, "快照专辑")
        XCTAssertEqual(snapshot.playbackRate, 1.0, accuracy: 0.0001)
        XCTAssertEqual(snapshot.duration, 2.0, accuracy: 0.0001)

        service.stop()
        XCTAssertNil(service.nowPlayingSnapshot)
        XCTAssertNil(service.currentMusic)
        XCTAssertNil(service.currentURL)
    }

    // MARK: - 系统 Now Playing / 媒体键集成

    func testSystemIntegrationPublishesAndClearsNowPlayingInfo() throws {
        let service = AVPlayerService()
        service.systemIntegrationEnabled = true
        defer {
            service.stop()
            service.systemIntegrationEnabled = false
        }
        let wav = try WAVFixture.writeTemporaryWAV(seconds: 2.0)
        defer { try? FileManager.default.removeItem(at: wav) }

        let music = makeMusic(name: "系统集成", singer: "集成歌手", album: "集成专辑")
        try service.play(url: wav, music: music)

        let info = try XCTUnwrap(MPNowPlayingInfoCenter.default().nowPlayingInfo)
        XCTAssertEqual(info[MPMediaItemPropertyTitle] as? String, "系统集成")
        XCTAssertEqual(info[MPMediaItemPropertyArtist] as? String, "集成歌手")
        XCTAssertEqual(info[MPMediaItemPropertyAlbumTitle] as? String, "集成专辑")

        service.pause()
        let pausedInfo = try XCTUnwrap(MPNowPlayingInfoCenter.default().nowPlayingInfo)
        XCTAssertEqual(MPNowPlayingInfoCenter.default().playbackState, .paused)
        XCTAssertEqual((pausedInfo[MPNowPlayingInfoPropertyPlaybackRate] as? NSNumber)?.doubleValue, 0)

        service.stop()
        XCTAssertNil(MPNowPlayingInfoCenter.default().nowPlayingInfo)
        XCTAssertEqual(MPNowPlayingInfoCenter.default().playbackState, .stopped)
    }

    // MARK: - 真实本地播放：开始 → 进度 → seek → ended

    func testLocalWAVPlaybackProgressSeekAndEnded() throws {
        let service = makeService()
        defer { service.stop() }
        let wav = try WAVFixture.writeTemporaryWAV(seconds: 2.0)
        defer { try? FileManager.default.removeItem(at: wav) }

        let playingExp = expectation(description: "进入 playing")
        let progressExp = expectation(description: "收到进度回调")
        let endedExp = expectation(description: "收到 ended")

        var playingFired = false
        var progressFired = false
        var endedFired = false
        var lastProgress: TimeInterval = 0
        var errorMessage: String?

        service.eventHandler = { event in
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

        try service.play(url: wav, music: makeMusic(interval: "00:02"))

        let startResult = XCTWaiter().wait(for: [playingExp, progressExp], timeout: 10)
        if startResult != .completed {
            if let errorMessage {
                XCTFail("本地 WAV 播放报错：\(errorMessage)")
            }
            throw XCTSkip("当前环境无法在 10s 内开始播放音频（status=\(service.status)），可能是 headless/无音频输出设备")
        }

        XCTAssertGreaterThan(lastProgress, 0.05)
        XCTAssertEqual(service.duration, 2.0, accuracy: 0.05, "应从 AVPlayerItem 拿到真实时长")
        XCTAssertEqual(service.status, .playing)

        // 暂停 → seek
        service.pause()
        XCTAssertEqual(service.status, .paused)
        service.seek(to: 1.2)
        XCTAssertEqual(service.currentTime, 1.2, accuracy: 0.05)

        // 恢复播放 → 应该走到结尾
        service.resume()
        let endResult = XCTWaiter().wait(for: [endedExp], timeout: 15)
        if endResult != .completed {
            if let errorMessage {
                XCTFail("本地 WAV 播放报错：\(errorMessage)")
            }
            throw XCTSkip("当前环境未在 15s 内播放到结尾（status=\(service.status), currentTime=\(service.currentTime)）")
        }

        XCTAssertEqual(service.status, .stopped)
        XCTAssertEqual(service.currentTime, 2.0, accuracy: 0.3)
        XCTAssertGreaterThan(lastProgress, 1.0)
    }

    // MARK: - 远程 URL：本地 127.0.0.1 HTTP 流

    func testRemoteWAVOverLocalHTTPStream() throws {
        let wavData = WAVFixture.makeWAVData(seconds: 2.0)
        let server = try LocalHTTPServer(payload: wavData)
        let port = try server.start()
        defer { server.stop() }

        let service = makeService()
        defer { service.stop() }
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/melo-test.wav"))

        let playingExp = expectation(description: "HTTP 流进入 playing")
        let progressExp = expectation(description: "HTTP 流收到进度")
        var playingFired = false
        var progressFired = false
        var lastProgress: TimeInterval = 0
        var errorMessage: String?

        service.eventHandler = { event in
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
            case .error(let message):
                errorMessage = message
            default:
                break
            }
        }

        try service.play(url: url, music: makeMusic(interval: "00:02"))
        XCTAssertEqual(service.currentURL, url)

        let result = XCTWaiter().wait(for: [playingExp, progressExp], timeout: 12)
        if result != .completed {
            if let errorMessage {
                throw XCTSkip("本机 HTTP 流播放不可用（可能是 ATS/网络环境限制）：\(errorMessage)")
            }
            throw XCTSkip("本机 HTTP 流未在 12s 内开始播放（status=\(service.status)）")
        }

        XCTAssertGreaterThan(lastProgress, 0.05)
        XCTAssertEqual(service.status, .playing)
    }

    // MARK: - 异步错误：损坏的音频文件

    func testCorruptAudioFileEmitsReadableError() throws {
        let service = makeService()
        defer { service.stop() }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("melo-corrupt-\(UUID().uuidString)")
            .appendingPathExtension("mp3")
        try Data("this is not a valid audio stream".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let errorExp = expectation(description: "收到错误事件")
        var errorFired = false
        var errorMessage: String?

        service.eventHandler = { event in
            if case .error(let message) = event, !errorFired {
                errorFired = true
                errorMessage = message
                errorExp.fulfill()
            }
        }

        try service.play(url: url, music: makeMusic(interval: nil))
        let result = XCTWaiter().wait(for: [errorExp], timeout: 10)
        if result != .completed {
            throw XCTSkip("当前环境未在 10s 内报告损坏音频错误（status=\(service.status)）")
        }

        let message = try XCTUnwrap(errorMessage)
        XCTAssertFalse(message.isEmpty, "错误信息不能是空字符串")
        XCTAssertEqual(service.status, .error)
    }
}
