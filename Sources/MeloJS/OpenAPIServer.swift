import Foundation
import Network
import MeloCore

/// 开放 API 本地 HTTP 服务（MeloJS 实现）。
///
/// - 仅监听 `127.0.0.1`（`NWParameters.requiredInterfaceType = .loopback`）；
/// - 最小 HTTP/1.1：GET/POST、query、Content-Length body、`Connection: close`（无需 keep-alive/chunked 请求）；
/// - 端口传 0 时使用系统随机端口，实际端口通过 `actualPort` 暴露；
/// - token 非空时 `/api/*` 需要 `Authorization: Bearer <token>` 或 `?token=`；
/// - 状态/命令由 `OpenAPIHost`（AppModel）在 @MainActor 上提供，服务只负责路由/鉴权/JSON。
@MainActor
public final class OpenAPIServer: OpenAPIServing {

    public private(set) var isRunning = false
    /// 实际监听端口（port 传 0 时由系统分配）
    public private(set) var actualPort: UInt16 = 0
    /// 最近一次启动/运行错误（供 App 显示）
    public private(set) var lastError: String?

    private weak var host: (any OpenAPIHost)?
    private var token: String?
    private var listener: NWListener?
    private var bindLanEnabled = false
    private var sseSessions: [ObjectIdentifier: SSESession] = [:]

    private let queue = DispatchQueue(label: "melo.openapi.listener", qos: .userInitiated)
    private let registry = ConnectionRegistry()

    private static let maxHeaderBytes = 64 * 1024
    private static let maxBodyBytes = 1 * 1024 * 1024
    private static let maxConnections = 64
    private static let idleTimeout: TimeInterval = 15

    /// 服务认识的命令（其余直接 404，避免把任意字符串转给 AppModel）
    private static let knownCommands: Set<String> = [
        "play", "pause", "toggle", "toggleplay", "toggleplaypause",
        "next", "skipnext", "previous", "prev", "skipprev",
        "seek", "volume", "setvolume", "collect", "like", "uncollect", "unlike",
    ]

    public init() {}

    // MARK: - 生命周期

    public func start(port: UInt16, token: String?, host: OpenAPIHost) throws {
        try start(port: port, token: token, bindLan: false, host: host)
    }

