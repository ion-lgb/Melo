import Foundation
import Network
import MeloCore

/// Network.framework 原始 HTTP/1.1 客户端。
///
/// 背景：macOS 26/27 上 ATS 对 `NSAllowsArbitraryLoads` 的处理发生变化（只剩
/// `NSExceptionDomains` 白名单生效）。内置源域名已在 Info.plist 加例外，但用户导入的
/// 自定义源可能请求任意 `http://` 域名，因此不能用 URLSession（会触发 ATS 拦截），
/// 改由 NWConnection 直接建立 TCP 连接、手写 HTTP/1.1 报文。
///
/// 能力：
/// - 任意 HTTP method、headers、body；
/// - 超时 / 取消（返回 "aborted"，与 URLSession 语义一致）；
/// - 响应解析：Content-Length、`Transfer-Encoding: chunked`、无长度读至 EOF；
/// - 可选 HTTP 代理（用户配置；连接代理 host:port，absolute-form 请求行 + Host 目标 + Proxy-Authorization Basic）；
/// - 重定向 301/302/303/307/308（最多 5 次，相对 Location 支持；303 及非 GET 的 301/302 降级 GET）；
/// - 固定 `Accept-Encoding: identity`，避免压缩；若服务端仍返回 gzip/deflate 则兜底解压；
/// - 响应体上限与 HTTPBridge 一致（16 MiB）；
/// - 线程：内部串行队列处理网络，completion 在内部队列回调（调用方自行 hop）。
final class NWHTTPClient {

    private final class State {
        let id: Int
        let initialURL: URL
        var currentURL: URL
        var method: String
        var headers: [String: String]
        var body: Data?
        var redirectCount = 0
        let maxRedirects: Int
        /// 请求发起时代理配置快照（后台队列安全使用）
        let proxy: ResolvedHTTPProxy?
        var connection: NWConnection?
        var buffer = Data()
        var headersParsed = false
        var completed = false
        var cancelled = false
        /// 传输层重试次数（连接被提前关闭/重置时整请求重试一次）
        var attempt = 0
        var timeoutWork: DispatchWorkItem?
        let timeout: TimeInterval
        let completion: (String?, HTTPBridge.Response?) -> Void

        init(id: Int, request: HTTPBridge.PreparedRequest, completion: @escaping (String?, HTTPBridge.Response?) -> Void) {
            self.id = id
            self.initialURL = request.url
            self.currentURL = request.url
            self.method = request.method
            var normalized: [String: String] = [:]
            for (key, value) in request.headers { normalized[key.lowercased()] = value }
            self.headers = normalized
            self.body = request.body
            self.timeout = request.timeout
            self.maxRedirects = request.maxRedirects
            self.proxy = NetworkProxyStore.shared.current
            self.completion = completion
        }
    }

    private let queue = DispatchQueue(label: "melo.nw-http", qos: .userInitiated)
    private let lock = NSLock()
    private var states: [Int: State] = [:]
    private static let maxHeaderBytes = 256 * 1024
    private static let maxResponseBytes = HTTPBridge.maxResponseBytes

    // MARK: - 对外 API

    func request(id: Int, request: HTTPBridge.PreparedRequest, completion: @escaping (String?, HTTPBridge.Response?) -> Void) {
        let state = State(id: id, request: request, completion: completion)
        lock.lock()
        states[id] = state
        lock.unlock()
        queue.async { [weak self] in
            self?.start(state)
        }
    }

    func cancel(id: Int) {
        lock.lock()
        let state = states.removeValue(forKey: id)
        lock.unlock()
        guard let state else { return }
        queue.async { [weak self] in
            state.cancelled = true
            self?.complete(state, error: "aborted", response: nil)
        }
    }

    func cancelAll() {
        lock.lock()
        let all = states.values
        states.removeAll()
        lock.unlock()
        queue.async { [weak self] in
            for state in all {
                state.cancelled = true
                self?.complete(state, error: "aborted", response: nil)
            }
        }
    }

    // MARK: - 生命周期

