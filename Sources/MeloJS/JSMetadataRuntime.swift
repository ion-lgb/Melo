import Foundation
import JavaScriptCore
import MeloCore

/// `musicSdk.bundle.js` 的 JSContext 宿主。
///
/// - 主线程串行（由 `JSMetadataService` 的 @MainActor 保证）；
/// - 注入 `globalThis.__meloNative`（HTTP / crypto / log / timers）供 bundle 内 shim 调用；
/// - 应用 → bundle 的调用通过 `__meloCall(tag, method, argsJSON)` + `__meloPending` 轮询完成，
///   不在 Swift 中直接桥接 Promise；
/// - 超时由调用方传入（默认 20s）。
@MainActor
final class JSMetadataRuntime {

    let context: JSContext
    let http = HTTPBridge()
    var onLog: (@MainActor (String) -> Void)?
    private(set) var isLoaded = false
    private(set) var isShutdown = false

    private var callSequence = 0
    private var timerCallbacks: [Int: JSValue] = [:]
    private var timerTasks: [Int: Task<Void, Never>] = [:]

    init() {
        self.context = JSContext()!
        context.exceptionHandler = { [weak self] _, exception in
            let message = exception?.toString() ?? "未知 JS 异常"
            self?.onLog?("JS 异常：\(message)")
        }
        installNativeBridge()
    }

    // MARK: - 加载

    func loadBundle(_ source: String, sourceURL: URL?) throws {
        context.exception = nil
        context.evaluateScript(source, withSourceURL: sourceURL)
        if let exception = context.exception {
            throw MetadataError.scriptError("内置音源 bundle 加载失败：\(exception)")
        }
        let type = context.evaluateScript("typeof MeloMetadata")?.toString() ?? ""
        guard type == "object" else {
            throw MetadataError.scriptError("内置音源 bundle 未暴露 MeloMetadata")
        }
        isLoaded = true
    }

    // MARK: - 网络代理

    func configureProxy(_ settings: ProxySettings) {
        http.configureProxy(settings)
    }

    // MARK: - 调用