    /// 原版兼容：bindLan=true 监听 0.0.0.0（局域网可访问）；false 仅 127.0.0.1
    public func start(port: UInt16, token: String?, bindLan: Bool, host: OpenAPIHost) throws {
        guard !isRunning else {
            lastError = "开放 API 已在运行"
            throw OpenAPIServerError.alreadyRunning
        }
        self.lastError = nil
        self.host = host
        self.bindLanEnabled = bindLan
        let trimmedToken = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.token = (trimmedToken?.isEmpty ?? true) ? nil : trimmedToken

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        if !bindLan {
            parameters.requiredInterfaceType = .loopback
        }

        let listener: NWListener
        do {
            if port == 0 {
                listener = try NWListener(using: parameters, on: .any)
            } else {
                guard let requestedPort = NWEndpoint.Port(rawValue: port) else {
                    throw OpenAPIServerError.invalidPort
                }
                listener = try NWListener(using: parameters, on: requestedPort)
            }
        } catch let error as OpenAPIServerError {
            lastError = error.localizedDescription
            throw error
        } catch {
            let bindHost = bindLan ? "0.0.0.0" : "127.0.0.1"
            lastError = "无法监听 \(bindHost):\(port)：\(error.localizedDescription)"
            throw OpenAPIServerError.listenFailed(lastError!)
        }

        self.listener = listener
        let startBox = StartBox()
        let semaphore = DispatchSemaphore(value: 0)

        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                startBox.markReady()
                semaphore.signal()
            case .failed(let error):
                startBox.markFailed(error.localizedDescription)
                semaphore.signal()
            default:
                break
            }
            Task { @MainActor [weak self] in
                self?.handleListenerState(state)
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor [weak self] in
                self?.accept(connection)
            }
        }
        listener.start(queue: queue)

        let waitResult = semaphore.wait(timeout: .now() + 5)
        if waitResult == .timedOut {
            listener.cancel()
            self.listener = nil
            let bindHost = bindLan ? "0.0.0.0" : "127.0.0.1"
            lastError = "开放 API 启动超时（\(bindHost):\(port)）"
            throw OpenAPIServerError.startTimeout
        }
        if let error = startBox.errorMessage {
            listener.cancel()
            self.listener = nil
            lastError = "开放 API 启动失败：\(error)"
            throw OpenAPIServerError.listenFailed(error)
        }
        guard let actual = listener.port?.rawValue, actual > 0 else {
            listener.cancel()
            self.listener = nil
            lastError = "开放 API 未能确定监听端口"
            throw OpenAPIServerError.listenFailed("未能确定监听端口")
        }
        actualPort = actual
        isRunning = true
        lastError = nil
    }

    public func stop() {
        closeAllSSESessions()
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        for connection in registry.removeAll() {
            connection.cancel()
        }
        host = nil
        token = nil
        bindLanEnabled = false
        isRunning = false
        actualPort = 0
    }

    private func handleListenerState(_ state: NWListener.State) {
        guard isRunning else { return }
        if case .failed(let error) = state {
            lastError = "开放 API 异常停止：\(error.localizedDescription)"
            isRunning = false
            actualPort = 0
            listener = nil
            for connection in registry.removeAll() {
                connection.cancel()
            }
        }
    }

    // MARK: - 连接处理

    private final class ConnectionContext: @unchecked Sendable {
        let connection: NWConnection
        var buffer = Data()
        var completed = false
        var timeoutTask: Task<Void, Never>?
        init(connection: NWConnection) {
            self.connection = connection
        }
    }

    /// 一条 SSE 订阅连接（原版 /subscribe-player-status）
    private final class SSESession: @unchecked Sendable {
        let connection: NWConnection
        let keys: [String]
        var lastSnapshot: [String: JSONValue]
        var task: Task<Void, Never>?
        var closed = false

        init(connection: NWConnection, keys: [String], snapshot: [String: JSONValue]) {
            self.connection = connection
            self.keys = keys
            self.lastSnapshot = snapshot
        }
    }

    private func accept(_ connection: NWConnection) {
        guard isRunning else {
            connection.cancel()
            return
        }
        guard registry.add(connection) else {
            Self.sendImmediateError(
                "服务繁忙（连接数超过 \(Self.maxConnections)）",
                status: 503,
                to: connection
            )
            return
        }
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                Task { @MainActor [weak self] in
                    self?.handleConnectionClosed(connection)
                }
            default:
                break
            }
        }
        connection.start(queue: queue)
        let context = ConnectionContext(connection: connection)
        context.timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.idleTimeout * 1_000_000_000))
            guard !Task.isCancelled, let self, !context.completed else { return }
            context.completed = true
            context.connection.cancel()
            self.registry.remove(context.connection)
        }
        receive(context)
    }

    private func receive(_ context: ConnectionContext) {
        guard isRunning, !context.completed else { return }
        context.connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            Task { @MainActor [weak self] in
                guard let self, !context.completed else { return }
                if let data, !data.isEmpty {
                    context.buffer.append(data)
                }
                switch Self.parseRequest(buffer: context.buffer, isComplete: isComplete) {
                case .needMore:
                    if isComplete || error != nil {
                        context.completed = true
                        context.timeoutTask?.cancel()
                        context.connection.cancel()
                        self.registry.remove(context.connection)
                    } else {
                        self.receive(context)
                    }
                case .failure(let status, let message):
                    context.completed = true
                    context.timeoutTask?.cancel()
                    let response = Self.jsonResponse(
                        status: status,
                        reason: Self.reasonPhrase(status),
                        value: APIErrorEnvelope(message: message)
                    )
                    self.send(response, to: context.connection)
                case .success(let request):
                    context.completed = true
                    context.timeoutTask?.cancel()
                    switch await self.route(request, connection: context.connection) {
                    case .response(let response):
                        self.send(response, to: context.connection)
                    case .sseStarted:
                        break
                    }
                }
            }
        }
    }

    private func send(_ response: HTTPResponse, to connection: NWConnection) {
        var headers = response.headers
        headers["Content-Length"] = String(response.body.count)
        headers["Connection"] = "close"
        headers["Cache-Control"] = "no-store"
        headers["Access-Control-Allow-Origin"] = "*"
        var head = "HTTP/1.1 \(response.status) \(response.reason)\r\n"
        for (key, value) in headers {
            head += "\(key): \(value)\r\n"
        }
        head += "\r\n"
        var data = Data(head.utf8)
        data.append(response.body)
        connection.send(content: data, completion: .contentProcessed { [weak self] _ in
            connection.cancel()
            Task { @MainActor [weak self] in
                self?.registry.remove(connection)
            }
        })
    }

    private static func sendImmediateError(_ message: String, status: Int, to connection: NWConnection) {
        let body = (try? JSONEncoder().encode(APIErrorEnvelope(message: message))) ?? Data()
        var head = "HTTP/1.1 \(status) \(reasonPhrase(status))\r\n"
        head += "Content-Type: application/json; charset=utf-8\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n"
        head += "Access-Control-Allow-Origin: *\r\n\r\n"
        var data = Data(head.utf8)
        data.append(body)
        connection.start(queue: DispatchQueue(label: "melo.openapi.reject"))
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
    }

    // MARK: - 路由

    /// 自定义 `/api/*` 协议（保持 Round 7 行为：token 鉴权 + JSON）
    private func customRoute(_ request: HTTPRequest) async -> HTTPResponse {
        guard let components = URLComponents(string: "http://127.0.0.1" + request.target) else {
            return Self.jsonResponse(status: 400, reason: "Bad Request", value: APIErrorEnvelope(message: "无效的请求地址"))
        }
        let path = components.path
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] {
            query[item.name] = item.value ?? ""
        }

        // /api/* 需要 token（/ 说明页公开，便于浏览器直接打开）
        if path.hasPrefix("/api/") {
            guard isAuthorized(request: request, query: query) else {
                return Self.jsonResponse(status: 401, reason: "Unauthorized",
                                         value: APIErrorEnvelope(message: "未授权：缺少或错误的 token（可用 Authorization: Bearer <token> 或 ?token=）"))
            }
        }

        switch path {
        case "/", "":
            guard request.method == "GET" else { return methodNotAllowed() }
            return HTTPResponse(status: 200, reason: "OK",
                                headers: ["Content-Type": "text/html; charset=utf-8"],
                                body: Data(helpPage().utf8))

        case "/api/status":
            guard request.method == "GET" else { return methodNotAllowed() }
            guard let host else { return hostUnavailable() }
            return Self.jsonResponse(status: 200, reason: "OK", value: host.openAPIStatus())

        case "/api/lyric":
            guard request.method == "GET" || request.method == "POST" else { return methodNotAllowed() }
            return Self.jsonResponse(status: 501, reason: "Not Implemented",
                                     value: APIErrorEnvelope(message: "歌词接口暂未实现（当前播放歌词可通过 App UI 查看）"))

        default:
            break
        }

        if path.hasPrefix("/api/command/") {
            guard request.method == "GET" || request.method == "POST" else { return methodNotAllowed() }
            let rawCommand = String(path.dropFirst("/api/command/".count))
            let command = rawCommand.removingPercentEncoding ?? rawCommand
            guard !command.isEmpty else {
                return Self.jsonResponse(status: 400, reason: "Bad Request", value: APIErrorEnvelope(message: "缺少命令名称"))
            }
            guard Self.knownCommands.contains(command.lowercased()) else {
                return Self.jsonResponse(status: 404, reason: "Not Found", value: APIErrorEnvelope(message: "未知命令：\(command)"))
            }
            var arguments = query
            if request.method == "POST", !request.body.isEmpty {
                switch Self.parseBodyArguments(body: request.body, headers: request.headers) {
                case .success(let bodyArgs):
                    for (key, value) in bodyArgs { arguments[key] = value }
                case .failure(let message):
                    return Self.jsonResponse(status: 400, reason: "Bad Request", value: APIErrorEnvelope(message: message))
                }
            }
            guard let host else { return hostUnavailable() }
            let result = await host.openAPICommand(command, arguments: arguments)
            let envelope = CommandEnvelope(ok: result.ok, message: result.message, status: result.status)
            return Self.jsonResponse(
                status: result.ok ? 200 : 400,
                reason: result.ok ? "OK" : "Bad Request",
                value: envelope
            )
        }

        return Self.jsonResponse(status: 404, reason: "Not Found",
                                 value: APIErrorEnvelope(message: "未知接口：\(path)"))
    }

    private func isAuthorized(request: HTTPRequest, query: [String: String]) -> Bool {
        guard let token, !token.isEmpty else { return true }
        if query["token"] == token { return true }
        guard let authorization = request.headers["authorization"] else { return false }
        let trimmed = authorization.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix("bearer ") else { return false }
        let provided = String(trimmed.dropFirst("Bearer ".count)).trimmingCharacters(in: .whitespaces)
        return provided == token
    }

    private func methodNotAllowed() -> HTTPResponse {
        HTTPResponse(status: 405, reason: "Method Not Allowed",
                     headers: ["Content-Type": "application/json; charset=utf-8", "Allow": "GET, POST"],
                     body: Self.encode(APIErrorEnvelope(message: "不支持的请求方法")))
    }

    private func hostUnavailable() -> HTTPResponse {
        Self.jsonResponse(status: 503, reason: "Service Unavailable",
                          value: APIErrorEnvelope(message: "播放器状态不可用（host 已释放）"))
    }

    private func helpPage() -> String {
        let tokenHint = token == nil
            ? "当前未设置 token，直接访问即可。"
            : "当前已启用 token：请求 /api/* 需带 Authorization: Bearer &lt;token&gt; 或 ?token=&lt;token&gt;。"
        return """
        <!DOCTYPE html>
        <html lang="zh-CN"><head><meta charset="utf-8"><title>Melo 开放 API</title></head>
        <body>
        <h1>Melo 开放 API</h1>
        <p>监听地址：<code>http://127.0.0.1:\(actualPort)</code>。\(tokenHint)</p>
        <h2>原版 LX Music 兼容协议（无需 token）</h2>
        <ul>
          <li><code>GET /status?filter=a,b</code> — player_status 字段（默认 status,name,singer,albumName,lyricLineText,duration,progress,playbackRate）</li>
          <li><code>GET /lyric</code> — 当前歌词纯文本；<code>GET /lyric-all</code> — {lyric,tlyric,rlyric,lxlyric}</li>
          <li><code>GET /play|/pause|/skip-next|/skip-prev|/collect|/uncollect</code> — 控制播放</li>
          <li><code>GET /seek?offset=秒</code>、<code>/volume?volume=0-100</code>、<code>/mute?mute=true|false</code></li>
          <li><code>GET /subscribe-player-status?filter=</code> — SSE 状态推送</li>
        </ul>
        <h2>自定义 /api 协议（token 可保护）</h2>
        <ul>
          <li><code>GET /api/status</code> — 当前播放状态（JSON）</li>
          <li><code>GET|POST /api/command/{command}</code> — play / pause / toggle / next / previous / seek(position|percent) / volume(volume) / collect / uncollect</li>
          <li><code>GET /api/lyric</code> — 歌词（暂未实现，501）</li>
        </ul>
        <p>示例：<code>curl http://127.0.0.1:\(actualPort)/status</code>；
        <code>curl -X POST -H 'Content-Type: application/json' -d '{"position":12.5}' http://127.0.0.1:\(actualPort)/api/command/seek</code></p>
        <p>监听范围：<code>\(bindLanEnabled ? "0.0.0.0（允许局域网访问，注意安全）" : "仅 127.0.0.1（本机）")</code></p>
        </body></html>
        """
    }
}

