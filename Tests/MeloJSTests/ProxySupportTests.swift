import XCTest
import Foundation
import Network
import CFNetwork
import MeloCore
@testable import MeloJS

/// 测试用 fake HTTP 代理：NWListener 接收 absolute-form 请求，记录请求头并返回固定响应。
final class TestProxyServer {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "melo.test.proxy")
    private let lock = NSLock()
    private var heads: [String] = []
    private let startBox = ProxyStartBox()
    private var _port: UInt16 = 0

    var responseStatusLine = "HTTP/1.1 200 OK"
    var responseBody = "proxied"
    var extraHeaders = ""

    var port: UInt16 { _port }
    var requestHeads: [String] {
        lock.lock()
        defer { lock.unlock() }
        return heads
    }
    var lastRequestHead: String? { requestHeads.last }

    func start() throws {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        let listener = try NWListener(using: parameters, on: .any)
        self.listener = listener
        let semaphore = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { [startBox] state in
            switch state {
            case .ready:
                semaphore.signal()
            case .failed(let error):
                startBox.setError(error.localizedDescription)
                semaphore.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
        guard semaphore.wait(timeout: .now() + 5) == .success else {
            listener.cancel()
            throw NSError(domain: "TestProxyServer", code: 1, userInfo: [NSLocalizedDescriptionKey: "代理启动超时"])
        }
        if let error = startBox.error {
            listener.cancel()
            throw NSError(domain: "TestProxyServer", code: 2, userInfo: [NSLocalizedDescriptionKey: error])
        }
        _port = listener.port?.rawValue ?? 0
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var buffer = buffer
            if let data, !data.isEmpty { buffer.append(data) }
            if let range = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(data: Data(buffer[..<range.lowerBound]), encoding: .utf8) ?? ""
                self.lock.lock()
                self.heads.append(head)
                self.lock.unlock()
                self.respond(connection)
            } else if isComplete || error != nil {
                connection.cancel()
            } else {
                self.receive(connection, buffer: buffer)
            }
        }
    }

    private func respond(_ connection: NWConnection) {
        let body = Data(responseBody.utf8)
        var response = Data("\(responseStatusLine)\r\n".utf8)
        response.append(Data("Content-Type: text/plain\r\n".utf8))
        response.append(Data("Content-Length: \(body.count)\r\n".utf8))
        response.append(Data("Connection: close\r\n".utf8))
        if !extraHeaders.isEmpty { response.append(Data(extraHeaders.utf8)) }
        response.append(Data("\r\n".utf8))
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

private final class ProxyStartBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    func setError(_ message: String) {
        lock.lock(); value = message; lock.unlock()
    }
    var error: String? {
        lock.lock(); defer { lock.unlock() }; return value
    }
}

final class ProxySupportTests: XCTestCase {

    override func setUp() {
        super.setUp()
        NetworkProxyStore.shared.reset()
    }

    override func tearDown() {
        NetworkProxyStore.shared.reset()
        super.tearDown()
    }

    // MARK: - 辅助

    private func rawRequest(url: URL, timeout: TimeInterval = 5) async -> (String?, HTTPBridge.Response?) {
        await withCheckedContinuation { continuation in
            let request = HTTPBridge.PreparedRequest(
                url: url,
                method: "GET",
                headers: [:],
                body: nil,
                timeout: timeout,
                maxRedirects: 5
            )
            let client = NWHTTPClient()
            client.request(id: 1, request: request) { [client] error, response in
                _ = client // 保持客户端存活到回调（request 内部弱引用自身队列）
                continuation.resume(returning: (error, response))
            }
        }
    }

