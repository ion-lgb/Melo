import XCTest
import Foundation
import MeloCore
@testable import MeloJS

/// 原版 LX Music v2.12.6 开放 API 协议兼容测试（根路径端点 / SSE / CORS / bindLan）。
@MainActor
private final class OriginalProtocolFakeHost: OpenAPIHost {
    var status: [String: JSONValue]
    var lyricBundle: [String: String]
    var playerStatus: OpenAPIStatus
    private(set) var commands: [(name: String, arguments: [String: String])] = []

    init() {
        status = [
            "status": .string("playing"),
            "name": .string("晴天"),
            "singer": .string("周杰伦"),
            "albumName": .string("叶惠美"),
            "picUrl": .string("https://example.com/pic.jpg"),
            "progress": .double(12.5),
            "duration": .double(269.8),
            "playbackRate": .double(1.0),
            "lyricLineText": .string("故事的小黄花"),
            "lyricLineAllText": .string("故事的小黄花"),
            "lyric": .string("[00:00.00]故事的小黄花"),
            "tlyric": .string("[00:00.00]trans"),
            "rlyric": .string(""),
            "lxlyric": .string("[00:00.00]<0,100>故事的小黄花"),
            "collect": .bool(false),
            "volume": .double(0.8),
            "mute": .bool(false),
        ]
        lyricBundle = [
            "lyric": "[00:00.00]故事的小黄花",
            "tlyric": "[00:00.00]trans",
            "rlyric": "",
            "lxlyric": "[00:00.00]<0,100>故事的小黄花",
        ]
        playerStatus = OpenAPIStatus(
            status: "playing", isPlaying: true,
            music: OpenAPIMusic(id: "kw_1", name: "晴天", singer: "周杰伦", albumName: "叶惠美", source: "kw", duration: 269.8),
            currentTime: 12.5, duration: 269.8, volume: 0.8, isMuted: false,
            playbackRate: 1.0, quality: "128k", queueCount: 3
        )
    }

    func openAPIStatus() -> OpenAPIStatus { playerStatus }

    func openAPICommand(_ command: String, arguments: [String: String]) async -> OpenAPICommandResult {
        commands.append((command, arguments))
        return OpenAPICommandResult(ok: true, status: playerStatus)
    }

    func openAPIPlayerStatus() -> [String: JSONValue] { status }

    func openAPILyricBundle() -> [String: String] { lyricBundle }
}

@MainActor
final class OriginalOpenAPIProtocolTests: XCTestCase {

    private var server: OpenAPIServer!
    private var host: OriginalProtocolFakeHost!