// MARK: - 原版开放 API 协议（LX Music v2.12.6）

private enum OpenAPIRouteOutcome {
    case response(OpenAPIServer.HTTPResponse)
    case sseStarted
}

private extension OpenAPIServer {
    static let originalDefaultFilter: [String] = [
        "status", "name", "singer", "albumName", "lyricLineText", "duration", "progress", "playbackRate",
    ]

    /// 原版 player_status 字段顺序（用于 filter 归一化与 SSE event 顺序）
    static let originalStatusKeyOrder: [String] = [
        "status", "name", "singer", "albumName", "picUrl", "progress", "duration", "playbackRate",
        "lyricLineText", "lyricLineAllText", "lyric", "tlyric", "rlyric", "lxlyric",
        "collect", "volume", "mute",
    ]

    /// 总路由：`/api/*` 走自定义协议（token），`/` 保留说明页，其余走原版协议
    private func route(_ request: HTTPRequest, connection: NWConnection) async -> OpenAPIRouteOutcome {
        let path = URLComponents(string: "http://127.0.0.1" + request.target)?.path ?? request.target
        if path.hasPrefix("/api/") || path == "/" || path.isEmpty {
            return .response(await customRoute(request))
        }
        return await originalProtocolRoute(request, connection: connection)
    }

    private func originalProtocolRoute(_ request: HTTPRequest, connection: NWConnection) async -> OpenAPIRouteOutcome {
        let components = URLComponents(string: "http://127.0.0.1" + request.target)
        let path = components?.path ?? request.target
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] {
            query[item.name] = item.value ?? ""
        }
        guard let host else {
            return .response(Self.textResponse(503, "Service Unavailable"))
        }