    private func start(_ state: State) {
        guard !state.completed, !state.cancelled else { return }

        let connectionHost: String
        let connectionPortValue: UInt16
        if let proxy = state.proxy {
            connectionHost = proxy.host
            connectionPortValue = UInt16(proxy.port)
        } else {
            guard let port = UInt16(exactly: state.currentURL.port ?? 80),
                  let host = state.currentURL.host, !host.isEmpty else {
                complete(state, error: "无效的 HTTP 地址", response: nil)
                return
            }
            connectionHost = host
            connectionPortValue = port
        }
        guard let connectionPort = NWEndpoint.Port(rawValue: connectionPortValue) else {
            complete(state, error: state.proxy == nil ? "无效的 HTTP 地址" : "无效的代理地址", response: nil)
            return
        }

        scheduleTimeout(state)
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let connection = NWConnection(host: NWEndpoint.Host(connectionHost), port: connectionPort, using: parameters)
        state.connection = connection
        state.buffer = Data()
        state.headersParsed = false

        connection.stateUpdateHandler = { [weak self] connectionState in
            guard let self else { return }
            switch connectionState {
            case .failed(let error):
                self.retryOrFail(state, error: "网络连接失败：\(error.localizedDescription)")
            case .waiting(let error):
                // 连接被拒绝 / DNS 失败属于确定性错误：重试一次后立即失败（不必等到超时）
                switch error {
                case .posix(let code) where code == .ECONNREFUSED:
                    self.retryOrFail(state, error: "网络连接失败：连接被拒绝")
                case .dns:
                    self.retryOrFail(state, error: "网络连接失败：域名解析失败")
                default:
                    break
                }
            case .cancelled:
                break
            default:
                break
            }
        }
        connection.start(queue: queue)

        let requestData = buildRequestData(state)
        connection.send(content: requestData, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if let error {
                self.retryOrFail(state, error: "发送请求失败：\(error.localizedDescription)")
                return
            }
            self.receive(state)
        })
    }

    private func receive(_ state: State) {
        guard let connection = state.connection, !state.completed, !state.cancelled else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                self.retryOrFail(state, error: "接收响应失败：\(error.localizedDescription)")
                return
            }
            if let data, !data.isEmpty {
                state.buffer.append(data)
                if state.buffer.count > Self.maxResponseBytes + Self.maxHeaderBytes {
                    self.complete(state, error: "响应体超过 16 MiB 限制", response: nil)
                    return
                }
            }

            if let result = self.parse(state, connectionFinished: isComplete) {
                self.handle(result, state: state)
                return
            }
            if isComplete {
                if ProcessInfo.processInfo.environment["MELO_HTTP_DEBUG"] == "1" {
                    let preview = String(data: state.buffer.prefix(600), encoding: .isoLatin1) ?? "<binary>"
                    FileHandle.standardError.write(Data("[NW] incomplete \(state.currentURL.host ?? "?"): \(state.buffer.count) bytes\n\(preview)\n".utf8))
                }
                self.retryOrFail(state, error: "连接提前关闭（响应不完整）")
                return
            }
            self.receive(state)
        }
    }

    private func handle(_ result: ParseResult, state: State) {
        switch result {
        case .complete(let statusCode, let statusMessage, let headers, let body):
            handleResponse(state, statusCode: statusCode, statusMessage: statusMessage, headers: headers, body: body)
        case .redirect(let statusCode, let location):
            handleRedirect(state, statusCode: statusCode, location: location)
        case .failure(let message):
            complete(state, error: message, response: nil)
        }
    }

    private enum ParseResult {
        case complete(statusCode: Int, statusMessage: String, headers: [String: String], body: Data)
        case redirect(statusCode: Int, location: String)
        case failure(String)
    }

    /// 每次收到数据后重新解析整个 buffer（源站元数据响应通常 < 1 MiB，实现更稳）。
    private func parse(_ state: State, connectionFinished: Bool) -> ParseResult? {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerRange = state.buffer.range(of: separator) else {
            if state.buffer.count > Self.maxHeaderBytes { return .failure("响应头过大") }
            return nil
        }
        let headerData = state.buffer[state.buffer.startIndex..<headerRange.lowerBound]
        guard let headerText = String(data: Data(headerData), encoding: .isoLatin1) else {
            return .failure("响应头编码无效")
        }
        var lines = headerText.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else { return .failure("缺少 HTTP 状态行") }
        lines.removeFirst()
        let statusParts = statusLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard statusParts.count >= 2, statusParts[0].hasPrefix("HTTP/"),
              let statusCode = Int(statusParts[1]) else {
            return .failure("无效的 HTTP 状态行：\(statusLine)")
        }
        let statusMessage = statusParts.count >= 3 ? String(statusParts[2]) : ""

        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if let existing = headers[key] {
                headers[key] = existing + ", " + value
            } else {
                headers[key] = value
            }
        }

        let rawBody = Data(state.buffer[headerRange.upperBound...])
        let hasBody = !(statusCode == 204 || statusCode == 304 || state.method == "HEAD")
        var body: Data
        if !hasBody {
            body = Data()
        } else if let transferEncoding = headers["transfer-encoding"]?.lowercased(),
                  transferEncoding.contains("chunked") {
            guard let decoded = Self.decodeChunked(rawBody) else {
                return nil
            }
            body = decoded
        } else if let contentLengthText = headers["content-length"],
                  let contentLength = Int(contentLengthText.trimmingCharacters(in: .whitespaces)) {
            guard rawBody.count >= contentLength else { return nil }
            body = rawBody.prefix(contentLength)
        } else {
            // 无长度：只有连接关闭后才能确定 body 结束
            guard connectionFinished else { return nil }
            body = rawBody
        }

        body = Self.decodeContentEncodingIfNeeded(body, headers: headers)
        if body.count > Self.maxResponseBytes {
            return .failure("响应体超过 16 MiB 限制")
        }

        if (301...308).contains(statusCode), let location = headers["location"], !location.isEmpty {
            return .redirect(statusCode: statusCode, location: location)
        }
        return .complete(statusCode: statusCode, statusMessage: statusMessage, headers: headers, body: body)
    }

    private func handleResponse(_ state: State, statusCode: Int, statusMessage: String, headers: [String: String], body: Data) {
        // 代理认证失败（407）映射为可读错误；其余代理响应（404/500/502...）按原样透传
        if state.proxy != nil, statusCode == 407 {
            complete(state, error: "代理认证失败（HTTP 407），请检查代理用户名/密码", response: nil)
            return
        }
        complete(state, error: nil, response: HTTPBridge.Response(
            statusCode: statusCode,
            statusMessage: statusMessage.isEmpty ? HTTPURLResponse.localizedString(forStatusCode: statusCode) : statusMessage,
            headers: headers,
            data: body
        ))
    }

    private func handleRedirect(_ state: State, statusCode: Int, location: String) {
        guard let resolved = URL(string: location, relativeTo: state.currentURL)?.absoluteURL else {
            complete(state, error: "无法解析重定向地址：\(location)", response: nil)
            return
        }
        guard state.redirectCount < state.maxRedirects else {
            complete(state, error: "重定向次数超过 \(state.maxRedirects) 次", response: nil)
            return
        }
        state.redirectCount += 1

        // 303 一律 GET；301/302 对非 GET 也降级 GET；307/308 保持原 method/body
        let shouldSwitchToGET = statusCode == 303 ||
            ((statusCode == 301 || statusCode == 302) && state.method != "GET" && state.method != "HEAD")
        if shouldSwitchToGET {
            state.method = "GET"
            state.body = nil
            state.headers.removeValue(forKey: "content-length")
            state.headers.removeValue(forKey: "content-type")
        }

        state.connection?.cancel()
        state.connection = nil
        state.currentURL = resolved
        start(state)
    }

    private func complete(_ state: State, error: String?, response: HTTPBridge.Response?) {
        guard !state.completed else { return }
        state.completed = true
        state.timeoutWork?.cancel()
        state.connection?.cancel()
        state.connection = nil
        lock.lock()
        if states[state.id] === state { states.removeValue(forKey: state.id) }
        lock.unlock()
        state.completion(error, response)
    }

    /// 传输层瞬断（连接重置/提前关闭）时整请求重试一次；第二次仍失败才上报。
    private func retryOrFail(_ state: State, error: String) {
        guard !state.completed, !state.cancelled else { return }
        if state.attempt < 1 {
            state.attempt += 1
            MeloLog.warn("NWHTTP 传输瞬断，重试一次：\(error)")
            state.connection?.cancel()
            state.connection = nil
            state.buffer = Data()
            state.headersParsed = false
            queue.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let self, !state.completed, !state.cancelled else { return }
                self.start(state)
            }
            return
        }
        complete(state, error: error, response: nil)
    }

    private func scheduleTimeout(_ state: State) {
        guard state.timeoutWork == nil else { return }
        let work = DispatchWorkItem { [weak self, weak state] in
            guard let self, let state, !state.completed else { return }
            self.complete(state, error: "请求超时", response: nil)
        }
        state.timeoutWork = work
        queue.asyncAfter(deadline: .now() + state.timeout, execute: work)
    }

    // MARK: - 请求构造

    private func buildRequestData(_ state: State) -> Data {
        let url = state.currentURL
        let host = url.host ?? ""
        let defaultPort = url.scheme?.lowercased() == "https" ? 443 : 80
        let port = url.port ?? defaultPort
        let hostHeader = port == defaultPort ? host : "\(host):\(port)"
        var path = url.path.isEmpty ? "/" : url.path
        if let query = url.query, !query.isEmpty { path += "?" + query }

        var headers = state.headers
        if headers["host"] == nil { headers["host"] = hostHeader }
        headers["accept-encoding"] = "identity"
        if headers["connection"] == nil { headers["connection"] = "close" }
        if let body = state.body {
            headers["content-length"] = String(body.count)
        } else if state.method == "POST" || state.method == "PUT" || state.method == "PATCH" {
            headers["content-length"] = "0"
        }

        // 经 HTTP 代理时使用 absolute-form 请求行（Host 仍为目标主机），并附 Proxy-Authorization
        var requestTarget = path
        if let proxy = state.proxy {
            requestTarget = "\(url.scheme?.lowercased() ?? "http")://\(hostHeader)\(path)"
            if let authorization = proxy.basicAuthorization {
                headers["proxy-authorization"] = authorization
            }
        }

        var text = "\(state.method) \(requestTarget) HTTP/1.1\r\n"
        for (key, value) in headers {
            text += "\(key): \(value)\r\n"
        }
        text += "\r\n"
        var data = Data(text.utf8)
        if let body = state.body { data.append(body) }
        return data
    }

    // MARK: - 响应解码

    /// 解析 chunked 编码；数据不完整返回 nil
    private static func decodeChunked(_ input: Data) -> Data? {
        var output = Data()
        var index = input.startIndex
        let crlf = Data("\r\n".utf8)
        while true {
            guard let lineEnd = input.range(of: crlf, in: index..<input.endIndex) else { return nil }
            let lineData = input[index..<lineEnd.lowerBound]
            guard let lineText = String(data: Data(lineData), encoding: .utf8) else { return nil }
            let sizeText = lineText.split(separator: ";", maxSplits: 1).first.map(String.init) ?? lineText
            guard let size = Int(sizeText.trimmingCharacters(in: .whitespaces), radix: 16), size >= 0 else {
                return nil
            }
            let dataStart = lineEnd.upperBound
            if size == 0 {
                // 结尾：0 长度块之后是可选 trailer，以空行结束
                var scan = dataStart
                while true {
                    guard let lineRange = input.range(of: crlf, in: scan..<input.endIndex) else { return nil }
                    if lineRange.lowerBound == scan { return output }
                    scan = lineRange.upperBound
                }
            }
            guard let dataEnd = input.index(dataStart, offsetBy: size, limitedBy: input.endIndex) else { return nil }
            output.append(input[dataStart..<dataEnd])
            guard let crlfEnd = input.index(dataEnd, offsetBy: 2, limitedBy: input.endIndex),
                  input[dataEnd..<crlfEnd] == crlf else { return nil }
            index = crlfEnd
        }
    }

    private static func decodeContentEncodingIfNeeded(_ body: Data, headers: [String: String]) -> Data {
        guard let encoding = headers["content-encoding"]?.lowercased(), !encoding.isEmpty, encoding != "identity" else {
            return body
        }
        let bytes = [UInt8](body)
        if encoding.contains("gzip") {
            if let inflated = gzipInflate(bytes) { return inflated }
        } else if encoding.contains("deflate") {
            if let inflated = ZlibCodec.inflate(bytes) { return Data(inflated) }
            if let inflated = ZlibCodec.inflateRaw(bytes) { return Data(inflated) }
        }
        return body
    }

    /// gzip = 10 字节头（可扩展）+ raw DEFLATE + 8 字节尾
    private static func gzipInflate(_ bytes: [UInt8]) -> Data? {
        guard bytes.count > 18, bytes[0] == 0x1F, bytes[1] == 0x8B, bytes[2] == 0x08 else { return nil }
        let flags = bytes[3]
        var offset = 10
        if flags & 0x04 != 0 { // FEXTRA
            guard bytes.count >= offset + 2 else { return nil }
            let xlen = Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8)
            offset += 2 + xlen
        }
        if flags & 0x08 != 0 { // FNAME
            while offset < bytes.count, bytes[offset] != 0 { offset += 1 }
            offset += 1
        }
        if flags & 0x10 != 0 { // FCOMMENT
            while offset < bytes.count, bytes[offset] != 0 { offset += 1 }
            offset += 1
        }
        if flags & 0x02 != 0 { offset += 2 } // FHCRC
        guard offset < bytes.count - 8 else { return nil }
        let deflateData = Array(bytes[offset..<(bytes.count - 8)])
        guard let inflated = ZlibCodec.inflateRaw(deflateData) else { return nil }
        return Data(inflated)
    }
}