    func call(_ method: String, arguments: [JSONValue], timeout: TimeInterval) async throws -> JSONValue {
        guard isLoaded, !isShutdown else { throw MetadataError.notReady }
        callSequence += 1
        let tag = "meta_\(callSequence)"
        let argsJSON = JSONValue.array(arguments).jsonString() ?? "[]"
        context.setObject(tag, forKeyedSubscript: "__meloCallTag" as NSString)
        context.setObject(method, forKeyedSubscript: "__meloCallMethod" as NSString)
        context.setObject(argsJSON, forKeyedSubscript: "__meloCallArgs" as NSString)
        context.exception = nil
        context.evaluateScript("__meloCall(__meloCallTag, __meloCallMethod, __meloCallArgs)")
        if let exception = context.exception {
            throw MetadataError.scriptError(exception.toString() ?? "内置音源调用失败")
        }

        let deadline = Date().addingTimeInterval(timeout)
        while true {
            context.setObject(tag, forKeyedSubscript: "__meloCallTag" as NSString)
            let state = context.evaluateScript("__meloPending[__meloCallTag] && __meloPending[__meloCallTag].state")?.toString()
            switch state {
            case "resolved":
                let json = context.evaluateScript("__meloPending[__meloCallTag].json")?.toString()
                guard let json, let value = JSONValue(jsonString: json) else {
                    throw MetadataError.invalidResult("音源返回的 JSON 无法解析")
                }
                return value
            case "rejected":
                let message = context.evaluateScript("__meloPending[__meloCallTag].message")?.toString() ?? "未知错误"
                throw MetadataError.scriptError(message)
            default:
                break
            }
            // 说明：这里不响应调用方的 Task 取消——元数据调用由 20s 超时兜底，
            // SwiftUI 视图生命周期变化不应让已发出的搜索任务失败（否则热搜偶发 CancellationError）。
            if isShutdown { throw MetadataError.scriptError("内置音源运行时已关闭") }
            if Date() >= deadline {
                throw MetadataError.timeout("内置音源响应超时（\(String(format: "%.1f", timeout)) 秒）")
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// 测试/诊断用：直接执行一段表达式（内部可见，不暴露给 App）
    func evaluateForTesting(_ expression: String) -> String? {
        context.exception = nil
        let value = context.evaluateScript(expression)?.toString()
        if let exception = context.exception {
            return "EXCEPTION: \(exception)"
        }
        return value
    }

    func shutdown() {
        guard !isShutdown else { return }
        isShutdown = true
        isLoaded = false
        for task in timerTasks.values { task.cancel() }
        timerTasks.removeAll()
        timerCallbacks.removeAll()
        http.cancelAll()
    }

    // MARK: - native 桥

    private func installNativeBridge() {
        let native = JSValue(newObjectIn: context)!
        func set(_ name: String, _ block: AnyObject) {
            native.setObject(JSValue(object: block, in: context)!, forKeyedSubscript: name as NSString)
        }

        let logBlock: @convention(block) (String, String) -> Void = { [weak self] level, message in
            self?.onLog?("[\(level)] \(message)")
        }
        set("log", unsafeBitCast(logBlock, to: AnyObject.self))

        let httpRequestBlock: @convention(block) (Int, String, String) -> Void = { [weak self] id, url, optionsJSON in
            guard let self else { return }
            self.http.request(id: id, urlString: url, optionsJSON: optionsJSON) { [weak self] error, response in
                Task { @MainActor [weak self] in
                    self?.deliverHTTPResponse(id: id, error: error, response: response)
                }
            }
        }
        set("http", unsafeBitCast(httpRequestBlock, to: AnyObject.self))

        let httpCancelBlock: @convention(block) (Int) -> Void = { [weak self] id in
            self?.http.cancel(id: id)
        }
        set("httpCancel", unsafeBitCast(httpCancelBlock, to: AnyObject.self))

        let hashBlock: @convention(block) (String, JSValue) -> JSValue = { [weak self] algorithm, bytesValue in
            guard let self else { return JSValue(nullIn: nil) }
            guard let hex = CryptoBridge.hash(algorithm, self.bytes(from: bytesValue)) else {
                return JSValue(nullIn: self.context)
            }
            return JSValue(object: hex, in: self.context)!
        }
        set("hash", unsafeBitCast(hashBlock, to: AnyObject.self))

        let aesBlock: @convention(block) (JSValue, String, JSValue, JSValue) -> JSValue = { [weak self] data, mode, key, iv in
            guard let self else { return JSValue(nullIn: nil) }
            let output = CryptoBridge.aesEncrypt(self.bytes(from: data), mode: mode, key: self.bytes(from: key), iv: self.bytes(from: iv))
            guard let output else { return JSValue(nullIn: self.context) }
            return JSValue(object: output.map(Int.init), in: self.context)!
        }
        set("aesEncrypt", unsafeBitCast(aesBlock, to: AnyObject.self))

        let aesDecryptBlock: @convention(block) (JSValue, String, JSValue, JSValue) -> JSValue = { [weak self] data, mode, key, iv in
            guard let self else { return JSValue(nullIn: nil) }
            let output = CryptoBridge.aesDecrypt(self.bytes(from: data), mode: mode, key: self.bytes(from: key), iv: self.bytes(from: iv))
            guard let output else { return JSValue(nullIn: self.context) }
            return JSValue(object: output.map(Int.init), in: self.context)!
        }
        set("aesDecrypt", unsafeBitCast(aesDecryptBlock, to: AnyObject.self))

        let rsaBlock: @convention(block) (JSValue, String) -> JSValue = { [weak self] data, pem in
            guard let self else { return JSValue(nullIn: nil) }
            guard let output = CryptoBridge.rsaEncrypt(self.bytes(from: data), pem: pem) else {
                return JSValue(nullIn: self.context)
            }
            return JSValue(object: output.map(Int.init), in: self.context)!
        }
        set("rsaEncrypt", unsafeBitCast(rsaBlock, to: AnyObject.self))

        let randomBytesBlock: @convention(block) (Int) -> JSValue = { [weak self] count in
            guard let self else { return JSValue(nullIn: nil) }
            return JSValue(object: CryptoBridge.randomBytes(count).map(Int.init), in: self.context)!
        }
        set("randomBytes", unsafeBitCast(randomBytesBlock, to: AnyObject.self))

        let timerStartBlock: @convention(block) (Int, JSValue, Double, Bool) -> Void = { [weak self] id, callback, delayMilliseconds, repeats in
            guard let self, !self.isShutdown else { return }
            self.timerCallbacks[id] = callback
            let nanoseconds = UInt64(min(max(delayMilliseconds, 0), 24 * 3600 * 1000) * 1_000_000)
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
        set("timerStart", unsafeBitCast(timerStartBlock, to: AnyObject.self))

        let timerCancelBlock: @convention(block) (Int) -> Void = { [weak self] id in
            guard let self else { return }
            self.timerCallbacks[id] = nil
            self.timerTasks[id]?.cancel()
            self.timerTasks[id] = nil
        }
        set("timerCancel", unsafeBitCast(timerCancelBlock, to: AnyObject.self))

        context.setObject(native, forKeyedSubscript: "__meloNative" as NSString)
    }

    private func deliverHTTPResponse(id: Int, error: String?, response: HTTPBridge.Response?) {
        guard !isShutdown,
              let function = context.objectForKeyedSubscript("__meloNativeHttpResponse") else { return }
        // requestId 必须保持数字类型，与 JS 侧 callback Map 的 key 完全一致（Lead 联调踩坑）
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

    private func fireTimer(_ id: Int) {
        guard !isShutdown, let callback = timerCallbacks[id] else { return }
        _ = callback.call(withArguments: [])
    }

    private func bytes(from value: JSValue) -> [UInt8] {
        guard let array = value.toArray() else { return [] }
        return array.map { element in
            if let number = element as? NSNumber { return UInt8(truncatingIfNeeded: number.intValue) }
            return UInt8(truncatingIfNeeded: (element as? Int) ?? 0)
        }
    }
}