    private func headerValue(_ name: String, in head: String) -> String? {
        for line in head.components(separatedBy: "\r\n").dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            guard key == name.lowercased() else { continue }
            return line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    // MARK: - URLSession 配置字典

    func testConnectionProxyDictionaryEnabledAndDisabled() throws {
        let proxy = try XCTUnwrap(ResolvedHTTPProxy(ProxySettings(
            enabled: true, host: "proxy.local", port: 7890, username: "user", password: "pass"
        )))
        let dictionary = try XCTUnwrap(NetworkProxy.connectionProxyDictionary(for: proxy))
        XCTAssertEqual(dictionary[kCFNetworkProxiesHTTPEnable] as? Bool, true)
        XCTAssertEqual(dictionary[kCFNetworkProxiesHTTPProxy] as? String, "proxy.local")
        XCTAssertEqual(dictionary[kCFNetworkProxiesHTTPPort] as? Int, 7890)
        XCTAssertEqual(dictionary[kCFNetworkProxiesHTTPSEnable] as? Bool, true)
        XCTAssertEqual(dictionary[kCFNetworkProxiesHTTPSProxy] as? String, "proxy.local")
        XCTAssertEqual(dictionary[kCFNetworkProxiesHTTPSPort] as? Int, 7890)
        XCTAssertEqual(dictionary[kCFProxyUsernameKey] as? String, "user")
        XCTAssertEqual(dictionary[kCFProxyPasswordKey] as? String, "pass")

        // 禁用 → 无字典（清空代理）
        XCTAssertNil(NetworkProxy.connectionProxyDictionary(for: nil))
    }

    func testInvalidProxySettingsTreatedAsDisabled() {
        XCTAssertNil(ResolvedHTTPProxy(ProxySettings(enabled: false, host: "proxy.local", port: 7890)))
        XCTAssertNil(ResolvedHTTPProxy(ProxySettings(enabled: true, host: "", port: 7890)))
        XCTAssertNil(ResolvedHTTPProxy(ProxySettings(enabled: true, host: "   ", port: 7890)))
        XCTAssertNil(ResolvedHTTPProxy(ProxySettings(enabled: true, host: "proxy.local", port: 0)))
        XCTAssertNil(ResolvedHTTPProxy(ProxySettings(enabled: true, host: "proxy.local", port: 70000)))

        NetworkProxyStore.shared.update(ProxySettings(enabled: true, host: "", port: 0))
        XCTAssertNil(NetworkProxyStore.shared.current)
        XCTAssertNil(NetworkProxy.connectionProxyDictionary(for: NetworkProxyStore.shared.current))
    }

    // MARK: - NW raw http 走代理

    func testHTTPRequestThroughProxyUsesAbsoluteFormAndAuth() async throws {
        let proxyServer = TestProxyServer()
        try proxyServer.start()
        defer { proxyServer.stop() }

        let settings = ProxySettings(
            enabled: true, host: "127.0.0.1", port: Int(proxyServer.port),
            username: "user", password: "pass"
        )
        NetworkProxyStore.shared.update(settings)
        defer { NetworkProxyStore.shared.reset() }

        let (error, response) = await rawRequest(url: URL(string: "http://example.test/path?x=1")!)
        XCTAssertNil(error)
        XCTAssertEqual(response?.statusCode, 200)
        XCTAssertEqual(String(data: response?.data ?? Data(), encoding: .utf8), "proxied")

        let head = try XCTUnwrap(proxyServer.lastRequestHead)
        let requestLine = try XCTUnwrap(head.components(separatedBy: "\r\n").first)
        XCTAssertEqual(requestLine, "GET http://example.test/path?x=1 HTTP/1.1", "代理请求行应为 absolute-form")
        XCTAssertEqual(headerValue("Host", in: head), "example.test", "Host 头应保持目标主机")
        XCTAssertEqual(headerValue("Proxy-Authorization", in: head), "Basic dXNlcjpwYXNz",
                       "Basic base64(user:pass) 应为 dXNlcjpwYXNz")
    }

    func testHTTPRequestWithoutProxyDoesNotContactProxy() async throws {
        let origin = TestHTTPServer()
        try origin.start()
        defer { origin.stop() }
        let proxyServer = TestProxyServer()
        try proxyServer.start()
        defer { proxyServer.stop() }

        // 默认禁用：直连 origin，不经过代理
        XCTAssertNil(NetworkProxyStore.shared.current)
        let (error, response) = await rawRequest(url: URL(string: "http://127.0.0.1:\(origin.port)/health")!)
        XCTAssertNil(error)
        XCTAssertEqual(response?.statusCode, 200)
        XCTAssertTrue(proxyServer.requestHeads.isEmpty, "未启用代理时不应连接代理")
        XCTAssertEqual(origin.requestLines.count, 1)
    }

    func testHTTPProxy407MapsReadableError() async throws {
        let proxyServer = TestProxyServer()
        proxyServer.responseStatusLine = "HTTP/1.1 407 Proxy Authentication Required"
        try proxyServer.start()
        defer { proxyServer.stop() }

        NetworkProxyStore.shared.update(ProxySettings(
            enabled: true, host: "127.0.0.1", port: Int(proxyServer.port)
        ))
        defer { NetworkProxyStore.shared.reset() }

        let (error, response) = await rawRequest(url: URL(string: "http://example.test/secret")!)
        XCTAssertNil(response)
        let message = try XCTUnwrap(error)
        XCTAssertTrue(message.contains("代理认证失败"), "错误信息：\(message)")
        XCTAssertTrue(message.contains("407"), "错误信息：\(message)")
    }

    func testInvalidProxyConfigFallsBackToDirect() async throws {
        let origin = TestHTTPServer()
        try origin.start()
        defer { origin.stop() }
        let proxyServer = TestProxyServer()
        try proxyServer.start()
        defer { proxyServer.stop() }

        // 非法配置（host 空）应视为禁用：请求直连 origin
        NetworkProxyStore.shared.update(ProxySettings(enabled: true, host: "", port: 0))
        let (error, response) = await rawRequest(url: URL(string: "http://127.0.0.1:\(origin.port)/health")!)
        XCTAssertNil(error)
        XCTAssertEqual(response?.statusCode, 200)
        XCTAssertTrue(proxyServer.requestHeads.isEmpty)
    }

    // MARK: - 服务 conform ProxyConfiguring

    @MainActor
    func testServicesConfigureProxy() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("melo-proxy-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let lxDatas = root.appendingPathComponent("LxDatas", isDirectory: true)
        try FileManager.default.createDirectory(at: lxDatas, withIntermediateDirectories: true)
        let settings = SettingsStore(dataDirectory: lxDatas)

        let metadata: ProxyConfiguring = JSMetadataService(resourcesDirectory: root)
        let customSource: ProxyConfiguring = JSCustomSourceService(dataDirectory: root, settings: settings)
        let proxySettings = ProxySettings(enabled: true, host: "127.0.0.1", port: 7890, username: "u", password: "p")

        metadata.configureProxy(proxySettings)
        XCTAssertEqual(NetworkProxyStore.shared.current?.host, "127.0.0.1")
        XCTAssertEqual(NetworkProxyStore.shared.current?.port, 7890)

        customSource.configureProxy(ProxySettings()) // 禁用
        XCTAssertNil(NetworkProxyStore.shared.current)
    }
}