        switch path {
        case "/status":
            let status = host.openAPIPlayerStatus()
            let keys = Self.originalFilterKeys(query["filter"], statusKeys: Set(status.keys))
            var filtered: [String: JSONValue] = [:]
            for key in keys {
                if let value = status[key] { filtered[key] = value }
            }
            return .response(Self.jsonResponse(status: 200, reason: "OK", value: filtered))

        case "/lyric":
            return .response(Self.textResponse(200, host.openAPILyricBundle()["lyric"] ?? ""))

        case "/lyric-all":
            return .response(Self.jsonResponse(status: 200, reason: "OK", value: host.openAPILyricBundle()))

        case "/play":
            _ = await host.openAPICommand("play", arguments: [:])
            return .response(Self.textResponse(200, "OK"))
        case "/pause":
            _ = await host.openAPICommand("pause", arguments: [:])
            return .response(Self.textResponse(200, "OK"))
        case "/skip-next":
            _ = await host.openAPICommand("next", arguments: [:])
            return .response(Self.textResponse(200, "OK"))
        case "/skip-prev":
            _ = await host.openAPICommand("previous", arguments: [:])
            return .response(Self.textResponse(200, "OK"))
        case "/collect":
            _ = await host.openAPICommand("collect", arguments: [:])
            return .response(Self.textResponse(200, "OK"))
        case "/uncollect":
            _ = await host.openAPICommand("uncollect", arguments: [:])
            return .response(Self.textResponse(200, "OK"))

        case "/seek":
            let duration = host.openAPIPlayerStatus()["duration"]?.doubleValue ?? 0
            guard let raw = query["offset"], let offset = Self.parseFloatJS(raw),
                  !offset.isNaN, offset >= 0, offset <= duration else {
                return .response(Self.textResponse(400, "Invalid offset"))
            }
            _ = await host.openAPICommand("seek", arguments: ["position": String(format: "%.3f", offset)])
            return .response(Self.textResponse(200, "OK"))

        case "/volume":
            guard let raw = query["volume"], let volume = Self.parseIntJS(raw),
                  volume >= 0, volume <= 100 else {
                return .response(Self.textResponse(400, "Invalid volume"))
            }
            _ = await host.openAPICommand("volume", arguments: ["volume": String(Double(volume) / 100.0)])
            return .response(Self.textResponse(200, "OK"))

        case "/mute":
            guard let value = query["mute"], value == "true" || value == "false" else {
                return .response(Self.textResponse(400, "Invalid mute value"))
            }
            _ = await host.openAPICommand("mute", arguments: ["mute": value])
            return .response(Self.textResponse(200, "OK"))

        case "/subscribe-player-status":
            startSSESession(connection: connection, request: request, query: query)
            return .sseStarted

        default:
            return .response(Self.textResponse(401, "Forbidden"))
        }
    }

    // MARK: - SSE

    private func startSSESession(connection: NWConnection, request: HTTPRequest, query: [String: String]) {
        guard let host else {
            send(Self.textResponse(503, "Service Unavailable"), to: connection)
            return
        }
        let status = host.openAPIPlayerStatus()
        let keys = Self.originalFilterKeys(query["filter"], statusKeys: Set(status.keys))
        let session = SSESession(connection: connection, keys: keys, snapshot: status)
        sseSessions[ObjectIdentifier(connection)] = session

        var header = "HTTP/1.1 200 OK\r\n"
        header += "Content-Type: text/event-stream\r\n"
        header += "Cache-Control: no-cache\r\n"
        header += "Connection: keep-alive\r\n"
        header += "Access-Control-Allow-Origin: *\r\n"
        header += "Transfer-Encoding: chunked\r\n\r\n"
        connection.send(content: Data(header.utf8), completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if error != nil {
                Task { @MainActor [weak self] in self?.closeSSESession(session) }
                return
            }
            Task { @MainActor [weak self] in self?.sendSSEInitial(session) }
        })

        session.task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled, let self, !session.closed, let host = self.host else { break }
                let current = host.openAPIPlayerStatus()
                var changes: [(String, JSONValue)] = []
                for key in session.keys {
                    if current[key] != session.lastSnapshot[key], let value = current[key] {
                        changes.append((key, value))
                    }
                }
                guard !changes.isEmpty else { continue }
                session.lastSnapshot = current
                self.sendSSEEvents(session, changes: changes)
            }
        }
    }

    private func sendSSEInitial(_ session: SSESession) {
        guard !session.closed else { return }
        var text = ""
        for key in session.keys {
            guard let value = session.lastSnapshot[key] else { continue }
            text += "event: \(key)\ndata: \(value.jsonString() ?? "null")\n\n"
        }
        writeSSE(session, text)
    }

    private func sendSSEEvents(_ session: SSESession, changes: [(String, JSONValue)]) {
        var text = ""
        for (key, value) in changes {
            text += "event: \(key)\ndata: \(value.jsonString() ?? "null")\n\n"
        }
        writeSSE(session, text)
    }

    private func writeSSE(_ session: SSESession, _ text: String) {
        guard !session.closed, !text.isEmpty else { return }
        let data = Data(text.utf8)
        var frame = Data("\(String(data.count, radix: 16))\r\n".utf8)
        frame.append(data)
        frame.append(Data("\r\n".utf8))
        session.connection.send(content: frame, completion: .contentProcessed { [weak self] error in
            guard error != nil else { return }
            Task { @MainActor [weak self] in self?.closeSSESession(session) }
        })
    }

    private func closeSSESession(_ session: SSESession) {
        guard !session.closed else { return }
        session.closed = true
        session.task?.cancel()
        session.task = nil
        sseSessions.removeValue(forKey: ObjectIdentifier(session.connection))
        session.connection.cancel()
        registry.remove(session.connection)
    }

    private func closeAllSSESessions() {
        for session in sseSessions.values {
            session.closed = true
            session.task?.cancel()
            session.connection.cancel()
        }
        sseSessions.removeAll()
    }

    private func handleConnectionClosed(_ connection: NWConnection) {
        registry.remove(connection)
        if let session = sseSessions.removeValue(forKey: ObjectIdentifier(connection)) {
            session.closed = true
            session.task?.cancel()
            session.task = nil
        }
    }

    // MARK: - 原版辅助

    private static func originalFilterKeys(_ filter: String?, statusKeys: Set<String>) -> [String] {
        if let filter, !filter.isEmpty {
            let requested = Set(filter.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
            let matched = originalStatusKeyOrder.filter { requested.contains($0) && statusKeys.contains($0) }
            if !matched.isEmpty { return matched }
        }
        return originalDefaultFilter.filter { statusKeys.contains($0) }
    }

    private static func textResponse(_ status: Int, _ message: String) -> HTTPResponse {
        HTTPResponse(
            status: status,
            reason: reasonPhrase(status),
            headers: ["Content-Type": "text/plain; charset=utf-8"],
            body: Data(message.utf8)
        )
    }

    /// JS parseFloat 语义（接受前缀数字，如 "12.5abc" → 12.5）
    private static func parseFloatJS(_ raw: String) -> Double? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard let range = trimmed.range(of: #"^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?"#, options: .regularExpression) else {
            return nil
        }
        return Double(trimmed[range])
    }

    /// JS parseInt 语义（接受前缀整数，如 "50abc" → 50）
    private static func parseIntJS(_ raw: String) -> Int? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard let range = trimmed.range(of: #"^[+-]?\d+"#, options: .regularExpression) else {
            return nil
        }
        return Int(trimmed[range])
    }
}

