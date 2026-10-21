import Foundation
import MeloCore

/// 内置元数据源服务：在独立 JavaScriptCore 中运行原版 `musicSdk` bundle，
/// 为 App 提供搜索 / 热搜 / 排行榜 / 歌单 / 歌词能力。
///
/// 设计：
/// - 独立 `JSContext`（与自定义源运行时隔离），主线程串行；
/// - bundle 为 `resourcesDirectory/js/musicSdk.bundle.js`（仓库产物，App 运行不需要 Node）；
/// - 所有调用 20s 超时、可取消；错误统一转 `MetadataError`；
/// - `sources` 在 prepare 前返回内置源列表（AppModel bootstrap 会先读取）。
@MainActor
public final class JSMetadataService: MetadataService, ProxyConfiguring {

    public private(set) var isReady = false
    public private(set) var sources: [MusicSourceInfo]

    private let resourcesDirectory: URL
    private let bundleURL: URL
    private var runtime: JSMetadataRuntime?
    private var loadGeneration = 0

    /// 测试可注入更短超时
    var prepareTimeout: TimeInterval = 20
    var requestTimeout: TimeInterval = 20

    static let defaultSources: [MusicSourceInfo] = [
        MusicSourceInfo(id: "kw", name: "酷我音乐"),
        MusicSourceInfo(id: "kg", name: "酷狗音乐"),
        MusicSourceInfo(id: "tx", name: "QQ音乐"),
        MusicSourceInfo(id: "wy", name: "网易云音乐"),
        MusicSourceInfo(id: "mg", name: "咪咕音乐"),
    ]

    public init(resourcesDirectory: URL) {
        self.resourcesDirectory = resourcesDirectory
        self.bundleURL = resourcesDirectory.appendingPathComponent("js/musicSdk.bundle.js")
        self.sources = Self.defaultSources
    }

    // MARK: - 预加载

    public func prepare() async throws {
        if isReady { return }
        loadGeneration += 1
        let generation = loadGeneration

        guard FileManager.default.fileExists(atPath: bundleURL.path) else {
            throw MetadataError.scriptError("找不到内置音源资源 js/musicSdk.bundle.js")
        }
        let bundleSource: String
        do {
            bundleSource = try String(contentsOf: bundleURL, encoding: .utf8)
        } catch {
            throw MetadataError.scriptError("读取内置音源资源失败：\(error.localizedDescription)")
        }

        runtime?.shutdown()
        let runtime = JSMetadataRuntime()
        runtime.onLog = { message in
            MeloLog.info("[metadata] \(message)")
        }
        do {
            try runtime.loadBundle(bundleSource, sourceURL: bundleURL)
            let result = try await runtime.call("prepare", arguments: [], timeout: prepareTimeout)
            let decodedSources: [MusicSourceInfo]
            if let list = result["sources"]?.arrayValue {
                decodedSources = try Self.decode([MusicSourceInfo].self, from: .array(list))
            } else {
                decodedSources = Self.defaultSources
            }
            guard generation == loadGeneration, !runtime.isShutdown else {
                runtime.shutdown()
                return
            }
            self.runtime = runtime
            if !decodedSources.isEmpty { self.sources = decodedSources }
            self.isReady = true
        } catch {
            runtime.shutdown()
            throw error
        }
    }

    // MARK: - MetadataService

    public func hotSearch(source: String) async throws -> [String] {
        let value = try await call("hotSearch", arguments: [.string(source)])
        return try Self.decode([String].self, from: value)
    }

    public func searchMusic(keyword: String, source: String, page: Int, limit: Int) async throws -> SearchPage<MusicInfo> {
        let value = try await call("searchMusic", arguments: [
            .object([
                "keyword": .string(keyword),
                "source": .string(source),
                "page": .int(Int64(page)),
                "limit": .int(Int64(limit)),
            ])
        ])
        return try Self.decode(SearchPage<MusicInfo>.self, from: value)
    }

    public func searchSongList(keyword: String, source: String, page: Int, limit: Int) async throws -> SearchPage<SongListItem> {
        let value = try await call("searchSongList", arguments: [
            .object([
                "keyword": .string(keyword),
                "source": .string(source),
                "page": .int(Int64(page)),
                "limit": .int(Int64(limit)),
            ])
        ])
        return try Self.decode(SearchPage<SongListItem>.self, from: value)
    }

    public func leaderboards(source: String) async throws -> [LeaderboardInfo] {
        let value = try await call("leaderboards", arguments: [.string(source)])
        return try Self.decode([LeaderboardInfo].self, from: value)
    }

