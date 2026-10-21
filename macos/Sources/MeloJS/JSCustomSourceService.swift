import Foundation
import MeloCore

/// 自定义源运行时（JavaScriptCore 承载落雪 LX Music 自定义源脚本）。
///
/// 设计要点：
/// - 单例串行：同一时刻只有一个 `JSContext`（主线程），切换源时销毁旧运行时；
/// - 不内置任何源脚本：用户通过 `importSource(from:)` 导入 `.js`，持久化到原版兼容的
///   `<LxDatas>/user_api.json`（`gz_` + base64(zlib deflate)）；
/// - `window.lx` 语义对齐原版 `src/main/modules/userApi/renderer/preload.js`；
/// - 所有状态/日志通过 `eventHandler(CustomSourceEvent)` 广播；
/// - 网络仅允许 http(s)，响应/结果尺寸受限，事件有 5s/20s 超时。
@MainActor
public final class JSCustomSourceService: CustomSourceService, ProxyConfiguring {

    // MARK: - 协议状态

    public var eventHandler: ((CustomSourceEvent) -> Void)?
    public private(set) var sources: [UserSourceInfo] = []
    public private(set) var activeSourceId: String?
    public private(set) var status: SourceRuntimeStatus = .idle
    public private(set) var capabilities: [SourceCapability] = []

    // MARK: - 依赖

    private let settings: SettingsStore
    private let lxDatasDirectory: URL
    private let store: UserSourceStore
    private var runtime: JSContextRuntime?
    private var activationGeneration = 0
    private var requestSequence = 0

    // 在线导入（URL）使用独立 HTTPBridge：http→Network.framework，https→URLSession
    private let remoteImportBridge = HTTPBridge()
    private var remoteImportSequence = 0
    /// 在线导入参数（internal 供测试注入更短超时/更小上限）
    var remoteImportTimeout: TimeInterval = 20
    var remoteImportMaxRedirects: Int = 3
    var remoteImportMaxBytes: Int = 9_000_000

    /// 激活/请求超时（internal 供测试注入更短值）
    var activationTimeout: TimeInterval = 5
    var requestTimeout: TimeInterval = 20

    // MARK: - init

    public init(dataDirectory: URL, settings: SettingsStore) {
        self.settings = settings
        let lxDatas = Self.resolveLxDatasDirectory(from: dataDirectory)
        self.lxDatasDirectory = lxDatas
        self.store = UserSourceStore(lxDatasDirectory: lxDatas)
        if let saved = settings.string(SettingKeys.apiSource), saved.hasPrefix("user_api") {
            self.activeSourceId = saved
        }
        // 初次装载：读取失败不抛（reloadSources 会抛给 AppModel）
        try? store.load()
        self.sources = store.userSourceInfos(activeId: activeSourceId)
    }

    /// `MeloApp` 传的是 `<userData>/LxDatas`；任务约定也可以传 userData 根目录。
    /// - 已是 `LxDatas` 目录 → 直接使用；
    /// - 其他目录 → 追加 `LxDatas` 子目录。
    private static func resolveLxDatasDirectory(from dataDirectory: URL) -> URL {
        if dataDirectory.lastPathComponent == "LxDatas" { return dataDirectory }
        return dataDirectory.appendingPathComponent("LxDatas", isDirectory: true)
    }

    // MARK: - 源列表

    public func reloadSources() throws {
        do {
            try store.load()
        } catch {
            throw CustomSourceError.ioError(error.localizedDescription)
        }
        // 活动源被外部删除 → 停止运行时
        if runtime != nil, let active = activeSourceId, store.record(id: active) == nil {
            stopRuntime()
            activeSourceId = nil
            capabilities = []
            status = .idle
        }
        if runtime == nil {
            if let saved = settings.string(SettingKeys.apiSource),
               saved.hasPrefix("user_api"),
               store.record(id: saved) != nil {
                activeSourceId = saved
            } else if let active = activeSourceId, store.record(id: active) == nil {
                activeSourceId = nil
            }
        }
        sources = store.userSourceInfos(activeId: activeSourceId)
    }

    // MARK: - 导入（文件 / 在线 URL / 脚本文本，共用入库核心）

