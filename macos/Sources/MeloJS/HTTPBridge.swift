import Foundation
import CFNetwork
import MeloCore

/// `lx.request` 的 Swift 侧实现（替代原版 Electron preload 里的 needle）。
///
/// 语义对齐 `preload.js`：
/// - 支持 method / headers / body / form / formData / timeout（上限 60s）
/// - 回调 `err, resp, body`，resp 形态 `{statusCode,statusMessage,headers,bytes,raw,body}`
/// - 返回取消函数 → `cancel(id:)`
/// - 只允许 http(s)，响应体上限 16 MiB（防脚本/远端拖垮 App 内存）
///
/// 传输层：
/// - 支持用户自定义 HTTP/HTTPS 代理（`ProxyConfiguring` → `configureProxy`）：
///   显式配置优先于环境变量 `HTTP(S)_PROXY`，禁用时回退环境变量；
/// - `https://` → URLSession（connectionProxyDictionary + 系统 TLS/压缩处理）；
/// - `http://`  → `NWHTTPClient`（Network.framework 原始 HTTP/1.1），
///   绕过 macOS 26/27 的 ATS 限制（用户自定义源可能请求任意 http 域名）。
final class HTTPBridge {

    struct Response {
        var statusCode: Int
        var statusMessage: String
        var headers: [String: String]
        var data: Data
    }

    struct PreparedRequest {
        var url: URL
        var method: String
        var headers: [String: String]
        var body: Data?
        var timeout: TimeInterval
        var maxRedirects: Int
    }

    static let maxResponseBytes = 16 * 1024 * 1024
    static let maxTimeout: TimeInterval = 60

    private var session: URLSession
    private let sessionLock = NSLock()
    private let redirectDelegate = RedirectLimitDelegate()
    private var tasks: [Int: URLSessionDataTask] = [:]
    private let rawClient = NWHTTPClient()
    private let lock = NSLock()
    private static let debugEnabled = ProcessInfo.processInfo.environment["MELO_HTTP_DEBUG"] == "1"

    /// 测试/诊断：走 Network.framework 原始 HTTP 的请求数
    private(set) var rawRequestCount = 0

    init() {
        let customProxy = NetworkProxyStore.shared.current
        let proxyDictionary = NetworkProxy.connectionProxyDictionary(for: customProxy) ?? Self.environmentProxyDictionary()
        self.session = URLSession(
            configuration: Self.makeConfiguration(proxyDictionary: proxyDictionary),
            delegate: redirectDelegate,
            delegateQueue: nil
        )
    }

