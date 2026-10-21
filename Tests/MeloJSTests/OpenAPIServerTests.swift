import XCTest
import Foundation
import MeloCore
@testable import MeloJS

@MainActor
private final class FakeOpenAPIHost: OpenAPIHost {
    var status: OpenAPIStatus
    private(set) var commands: [(name: String, arguments: [String: String])] = []
    var failingCommands: Set<String> = []
    var isPlaying = false

    init() {
        status = OpenAPIStatus(
            status: "paused",
            isPlaying: false,
            music: OpenAPIMusic(id: "kw_1", name: "晴天", singer: "周杰伦", albumName: "叶惠美", source: "kw", duration: 269.8),
            currentTime: 0,
            duration: 269.8,
            volume: 0.8,
            isMuted: false,
            playbackRate: 1.0,
            quality: "128k",
            queueCount: 3
        )
    }

    func openAPIStatus() -> OpenAPIStatus { status }

    func openAPIPlayerStatus() -> [String: JSONValue] {
        [
            "status": .string(status.status),
            "name": .string(status.music?.name ?? ""),
            "singer": .string(status.music?.singer ?? ""),
            "albumName": .string(status.music?.albumName ?? ""),
            "progress": .double(status.currentTime),
            "duration": .double(status.duration),
            "volume": .double(status.volume),
            "mute": .bool(status.isMuted),
        ]
    }

    func openAPILyricBundle() -> [String: String] {
        ["lyric": "", "tlyric": "", "rlyric": "", "lxlyric": ""]
    }

    func openAPICommand(_ command: String, arguments: [String: String]) async -> OpenAPICommandResult {
        commands.append((command, arguments))
        let lower = command.lowercased()
        if failingCommands.contains(lower) {
            return OpenAPICommandResult(ok: false, message: "fake failure")
        }
        if lower.contains("toggle") {
            isPlaying.toggle()
            status.isPlaying = isPlaying
            status.status = isPlaying ? "playing" : "paused"
        }
        if lower == "seek", let position = arguments["position"].flatMap(Double.init) {
            status.currentTime = position
        }
        return OpenAPICommandResult(ok: true, status: status)
    }
}

@MainActor
final class OpenAPIServerTests: XCTestCase {

    private var server: OpenAPIServer!
    private var host: FakeOpenAPIHost!

    override func setUpWithError() throws {
        server = OpenAPIServer()
        host = FakeOpenAPIHost()
    }

    override func tearDownWithError() throws {
        server?.stop()
        server = nil
        host = nil
    }

    // MARK: - 辅助

    private struct HTTPResult {
        let status: Int
        let headers: [String: String]
        let body: Data
    }

    private func startServer(token: String? = nil, port: UInt16 = 0) throws {
        try server.start(port: port, token: token, host: host)
        XCTAssertTrue(server.isRunning)
        XCTAssertGreaterThan(server.actualPort, 0)
    }

