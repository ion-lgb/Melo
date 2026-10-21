import Foundation
import JavaScriptCore
import MeloCore

/// 一次自定义源运行时的 JSContext 宿主。
///
/// - 仅在主线程使用（由 `JSCustomSourceService` 的 @MainActor 保证）；
/// - 注入 `globalThis.__native` 原语 + `Resources/js/prelude.js`（等价原版 preload.js 的 `window.lx`）；
/// - 定时器用 Swift Concurrency Task 实现（不依赖主 RunLoop）；
/// - 应用 → 脚本事件通过 prelude 的 `__lxDispatchRequestJSON`，结果用轮询 `__pending` 读取，
///   避免在 Swift 中直接桥接 Promise。
@MainActor
final class JSContextRuntime {

    enum RequestState {
        case pending
        case resolved(JSONValue)
        case rejected(String)
        case unknown
    }

    let context: JSContext
    let http = HTTPBridge()
    private(set) var initedPayloadJSON: String?
    private(set) var initFailedMessage: String?
    private(set) var lastException: String?
    private(set) var isShutdown = false

    var onLog: (@MainActor (String) -> Void)?
    var onUpdateAlert: (@MainActor (String, String?) -> Void)?

    private let scriptInfoJSON: String
    private var timerCallbacks: [Int: JSValue] = [:]
    private var timerTasks: [Int: Task<Void, Never>] = [:]
    private var requestHandler: JSValue?

    init(scriptInfo: [String: String]) {
        self.context = JSContext()!
        if JSONSerialization.isValidJSONObject(scriptInfo),
           let data = try? JSONSerialization.data(withJSONObject: scriptInfo),
           let string = String(data: data, encoding: .utf8) {
            self.scriptInfoJSON = string
        } else {
            self.scriptInfoJSON = "{}"
        }
        context.exceptionHandler = { [weak self] _, exception in
            let message = exception?.toString() ?? "未知 JS 异常"
            let stack = exception?.objectForKeyedSubscript("stack")?.toString()
            self?.lastException = message
            self?.log("JS 异常：\(message)\(stack.map { "\n\($0)" } ?? "")")
        }
        installNativeBridge()
    }

    // MARK: - 网络代理

    func configureProxy(_ settings: ProxySettings) {
        http.configureProxy(settings)
    }

    // MARK: - 日志

    private func log(_ message: String) {
        onLog?(message)
    }

    // MARK: - JS 加载

    func loadPrelude(_ source: String, sourceURL: URL?) throws {
        context.exception = nil
        context.evaluateScript(source, withSourceURL: sourceURL)
        if let exception = context.exception {
            lastException = exception.toString()
            throw CustomSourceError.scriptError("运行时 prelude 注入失败：\(exception)")
        }
    }

    func evaluate(_ script: String, sourceURL: URL?) throws {
        context.exception = nil
        context.evaluateScript(script, withSourceURL: sourceURL)
        if let exception = context.exception {
            let message = exception.toString() ?? "未知异常"
            lastException = message
            throw CustomSourceError.scriptError(message)
        }
    }

    // MARK: - 应用 → 脚本事件

    var hasRequestHandler: Bool { requestHandler != nil }

    func dispatchRequest(payloadJSON: String, tag: String) throws {
        guard !isShutdown else { throw CustomSourceError.scriptError("运行时已关闭") }
        context.setObject(payloadJSON, forKeyedSubscript: "__payloadJSON" as NSString)
        context.setObject(tag, forKeyedSubscript: "__trackTag" as NSString)
        context.exception = nil
        context.evaluateScript("__track(__lxDispatchRequestJSON(__payloadJSON), __trackTag)")
        if let exception = context.exception {
            let message = exception.toString() ?? "未知异常"
            lastException = message
            throw CustomSourceError.scriptError(message)
        }
    }

    func requestState(tag: String) -> RequestState {
        guard !isShutdown else { return .unknown }
        context.setObject(tag, forKeyedSubscript: "__trackTag" as NSString)
        context.exception = nil
        let state = context.evaluateScript("__pending[__trackTag] && __pending[__trackTag].state")?.toString()
        if let exception = context.exception {
            lastException = exception.toString()
            return .unknown
        }
        switch state {
        case nil:
            return .unknown
        case "pending":
            return .pending
        case "resolved":
            let json = context.evaluateScript("__pending[__trackTag].json")?.toString()
            if let json, let value = JSONValue(jsonString: json) { return .resolved(value) }
            return .resolved(.null)
        case "rejected":
            let message = context.evaluateScript("__pending[__trackTag].message")?.toString() ?? "未知错误"
            return .rejected(message)
        default:
            return .unknown
        }
    }