    private static func makeConfiguration(proxyDictionary: [AnyHashable: Any]?) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = Self.maxTimeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.connectionProxyDictionary = proxyDictionary
        return configuration
    }

    /// 应用用户自定义代理（原版 network.proxy.*）。
    /// - https → 重建 URLSession（connectionProxyDictionary）；
    /// - http → NWHTTPClient 每次请求读取 `NetworkProxyStore` 快照；
    /// - 禁用/非法 → 清空自定义代理，https 回退到环境变量代理（开发期兼容，正常 App 无该变量）。
    func configureProxy(_ settings: ProxySettings) {
        let resolved = NetworkProxyStore.shared.update(settings)
        let dictionary = NetworkProxy.connectionProxyDictionary(for: resolved) ?? Self.environmentProxyDictionary()
        let newSession = URLSession(
            configuration: Self.makeConfiguration(proxyDictionary: dictionary),
            delegate: redirectDelegate,
            delegateQueue: nil
        )
        sessionLock.lock()
        let oldSession = session
        session = newSession
        sessionLock.unlock()
        oldSession.finishTasksAndInvalidate()
    }

    private func currentSession() -> URLSession {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        return session
    }

    /// 兼容原版 request.js 的 proxy.envProxy 语义：允许通过进程环境变量
    /// HTTP(S)_PROXY 指定代理（App 正常运行仍优先使用系统代理设置）。
    private static func environmentProxyDictionary() -> [AnyHashable: Any]? {
        let environment = ProcessInfo.processInfo.environment
        func value(_ keys: [String]) -> String? {
            for key in keys {
                if let raw = environment[key], !raw.isEmpty { return raw }
            }
            return nil
        }
        guard var proxy = value(["HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy"]) else { return nil }
        if let schemeRange = proxy.range(of: "://") { proxy = String(proxy[schemeRange.upperBound...]) }
        proxy = proxy.split(separator: "/").first.map(String.init) ?? proxy
        if let at = proxy.lastIndex(of: "@") { proxy = String(proxy[proxy.index(after: at)...]) }
        guard let colon = proxy.lastIndex(of: ":"),
              let port = Int(proxy[proxy.index(after: colon)...]) else { return nil }
        let host = String(proxy[..<colon])
        guard !host.isEmpty else { return nil }
        return [
            kCFNetworkProxiesHTTPEnable: true,
            kCFNetworkProxiesHTTPProxy: host,
            kCFNetworkProxiesHTTPPort: port,
            kCFNetworkProxiesHTTPSEnable: true,
            kCFNetworkProxiesHTTPSProxy: host,
            kCFNetworkProxiesHTTPSPort: port,
            kCFNetworkProxiesExceptionsList: ["localhost", "127.0.0.1", "::1"],
        ]
    }

    func request(id: Int, urlString: String, optionsJSON: String, completion: @escaping (String?, Response?) -> Void) {
        let options = (try? JSONSerialization.jsonObject(with: Data(optionsJSON.utf8))) as? [String: Any] ?? [:]
        guard let url = URL(string: urlString) else {
            completion("无效的请求 URL", nil)
            return
        }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            completion("仅支持 http/https 请求", nil)
            return
        }
        let prepared = Self.prepare(url: url, options: options)

        // http:// 走 Network.framework 原始 HTTP，绕过 ATS（macOS 26/27 只认 NSExceptionDomains）
        if scheme == "http" {
            rawRequestCount += 1
            rawClient.request(id: id, request: prepared) { error, response in
                if let error {
                    completion(error, nil)
                    return
                }
                guard let response else {
                    completion("无 HTTP 响应", nil)
                    return
                }
                if Self.debugEnabled {
                    Self.log(method: prepared.method, url: url, response: response)
                }
                completion(nil, response)
            }
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = prepared.method
        request.timeoutInterval = prepared.timeout
        for (key, value) in prepared.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = prepared.body

        let activeSession = currentSession()
        let taskBox = TaskReferenceBox()
        let task = activeSession.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            self.lock.lock()
            self.tasks[id] = nil
            self.lock.unlock()
            if let task = taskBox.task {
                self.redirectDelegate.remove(task: task)
            }
            if let maxRedirects = self.redirectDelegate.takeExceeded(requestID: id) {
                completion("重定向次数超过 \(maxRedirects) 次", nil)
                return
            }

            if let error {
                let nsError = error as NSError
                if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
                    completion("aborted", nil)
                } else {
                    completion(error.localizedDescription, nil)
                }
                return
            }
            guard let http = response as? HTTPURLResponse else {
                completion("无 HTTP 响应", nil)
                return
            }
            let bodyData = data ?? Data()
            guard bodyData.count <= Self.maxResponseBytes else {
                completion("响应体超过 16 MiB 限制", nil)
                return
            }
            var headers: [String: String] = [:]
            for (key, value) in http.allHeaderFields {
                headers[String(describing: key).lowercased()] = String(describing: value)
            }
            let bridged = Response(
                statusCode: http.statusCode,
                statusMessage: HTTPURLResponse.localizedString(forStatusCode: http.statusCode),
                headers: headers,
                data: bodyData
            )
            if Self.debugEnabled { Self.log(method: prepared.method, url: url, response: bridged) }
            completion(nil, bridged)
        }
        taskBox.task = task
        redirectDelegate.register(task: task, requestID: id, maxRedirects: prepared.maxRedirects)
        lock.lock()
        tasks[id] = task
        lock.unlock()
        task.resume()
    }

    func cancel(id: Int) {
        lock.lock()
        let task = tasks.removeValue(forKey: id)
        lock.unlock()
        task?.cancel()
        rawClient.cancel(id: id)
    }

    func cancelAll() {
        lock.lock()
        let all = tasks.values
        tasks.removeAll()
        lock.unlock()
        for task in all { task.cancel() }
        rawClient.cancelAll()
    }

    // MARK: - 请求构造

    static func prepare(url: URL, options: [String: Any]) -> PreparedRequest {
        var headers: [String: String] = [:]
        if let rawHeaders = options["headers"] as? [String: Any] {
            for (key, value) in rawHeaders {
                headers[key] = "\(value)"
            }
        }
        var method = (options["method"] as? String) ?? "get"
        method = method.uppercased()
        let timeoutMilliseconds = (options["timeout"] as? Double) ?? 60_000
        let timeout = min(max(timeoutMilliseconds / 1000.0, 0.1), Self.maxTimeout)

        var body: Data?
        if let rawBody = options["body"] {
            if let string = rawBody as? String {
                body = Data(string.utf8)
            } else if JSONSerialization.isValidJSONObject(rawBody),
                      let data = try? JSONSerialization.data(withJSONObject: rawBody) {
                body = data
                if headers.keys.first(where: { $0.lowercased() == "content-type" }) == nil {
                    headers["Content-Type"] = "application/json"
                }
            }
        } else if let form = options["form"] as? [String: Any] {
            body = Self.urlEncoded(form)
            if headers.keys.first(where: { $0.lowercased() == "content-type" }) == nil {
                headers["Content-Type"] = "application/x-www-form-urlencoded"
            }
        } else if let formData = options["formData"] as? [String: Any] {
            let boundary = "----MeloBoundary\(UUID().uuidString)"
            body = Self.multipart(formData, boundary: boundary)
            headers["Content-Type"] = "multipart/form-data; boundary=\(boundary)"
        }

        var maxRedirects = 5
        if let rawMax = options["maxRedirects"] as? NSNumber {
            maxRedirects = min(max(rawMax.intValue, 0), 10)
        }
        return PreparedRequest(url: url, method: method, headers: headers, body: body, timeout: timeout, maxRedirects: maxRedirects)
    }

    private static func log(method: String, url: URL, response: Response) {
        let encoding = response.headers["content-encoding"] ?? "-"
        let preview = String(data: response.data.prefix(160), encoding: .utf8) ?? "<binary>"
        let line = "[HTTP] \(method) \(url.absoluteString.prefix(110)) -> \(response.statusCode) enc=\(encoding) bytes=\(response.data.count) body=\(preview.replacingOccurrences(of: "\n", with: " "))\n"
        FileHandle.standardError.write(Data(line.utf8))
    }

    private static func urlEncoded(_ values: [String: Any]) -> Data? {
        var components = URLComponents()
        components.queryItems = values.map { URLQueryItem(name: $0.key, value: "\($0.value)") }
        return components.percentEncodedQuery.map { Data($0.utf8) }
    }

    private static func multipart(_ values: [String: Any], boundary: String) -> Data {
        var data = Data()
        for (key, value) in values {
            data.append(Data("--\(boundary)\r\n".utf8))
            data.append(Data("Content-Disposition: form-data; name=\"\(key)\"\r\n\r\n".utf8))
            data.append(Data("\(value)\r\n".utf8))
        }
        data.append(Data("--\(boundary)--\r\n".utf8))
        return data
    }
}

