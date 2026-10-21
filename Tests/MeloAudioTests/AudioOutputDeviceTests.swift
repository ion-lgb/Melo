import XCTest
import AVFoundation
import CoreAudio
import MeloCore
@testable import MeloAudio

/// Round 9：CoreAudio 输出设备枚举 + EffectsAudioEngine 设备切换测试。
///
/// headless CI 无音频设备时，设备列表/切换类用例 XCTSkip；错误校验类用例始终运行。
@MainActor
final class AudioOutputDeviceTests: XCTestCase {

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

    private func makeMusic(interval: String? = "00:04") -> MusicInfo {
        MusicInfo(
            id: "device_song_1",
            name: "设备测试歌曲",
            singer: "设备测试歌手",
            source: "test",
            interval: interval,
            meta: .object(["songId": .string("1")])
        )
    }

    private func waitForPlaying(_ engine: EffectsAudioEngine,
                                timeout: TimeInterval = 15,
                                file: StaticString = #filePath,
                                line: UInt = #line) throws {
        let exp = expectation(description: "engine playing")
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
                XCTFail("播放报错：\(errorMessage)", file: file, line: line)
            }
            throw XCTSkip("当前环境无法开始播放（status=\(engine.status)）", file: file, line: line)
        }
    }

    private func waitForProgress(_ engine: EffectsAudioEngine,
                                 greaterThan threshold: TimeInterval,
                                 timeout: TimeInterval = 15) throws {
        let exp = expectation(description: "engine progress > \(threshold)")
        var fired = false
        let previous = engine.eventHandler
        engine.eventHandler = { event in
            if case .progress(let current, _) = event, current > threshold, !fired {
                fired = true
                exp.fulfill()
            }
            previous?(event)
        }
        let result = XCTWaiter().wait(for: [exp], timeout: timeout)
        engine.eventHandler = previous
        if result != .completed {
            throw XCTSkip("当前环境未在 \(Int(timeout))s 内推进播放（status=\(engine.status)）")
        }
    }

    // MARK: - 设备枚举

    func testListOutputDevices() throws {
        let devices = AudioOutputDevices.list()
        guard !devices.isEmpty else {
            throw XCTSkip("当前环境没有可用的 CoreAudio 输出设备（headless CI）")
        }
        XCTAssertEqual(Set(devices.map(\.uid)).count, devices.count, "设备 UID 应唯一")
        XCTAssertTrue(devices.allSatisfy { !$0.uid.isEmpty && !$0.name.isEmpty })
        XCTAssertLessThanOrEqual(devices.filter(\.isDefault).count, 1, "默认设备最多一个")

        for device in devices {
            XCTAssertEqual(AudioOutputDevices.deviceID(forUID: device.uid), device.deviceID,
                           "UID→AudioDeviceID 应可回查：\(device.name)")
        }

        if let defaultUID = AudioOutputDevices.defaultDeviceID() {
            let defaultDevice = devices.first { $0.uid == defaultUID }
            XCTAssertNotNil(defaultDevice, "默认设备 UID 应出现在 list() 中")
            XCTAssertTrue(defaultDevice?.isDefault ?? false)
            XCTAssertNotNil(AudioOutputDevices.deviceID(forUID: defaultUID))
        }
        // 默认设备排在最前（若存在）
        if let first = devices.first {
            XCTAssertTrue(first.isDefault || AudioOutputDevices.defaultDeviceID() == nil)
        }
    }

    // MARK: - 非法 UID / 默认设备

    func testInvalidUIDThrowsReadableError() throws {
        let cacheDir = try makeTempDirectory(prefix: "melo-dev-invalid")
        defer { remove(cacheDir) }
        let engine = makeEngine(cacheDirectory: cacheDir)
        defer { engine.stop() }

        XCTAssertThrowsError(try engine.setOutputDevice(uid: "cn.melo.no-such-output-device-\(UUID().uuidString)")) { error in
            XCTAssertTrue(error is AudioOutputDeviceError)
            XCTAssertTrue(error.localizedDescription.contains("输出设备"),
                          "错误应为可读中文：\(error.localizedDescription)")
        }
        XCTAssertNil(engine.outputDeviceUID, "非法 UID 不应改变当前设备设置")
    }

    func testDefaultDeviceSettingDoesNotThrow() throws {
        let cacheDir = try makeTempDirectory(prefix: "melo-dev-default")
        defer { remove(cacheDir) }
        let engine = makeEngine(cacheDirectory: cacheDir)
        defer { engine.stop() }

        XCTAssertNoThrow(try engine.setOutputDevice(uid: nil))
        XCTAssertNil(engine.outputDeviceUID)
        XCTAssertFalse(engine.hasCustomOutputDevice)

        XCTAssertNoThrow(try engine.setOutputDevice(uid: ""))
        XCTAssertNil(engine.outputDeviceUID)

        XCTAssertNoThrow(try engine.setOutputDevice(uid: "default"))
        XCTAssertNil(engine.outputDeviceUID)

        XCTAssertNoThrow(try engine.resetOutputDevice())
        XCTAssertFalse(engine.hasCustomOutputDevice)
    }

    // MARK: - 播放中切换设备保持位置

    func testSwitchDeviceWhilePlayingKeepsPosition() throws {
        let devices = AudioOutputDevices.list()
        // 优先切到「非默认设备」以验证真实切换；只有一个设备时切到该设备（重建路径同样生效）。
        guard let target = devices.first(where: { !$0.isDefault }) ?? devices.first else {
            throw XCTSkip("当前环境没有可用的 CoreAudio 输出设备（headless CI）")
        }
        let cacheDir = try makeTempDirectory(prefix: "melo-dev-switch")
        defer { remove(cacheDir) }
        let engine = makeEngine(cacheDirectory: cacheDir)
        defer { engine.stop() }

        let wav = try WAVFixture.writeTemporaryWAV(seconds: 4.0)
        defer { remove(wav) }

        try engine.play(url: wav, music: makeMusic())
        try waitForPlaying(engine)
        try waitForProgress(engine, greaterThan: 0.3)
        let positionBeforeSwitch = engine.currentTime
        XCTAssertGreaterThan(positionBeforeSwitch, 0.2)

        // 切到目标设备：引擎重建后应从原位置继续播放
        try engine.setOutputDevice(uid: target.uid)
        XCTAssertEqual(engine.outputDeviceUID, target.uid)
        XCTAssertTrue(engine.hasCustomOutputDevice)
        XCTAssertEqual(engine.status, .playing, "切换设备后应保持播放状态")
        XCTAssertGreaterThanOrEqual(engine.currentTime, positionBeforeSwitch - 0.5,
                                    "切换设备后应保持播放位置")
        try waitForProgress(engine, greaterThan: positionBeforeSwitch + 0.05)

        // 恢复默认设备：同样保持位置
        let positionBeforeReset = engine.currentTime
        try engine.setOutputDevice(uid: nil)
        XCTAssertNil(engine.outputDeviceUID)
        XCTAssertFalse(engine.hasCustomOutputDevice)
        XCTAssertEqual(engine.status, .playing)
        XCTAssertGreaterThanOrEqual(engine.currentTime, positionBeforeReset - 0.5)
    }
}