// MARK: - HTTP 数据模型

extension OpenAPIServer {
    fileprivate struct HTTPRequest {
        var method: String
        var target: String
        var headers: [String: String]
        var body: Data
    }

    fileprivate struct HTTPResponse {
        var status: Int
        var reason: String
        var headers: [String: String]
        var body: Data
    }

    fileprivate struct CommandEnvelope: Encodable {
        var ok: Bool
        var message: String?
        var status: OpenAPIStatus?
    }

    fileprivate struct APIErrorEnvelope: Encodable {
        var ok: Bool = false
        var message: String
    }

    fileprivate enum ParseOutcome {
        case needMore
        case success(HTTPRequest)
        case failure(status: Int, message: String)
    }

    fileprivate static func parseRequest(buffer: Data, isComplete: Bool) -> ParseOutcome {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerRange = buffer.range(of: separator) else {
            if buffer.count > maxHeaderBytes {
                return .failure(status: 431, message: "请求头过大")
            }
            if isComplete {
                return .failure(status: 400, message: "请求不完整")
            }
            return .needMore
        }
        guard let headerText = String(data: Data(buffer[..<headerRange.lowerBound]), encoding: .isoLatin1) else {
            return .failure(status: 400, message: "请求头编码无效")
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            return .failure(status: 400, message: "缺少请求行")
        }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            return .failure(status: 400, message: "无效的请求行")
        }
        let method = String(parts[0]).uppercased()
        let target = String(parts[1])
        guard target.hasPrefix("/") else {
            return .failure(status: 400, message: "无效的请求路径")
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }
        if let transferEncoding = headers["transfer-encoding"]?.lowercased(),
           transferEncoding.contains("chunked") {
            return .failure(status: 400, message: "不支持 chunked 请求体")
        }
        let bodyOffset = headerRange.upperBound
        let availableBody = buffer.distance(from: bodyOffset, to: buffer.endIndex)
        let contentLength = Int(headers["content-length"]?.trimmingCharacters(in: .whitespaces) ?? "0") ?? 0
        if contentLength > maxBodyBytes {
            return .failure(status: 413, message: "请求体超过 1 MiB 限制")
        }
        let body: Data
        if availableBody >= contentLength {
            body = Data(buffer[bodyOffset..<buffer.index(bodyOffset, offsetBy: contentLength)])
        } else if isComplete {
            return .failure(status: 400, message: "请求体不完整")
        } else {
            return .needMore
        }
        return .success(HTTPRequest(method: method, target: target, headers: headers, body: body))
    }

    fileprivate enum BodyParseOutcome {
        case success([String: String])
        case failure(String)
    }

    fileprivate static func parseBodyArguments(body: Data, headers: [String: String]) -> BodyParseOutcome {
        let contentType = (headers["content-type"] ?? "").lowercased()
        if contentType.contains("application/json") {
            guard let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
                return .failure("请求体不是合法的 JSON 对象")
            }
            var arguments: [String: String] = [:]
            for (key, value) in object {
                if let string = value as? String {
                    arguments[key] = string
                } else if let bool = value as? Bool {
                    arguments[key] = bool ? "true" : "false"
                } else if let number = value as? NSNumber {
                    arguments[key] = number.stringValue
                } else if let array = value as? [Any],
                          let data = try? JSONSerialization.data(withJSONObject: array),
                          let text = String(data: data, encoding: .utf8) {
                    arguments[key] = text
                }
            }
            return .success(arguments)
        }
        if let text = String(data: body, encoding: .utf8) {
            var arguments: [String: String] = [:]
            for pair in text.split(separator: "&") where !pair.isEmpty {
                let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let key = String(parts[0]).removingPercentEncoding ?? String(parts[0])
                let value = parts.count > 1 ? (String(parts[1]).removingPercentEncoding ?? String(parts[1])) : ""
                arguments[key] = value
            }
            return .success(arguments)
        }
        return .failure("请求体不是 UTF-8 文本")
    }

    fileprivate static func encode<T: Encodable>(_ value: T) -> Data {
        (try? JSONEncoder().encode(value)) ?? Data("{\"ok\":false,\"message\":\"JSON 序列化失败\"}".utf8)
    }

    fileprivate static func jsonResponse<T: Encodable>(status: Int, reason: String, value: T) -> HTTPResponse {
        HTTPResponse(status: status, reason: reason,
                     headers: ["Content-Type": "application/json; charset=utf-8"],
                     body: encode(value))
    }

    fileprivate static func reasonPhrase(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 413: return "Payload Too Large"
        case 431: return "Request Header Fields Too Large"
        case 501: return "Not Implemented"
        case 503: return "Service Unavailable"
        default: return "Error"
        }
    }
}