/// URLSession 重定向次数限制（用于在线导入自定义源：最多 3 次）
private final class RedirectLimitDelegate: NSObject, URLSessionTaskDelegate {
    private struct State {
        let requestID: Int
        let maxRedirects: Int
        var count: Int
    }

    private let lock = NSLock()
    private var states: [ObjectIdentifier: State] = [:] // key = task 对象（跨重建 session 的 taskIdentifier 可能重复）
    private var exceeded: [Int: Int] = [:] // requestID -> maxRedirects

    func register(task: URLSessionTask, requestID: Int, maxRedirects: Int) {
        lock.lock()
        states[ObjectIdentifier(task)] = State(requestID: requestID, maxRedirects: maxRedirects, count: 0)
        lock.unlock()
    }

    func remove(task: URLSessionTask) {
        lock.lock()
        states.removeValue(forKey: ObjectIdentifier(task))
        lock.unlock()
    }

    func takeExceeded(requestID: Int) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        return exceeded.removeValue(forKey: requestID)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        lock.lock()
        var allow = false
        var exceededMax: Int?
        var requestID: Int?
        if var state = states[ObjectIdentifier(task)] {
            state.count += 1
            requestID = state.requestID
            if state.count > state.maxRedirects {
                exceededMax = state.maxRedirects
            } else {
                states[ObjectIdentifier(task)] = state
                allow = true
            }
        } else {
            allow = true // 未注册的任务按系统默认行为
        }
        if let exceededMax, let requestID {
            exceeded[requestID] = exceededMax
        }
        lock.unlock()
        completionHandler(allow ? request : nil)
    }
}

/// 在 URLSession 完成回调中安全读取对应的 task（避免捕获 var 的并发警告）。
private final class TaskReferenceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: URLSessionDataTask?
    var task: URLSessionDataTask? {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}
