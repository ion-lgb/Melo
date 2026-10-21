import Foundation
import Network
@testable import MeloJS

/// 测试专用本地 HTTP 服务（127.0.0.1 + 随机端口），不访问外网。
/// - 模拟两段式音乐 API，并校验脚本用 `lx.utils.crypto.md5` 生成的签名；
/// - 同时提供 Network.framework 原始 HTTP 客户端测试端点：
///   JSON / chunked / 301-302-307 重定向 / 404 / 无 Content-Length（EOF）/ POST echo / 慢响应。
final class TestHTTPServer {

    static let validMid = "MELO123"
    static let signSalt = ":melo-test"
    static let ticketSalt = ":melo-ticket"
    static let expectedURL = "https://cdn.example.com/MELO123/128k.m4a"

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "melo.tests.http-server")
    private let lock = NSLock()
    private(set) var port: UInt16 = 0
    private var _requestLines: [String] = []

    var requestLines: [String] {
        lock.lock(); defer { lock.unlock() }
        return _requestLines
    }

    var requestCount: Int { requestLines.count }

    func start() throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: .any)
        self.listener = listener
        let semaphore = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.port = listener.port?.rawValue ?? 0
                semaphore.signal()
            case .failed, .cancelled:
                semaphore.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.start(queue: queue)
        _ = semaphore.wait(timeout: .now() + 5)
        if port == 0 {
            throw NSError(domain: "TestHTTPServer", code: 1, userInfo: [NSLocalizedDescriptionKey: "测试 HTTP 服务启动失败"])
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - 请求接收（支持 Content-Length body）

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var accumulated = buffer
            if let data { accumulated.append(data) }
            let headerEnd = Data("\r\n\r\n".utf8)
            if let headerRange = accumulated.range(of: headerEnd) {
                let headText = String(decoding: accumulated[..<headerRange.lowerBound], as: UTF8.self)
                let contentLength = self.contentLength(in: headText)
                let bodyStart = headerRange.upperBound
                let bodyCount = accumulated.distance(from: bodyStart, to: accumulated.endIndex)
                if bodyCount >= contentLength {
                    self.route(connection, requestData: accumulated)
                    return
                }
            }
            if isComplete || error != nil || accumulated.count > 1_048_576 {
                connection.cancel()
                return
            }
            self.receive(connection, buffer: accumulated)
        }
    }

    private func contentLength(in head: String) -> Int {
        for line in head.components(separatedBy: "\r\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            guard key == "content-length" else { continue }
            return Int(line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)) ?? 0
        }
        return 0
    }

    private func route(_ connection: NWConnection, requestData: Data) {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerRange = requestData.range(of: separator) else {
            connection.cancel()
            return
        }
        let headText = String(decoding: requestData[..<headerRange.lowerBound], as: UTF8.self)
        let body = Data(requestData[headerRange.upperBound...])

        let lines = headText.components(separatedBy: "\r\n")
        let requestLine = lines.first ?? ""
        lock.lock(); _requestLines.append(requestLine); lock.unlock()

        let parts = requestLine.split(separator: " ")
        let method = parts.count > 0 ? String(parts[0]).uppercased() : "GET"
        let target = parts.count > 1 ? String(parts[1]) : "/"
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        guard let components = URLComponents(string: "http://127.0.0.1" + target) else {
            sendJSON(connection, status: 400, body: "{\"error\":\"bad request\"}")
            return
        }
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] { query[item.name] = item.value ?? "" }

        switch components.path {
        // MARK: 音乐 API（既有测试）
        case "/api/song":
            let mid = query["mid"] ?? ""
            let sign = query["sign"] ?? ""
            let expectedSign = CryptoBridge.md5(mid + Self.signSalt)
            if mid == Self.validMid, sign == expectedSign, headers["x-melo-test"] != nil {
                let ticket = CryptoBridge.md5(mid + Self.ticketSalt)
                sendJSON(connection, status: 200, body: "{\"path\":\"/api/play\",\"token\":\"\(ticket)\",\"quality\":\"\(query["quality"] ?? "128k")\"}")
            } else {
                sendJSON(connection, status: 403, body: "{\"error\":\"forbidden\",\"reason\":\"bad sign or missing X-Melo-Test header\"}")
            }
        case "/api/play":
            let token = query["token"] ?? ""
            let expected = CryptoBridge.md5(Self.validMid + Self.ticketSalt)
            if token == expected {
                sendJSON(connection, status: 200, body: "{\"url\":\"\(Self.expectedURL)\",\"format\":\"m4a\"}")
            } else {
                sendJSON(connection, status: 403, body: "{\"error\":\"forbidden\",\"reason\":\"bad ticket\"}")
            }
        case "/health":
            sendJSON(connection, status: 200, body: "{\"ok\":true}")

        // MARK: Network.framework 原始 HTTP 测试端点
        case "/api/raw/json":
            sendJSON(connection, status: 200, body: "{\"raw\":true,\"message\":\"hello-raw\"}",
                     extraHeaders: ["X-Melo-Raw": "1"])
        case "/api/raw/chunked":
            sendChunked(connection, status: 200, body: "{\"chunked\":true,\"message\":\"chunked-hello\"}", chunkSize: 7)
        case "/api/raw/redirect":
            sendRedirect(connection, status: 302, location: "/api/raw/json")
        case "/api/raw/redirect-chain":
            sendRedirect(connection, status: 301, location: "/api/raw/redirect2")
        case "/api/raw/redirect2":
            sendRedirect(connection, status: 307, location: "/api/raw/json")
        case "/api/raw/404":
            sendJSON(connection, status: 404, body: "{\"error\":\"not found\"}")
        case "/api/raw/eof":
            sendEOF(connection, status: 200, body: "eof-body-without-content-length")
        case "/api/raw/echo":
            let bodyText = String(decoding: body, as: UTF8.self)
            let payload: [String: Any] = [
                "method": method,
                "body": bodyText,
                "xTest": headers["x-melo-test"] ?? NSNull(),
            ]
            let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
            sendJSON(connection, status: 200, body: String(decoding: data, as: UTF8.self))
        case "/api/raw/slow":
            queue.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                guard let self else { return }
                self.sendJSON(connection, status: 200, body: "{\"slow\":true}")
            }
        case "/api/raw/redirect-loop":
            sendRedirect(connection, status: 302, location: "/api/raw/redirect-loop")

        // MARK: 在线导入自定义源测试端点
        case "/api/script/ok":
            sendText(connection, status: 200, body: Self.remoteSourceScript())
        case "/api/script/named":
            sendText(connection, status: 200, body: Self.remoteSourceScript(name: "命名远程源"))
        case "/api/script/bom":
            sendText(connection, status: 200, body: Self.remoteSourceScript(name: "BOM 远程源"), prefixBOM: true)
        case "/api/script/invalid":
            sendText(connection, status: 200, body: "这并不是一个有效的 LX 自定义源脚本")
        case "/api/script/binary":
            sendData(connection, status: 200, data: Data([0xFF, 0xFE, 0x00, 0x01, 0x80]))
        case "/api/script/large":
            sendLarge(connection, status: 200, totalBytes: 9_000_001)
        case "/api/script/404":
            sendJSON(connection, status: 404, body: "{\"error\":\"not found\"}")
        case "/api/script/500":
            sendJSON(connection, status: 500, body: "{\"error\":\"server error\"}")
        case "/api/script/redirect":
            sendRedirect(connection, status: 302, location: "/api/script/ok")
        case "/api/script/redirect-loop":
            sendRedirect(connection, status: 302, location: "/api/script/redirect-loop")
        case "/api/script/slow":
            queue.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                guard let self else { return }
                self.sendText(connection, status: 200, body: Self.remoteSourceScript(name: "慢速远程源"))
            }
        default:
            sendJSON(connection, status: 404, body: "{\"error\":\"not found\"}")
        }
    }

    // MARK: - 自定义源脚本测试数据

    /// 一个可离线激活的最小自定义源脚本（`/*!` 头部注释形态）
    static func remoteSourceScript(name: String = "远程测试源") -> String {
        """
        /*!
         * @name \(name)
         * @description 在线导入测试源
         * @version 1.2.0
         * @author Melo Tests
         * @homepage http://127.0.0.1
         */
        const { EVENT_NAMES, on, send } = window.lx
        on(EVENT_NAMES.request, () => Promise.reject(new Error('unsupported action')))
        send(EVENT_NAMES.inited, {
          status: true,
          sources: {
            kw: { name: '\(name)', type: 'music', actions: ['musicUrl'], qualitys: ['128k'] }
          }
        })
        """
    }

    // MARK: - 响应发送

    private static func statusText(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 301: return "Moved Permanently"
        case 302: return "Found"
        case 303: return "See Other"
        case 307: return "Temporary Redirect"
        case 308: return "Permanent Redirect"
        case 400: return "Bad Request"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        default: return "Internal Server Error"
        }
    }

    private func sendJSON(_ connection: NWConnection, status: Int, body: String, extraHeaders: [String: String] = [:]) {
        let data = Data(body.utf8)
        var response = Data("HTTP/1.1 \(status) \(Self.statusText(status))\r\n".utf8)
        response.append(Data("Content-Type: application/json; charset=utf-8\r\n".utf8))
        for (key, value) in extraHeaders {
            response.append(Data("\(key): \(value)\r\n".utf8))
        }
        response.append(Data("Content-Length: \(data.count)\r\n".utf8))
        response.append(Data("Connection: close\r\n\r\n".utf8))
        response.append(data)
        send(connection, response)
    }

    private func sendRedirect(_ connection: NWConnection, status: Int, location: String) {
        var response = Data("HTTP/1.1 \(status) \(Self.statusText(status))\r\n".utf8)
        response.append(Data("Location: \(location)\r\n".utf8))
        response.append(Data("Content-Length: 0\r\n".utf8))
        response.append(Data("Connection: close\r\n\r\n".utf8))
        send(connection, response)
    }

    private func sendChunked(_ connection: NWConnection, status: Int, body: String, chunkSize: Int) {
        let bytes = [UInt8](body.utf8)
        var response = Data("HTTP/1.1 \(status) \(Self.statusText(status))\r\n".utf8)
        response.append(Data("Content-Type: application/json; charset=utf-8\r\n".utf8))
        response.append(Data("Transfer-Encoding: chunked\r\n".utf8))
        response.append(Data("Connection: close\r\n\r\n".utf8))
        var offset = 0
        while offset < bytes.count {
            let end = min(offset + chunkSize, bytes.count)
            let chunk = Array(bytes[offset..<end])
            response.append(Data("\(String(chunk.count, radix: 16))\r\n".utf8))
            response.append(Data(chunk))
            response.append(Data("\r\n".utf8))
            offset = end
        }
        response.append(Data("0\r\n\r\n".utf8))
        send(connection, response)
    }

    /// 无 Content-Length、发送后关闭连接（HTTP/1.0 风格 EOF body）
    private func sendEOF(_ connection: NWConnection, status: Int, body: String) {
        let data = Data(body.utf8)
        var response = Data("HTTP/1.1 \(status) \(Self.statusText(status))\r\n".utf8)
        response.append(Data("Content-Type: text/plain; charset=utf-8\r\n".utf8))
        response.append(Data("Connection: close\r\n\r\n".utf8))
        response.append(data)
        send(connection, response)
    }

    private func sendText(_ connection: NWConnection, status: Int, body: String, prefixBOM: Bool = false) {
        var data = Data(body.utf8)
        if prefixBOM { data = Data([0xEF, 0xBB, 0xBF]) + data }
        sendData(connection, status: status, data: data)
    }

    private func sendData(_ connection: NWConnection, status: Int, data: Data, contentType: String = "application/javascript; charset=utf-8") {
        var response = Data("HTTP/1.1 \(status) \(Self.statusText(status))\r\n".utf8)
        response.append(Data("Content-Type: \(contentType)\r\n".utf8))
        response.append(Data("Content-Length: \(data.count)\r\n".utf8))
        response.append(Data("Connection: close\r\n\r\n".utf8))
        response.append(data)
        send(connection, response)
    }

    /// 发送超大响应体（分块发送，避免 NWConnection 一次 send 过大）
    private func sendLarge(_ connection: NWConnection, status: Int, totalBytes: Int) {
        var header = Data("HTTP/1.1 \(status) \(Self.statusText(status))\r\n".utf8)
        header.append(Data("Content-Type: application/javascript; charset=utf-8\r\n".utf8))
        header.append(Data("Content-Length: \(totalBytes)\r\n".utf8))
        header.append(Data("Connection: close\r\n\r\n".utf8))
        connection.send(content: header, completion: .contentProcessed { [weak self] error in
            guard let self, error == nil else { connection.cancel(); return }
            self.sendBodyChunks(connection, remaining: totalBytes)
        })
    }

    private func sendBodyChunks(_ connection: NWConnection, remaining: Int) {
        guard remaining > 0 else {
            connection.cancel()
            return
        }
        let count = min(remaining, 128 * 1024)
        let chunk = Data(repeating: 0x61, count: count) // 'a'
        connection.send(content: chunk, completion: .contentProcessed { [weak self] error in
            guard let self, error == nil else { connection.cancel(); return }
            self.sendBodyChunks(connection, remaining: remaining - count)
        })
    }

    private func send(_ connection: NWConnection, _ data: Data) {
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