    private func request(
        _ path: String,
        method: String = "GET",
        headers: [String: String] = [:],
        body: Data? = nil,
        timeout: TimeInterval = 5
    ) async throws -> HTTPResult {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(server.actualPort)\(path)")!)
        request.httpMethod = method
        request.timeoutInterval = timeout
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "OpenAPIServerTests", code: 1)
        }
        var responseHeaders: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            responseHeaders[String(describing: key).lowercased()] = String(describing: value)
        }
        return HTTPResult(status: http.statusCode, headers: responseHeaders, body: data)
    }

    private func json(_ data: Data) -> [String: Any] {
        ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
    }

    // MARK: - 状态

    func testStatusJSON() async throws {
        try startServer()
        let result = try await request("/api/status")
        XCTAssertEqual(result.status, 200)
        XCTAssertTrue(result.headers["content-type"]?.contains("application/json") == true)

        let decoded = try JSONDecoder().decode(OpenAPIStatus.self, from: result.body)
        XCTAssertEqual(decoded, host.status)
        XCTAssertEqual(decoded.status, "paused")
        XCTAssertFalse(decoded.isPlaying)
        XCTAssertEqual(decoded.music?.id, "kw_1")
        XCTAssertEqual(decoded.music?.name, "晴天")
        XCTAssertEqual(decoded.music?.singer, "周杰伦")
        XCTAssertEqual(decoded.music?.source, "kw")
        XCTAssertEqual(decoded.volume, 0.8, accuracy: 0.0001)
        XCTAssertEqual(decoded.queueCount, 3)

        let object = json(result.body)
        XCTAssertEqual(object["status"] as? String, "paused")
        XCTAssertEqual((object["music"] as? [String: Any])?["name"] as? String, "晴天")
    }

    // MARK: - 鉴权

    func testAuthentication() async throws {
        try startServer(token: "s3cret")

        let unauthorized = try await request("/api/status")
        XCTAssertEqual(unauthorized.status, 401)
        XCTAssertEqual(json(unauthorized.body)["ok"] as? Bool, false)
        XCTAssertTrue((json(unauthorized.body)["message"] as? String)?.contains("token") == true)

        let wrongToken = try await request("/api/status?token=wrong")
        XCTAssertEqual(wrongToken.status, 401)

        let queryToken = try await request("/api/status?token=s3cret")
        XCTAssertEqual(queryToken.status, 200)

        let bearer = try await request("/api/status", headers: ["Authorization": "Bearer s3cret"])
        XCTAssertEqual(bearer.status, 200)

        // 说明页公开（浏览器直接打开）
        let root = try await request("/")
        XCTAssertEqual(root.status, 200)
    }

    // MARK: - 命令

    func testCommandGETAndToggle() async throws {
        try startServer()
        let result = try await request("/api/command/togglePlay")
        XCTAssertEqual(result.status, 200)
        XCTAssertEqual(host.commands.count, 1)
        XCTAssertEqual(host.commands.first?.name, "togglePlay")
        XCTAssertEqual(host.commands.first?.arguments.isEmpty, true)
        XCTAssertEqual(json(result.body)["ok"] as? Bool, true)
        let status = json(result.body)["status"] as? [String: Any]
        XCTAssertEqual(status?["isPlaying"] as? Bool, true)
    }

    func testCommandSeekQueryArguments() async throws {
        try startServer()
        let result = try await request("/api/command/seek?position=12.5")
        XCTAssertEqual(result.status, 200)
        XCTAssertEqual(host.commands.first?.arguments["position"], "12.5")
        let status = json(result.body)["status"] as? [String: Any]
        XCTAssertEqual((status?["currentTime"] as? NSNumber)?.doubleValue, 12.5)
    }

    func testCommandPOSTJSONBody() async throws {
        try startServer()
        let body = Data(#"{"position": 42.5, "percent": "50"}"#.utf8)
        let result = try await request("/api/command/seek", method: "POST",
                                       headers: ["Content-Type": "application/json"], body: body)
        XCTAssertEqual(result.status, 200)
        XCTAssertEqual(host.commands.first?.arguments["position"], "42.5")
        XCTAssertEqual(host.commands.first?.arguments["percent"], "50")
    }

    func testCommandPOSTFormBodyAndQueryMerge() async throws {
        try startServer()
        let body = Data("volume=0.5&unknown=1".utf8)
        let result = try await request("/api/command/volume?token=ignored", method: "POST",
                                       headers: ["Content-Type": "application/x-www-form-urlencoded"], body: body)
        XCTAssertEqual(result.status, 200)
        XCTAssertEqual(host.commands.first?.arguments["volume"], "0.5")
        XCTAssertEqual(host.commands.first?.arguments["unknown"], "1")
    }

    func testCommandFailureMaps400() async throws {
        try startServer()
        host.failingCommands = ["seek"]
        let result = try await request("/api/command/seek?position=1")
        XCTAssertEqual(result.status, 400)
        XCTAssertEqual(json(result.body)["ok"] as? Bool, false)
        XCTAssertEqual(json(result.body)["message"] as? String, "fake failure")
    }

    func testUnknownCommand404() async throws {
        try startServer()
        let result = try await request("/api/command/definitely-not-a-command")
        XCTAssertEqual(result.status, 404)
        XCTAssertEqual(json(result.body)["ok"] as? Bool, false)
        XCTAssertTrue(host.commands.isEmpty)
    }

    // MARK: - 其它路由

    func testLyricNotImplemented() async throws {
        try startServer()
        let result = try await request("/api/lyric")
        XCTAssertEqual(result.status, 501)
        XCTAssertTrue((json(result.body)["message"] as? String)?.contains("歌词") == true)
    }

    func testRootHelpPage() async throws {
        try startServer()
        let result = try await request("/")
        XCTAssertEqual(result.status, 200)
        XCTAssertTrue(result.headers["content-type"]?.contains("text/html") == true)
        let text = String(decoding: result.body, as: UTF8.self)
        XCTAssertTrue(text.contains("/api/status"))
        XCTAssertTrue(text.contains("127.0.0.1"))
    }

    func testMethodNotAllowed() async throws {
        try startServer()
        let result = try await request("/api/status", method: "POST")
        XCTAssertEqual(result.status, 405)
        XCTAssertTrue(result.headers["allow"]?.contains("GET") == true)
    }

    func testUnknownPath404() async throws {
        try startServer()
        let result = try await request("/api/unknown")
        XCTAssertEqual(result.status, 404)
    }

    // MARK: - 生命周期

    func testDoubleStartThrowsAndStopResets() async throws {
        try startServer()
        XCTAssertThrowsError(try server.start(port: 0, token: nil, host: host)) { error in
            XCTAssertEqual((error as? OpenAPIServerError)?.errorDescription, "开放 API 已在运行")
        }
        server.stop()
        XCTAssertFalse(server.isRunning)
        XCTAssertEqual(server.actualPort, 0)
        try server.start(port: 0, token: nil, host: host)
        XCTAssertTrue(server.isRunning)
        let result = try await request("/api/status")
        XCTAssertEqual(result.status, 200)
    }

    func testStopClosesListener() async throws {
        try startServer()
        let port = server.actualPort
        server.stop()
        XCTAssertFalse(server.isRunning)
        // 端口已关闭：请求应失败
        do {
            _ = try await request("/api/status", timeout: 2)
            XCTFail("服务已停止，请求不应成功（端口 \(port)）")
        } catch {
            // expected
        }
    }
}