    // MARK: - 生命周期

    func shutdown() {
        guard !isShutdown else { return }
        isShutdown = true
        for task in timerTasks.values { task.cancel() }
        timerTasks.removeAll()
        timerCallbacks.removeAll()
        http.cancelAll()
        requestHandler = nil
    }

    // MARK: - native 原语

    private func installNativeBridge() {
        let native = JSValue(newObjectIn: context)!
        func set(_ name: String, _ block: AnyObject) {
            native.setObject(JSValue(object: block, in: context)!, forKeyedSubscript: name as NSString)
        }
        func fn(_ block: @autoclosure () -> AnyObject) -> AnyObject { block() }

        let logBlock: @convention(block) (String, String) -> Void = { [weak self] level, message in
            self?.log("[\(level)] \(message)")
        }
        set("log", fn(unsafeBitCast(logBlock, to: AnyObject.self)))

        let sendBlock: @convention(block) (String, String) -> String = { [weak self] event, json in
            guard let self else { return "error:runtime gone" }
            switch event {
            case "inited":
                self.initedPayloadJSON = json
                return "ok"
            case "initFailed":
                self.initFailedMessage = Self.decodeMessage(from: json) ?? "自定义源初始化失败"
                return "ok"
            case "updateAlert":
                self.handleUpdateAlert(json)
                return "ok"
            case "openDevTools":
                self.log("脚本请求打开开发者工具（macOS 移植版暂不支持，已忽略）")
                return "ok"
            default:
                return "error:unsupported event \(event)"
            }
        }
        set("send", fn(unsafeBitCast(sendBlock, to: AnyObject.self)))

        let setRequestHandlerBlock: @convention(block) (JSValue) -> Void = { [weak self] handler in
            self?.requestHandler = handler
        }
        set("setRequestHandler", fn(unsafeBitCast(setRequestHandlerBlock, to: AnyObject.self)))

        let httpRequestBlock: @convention(block) (Int, String, String) -> Void = { [weak self] id, url, optionsJSON in
            guard let self else { return }
            self.http.request(id: id, urlString: url, optionsJSON: optionsJSON) { [weak self] error, response in
                Task { @MainActor [weak self] in
                    self?.deliverHTTPResponse(id: id, error: error, response: response)
                }
            }
        }
        set("httpRequest", fn(unsafeBitCast(httpRequestBlock, to: AnyObject.self)))

        let httpCancelBlock: @convention(block) (Int) -> Void = { [weak self] id in
            self?.http.cancel(id: id)
        }
        set("httpCancel", fn(unsafeBitCast(httpCancelBlock, to: AnyObject.self)))

        let timerStartBlock: @convention(block) (Int, JSValue, Double, Bool) -> Void = { [weak self] id, callback, delayMilliseconds, repeats in
            guard let self, !self.isShutdown else { return }
            self.timerCallbacks[id] = callback
            let clamped = min(max(delayMilliseconds, 0.0), 24 * 3600 * 1000.0)
            let nanoseconds = UInt64(clamped * 1_000_000)
            let task = Task { @MainActor [weak self] in
                if repeats {
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: max(nanoseconds, 1_000_000))
                        if Task.isCancelled { break }
                        guard let self, !self.isShutdown, self.timerCallbacks[id] != nil else { break }
                        self.fireTimer(id)
                    }
                } else {
                    try? await Task.sleep(nanoseconds: nanoseconds)
                    guard !Task.isCancelled, let self, !self.isShutdown else { return }
                    self.fireTimer(id)
                    self.timerCallbacks[id] = nil
                    self.timerTasks[id] = nil
                }
            }
            self.timerTasks[id] = task
        }
        set("timerStart", fn(unsafeBitCast(timerStartBlock, to: AnyObject.self)))

        let timerCancelBlock: @convention(block) (Int) -> Void = { [weak self] id in
            guard let self else { return }
            self.timerCallbacks[id] = nil
            self.timerTasks[id]?.cancel()
            self.timerTasks[id] = nil
        }
        set("timerCancel", fn(unsafeBitCast(timerCancelBlock, to: AnyObject.self)))

        let md5Block: @convention(block) (String) -> String = { CryptoBridge.md5($0) }
        set("md5", fn(unsafeBitCast(md5Block, to: AnyObject.self)))

        let randomBytesBlock: @convention(block) (Int) -> JSValue = { [weak self] count in
            guard let context = self?.context else { return JSValue(nullIn: nil) }
            return JSValue(object: CryptoBridge.randomBytes(count).map(Int.init), in: context)!
        }
        set("randomBytes", fn(unsafeBitCast(randomBytesBlock, to: AnyObject.self)))

        let aesBlock: @convention(block) (JSValue, String, JSValue, JSValue) -> JSValue = { [weak self] data, mode, key, iv in
            guard let self else { return JSValue(nullIn: nil) }
            let result = CryptoBridge.aesEncrypt(self.bytes(from: data), mode: mode, key: self.bytes(from: key), iv: self.bytes(from: iv))
            guard let result else { return JSValue(nullIn: self.context) }
            return JSValue(object: result.map(Int.init), in: self.context)!
        }
        set("aesEncrypt", fn(unsafeBitCast(aesBlock, to: AnyObject.self)))

        let rsaBlock: @convention(block) (JSValue, String) -> JSValue = { [weak self] data, pem in
            guard let self else { return JSValue(nullIn: nil) }
            let result = CryptoBridge.rsaEncrypt(self.bytes(from: data), pem: pem)
            guard let result else { return JSValue(nullIn: self.context) }
            return JSValue(object: result.map(Int.init), in: self.context)!
        }
        set("rsaEncrypt", fn(unsafeBitCast(rsaBlock, to: AnyObject.self)))

        let inflateBlock: @convention(block) (JSValue) -> JSValue = { [weak self] data in
            guard let self else { return JSValue(nullIn: nil) }
            let output = ZlibCodec.inflate(self.bytes(from: data))
            return self.zlibResult(ok: output != nil, data: output ?? [], error: output == nil ? "inflate failed" : nil)
        }
        set("zlibInflate", fn(unsafeBitCast(inflateBlock, to: AnyObject.self)))

        let deflateBlock: @convention(block) (JSValue) -> JSValue = { [weak self] data in
            guard let self else { return JSValue(nullIn: nil) }
            let output = ZlibCodec.deflate(self.bytes(from: data))
            return self.zlibResult(ok: output != nil, data: output ?? [], error: output == nil ? "deflate failed" : nil)
        }
        set("zlibDeflate", fn(unsafeBitCast(deflateBlock, to: AnyObject.self)))

        let scriptInfoBlock: @convention(block) () -> String = { [weak self] in
            self?.scriptInfoJSON ?? "{}"
        }
        set("scriptInfo", fn(unsafeBitCast(scriptInfoBlock, to: AnyObject.self)))

        context.setObject(native, forKeyedSubscript: "__native" as NSString)
    }

    private func fireTimer(_ id: Int) {
        guard !isShutdown, let callback = timerCallbacks[id] else { return }
        _ = callback.call(withArguments: [])
    }

    private func deliverHTTPResponse(id: Int, error: String?, response: HTTPBridge.Response?) {
        guard !isShutdown,
              let function = context.objectForKeyedSubscript("__nativeHttpResponse") else { return }
        let idValue = JSValue(int32: Int32(id), in: context)!
        let errorValue = error.map { JSValue(object: $0, in: context)! } ?? JSValue(nullIn: context)!
        var payloadValue = JSValue(nullIn: context)!
        if let response {
            let dictionary: [String: Any] = [
                "statusCode": response.statusCode,
                "statusMessage": response.statusMessage,
                "headers": response.headers,
                "bytes": response.data.count,
                "bodyBase64": response.data.base64EncodedString(),
            ]
            if let data = try? JSONSerialization.data(withJSONObject: dictionary),
               let json = String(data: data, encoding: .utf8) {
                payloadValue = JSValue(object: json, in: context)!
            }
        }
        _ = function.call(withArguments: [idValue, errorValue, payloadValue])
    }

    private func handleUpdateAlert(_ json: String) {
        guard let data = json.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        let log = (object["log"] as? String) ?? ""
        let updateUrl = object["updateUrl"] as? String
        onUpdateAlert?(log, updateUrl)
    }

    private func bytes(from value: JSValue) -> [UInt8] {
        guard let array = value.toArray() else { return [] }
        return array.map { element in
            if let number = element as? NSNumber { return UInt8(truncatingIfNeeded: number.intValue) }
            return UInt8(truncatingIfNeeded: (element as? Int) ?? 0)
        }
    }

    private func zlibResult(ok: Bool, data: [UInt8], error: String?) -> JSValue {
        let dictionary: [String: Any] = [
            "ok": ok,
            "data": data.map(Int.init),
            "error": error as Any? ?? NSNull(),
        ]
        return JSValue(object: dictionary, in: context)!
    }

    private static func decodeMessage(from json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return object["message"] as? String
    }
}