    public func leaderboardMusics(boardId: String, page: Int, limit: Int) async throws -> SearchPage<MusicInfo> {
        let value = try await call("leaderboardMusics", arguments: [
            .object([
                "boardId": .string(boardId),
                "page": .int(Int64(page)),
                "limit": .int(Int64(limit)),
            ])
        ])
        return try Self.decode(SearchPage<MusicInfo>.self, from: value)
    }

    public func songListSorts(source: String) async throws -> [SongListSort] {
        let value = try await call("songListSorts", arguments: [.string(source)])
        return try Self.decode([SongListSort].self, from: value)
    }

    public func songListTags(source: String) async throws -> SongListTags {
        let value = try await call("songListTags", arguments: [.string(source)])
        return try Self.decode(SongListTags.self, from: value)
    }

    public func songLists(source: String, tagId: String, sortId: String, page: Int, limit: Int) async throws -> SearchPage<SongListItem> {
        let value = try await call("songLists", arguments: [
            .object([
                "source": .string(source),
                "tagId": .string(tagId),
                "sortId": .string(sortId),
                "page": .int(Int64(page)),
                "limit": .int(Int64(limit)),
            ])
        ])
        return try Self.decode(SearchPage<SongListItem>.self, from: value)
    }

    public func songListDetail(id: String, source: String, page: Int, limit: Int) async throws -> SongListDetail {
        let value = try await call("songListDetail", arguments: [
            .object([
                "id": .string(id),
                "source": .string(source),
                "page": .int(Int64(page)),
                "limit": .int(Int64(limit)),
            ])
        ])
        return try Self.decode(SongListDetail.self, from: value)
    }

    public func lyric(musicInfo: MusicInfo) async throws -> LyricInfo? {
        guard let source = Self.sourceID(from: musicInfo) else {
            throw MetadataError.unsupported("无法确定歌曲所属音源：\(musicInfo.id)")
        }
        let value = try await call("lyric", arguments: [
            .object([
                "source": .string(source),
                "musicInfo": musicInfo.jsonObject,
            ])
        ])
        if value.isNull { return nil }
        let info = try Self.decode(LyricInfo.self, from: value)
        return info.isEmpty ? nil : info
    }

    // MARK: - 歌曲评论

    /// 歌曲评论（分页）。单源失败以中文 `MetadataError` 抛出。
    public func comments(musicInfo: MusicInfo, page: Int, limit: Int) async throws -> CommentPage {
        let requestedPage = max(1, page)
        let requestedLimit = max(1, limit)
        let source = try Self.commentSource(from: musicInfo)
        let value: JSONValue
        do {
            value = try await call("comments", arguments: [
                .object([
                    "source": .string(source),
                    "musicInfo": musicInfo.jsonObject,
                    "page": .int(Int64(requestedPage)),
                    "limit": .int(Int64(requestedLimit)),
                ])
            ])
        } catch let error as MetadataError {
            throw Self.mapCommentError(error)
        }
        return try Self.decodeCommentPage(
            from: value,
            fallbackSource: source,
            fallbackPage: requestedPage,
            fallbackLimit: requestedLimit
        )
    }

    /// 热门评论。
    public func hotComments(musicInfo: MusicInfo, limit: Int) async throws -> CommentPage {
        let requestedLimit = max(1, limit)
        let source = try Self.commentSource(from: musicInfo)
        let value: JSONValue
        do {
            value = try await call("hotComments", arguments: [
                .object([
                    "source": .string(source),
                    "musicInfo": musicInfo.jsonObject,
                    "limit": .int(Int64(requestedLimit)),
                ])
            ])
        } catch let error as MetadataError {
            throw Self.mapCommentError(error)
        }
        return try Self.decodeCommentPage(
            from: value,
            fallbackSource: source,
            fallbackPage: 1,
            fallbackLimit: requestedLimit
        )
    }

    private static func commentSource(from musicInfo: MusicInfo) throws -> String {
        guard let source = sourceID(from: musicInfo) else {
            throw MetadataError.unsupported("无法确定歌曲所属音源：\(musicInfo.id)")
        }
        return source
    }