    override func setUpWithError() throws {
        server = OpenAPIServer()
        host = OriginalProtocolFakeHost()
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

    private func startServer(bindLan: Bool = false) throws {
        try server.start(port: 0, token: nil, bindLan: bindLan, host: host)
        XCTAssertTrue(server.isRunning)
        XCTAssertGreaterThan(server.actualPort, 0)
    }

    private func request(_ path: String, timeout: TimeInterval = 5) async throws -> HTTPResult {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(server.actualPort)\(path)")!)
        request.timeoutInterval = timeout
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "OriginalOpenAPIProtocolTests", code: 1)
        }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            headers[String(describing: key).lowercased()] = String(describing: value)
        }
        return HTTPResult(status: http.statusCode, headers: headers, body: data)
    }

    private func json(_ data: Data) -> [String: Any] {
        ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
    }

    private func text(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self)
    }

    private func localLANAddress() -> String? {
        var address: String?
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return nil }
        defer { freeifaddrs(pointer) }
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = entry.pointee
            guard let addr = interface.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: interface.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("bridge") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                                     &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            guard result == 0 else { continue }
            let ip = String(cString: host)
            if !ip.hasPrefix("127."), !ip.hasPrefix("169.254.") {
                address = ip
                break
            }
        }
        return address
    }

    // MARK: - /status

    func testStatusDefaultFilterAndCORS() async throws {
        try startServer()
        let result = try await request("/status")
        XCTAssertEqual(result.status, 200)
        XCTAssertTrue(result.headers["content-type"]?.contains("application/json") == true)
        XCTAssertEqual(result.headers["access-control-allow-origin"], "*")

        let object = json(result.body)
        XCTAssertEqual(Set(object.keys), Set(["status", "name", "singer", "albumName", "lyricLineText", "duration", "progress", "playbackRate"]))
        XCTAssertEqual(object["status"] as? String, "playing")
        XCTAssertEqual(object["name"] as? String, "晴天")
        XCTAssertEqual(object["singer"] as? String, "周杰伦")
        XCTAssertEqual(object["albumName"] as? String, "叶惠美")
        XCTAssertEqual(object["lyricLineText"] as? String, "故事的小黄花")
        XCTAssertEqual((object["duration"] as? NSNumber)?.doubleValue, 269.8)
        XCTAssertEqual((object["progress"] as? NSNumber)?.doubleValue, 12.5)
        XCTAssertEqual((object["playbackRate"] as? NSNumber)?.doubleValue, 1.0)
        // 默认 filter 不应返回 volume/lyric 等字段
        XCTAssertNil(object["volume"])
        XCTAssertNil(object["lyric"])
    }

    func testStatusCustomFilter() async throws {
        try startServer()
        let filtered = try await request("/status?filter=name,progress")
        XCTAssertEqual(filtered.status, 200)
        XCTAssertEqual(Set(json(filtered.body).keys), ["name", "progress"])
        XCTAssertEqual(json(filtered.body)["name"] as? String, "晴天")

        // 部分未知 key：仅返回匹配到的已知 key（原版行为）
        let partially = try await request("/status?filter=name,bogus")
        XCTAssertEqual(Set(json(partially.body).keys), ["name"])

        // 全部未知 → 回退默认 filter
        let fallback = try await request("/status?filter=bogus")
        XCTAssertEqual(Set(json(fallback.body).keys).count, 8)
    }

    // MARK: - 歌词

    func testLyricAndLyricAll() async throws {
        try startServer()
        let lyric = try await request("/lyric")
        XCTAssertEqual(lyric.status, 200)
        XCTAssertTrue(lyric.headers["content-type"]?.contains("text/plain") == true)
        XCTAssertEqual(text(lyric.body), "[00:00.00]故事的小黄花")
        XCTAssertEqual(lyric.headers["access-control-allow-origin"], "*")

        let all = try await request("/lyric-all")
        XCTAssertEqual(all.status, 200)
        let object = json(all.body)
        XCTAssertEqual(object["lyric"] as? String, "[00:00.00]故事的小黄花")
        XCTAssertEqual(object["tlyric"] as? String, "[00:00.00]trans")
        XCTAssertEqual(object["rlyric"] as? String, "")
        XCTAssertEqual(object["lxlyric"] as? String, "[00:00.00]<0,100>故事的小黄花")
    }

    // MARK: - 控制端点

    func testControlEndpoints() async throws {
        try startServer()
        let paths = ["/play", "/pause", "/skip-next", "/skip-prev", "/collect", "/uncollect"]
        for path in paths {
            let result = try await request(path)
            XCTAssertEqual(result.status, 200, "\(path)")
            XCTAssertEqual(text(result.body), "OK")
            XCTAssertEqual(result.headers["access-control-allow-origin"], "*")
        }
        XCTAssertEqual(host.commands.map(\.name), ["play", "pause", "next", "previous", "collect", "uncollect"])
    }

    func testSeekValidation() async throws {
        try startServer()
        let valid = try await request("/seek?offset=12.5")
        XCTAssertEqual(valid.status, 200)
        XCTAssertEqual(text(valid.body), "OK")
        XCTAssertEqual(host.commands.last?.name, "seek")
        XCTAssertEqual(host.commands.last?.arguments["position"], "12.500")

        for bad in ["/seek", "/seek?offset=abc", "/seek?offset=-1", "/seek?offset=9999"] {
            let result = try await request(bad)
            XCTAssertEqual(result.status, 400, "\(bad)")
            XCTAssertEqual(text(result.body), "Invalid offset", "\(bad)")
        }
    }

    func testVolumeValidation() async throws {
        try startServer()
        let valid = try await request("/volume?volume=50")
        XCTAssertEqual(valid.status, 200)
        XCTAssertEqual(text(valid.body), "OK")
        XCTAssertEqual(host.commands.last?.name, "volume")
        XCTAssertEqual(host.commands.last?.arguments["volume"], "0.5")

        for bad in ["/volume", "/volume?volume=abc", "/volume?volume=-1", "/volume?volume=101"] {
            let result = try await request(bad)
            XCTAssertEqual(result.status, 400, "\(bad)")
            XCTAssertEqual(text(result.body), "Invalid volume", "\(bad)")
        }
    }

    func testMuteValidation() async throws {
        try startServer()
        let mute = try await request("/mute?mute=true")
        XCTAssertEqual(mute.status, 200)
        XCTAssertEqual(text(mute.body), "OK")
        XCTAssertEqual(host.commands.last?.name, "mute")
        XCTAssertEqual(host.commands.last?.arguments["mute"], "true")

        let unmute = try await request("/mute?mute=false")
        XCTAssertEqual(unmute.status, 200)
        XCTAssertEqual(host.commands.last?.arguments["mute"], "false")

        let invalid = try await request("/mute?mute=yes")
        XCTAssertEqual(invalid.status, 400)
        XCTAssertEqual(text(invalid.body), "Invalid mute value")
    }

    func testUnknownPathForbidden() async throws {
        try startServer()
        let result = try await request("/unknown")
        XCTAssertEqual(result.status, 401)
        XCTAssertEqual(text(result.body), "Forbidden")
        XCTAssertEqual(result.headers["access-control-allow-origin"], "*")
    }

    // MARK: - SSE

    func testSubscribePlayerStatusSSE() async throws {
        try startServer()
        let url = URL(string: "http://127.0.0.1:\(server.actualPort)/subscribe-player-status?filter=status,name")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 200)
        XCTAssertEqual(http.value(forHTTPHeaderField: "Content-Type"), "text/event-stream")
        XCTAssertEqual(http.value(forHTTPHeaderField: "Access-Control-Allow-Origin"), "*")

        var lines: [String] = []
        let readTask = Task { @MainActor () -> [String] in
            do {
                for try await line in bytes.lines {
                    lines.append(line)
                    if lines.contains("data: \"夜曲\"") { break }
                    if lines.count > 60 { break }
                }
            } catch {}
            return lines
        }

        // 等首帧后修改状态，触发变更推送
        try await Task.sleep(nanoseconds: 500_000_000)
        host.status["status"] = .string("paused")
        host.status["name"] = .string("夜曲")

        let collected = await readTask.value
        XCTAssertTrue(collected.contains("event: status"), "首帧应包含 status：\(collected)")
        XCTAssertTrue(collected.contains("event: name"), "首帧应包含 name：\(collected)")
        XCTAssertTrue(collected.contains("data: \"playing\""), "首帧 status 值：\(collected)")
        XCTAssertTrue(collected.contains("data: \"晴天\""), "首帧 name 值：\(collected)")
        XCTAssertTrue(collected.contains("data: \"paused\""), "应推送 status 变更：\(collected)")
        XCTAssertTrue(collected.contains("data: \"夜曲\""), "应推送 name 变更：\(collected)")
    }

    // MARK: - bindLan

    func testBindLanFalseOnlyLoopback() async throws {
        try startServer(bindLan: false)
        let loopback = try await request("/status")
        XCTAssertEqual(loopback.status, 200)

        guard let lanAddress = localLANAddress() else {
            throw XCTSkip("未找到非 loopback IPv4 地址，跳过局域网不可达断言")
        }
        var request = URLRequest(url: URL(string: "http://\(lanAddress):\(server.actualPort)/status")!)
        request.timeoutInterval = 1.5
        do {
            _ = try await URLSession.shared.data(for: request)
            XCTFail("bindLan=false 时局域网地址 \(lanAddress) 不应可访问")
        } catch {
            // expected：仅 loopback 监听
        }
    }

    func testBindLanTrueStartsSuccessfully() async throws {
        try startServer(bindLan: true)
        let loopback = try await request("/status")
        XCTAssertEqual(loopback.status, 200)
    }

    // MARK: - 与既有 /api/* 协议共存

    func testCustomAPIStyleStillAvailable() async throws {
        try startServer()
        let result = try await request("/api/status")
        XCTAssertEqual(result.status, 200)
        XCTAssertEqual(json(result.body)["status"] as? String, "playing")
        XCTAssertEqual(result.headers["access-control-allow-origin"], "*")
    }
}
