import XCTest
import Foundation
import MeloCore
@testable import MeloJS

/// MeloJS 运行时测试：全部走本地 127.0.0.1 测试服务，不访问外网。
final class JSCustomSourceServiceTests: XCTestCase {

    // MARK: - 测试夹具

    private struct TestContext {
        let root: URL
        let lxDatas: URL
        let settings: SettingsStore
        let service: JSCustomSourceService
    }

    private final class EventCollector {
        private(set) var events: [CustomSourceEvent] = []
        func append(_ event: CustomSourceEvent) { events.append(event) }

        var readyCapabilities: [SourceCapability]? {
            for event in events {
                if case .status(let status) = event, case .ready(let capabilities) = status {
                    return capabilities
                }
            }
            return nil
        }

        var logs: [String] {
            events.compactMap { event in
                if case .log(let message) = event { return message }
                return nil
            }
        }

        var updateAlerts: [(log: String, updateUrl: String?)] {
            events.compactMap { event in
                if case .updateAlert(let log, let updateUrl) = event { return (log, updateUrl) }
                return nil
            }
        }
    }

    // MARK: - 路径 / 文件辅助

    private static var testAssetsDirectory: URL {
        URL(fileURLWithPath: #filePath) // Tests/MeloJSTests/xxx.swift
            .deletingLastPathComponent() // MeloJSTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // macos
            .appendingPathComponent("TestAssets", isDirectory: true)
    }

    private func fixture(_ name: String, port: UInt16? = nil) throws -> String {
        let url = Self.testAssetsDirectory.appendingPathComponent(name)
        var text = try String(contentsOf: url, encoding: .utf8)
        if let port {
            text = text.replacingOccurrences(of: "__MELO_TEST_PORT__", with: String(port))
        }
        return text
    }

    private func writeScript(_ content: String, in root: URL, name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @MainActor
    private func makeContext(appStyle: Bool = false) throws -> TestContext {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("melo-js-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let lxDatas = root.appendingPathComponent("LxDatas", isDirectory: true)
        try FileManager.default.createDirectory(at: lxDatas, withIntermediateDirectories: true)
        let settings = SettingsStore(dataDirectory: lxDatas)
        let service = JSCustomSourceService(dataDirectory: appStyle ? lxDatas : root, settings: settings)
        return TestContext(root: root, lxDatas: lxDatas, settings: settings, service: service)
    }

    @MainActor
    @discardableResult
    private func importFixture(_ name: String, port: UInt16? = nil, in context: TestContext) throws -> UserSourceInfo {
        let script = try fixture(name, port: port)
        let file = try writeScript(script, in: context.root, name: "fixture-\(name)")
        return try context.service.importSource(from: file)
    }

    private func userApiJSON(_ lxDatas: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: lxDatas.appendingPathComponent("user_api.json"))
        return (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    private func storedEntries(_ lxDatas: URL) throws -> [[String: Any]] {
        let root = try userApiJSON(lxDatas)
        return (root["userApis"] as? [[String: Any]]) ?? []
    }

    private func musicInfo(source: String = "kw", songId: String = TestHTTPServer.validMid) -> MusicInfo {
        MusicInfo(
            id: "\(source)_\(songId)",
            name: "Melo 测试歌曲",
            singer: "Melo",
            source: source,
            interval: "00:20",
            meta: .object(["songId": .string(songId), "albumName": .string("Melo Test")])
        )
    }

    // MARK: - 1. 导入与存储兼容（原版 user_api.json）

    @MainActor
    func testImportPersistsOriginalUserApiJSON() async throws {
        let context = try makeContext()
        defer { try? FileManager.default.removeItem(at: context.root) }
        let info = try importFixture("test-source.js", port: 1, in: context)

        XCTAssertTrue(info.id.hasPrefix("user_api_"), "id 格式应为 user_api_<3位随机>_<毫秒时间戳>")
        let parts = info.id.split(separator: "_")
        XCTAssertEqual(parts.count, 4)
        XCTAssertEqual(parts[2].count, 3)
        XCTAssertEqual(info.name, "MeloJSTests 测试源")
        XCTAssertEqual(info.description, "仅用于 MeloJSTests 的本地测试源，不打包进 App")
        XCTAssertEqual(info.version, "1.2.3")
        XCTAssertEqual(info.author, "Melo Tests")
        XCTAssertTrue(info.script.hasPrefix("gz_"))

        let fileURL = context.lxDatas.appendingPathComponent("user_api.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        let entries = try storedEntries(context.lxDatas)
        XCTAssertEqual(entries.count, 1)
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry["id"] as? String, info.id)
        XCTAssertEqual(entry["name"] as? String, "MeloJSTests 测试源")
        XCTAssertEqual(entry["version"] as? String, "1.2.3")
        XCTAssertEqual(entry["allowShowUpdateAlert"] as? Bool, true)
        XCTAssertTrue((entry["script"] as? String)?.hasPrefix("gz_") == true)
        let expectedScript = try fixture("test-source.js", port: 1)
        XCTAssertEqual(ZlibCodec.decompressScript(entry["script"] as? String ?? ""), expectedScript)

        XCTAssertEqual(context.service.sources.count, 1)
        try context.service.reloadSources()
        XCTAssertEqual(context.service.sources.count, 1)

        // 重复内容拒绝
        let duplicateFile = try writeScript(try fixture("test-source.js", port: 1), in: context.root, name: "duplicate.js")
        do {
            _ = try context.service.importSource(from: duplicateFile)
            XCTFail("重复导入应失败")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("相同"), "错误信息应提示脚本重复：\(error.localizedDescription)")
        }

        // 无头部注释拒绝
        let invalidFile = try writeScript(try fixture("invalid-header.js"), in: context.root, name: "invalid.js")
        do {
            _ = try context.service.importSource(from: invalidFile)
            XCTFail("无头部注释应导入失败")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("无效的自定义源文件"), "错误信息：\(error.localizedDescription)")
        }
    }

    // MARK: - 2. 旧版无 version 条目迁移

    @MainActor
    func testLegacyEntryWithoutVersionIsMigrated() async throws {
        let context = try makeContext()
        defer { try? FileManager.default.removeItem(at: context.root) }
        let script = try fixture("test-source.js", port: 1)
        let compressed = try XCTUnwrap(ZlibCodec.compressScript(script))
        let legacyRoot: [String: Any] = [
            "userApis": [[
                "id": "user_api_123_1700000000000",
                "name": "旧版测试源",
                "description": "",
                "author": "",
                "homepage": "",
                "allowShowUpdateAlert": false,
                "script": compressed,
            ]]
        ]
        let data = try JSONSerialization.data(withJSONObject: legacyRoot)
        try MeloUtils.atomicWrite(data, to: context.lxDatas.appendingPathComponent("user_api.json"))

        try context.service.reloadSources()
        XCTAssertEqual(context.service.sources.count, 1)
        XCTAssertEqual(context.service.sources[0].name, "旧版测试源")
        XCTAssertEqual(context.service.sources[0].version, "1.2.3", "旧条目应从脚本头部补全 version")

        let entries = try storedEntries(context.lxDatas)
        XCTAssertEqual(entries.first?["version"] as? String, "1.2.3", "迁移结果应回写 user_api.json")
    }

    // MARK: - 3. App 传 LxDatas 目录时不重复追加

    @MainActor
    func testAppStyleLxDatasDirectoryDoesNotDoubleAppend() async throws {
        let context = try makeContext(appStyle: true)
        defer { try? FileManager.default.removeItem(at: context.root) }
        _ = try importFixture("test-source.js", port: 1, in: context)
        XCTAssertTrue(FileManager.default.fileExists(atPath: context.lxDatas.appendingPathComponent("user_api.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: context.lxDatas.appendingPathComponent("LxDatas").path))
    }

    // MARK: - 4. 激活 / capabilities / 事件 / settings

    @MainActor
    func testActivateSourceCapabilitiesAndEvents() async throws {
        let context = try makeContext()
        defer { try? FileManager.default.removeItem(at: context.root) }
        let collector = EventCollector()
        context.service.eventHandler = { collector.append($0) }
        let info = try importFixture("test-source.js", port: 1, in: context)
        context.service.activationTimeout = 3

        await context.service.activateSource(id: info.id)
        defer { context.service.deactivateSource() }

        guard case .ready(let capabilities) = context.service.status else {
            return XCTFail("激活应成功，实际状态：\(context.service.status)")
        }
        XCTAssertEqual(context.service.activeSourceId, info.id)
        XCTAssertEqual(context.settings.string(SettingKeys.apiSource), info.id, "活动源应写回 settings")
        XCTAssertEqual(context.service.sources.filter(\.isActive).map(\.id), [info.id])

        let bySource = Dictionary(uniqueKeysWithValues: capabilities.map { ($0.source, $0) })
        XCTAssertEqual(Set(bySource.keys), ["kw", "kg"], "xm 不在支持列表，应被过滤")
        XCTAssertEqual(bySource["kw"]?.actions, ["musicUrl"])
        XCTAssertEqual(bySource["kw"]?.qualitys, ["128k", "320k"])
        XCTAssertEqual(bySource["kw"]?.name, "Melo 测试源")
        XCTAssertEqual(bySource["kg"]?.qualitys, ["128k"])

        XCTAssertNotNil(collector.readyCapabilities)
        XCTAssertTrue(collector.logs.contains { $0.contains("[test-source] loaded") }, "console.log 应桥接到事件日志：\(collector.logs)")
        XCTAssertEqual(collector.updateAlerts.first?.log, "Melo 测试源更新日志")
        XCTAssertEqual(collector.updateAlerts.first?.updateUrl, "https://example.com/melo-update")
    }

    // MARK: - 5. 端到端 musicUrl（两段真实 HTTP + md5 签名）

    @MainActor
    func testEndToEndResolveMusicURL() async throws {
        let server = TestHTTPServer()
        try server.start()
        defer { server.stop() }
        let context = try makeContext()
        defer { try? FileManager.default.removeItem(at: context.root) }
        let info = try importFixture("test-source.js", port: server.port, in: context)
        context.service.activationTimeout = 3
        await context.service.activateSource(id: info.id)
        defer { context.service.deactivateSource() }
        XCTAssertTrue(context.service.status.isReady)

        let url = try await context.service.resolveMusicURL(
            source: "kw",
            musicInfo: musicInfo(),
            quality: "320k"
        )
        XCTAssertEqual(url.absoluteString, TestHTTPServer.expectedURL)
        XCTAssertEqual(server.requestCount, 2, "应完成两段 HTTP 请求；实际：\(server.requestLines)")
        XCTAssertTrue(server.requestLines.first?.contains("/api/song?mid=MELO123&sign=") == true)
    }

    // MARK: - 6. 歌词事件（local + lyric action）

    @MainActor
    func testResolveLyric() async throws {
        let context = try makeContext()
        defer { try? FileManager.default.removeItem(at: context.root) }
        let info = try importFixture("test-lyric-source.js", in: context)
        context.service.activationTimeout = 3
        await context.service.activateSource(id: info.id)
        defer { context.service.deactivateSource() }

        guard case .ready(let capabilities) = context.service.status else {
            return XCTFail("歌词源激活失败：\(context.service.status)")
        }
        XCTAssertEqual(capabilities.first?.source, "local")
        XCTAssertEqual(capabilities.first?.actions, ["lyric"])

        let lyric = try await context.service.resolveLyric(
            source: "local",
            musicInfo: musicInfo(source: "local", songId: "lyric-1")
        )
        XCTAssertEqual(lyric?.lyric, "[00:00.00]Melo test lyric")
        XCTAssertEqual(lyric?.tlyric, "[00:00.00]Melo test translated lyric")
    }

    // MARK: - 7. 非法结果 / 脚本失败 / 非 http(s) 限制

    @MainActor
    func testInvalidResultIsRejected() async throws {
        let context = try makeContext()
        defer { try? FileManager.default.removeItem(at: context.root) }
        let info = try importFixture("bad-result-source.js", in: context)
        context.service.activationTimeout = 3
        await context.service.activateSource(id: info.id)
        defer { context.service.deactivateSource() }
        do {
            _ = try await context.service.resolveMusicURL(source: "kw", musicInfo: musicInfo(), quality: "128k")
            XCTFail("非法 URL 应被拒绝")
        } catch let error as CustomSourceError {
            guard case .invalidResult = error else {
                return XCTFail("应为 invalidResult，实际：\(error)")
            }
        }
    }

    @MainActor
    func testScriptFailurePropagates() async throws {
        let context = try makeContext()
        defer { try? FileManager.default.removeItem(at: context.root) }
        let info = try importFixture("failing-source.js", in: context)
        context.service.activationTimeout = 3
        await context.service.activateSource(id: info.id)
        defer { context.service.deactivateSource() }
        do {
            _ = try await context.service.resolveMusicURL(source: "kw", musicInfo: musicInfo(), quality: "128k")
            XCTFail("脚本 reject 应抛出错误")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("boom-melo"), "错误信息应包含脚本错误：\(error.localizedDescription)")
        }
    }

    @MainActor
    func testBadURLSchemeIsRestricted() async throws {
        let context = try makeContext()
        defer { try? FileManager.default.removeItem(at: context.root) }
        let info = try importFixture("bad-scheme-source.js", in: context)
        context.service.activationTimeout = 3
        await context.service.activateSource(id: info.id)
        defer { context.service.deactivateSource() }
        do {
            _ = try await context.service.resolveMusicURL(source: "kw", musicInfo: musicInfo(), quality: "128k")
            XCTFail("file:// 请求应被拒绝")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("http"), "应提示仅支持 http(s)：\(error.localizedDescription)")
        }
    }

    @MainActor
    func testUnsupportedCapabilityIsRejected() async throws {
        let context = try makeContext()
        defer { try? FileManager.default.removeItem(at: context.root) }
        let info = try importFixture("test-source.js", port: 1, in: context)
        context.service.activationTimeout = 3
        await context.service.activateSource(id: info.id)
        defer { context.service.deactivateSource() }
        do {
            _ = try await context.service.resolveMusicURL(source: "tx", musicInfo: musicInfo(source: "tx"), quality: "128k")
            XCTFail("未声明的 tx 源应拒绝")
        } catch let error as CustomSourceError {
            guard case .noCapability = error else {
                return XCTFail("应为 noCapability，实际：\(error)")
            }
        }
    }

    // MARK: - 8. 超时

    @MainActor
    func testRequestTimeout() async throws {
        let context = try makeContext()
        defer { try? FileManager.default.removeItem(at: context.root) }
        let info = try importFixture("never-resolving-source.js", in: context)
        context.service.activationTimeout = 3
        await context.service.activateSource(id: info.id)
        defer { context.service.deactivateSource() }
        context.service.requestTimeout = 0.4
        let start = Date()
        do {
            _ = try await context.service.resolveMusicURL(source: "kw", musicInfo: musicInfo(), quality: "128k")
            XCTFail("永不返回的脚本应超时")
        } catch let error as CustomSourceError {
            guard case .timeout = error else {
                return XCTFail("应为 timeout，实际：\(error)")
            }
        }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertGreaterThan(elapsed, 0.3)
        XCTAssertLessThan(elapsed, 5)
    }

    @MainActor
    func testActivationTimeout() async throws {
        let context = try makeContext()
        defer { try? FileManager.default.removeItem(at: context.root) }
        let info = try importFixture("no-inited-source.js", in: context)
        context.service.activationTimeout = 0.4
        await context.service.activateSource(id: info.id)
        defer { context.service.deactivateSource() }
        guard case .error(let message) = context.service.status else {
            return XCTFail("未发 inited 应激活失败，实际：\(context.service.status)")
        }
        XCTAssertTrue(message.contains("超时"), "错误信息：\(message)")
        XCTAssertNil(context.service.activeSourceId)
        XCTAssertTrue(context.service.capabilities.isEmpty)
    }

    // MARK: - 9. 启动恢复活动源

    @MainActor
    func testRestoreActiveSourceFromSettings() async throws {
        let context = try makeContext()
        defer { try? FileManager.default.removeItem(at: context.root) }
        let info = try importFixture("test-source.js", port: 1, in: context)
        context.service.activationTimeout = 3
        await context.service.activateSource(id: info.id)
        XCTAssertEqual(context.settings.string(SettingKeys.apiSource), info.id)
        context.service.deactivateSource()
        XCTAssertNil(context.service.activeSourceId)

        // 模拟 App 重启：新 service 读取同一个 settings + 数据目录
        let restarted = JSCustomSourceService(dataDirectory: context.root, settings: context.settings)
        restarted.activationTimeout = 3
        await restarted.restoreActiveSourceIfNeeded()
        defer { restarted.deactivateSource() }
        XCTAssertEqual(restarted.activeSourceId, info.id)
        XCTAssertTrue(restarted.status.isReady)
    }

    // MARK: - 10. 删除活动源 → 运行时停止

    @MainActor
    func testRemoveActiveSourceDeactivates() async throws {
        let context = try makeContext()
        defer { try? FileManager.default.removeItem(at: context.root) }
        let info = try importFixture("test-source.js", port: 1, in: context)
        context.service.activationTimeout = 3
        await context.service.activateSource(id: info.id)
        XCTAssertTrue(context.service.status.isReady)

        try context.service.removeSource(id: info.id)
        XCTAssertNil(context.service.activeSourceId)
        XCTAssertEqual(context.service.status, SourceRuntimeStatus.idle)
        XCTAssertTrue(context.service.capabilities.isEmpty)
        XCTAssertTrue(context.service.sources.isEmpty)
        XCTAssertEqual(try storedEntries(context.lxDatas).count, 0)
    }
}
