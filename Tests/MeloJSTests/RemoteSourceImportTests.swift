import XCTest
import Foundation
import MeloCore
@testable import MeloJS

/// 在线 URL 导入自定义源测试。
/// 全部通过本地 TestHTTPServer（http://127.0.0.1）覆盖，真实 https 用例由环境变量门控。
@MainActor
final class RemoteSourceImportTests: XCTestCase {

    private var server: TestHTTPServer!

    override func setUpWithError() throws {
        server = TestHTTPServer()
        try server.start()
    }

    override func tearDownWithError() throws {
        server?.stop()
        server = nil
    }

    // MARK: - 辅助

    private struct Context {
        let root: URL
        let lxDatas: URL
        let settings: SettingsStore
        let service: JSCustomSourceService
    }

    private func makeContext() throws -> Context {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("melo-remote-import-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let lxDatas = root.appendingPathComponent("LxDatas", isDirectory: true)
        try FileManager.default.createDirectory(at: lxDatas, withIntermediateDirectories: true)
        let settings = SettingsStore(dataDirectory: lxDatas)
        let service = JSCustomSourceService(dataDirectory: root, settings: settings)
        service.remoteImportTimeout = 20
        return Context(root: root, lxDatas: lxDatas, settings: settings, service: service)
    }

    private func remoteURL(_ path: String) -> URL {
        URL(string: "http://127.0.0.1:\(server.port)\(path)")!
    }

    private func storedEntries(_ lxDatas: URL) throws -> [[String: Any]] {
        let data = try Data(contentsOf: lxDatas.appendingPathComponent("user_api.json"))
        let root = (try JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return (root?["userApis"] as? [[String: Any]]) ?? []
    }

    private func assertThrows(
        _ expectedFragment: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () async throws -> Void
    ) async {
        do {
            try await body()
            XCTFail("预期抛出错误（应包含 \(expectedFragment)）", file: file, line: line)
        } catch {
            let message = error.localizedDescription
            XCTAssertTrue(message.contains(expectedFragment), "错误信息应包含「\(expectedFragment)」，实际：\(message)", file: file, line: line)
        }
    }

    // MARK: - 成功路径

    func testImportFromHTTPPersistsAndActivates() async throws {
        let context = try makeContext()
        defer { try? FileManager.default.removeItem(at: context.root) }
        let url = remoteURL("/api/script/ok")

        let info = try await context.service.importSource(fromRemoteURL: url)
        XCTAssertEqual(info.name, "远程测试源")
        XCTAssertEqual(info.version, "1.2.0")
        XCTAssertEqual(info.author, "Melo Tests")
        XCTAssertTrue(info.id.hasPrefix("user_api_"))
        XCTAssertTrue(info.script.hasPrefix("gz_"))

        // user_api.json 兼容格式 + 来源 URL / 脚本 md5
        let entries = try storedEntries(context.lxDatas)
        XCTAssertEqual(entries.count, 1)
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry["sourceUrl"] as? String, url.absoluteString)
        let stored = try XCTUnwrap(entry["script"] as? String)
        let plain = try XCTUnwrap(ZlibCodec.decompressScript(stored))
        XCTAssertEqual(entry["scriptMd5"] as? String, CryptoBridge.md5(plain))
        XCTAssertEqual(plain, TestHTTPServer.remoteSourceScript())

        // 重新加载后仍存在
        let reloaded = JSCustomSourceService(dataDirectory: context.root, settings: context.settings)
        try reloaded.reloadSources()
        XCTAssertEqual(reloaded.sources.count, 1)
        XCTAssertEqual(reloaded.sources.first?.name, "远程测试源")

        // 可激活
        context.service.activationTimeout = 3
        await context.service.activateSource(id: info.id)
        defer { context.service.deactivateSource() }
        guard case .ready(let capabilities) = context.service.status else {
            return XCTFail("远程导入的源应可激活，实际：\(context.service.status)")
        }
        XCTAssertEqual(capabilities.first?.source, "kw")
        XCTAssertEqual(capabilities.first?.actions, ["musicUrl"])
        XCTAssertEqual(context.settings.string(SettingKeys.apiSource), info.id)
    }

    func testImportStripsUTF8BOM() async throws {
        let context = try makeContext()
        defer { try? FileManager.default.removeItem(at: context.root) }
        let info = try await context.service.importSource(fromRemoteURL: remoteURL("/api/script/bom"))
        XCTAssertEqual(info.name, "BOM 远程源")
        XCTAssertEqual(context.service.sources.count, 1)
    }

    func testImportFollowsShortRedirect() async throws {
        let context = try makeContext()
        defer { try? FileManager.default.removeItem(at: context.root) }
        let info = try await context.service.importSource(fromRemoteURL: remoteURL("/api/script/redirect"))
        XCTAssertEqual(info.name, "远程测试源")
    }

    func testImportScriptTextAPI() async throws {
        let context = try makeContext()
        defer { try? FileManager.default.removeItem(at: context.root) }
        let info = try context.service.importSource(script: TestHTTPServer.remoteSourceScript(name: "文本导入源"))
        XCTAssertEqual(info.name, "文本导入源")
        XCTAssertEqual(try storedEntries(context.lxDatas).count, 1)
        XCTAssertEqual(context.service.sources.count, 1)
    }

    // MARK: - 失败路径

    func testHTTP404And500Errors() async throws {
        let context = try makeContext()
        defer { try? FileManager.default.removeItem(at: context.root) }
        await assertThrows("HTTP 404") {
            _ = try await context.service.importSource(fromRemoteURL: self.remoteURL("/api/script/404"))
        }
        await assertThrows("HTTP 500") {
            _ = try await context.service.importSource(fromRemoteURL: self.remoteURL("/api/script/500"))
        }
        XCTAssertEqual(context.service.sources.count, 0)
    }

    func testOversizeScriptRejected() async throws {
        let context = try makeContext()
        defer { try? FileManager.default.removeItem(at: context.root) }
        // 9,000,001 字节 > 9,000,000 上限
        await assertThrows("脚本过大") {
            _ = try await context.service.importSource(fromRemoteURL: self.remoteURL("/api/script/large"))
        }
        XCTAssertEqual(context.service.sources.count, 0)
    }

    func testInvalidScriptRejected() async throws {
        let context = try makeContext()
        defer { try? FileManager.default.removeItem(at: context.root) }
        await assertThrows("无效的自定义源文件") {
            _ = try await context.service.importSource(fromRemoteURL: self.remoteURL("/api/script/invalid"))
        }
    }

    func testNonUTF8ContentRejected() async throws {
        let context = try makeContext()
        defer { try? FileManager.default.removeItem(at: context.root) }
        await assertThrows("不是 UTF-8") {
            _ = try await context.service.importSource(fromRemoteURL: self.remoteURL("/api/script/binary"))
        }
    }

    func testDuplicateRemoteImportRejected() async throws {
        let context = try makeContext()
        defer { try? FileManager.default.removeItem(at: context.root) }
        let url = remoteURL("/api/script/ok")
        _ = try await context.service.importSource(fromRemoteURL: url)
        await assertThrows("相同") {
            _ = try await context.service.importSource(fromRemoteURL: url)
        }
        XCTAssertEqual(context.service.sources.count, 1)
    }

    func testRedirectLimitExceeded() async throws {
        let context = try makeContext()
        defer { try? FileManager.default.removeItem(at: context.root) }
        await assertThrows("重定向") {
            _ = try await context.service.importSource(fromRemoteURL: self.remoteURL("/api/script/redirect-loop"))
        }
    }

    func testNetworkFailure() async throws {
        let context = try makeContext()
        defer { try? FileManager.default.removeItem(at: context.root) }
        // 未监听端口：连接被拒绝
        let url = URL(string: "http://127.0.0.1:1/api/script")!
        await assertThrows("在线导入失败") {
            _ = try await context.service.importSource(fromRemoteURL: url)
        }
    }

    func testTimeout() async throws {
        let context = try makeContext()
        defer { try? FileManager.default.removeItem(at: context.root) }
        context.service.remoteImportTimeout = 0.3
        await assertThrows("超时") {
            _ = try await context.service.importSource(fromRemoteURL: self.remoteURL("/api/script/slow"))
        }
    }

    func testURLValidation() async throws {
        let context = try makeContext()
        defer { try? FileManager.default.removeItem(at: context.root) }
        await assertThrows("链接不合法") {
            _ = try await context.service.importSource(fromRemoteURL: URL(string: "ftp://example.com/source.js")!)
        }
        let tooLong = URL(string: "http://127.0.0.1:\(server.port)/api/script/ok?padding=\(String(repeating: "a", count: 2100))")!
        await assertThrows("链接过长") {
            _ = try await context.service.importSource(fromRemoteURL: tooLong)
        }
    }

    // MARK: - 在线（默认跳过）

    func testOnlineHTTPSDownloadPath() async throws {
        guard ProcessInfo.processInfo.environment["MELO_ONLINE_TESTS"] == "1" else {
            throw XCTSkip("需要真实网络：MELO_ONLINE_TESTS=1")
        }
        let context = try makeContext()
        defer { try? FileManager.default.removeItem(at: context.root) }
        // https 走 URLSession：example.com 能下载但内容不是自定义源脚本 → 应报“无效的自定义源文件”
        await assertThrows("无效的自定义源文件") {
            _ = try await context.service.importSource(fromRemoteURL: URL(string: "https://example.com/")!)
        }
        print("[online] https://example.com/ 下载成功且被脚本校验拒绝（https 下载路径 OK）")
    }

    func testOnlineRealSourceURL() async throws {
        guard ProcessInfo.processInfo.environment["MELO_ONLINE_TESTS"] == "1" else {
            throw XCTSkip("需要真实网络：MELO_ONLINE_TESTS=1")
        }
        guard let urlString = ProcessInfo.processInfo.environment["MELO_ONLINE_SOURCE_URL"],
              let url = URL(string: urlString) else {
            throw XCTSkip("未提供 MELO_ONLINE_SOURCE_URL（真实在线源链接），跳过")
        }
        let context = try makeContext()
        defer { try? FileManager.default.removeItem(at: context.root) }
        let info = try await context.service.importSource(fromRemoteURL: url)
        print("[online] 真实 URL 导入成功：name=\(info.name), version=\(info.version ?? "-"), id=\(info.id)")
        XCTAssertFalse(info.name.isEmpty)
        XCTAssertEqual(try storedEntries(context.lxDatas).count, 1)
    }
}