    /// 导入本地 .js 源文件
    @discardableResult
    public func importSource(from url: URL) throws -> UserSourceInfo {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw CustomSourceError.ioError("读取自定义源文件失败：\(error.localizedDescription)")
        }
        guard let script = String(data: data, encoding: .utf8) else {
            throw CustomSourceError.scriptError("自定义源文件不是 UTF-8 文本")
        }
        return try importScriptText(script, extra: ["scriptMd5": CryptoBridge.md5(script)], sourceName: "本地文件")
    }

    /// 从脚本文本导入（文件导入 / URL 在线导入共用）
    @discardableResult
    public func importSource(script: String) throws -> UserSourceInfo {
        try importScriptText(script, extra: ["scriptMd5": CryptoBridge.md5(script)], sourceName: "脚本")
    }

    /// 在线导入：下载 http(s) 链接上的自定义源脚本后按原版规则入库
    /// - 注意：这是 URL 下载，不是本地文件路径；重定向 ≤3、超时 20s、≤9,000,000 字节。
    @discardableResult
    public func importSource(fromRemoteURL url: URL) async throws -> UserSourceInfo {
        try Self.validateRemoteURL(url)
        let script = try await downloadRemoteScript(from: url)
        return try importScriptText(
            script,
            extra: ["scriptMd5": CryptoBridge.md5(script), "sourceUrl": url.absoluteString],
            sourceName: "在线链接"
        )
    }

    @discardableResult
    private func importScriptText(_ script: String, extra: [String: Any], sourceName: String) throws -> UserSourceInfo {
        do {
            try store.ensureLoaded()
        } catch {
            throw CustomSourceError.ioError(error.localizedDescription)
        }
        let record: UserSourceStore.Record
        do {
            record = try store.importScript(script, extra: extra)
        } catch {
            throw Self.mapStoreError(error)
        }
        sources = store.userSourceInfos(activeId: activeSourceId)
        emit(.log("已通过\(sourceName)导入自定义源「\(record.name)」（\(record.id)）"))
        return UserSourceInfo(
            id: record.id,
            name: record.name,
            description: record.description,
            version: record.version,
            author: record.author,
            homepage: record.homepage,
            script: record.compressedScript,
            isActive: record.id == activeSourceId
        )
    }

    // MARK: - 在线导入（下载 / 校验 / 错误映射）

    private static func validateRemoteURL(_ url: URL) throws {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw CustomSourceError.ioError("链接不合法：仅支持 http/https 链接")
        }
        guard let host = url.host, !host.isEmpty else {
            throw CustomSourceError.ioError("链接不合法：缺少域名")
        }
        guard url.absoluteString.count <= 2048 else {
            throw CustomSourceError.ioError("链接过长：最多 2048 个字符")
        }
    }

    private func downloadRemoteScript(from url: URL) async throws -> String {
        let maxBytes = remoteImportMaxBytes
        let maxRedirects = remoteImportMaxRedirects
        let timeout = remoteImportTimeout
        let timeoutMilliseconds = max(Int(timeout * 1000), 100)
        let options: [String: Any] = [
            "method": "get",
            "headers": ["User-Agent": "lx-music-desktop/2.0.0"],
            "timeout": timeoutMilliseconds,
            "maxRedirects": maxRedirects,
        ]
        guard let optionsData = try? JSONSerialization.data(withJSONObject: options),
              let optionsJSON = String(data: optionsData, encoding: .utf8) else {
            throw CustomSourceError.ioError("在线导入失败：请求参数构造失败")
        }
        remoteImportSequence += 1
        let requestID = 900_000 + remoteImportSequence
        let bridge = remoteImportBridge
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            bridge.request(id: requestID, urlString: url.absoluteString, optionsJSON: optionsJSON) { error, response in
                if let error {
                    continuation.resume(throwing: Self.mapRemoteDownloadError(error, timeout: timeout))
                    return
                }
                guard let response else {
                    continuation.resume(throwing: CustomSourceError.ioError("在线导入失败：未收到响应"))
                    return
                }
                guard response.statusCode == 200 else {
                    continuation.resume(throwing: CustomSourceError.ioError("在线导入失败：HTTP \(response.statusCode)"))
                    return
                }
                guard response.data.count <= maxBytes else {
                    continuation.resume(throwing: CustomSourceError.ioError("在线导入失败：脚本过大（\(response.data.count) 字节，最多 \(maxBytes) 字节）"))
                    return
                }
                continuation.resume(returning: response.data)
            }
        }
        var bytes = [UInt8](data)
        // UTF-8 BOM 去除
        if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF {
            bytes.removeFirst(3)
        }
        guard let script = String(bytes: bytes, encoding: .utf8) else {
            throw CustomSourceError.scriptError("在线导入失败：下载内容不是 UTF-8 文本")
        }
        guard !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CustomSourceError.scriptError("在线导入失败：下载内容为空")
        }
        return script
    }

    private static func mapRemoteDownloadError(_ message: String, timeout: TimeInterval) -> CustomSourceError {
        let seconds = timeout < 1 ? String(format: "%.1f", timeout) : String(Int(timeout.rounded()))
        if message.contains("超时") {
            return .timeout("在线导入超时（\(seconds) 秒）")
        }
        if message.contains("重定向") {
            return .ioError("在线导入失败：\(message)")
        }
        return .ioError("在线导入失败：网络错误：\(message)")
    }

    public func removeSource(id: String) throws {
        do {
            try store.ensureLoaded()
        } catch {
            throw CustomSourceError.ioError(error.localizedDescription)
        }
        guard store.record(id: id) != nil else {
            throw CustomSourceError.ioError("自定义源不存在：\(id)")
        }
        if activeSourceId == id { deactivateSource() }
        store.remove(ids: [id])
        do {
            try store.save()
        } catch {
            throw CustomSourceError.ioError(error.localizedDescription)
        }
        sources = store.userSourceInfos(activeId: activeSourceId)
        emit(.log("已删除自定义源：\(id)"))
    }

    // MARK: - 网络代理

    /// 应用用户自定义 HTTP 代理（原版 network.proxy.*）。
    /// 运行中的自定义源立即生效；未激活时更新共享快照，下次激活自动生效。
    public func configureProxy(_ settings: ProxySettings) {
        NetworkProxyStore.shared.update(settings)
        runtime?.configureProxy(settings)
    }

    // MARK: - 激活 / 卸载

    public func activateSource(id: String) async {
        activationGeneration += 1
        let generation = activationGeneration
        stopRuntime()

        do {
            try store.ensureLoaded()
        } catch {
            finishActivationFailure("读取自定义源失败：\(error.localizedDescription)", generation: generation)
            return
        }
        guard store.record(id: id) != nil else {
            finishActivationFailure("自定义源不存在：\(id)", generation: generation)
            return
        }
        let script: String
        do {
            script = try store.plainScript(id: id)
        } catch {
            finishActivationFailure(error.localizedDescription, generation: generation)
            return
        }
        let info: ScriptInfoParser.Info
        do {
            info = try ScriptInfoParser.parse(script)
        } catch {
            finishActivationFailure("自定义源文件无效：\(error.localizedDescription)", generation: generation)
            return
        }

        status = .loading
        emit(.status(.loading))

        guard let prelude = loadPreludeSource() else {
            finishActivationFailure("找不到 JS 运行时资源 js/prelude.js", generation: generation)
            return
        }

        let scriptInfo: [String: String] = [
            "name": info.name,
            "description": info.description,
            "version": info.version,
            "author": info.author,
            "homepage": info.homepage,
            "rawScript": script,
        ]
        let runtime = JSContextRuntime(scriptInfo: scriptInfo)
        runtime.onLog = { [weak self] message in
            self?.emit(.log(message))
        }
        runtime.onUpdateAlert = { [weak self] log, updateUrl in
            guard let self else { return }
            guard let current = self.store.record(id: id), current.allowShowUpdateAlert else { return }
            self.emit(.updateAlert(log: log, updateUrl: updateUrl))
        }
        do {
            try runtime.loadPrelude(prelude, sourceURL: PreludeLocator.url())
            try runtime.evaluate(script, sourceURL: nil)
        } catch {
            runtime.shutdown()
            finishActivationFailure(error.localizedDescription, generation: generation)
            return
        }

        let inited = await waitForInited(runtime: runtime, generation: generation)
        guard generation == activationGeneration else {
            runtime.shutdown()
            return
        }
        switch inited {
        case .failure(let failure):
            runtime.shutdown()
            finishActivationFailure(failure.message, generation: generation)
        case .success(let payload):
            let parsed = parseInitedPayload(payload)
            guard parsed.status else {
                runtime.shutdown()
                finishActivationFailure(parsed.message ?? "自定义源初始化失败", generation: generation)
                return
            }
            let caps = parsed.capabilities
            if caps.isEmpty {
                runtime.onLog?("源脚本未声明任何可用能力（检查 inited.sources 的 kw/kg/tx/wy/mg/local 与 actions/qualitys）")
            }
            self.runtime = runtime
            self.activeSourceId = id
            self.capabilities = caps
            self.status = .ready(caps)
            self.sources = store.userSourceInfos(activeId: id)
            settings.set(SettingKeys.apiSource, .string(id))
            emit(.status(.ready(caps)))
            MeloLog.info("自定义源已激活: \(info.name)（\(id)），能力: \(caps.map(\.source))")
        }
    }

    /// 启动时恢复上次活动的自定义源（读取 settings 的 `common.apiSource`）。
    /// 不在 `CustomSourceService` 协议内：由 App 装配层在 `bootstrap` 后调用一次即可，
    /// 这样即使 UI 尚未打开设置页也能恢复播放能力（对齐原版 useInitUserApi 的 setUserApi 行为）。
    public func restoreActiveSourceIfNeeded() async {
        guard runtime == nil else { return }
        guard let saved = settings.string(SettingKeys.apiSource),
              saved.hasPrefix("user_api") else { return }
        do {
            try store.ensureLoaded()
        } catch {
            return
        }
        guard store.record(id: saved) != nil else { return }
        await activateSource(id: saved)
    }

    public func deactivateSource() {
        activationGeneration += 1
        stopRuntime()
        activeSourceId = nil
        capabilities = []
        status = .idle
        sources = store.userSourceInfos(activeId: nil)
        emit(.status(.idle))
    }

    // MARK: - 取链 / 取歌词

    public func resolveMusicURL(source: String, musicInfo: MusicInfo, quality: String) async throws -> URL {
        guard let runtime, status.isReady else { throw CustomSourceError.notActivated }
        guard let capability = capability(for: source), capability.actions.contains("musicUrl") else {
            throw CustomSourceError.noCapability(source: source, action: "musicUrl")
        }
        let info: JSONValue = .object([
            "type": .string(quality),
            "musicInfo": musicInfo.legacyJSON,
        ])
        let payload: JSONValue = .object([
            "source": .string(source),
            "action": .string("musicUrl"),
            "info": info,
        ])
        let result = try await performRequest(runtime: runtime, payload: payload)
        let data = result["data"] ?? result
        let urlString = data["url"]?.stringValue ?? result["url"]?.stringValue
        guard let urlString else {
            throw CustomSourceError.invalidResult("缺少 url 字段")
        }
        guard urlString.count <= 2048 else {
            throw CustomSourceError.invalidResult("url 长度超过 2048")
        }
        guard MeloUtils.isHTTPURL(urlString),
              let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else {
            throw CustomSourceError.invalidResult("url 不是合法的 http(s) 地址")
        }
        return url
    }

    public func resolveLyric(source: String, musicInfo: MusicInfo) async throws -> LyricInfo? {
        guard let runtime, status.isReady else { throw CustomSourceError.notActivated }
        guard let capability = capability(for: source), capability.actions.contains("lyric") else {
            throw CustomSourceError.noCapability(source: source, action: "lyric")
        }
        let info: JSONValue = .object([
            "type": .string("music"),
            "musicInfo": musicInfo.legacyJSON,
        ])
        let payload: JSONValue = .object([
            "source": .string(source),
            "action": .string("lyric"),
            "info": info,
        ])
        let result = try await performRequest(runtime: runtime, payload: payload)
        let data = result["data"] ?? result
        guard let lyric = data["lyric"]?.stringValue else {
            throw CustomSourceError.invalidResult("缺少 lyric 字段")
        }
        let lyricInfo = LyricInfo(
            lyric: lyric,
            tlyric: data["tlyric"]?.stringValue,
            rlyric: data["rlyric"]?.stringValue,
            lxlyric: data["lxlyric"]?.stringValue
        )
        return lyricInfo.isEmpty ? nil : lyricInfo
    }

    // MARK: - 内部实现

    private func capability(for source: String) -> SourceCapability? {
        capabilities.first { $0.source == source }
    }

    private func performRequest(runtime: JSContextRuntime, payload: JSONValue) async throws -> JSONValue {
        requestSequence += 1
        let tag = "req_\(requestSequence)"
        guard let payloadJSON = payload.jsonString() else {
            throw CustomSourceError.invalidResult("请求参数序列化失败")
        }
        try runtime.dispatchRequest(payloadJSON: payloadJSON, tag: tag)
        let deadline = Date().addingTimeInterval(requestTimeout)
        while true {
            switch runtime.requestState(tag: tag) {
            case .resolved(let value):
                return value
            case .rejected(let message):
                throw CustomSourceError.scriptError(message)
            case .unknown:
                throw CustomSourceError.scriptError("源脚本请求事件未注册")
            case .pending:
                break
            }
            if Task.isCancelled { throw CancellationError() }
            if runtime.isShutdown { throw CustomSourceError.scriptError("运行时已关闭") }
            if Date() >= deadline {
                throw CustomSourceError.timeout("源脚本响应超时（\(Self.formatSeconds(requestTimeout)) 秒）")
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private struct InitedFailure: Error {
        var message: String
    }

    private func waitForInited(runtime: JSContextRuntime, generation: Int) async -> Result<String, InitedFailure> {
        let deadline = Date().addingTimeInterval(activationTimeout)
        while true {
            if generation != activationGeneration {
                return .failure(InitedFailure(message: "激活已被新的激活请求取代"))
            }
            if runtime.isShutdown {
                return .failure(InitedFailure(message: "运行时已关闭"))
            }
            if let payload = runtime.initedPayloadJSON {
                return .success(payload)
            }
            if let failed = runtime.initFailedMessage {
                return .failure(InitedFailure(message: failed))
            }
            if Date() >= deadline {
                return .failure(InitedFailure(message: "源脚本初始化超时（\(Self.formatSeconds(activationTimeout)) 秒）"))
            }
            if Task.isCancelled {
                return .failure(InitedFailure(message: "激活已取消"))
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private struct ParsedInitedPayload {
        var status: Bool
        var message: String?
        var capabilities: [SourceCapability]
    }

    private func parseInitedPayload(_ json: String) -> ParsedInitedPayload {
        guard let value = JSONValue(jsonString: json) else {
            return ParsedInitedPayload(status: false, message: "源脚本 inited 事件数据无效", capabilities: [])
        }
        let status = value["status"]?.boolValue ?? true
        let message = value["message"]?.stringValue
        let sourceObjects = value["sources"]?.objectValue ?? [:]
        var capabilities: [SourceCapability] = []
        for (source, raw) in sourceObjects {
            guard let object = raw.objectValue else { continue }
            let actions = (object["actions"]?.arrayValue ?? []).compactMap(\.stringValue)
            let qualitys = (object["qualitys"]?.arrayValue ?? []).compactMap(\.stringValue)
            guard !actions.isEmpty else { continue }
            capabilities.append(SourceCapability(
                source: source,
                name: object["name"]?.stringValue,
                actions: actions,
                qualitys: qualitys
            ))
        }
        let order = ["kw", "kg", "tx", "wy", "mg", "local"]
        capabilities.sort { lhs, rhs in
            let l = order.firstIndex(of: lhs.source) ?? order.count
            let r = order.firstIndex(of: rhs.source) ?? order.count
            return l == r ? lhs.source < rhs.source : l < r
        }
        return ParsedInitedPayload(status: status, message: message, capabilities: capabilities)
    }

    private func loadPreludeSource() -> String? {
        guard let url = PreludeLocator.url() else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    private func stopRuntime() {
        runtime?.shutdown()
        runtime = nil
    }

    private func finishActivationFailure(_ message: String, generation: Int) {
        guard generation == activationGeneration else { return }
        stopRuntime()
        activeSourceId = nil
        capabilities = []
        status = .error(message)
        sources = store.userSourceInfos(activeId: nil)
        MeloLog.error("自定义源激活失败: \(message)")
        emit(.status(.error(message)))
    }

    private func emit(_ event: CustomSourceEvent) {
        eventHandler?(event)
    }

    private static func formatSeconds(_ value: TimeInterval) -> String {
        let rounded = max(value, 0.1)
        return String(format: "%.1f", rounded)
    }

    private static func mapStoreError(_ error: Error) -> CustomSourceError {
        let message = error.localizedDescription
        if let storeError = error as? UserSourceStore.StoreError {
            switch storeError {
            case .invalidFile: return .ioError(message)
            case .invalidScript: return .scriptError(message)
            case .duplicate: return .ioError(message)
            case .notFound: return .ioError(message)
            }
        }
        return .ioError(message)
    }
}

/// `Resources/js/prelude.js` 定位：优先走 `ResourceLocator`（App bundle / MELO_RESOURCES），
/// 测试与 `swift run` 场景用源码路径兜底（仅开发期可用）。
enum PreludeLocator {
    static func url() -> URL? {
        let primary = ResourceLocator.preludeJS
        if FileManager.default.fileExists(atPath: primary.path) { return primary }
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // MeloJS
            .deletingLastPathComponent() // Sources
            .deletingLastPathComponent() // macos
        let candidates = [
            packageRoot.appendingPathComponent("Resources/js/prelude.js"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/js/prelude.js"),
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }
}