// MARK: - 线程安全连接注册表

private final class ConnectionRegistry {
    private let lock = NSLock()
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    @discardableResult
    func add(_ connection: NWConnection) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard connections.count < 64 else { return false }
        connections[ObjectIdentifier(connection)] = connection
        return true
    }

    func remove(_ connection: NWConnection) {
        lock.lock()
        connections.removeValue(forKey: ObjectIdentifier(connection))
        lock.unlock()
    }

    func removeAll() -> [NWConnection] {
        lock.lock()
        defer { lock.unlock() }
        let all = Array(connections.values)
        connections.removeAll()
        return all
    }
}

// MARK: - 启动同步盒

private final class StartBox {
    private let lock = NSLock()
    private var ready = false
    private var failure: String?

    func markReady() {
        lock.lock(); ready = true; lock.unlock()
    }

    func markFailed(_ message: String) {
        lock.lock(); failure = message; lock.unlock()
    }

    var errorMessage: String? {
        lock.lock(); defer { lock.unlock() }
        return failure
    }
}

// MARK: - 错误

public enum OpenAPIServerError: LocalizedError {
    case alreadyRunning
    case invalidPort
    case startTimeout
    case listenFailed(String)

    public var errorDescription: String? {
        switch self {
        case .alreadyRunning: return "开放 API 已在运行"
        case .invalidPort: return "开放 API 端口无效"
        case .startTimeout: return "开放 API 启动超时"
        case .listenFailed(let message): return "开放 API 监听失败：\(message)"
        }
    }
}