    /// JS 抛错 → 中文可读的 MetadataError（不支持 / 请求失败原样保留）
    private static func mapCommentError(_ error: MetadataError) -> MetadataError {
        guard case .scriptError(let message) = error else { return error }
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .scriptError("获取评论失败") }
        if trimmed.contains("不支持") { return .unsupported(trimmed) }
        if trimmed.contains("失败") { return .scriptError(trimmed) }
        return .scriptError("获取评论失败：\(trimmed)")
    }

    /// 宽松解码评论页：id 统一 String、缺失字段使用默认值、reply 可为 null/数组（取首条）
    private static func decodeCommentPage(
        from value: JSONValue,
        fallbackSource: String,
        fallbackPage: Int,
        fallbackLimit: Int
    ) throws -> CommentPage {
        guard let object = value.objectValue else {
            throw MetadataError.invalidResult("评论结果格式错误")
        }
        let comments = (object["comments"]?.arrayValue ?? []).compactMap(decodeComment)
        let total = object["total"]?.intValue ?? comments.count
        let page = object["page"]?.intValue ?? fallbackPage
        let limit = object["limit"]?.intValue ?? fallbackLimit
        let maxPage = object["maxPage"]?.intValue
            ?? (limit > 0 ? max(1, (total + limit - 1) / limit) : 1)
        let source = object["source"]?.stringValue ?? fallbackSource
        return CommentPage(
            source: source,
            comments: comments,
            total: total,
            page: page,
            limit: limit,
            maxPage: maxPage
        )
    }

    private static func decodeComment(_ value: JSONValue) -> CommentInfo? {
        guard let object = value.objectValue else { return nil }
        let id = object["id"]?.stringValue ?? ""
        let text = object["text"]?.stringValue ?? ""
        guard !id.isEmpty || !text.isEmpty else { return nil }
        return CommentInfo(
            id: id,
            text: text,
            time: object["time"]?.doubleValue,
            timeStr: object["timeStr"]?.stringValue,
            location: object["location"]?.stringValue,
            userName: object["userName"]?.stringValue ?? "",
            avatar: object["avatar"]?.stringValue,
            userId: object["userId"]?.stringValue,
            likedCount: object["likedCount"]?.intValue ?? 0,
            reply: object["reply"].flatMap(decodeCommentReply)
        )
    }

    private static func decodeCommentReply(_ value: JSONValue) -> CommentReply? {
        if let list = value.arrayValue {
            guard let first = list.first else { return nil }
            return decodeCommentReply(first)
        }
        guard let object = value.objectValue else { return nil }
        let id = object["id"]?.stringValue ?? ""
        let text = object["text"]?.stringValue ?? ""
        guard !id.isEmpty || !text.isEmpty else { return nil }
        return CommentReply(
            id: id,
            text: text,
            userName: object["userName"]?.stringValue ?? "",
            avatar: object["avatar"]?.stringValue,
            userId: object["userId"]?.stringValue,
            likedCount: object["likedCount"]?.intValue,
            location: object["location"]?.stringValue
        )
    }

    // MARK: - 网络代理

    /// 应用用户自定义 HTTP 代理（原版 network.proxy.*）：
    /// - https → 重建本服务运行时 HTTPBridge 的 URLSession；
    /// - http → NWHTTPClient 后续请求读取共享代理快照；
    /// - 未运行（runtime == nil）时仅更新共享快照，下次 prepare 创建运行时自动生效。
    public func configureProxy(_ settings: ProxySettings) {
        NetworkProxyStore.shared.update(settings)
        runtime?.configureProxy(settings)
    }

    /// 测试/诊断用：bundle 注入后的全局环境探针
    func evaluateForTesting(_ expression: String) -> String? {
        runtime?.evaluateForTesting(expression)
    }

    // MARK: - 内部

    private func call(_ method: String, arguments: [JSONValue]) async throws -> JSONValue {
        guard isReady, let runtime else { throw MetadataError.notReady }
        return try await runtime.call(method, arguments: arguments, timeout: requestTimeout)
    }

    private static func decode<T: Decodable>(_ type: T.Type, from value: JSONValue) throws -> T {
        guard !value.isNull else {
            throw MetadataError.invalidResult("音源返回空结果")
        }
        guard let data = value.jsonData() else {
            throw MetadataError.invalidResult("无法序列化音源结果")
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw MetadataError.invalidResult("音源结果解析失败：\(error.localizedDescription)")
        }
    }

    private static func sourceID(from musicInfo: MusicInfo) -> String? {
        if !musicInfo.source.isEmpty { return musicInfo.source }
        if let metaSource = musicInfo.meta["source"]?.stringValue, !metaSource.isEmpty {
            return metaSource
        }
        // 兜底：MusicInfo.id 形如 `<source>_<songId>`（kg 的 id 为 `<songId>_<hash>`，依赖 source 字段）
        for source in defaultSources.map(\.id) where musicInfo.id.hasPrefix(source + "_") {
            return source
        }
        return nil
    }
}
