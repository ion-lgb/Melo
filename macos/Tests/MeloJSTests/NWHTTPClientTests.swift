import XCTest
import Foundation
@testable import MeloJS

/// Network.framework 原始 HTTP 客户端（ATS 兜底）离线测试。
/// 全部走本地 TestHTTPServer（127.0.0.1），不访问外网。
final class NWHTTPClientTests: XCTestCase {

    private var server: TestHTTPServer!

    override func setUpWithError() throws {
        server = TestHTTPServer()
        try server.start()
    }

    override func tearDownWithError() throws {
        server?.stop()
        server = nil
    }

    // MARK: - helpers

    private func makeOptions(_ options: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: options)) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    @discardableResult
    private func perform(
        _ path: String,
        options: [String: Any] = [:],
        bridge: HTTPBridge,
        id: Int = 1,
        timeout: TimeInterval = 5
    ) -> (error: String?, response: HTTPBridge.Response?) {
        let expectation = expectation(description: "http \(path)")
        var result: (String?, HTTPBridge.Response?) = (nil, nil)
        bridge.request(
            id: id,
            urlString: "http://127.0.0.1:\(server.port)\(path)",
            optionsJSON: makeOptions(options)
        ) { error, response in
            result = (error, response)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: timeout)
        return result
    }

    private func jsonBody(_ response: HTTPBridge.Response?) -> [String: Any]? {
        guard let data = response?.data else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    // MARK: - 基础响应

    func testRawJSONResponse() {
        let bridge = HTTPBridge()
        let result = perform("/api/raw/json", bridge: bridge)
        XCTAssertNil(result.error)
        XCTAssertEqual(result.response?.statusCode, 200)
        XCTAssertEqual(result.response?.headers["x-melo-raw"], "1")
        XCTAssertEqual(jsonBody(result.response)?["raw"] as? Bool, true)
        XCTAssertEqual(jsonBody(result.response)?["message"] as? String, "hello-raw")
        XCTAssertEqual(bridge.rawRequestCount, 1, "http:// 请求必须走 Network.framework 原始客户端")
    }

    func testChunkedResponse() {
        let result = perform("/api/raw/chunked", bridge: HTTPBridge())
        XCTAssertNil(result.error)
        XCTAssertEqual(result.response?.statusCode, 200)
        XCTAssertEqual(jsonBody(result.response)?["chunked"] as? Bool, true)
        XCTAssertEqual(jsonBody(result.response)?["message"] as? String, "chunked-hello")
    }

    func testEOFDelimitedResponse() {
        let result = perform("/api/raw/eof", bridge: HTTPBridge())
        XCTAssertNil(result.error)
        XCTAssertEqual(result.response?.statusCode, 200)
        XCTAssertEqual(String(decoding: result.response?.data ?? Data(), as: UTF8.self),
                       "eof-body-without-content-length")
    }

    func test404Response() {
        let result = perform("/api/raw/404", bridge: HTTPBridge())
        XCTAssertNil(result.error)
        XCTAssertEqual(result.response?.statusCode, 404)
        XCTAssertEqual(jsonBody(result.response)?["error"] as? String, "not found")
    }

    // MARK: - 重定向

    func testRedirect() {
        let bridge = HTTPBridge()
        let result = perform("/api/raw/redirect", bridge: bridge)
        XCTAssertNil(result.error)
        XCTAssertEqual(result.response?.statusCode, 200)
        XCTAssertEqual(jsonBody(result.response)?["message"] as? String, "hello-raw")
        XCTAssertEqual(bridge.rawRequestCount, 1, "一次逻辑请求（内部含重定向）只计数一次")
    }

    func testRedirectChain301And307() {
        let result = perform("/api/raw/redirect-chain", bridge: HTTPBridge())
        XCTAssertNil(result.error)
        XCTAssertEqual(result.response?.statusCode, 200)
        XCTAssertEqual(jsonBody(result.response)?["message"] as? String, "hello-raw")
    }

    func testRedirectLoopIsLimited() {
        let result = perform("/api/raw/redirect-loop", bridge: HTTPBridge())
        XCTAssertNotNil(result.error)
        XCTAssertTrue(result.error?.contains("重定向次数") == true, "错误：\(result.error ?? "-")")
    }

    // MARK: - POST / headers / 取消 / 超时

    func testPostEchoWithHeadersAndBody() {
        let result = perform("/api/raw/echo", options: [
            "method": "post",
            "headers": ["X-Melo-Test": "raw-header"],
            "body": "payload-raw-123",
            "timeout": 5000,
        ], bridge: HTTPBridge())
        XCTAssertNil(result.error)
        XCTAssertEqual(result.response?.statusCode, 200)
        XCTAssertEqual(jsonBody(result.response)?["method"] as? String, "POST")
        XCTAssertEqual(jsonBody(result.response)?["body"] as? String, "payload-raw-123")
        XCTAssertEqual(jsonBody(result.response)?["xTest"] as? String, "raw-header")
    }

    func testCancelInFlightRequest() {
        let bridge = HTTPBridge()
        let expectation = expectation(description: "cancel")
        var result: (String?, HTTPBridge.Response?) = (nil, nil)
        bridge.request(id: 7, urlString: "http://127.0.0.1:\(server.port)/api/raw/slow", optionsJSON: "{}") { error, response in
            result = (error, response)
            expectation.fulfill()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            bridge.cancel(id: 7)
        }
        wait(for: [expectation], timeout: 5)
        XCTAssertEqual(result.0, "aborted")
        XCTAssertNil(result.1)
    }

    func testTimeout() {
        let result = perform("/api/raw/slow", options: ["timeout": 300], bridge: HTTPBridge(), timeout: 5)
        XCTAssertEqual(result.error, "请求超时")
        XCTAssertNil(result.response)
    }

    func testCancelAllStopsPendingRequests() {
        let bridge = HTTPBridge()
        let expectation = expectation(description: "cancelAll")
        bridge.request(id: 9, urlString: "http://127.0.0.1:\(server.port)/api/raw/slow", optionsJSON: "{}") { error, _ in
            XCTAssertEqual(error, "aborted")
            expectation.fulfill()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            bridge.cancelAll()
        }
        wait(for: [expectation], timeout: 5)
    }

    // MARK: - HTTPS 仍走 URLSession（raw 计数不变）

    func testHTTPSStillUsesURLSession() {
        let bridge = HTTPBridge()
        let expectation = expectation(description: "https")
        var finished = false
        bridge.request(id: 11, urlString: "https://127.0.0.1:1/never", optionsJSON: "{\"timeout\":500}") { _, _ in
            finished = true
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5)
        XCTAssertTrue(finished)
        XCTAssertEqual(bridge.rawRequestCount, 0)
    }

    // MARK: - 在线（默认跳过，CI 不依赖网络）

    func testOnlineRawHTTPBypassesATS() throws {
        guard ProcessInfo.processInfo.environment["MELO_ONLINE_TESTS"] == "1" else {
            throw XCTSkip("需要真实网络：MELO_ONLINE_TESTS=1 swift test --filter NWHTTPClientTests")
        }
        let bridge = HTTPBridge()
        let expectation = expectation(description: "example.com")
        var result: (String?, HTTPBridge.Response?) = (nil, nil)
        // example.com 不在 App 的 ATS 例外域名白名单内；此请求成功证明 Network.framework 兜底生效
        bridge.request(id: 21, urlString: "http://example.com/", optionsJSON: "{\"timeout\":10000}") { error, response in
            result = (error, response)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 15)
        XCTAssertNil(result.0)
        XCTAssertEqual(result.1?.statusCode, 200)
        XCTAssertEqual(bridge.rawRequestCount, 1)
        let body = String(decoding: result.1?.data ?? Data(), as: UTF8.self)
        XCTAssertTrue(body.contains("Example Domain"), "响应体片段：\(body.prefix(120))")
        print("[online] http://example.com/ -> 200, \(result.1?.data.count ?? 0) bytes, title contains Example Domain")
    }
}
