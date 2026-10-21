import Foundation

// MARK: - 数据服务（SQLite，兼容原版 lx.data.db）

@MainActor
public protocol DataService: AnyObject {
    /// 初始化/创建数据库（首次启动按原版 DDL 建库）
    func bootstrap() throws

    /// 原版 `LxDatas` 目录（数据库、歌词、设置都在这里）
    var dataDirectory: URL { get }

    /// 用户自建列表（my_list 表，按 position 排序）；不含内置的 default/love/temp
    func loadUserLists() throws -> [ListInfo]
    /// 某个列表内的歌曲（按 order 表排序）；listId 可为 default/love/temp/download
    func loadMusics(listId: String) throws -> [MusicInfo]
    /// 各列表歌曲数量（用于侧边栏徽标）
    func loadMusicCounts() throws -> [String: Int]

    // 列表 CRUD
    @discardableResult
    func createList(name: String) throws -> ListInfo
    func renameList(id: String, name: String) throws
    func removeList(id: String) throws
    func updateListPosition(id: String, position: Int) throws
    func addMusic(_ music: MusicInfo, to listId: String, location: AddMusicLocationType) throws
    func removeMusic(ids: [String], from listId: String) throws
    func isMusicExist(id: String, in listId: String) throws -> Bool
    func clearList(listId: String) throws
    func overwriteList(listId: String, musics: [MusicInfo]) throws
    /// 按给定顺序重写列表内歌曲顺序（拖拽排序用）
    func updateMusicOrder(in listId: String, orderedMusicIDs: [String]) throws

    /// 扫描本地音频文件/目录（递归），生成 source=local 的 MusicInfo（不写库）
    func scanLocalMusic(at urls: [URL]) throws -> [MusicInfo]

    // 不喜欢的歌曲规则（dislike_list 表）
    func saveDislikeRulesText(_ text: String) throws
    func addDislikeMusic(name: String, singer: String) throws
    func clearDislikes() throws

    // 备份：列表导出/导入（原版 playList_v2 的 playList 数组结构）
    /// 导出默认列表/我的收藏/用户列表（不含临时列表），元素：{id,name,source,sourceListId,locationUpdateTime,list:[MusicInfo]}
    func exportPlaylistsBackup() throws -> JSONValue
    /// 导入列表备份：按 id 合并覆盖（default/love 覆盖，用户列表不存在则创建），返回统计
    func importPlaylistsBackup(_ lists: JSONValue) throws -> BackupImportSummary

    // 下载任务持久化（download_list 表）
    func saveDownloadTask(_ task: DownloadTaskInfo) throws
    func removeDownloadTasks(ids: [String]) throws
    func clearCompletedDownloadTasks() throws

    // 歌词 / URL 缓存
    func getLyric(musicId: String, source: String, type: String) throws -> String?
    func saveLyric(musicId: String, source: String, type: String, text: String) throws
    func removeLyric(musicId: String, source: String, type: String) throws
    func getMusicURL(musicId: String, quality: String) throws -> String?
    func saveMusicURL(musicId: String, quality: String, url: String) throws

    // 下载任务 / 不喜欢
    func loadDownloadTasks() throws -> [DownloadTaskInfo]
    func loadDislikes() throws -> [DislikeInfo]
}

public extension DataService {
    func updateMusicOrder(in listId: String, orderedMusicIDs: [String]) throws {
        throw DataServiceError.unsupported("当前数据层不支持排序")
    }

    func scanLocalMusic(at urls: [URL]) throws -> [MusicInfo] {
        throw DataServiceError.unsupported("当前数据层不支持本地音乐扫描")
    }

    func removeLyric(musicId: String, source: String, type: String) throws {
        throw DataServiceError.unsupported("当前数据层不支持删除歌词")
    }

    func exportPlaylistsBackup() throws -> JSONValue {
        throw DataServiceError.unsupported("当前数据层不支持列表备份")
    }

    func importPlaylistsBackup(_ lists: JSONValue) throws -> BackupImportSummary {
        throw DataServiceError.unsupported("当前数据层不支持列表恢复")
    }

    func saveDislikeRulesText(_ text: String) throws {
        throw DataServiceError.unsupported("当前数据层不支持不喜欢规则")
    }

    func addDislikeMusic(name: String, singer: String) throws {
        throw DataServiceError.unsupported("当前数据层不支持不喜欢规则")
    }

    func clearDislikes() throws {
        throw DataServiceError.unsupported("当前数据层不支持不喜欢规则")
    }

    func saveDownloadTask(_ task: DownloadTaskInfo) throws {
        throw DataServiceError.unsupported("当前数据层不支持下载任务持久化")
    }

    func removeDownloadTasks(ids: [String]) throws {
        throw DataServiceError.unsupported("当前数据层不支持下载任务持久化")
    }

    func clearCompletedDownloadTasks() throws {
        throw DataServiceError.unsupported("当前数据层不支持下载任务持久化")
    }
}

public enum DataServiceError: LocalizedError {
    case unsupported(String)
    case invalidState(String)
    public var errorDescription: String? {
        switch self {
        case .unsupported(let message): return message
        case .invalidState(let message): return message
        }
    }
}

// MARK: - 播放器服务

@MainActor
public protocol PlayerService: AnyObject {
    var eventHandler: ((PlayerEvent) -> Void)? { get set }
    var status: PlayerStatus { get }
    var currentMusic: MusicInfo? { get }

    var volume: Double { get set }
    var isMuted: Bool { get set }
    var playbackRate: Double { get set }
    /// 系统媒体键/Now Playing 下一首、上一首回调（由 AppModel 注入）
    var onNextRequested: (() -> Void)? { get set }
    var onPreviousRequested: (() -> Void)? { get set }

    /// 开始播放一个远程/本地 URL
    func play(url: URL, music: MusicInfo) throws
    func pause()
    func resume()
    func stop()
    func seek(to time: TimeInterval)
    /// 当前播放时间（秒）
    var currentTime: TimeInterval { get }
    var duration: TimeInterval { get }
}

/// 支持实时音效（EQ/变速变调）的播放器实现由 MeloAudio 提供；AppModel 用它应用设置。
@MainActor
public protocol AudioEffectApplying: AnyObject {
    func applyAudioEffects(_ settings: AudioEffectSettings)
}

// MARK: - 自定义源服务（落雪 LX 自定义源运行时）

@MainActor
public protocol CustomSourceService: AnyObject {
    var eventHandler: ((CustomSourceEvent) -> Void)? { get set }

    /// 所有已导入源（来自 LxDatas/user_api.json，兼容原版 `gz_` 压缩存储）
    var sources: [UserSourceInfo] { get }
    var activeSourceId: String? { get }
    var status: SourceRuntimeStatus { get }
    /// 当前活动源声明的能力（sources/qualitys/actions）
    var capabilities: [SourceCapability] { get }

    func reloadSources() throws
    /// 导入 .js 源文件（持久化到与原版兼容的 user_api.json）
    @discardableResult
    func importSource(from url: URL) throws -> UserSourceInfo
    /// 在线导入：从 http(s) 链接下载脚本后按原版规则导入
    @discardableResult
    func importSource(fromRemoteURL url: URL) async throws -> UserSourceInfo
    func removeSource(id: String) throws
    /// 激活源（启动 JSC 运行时并执行脚本，等待 inited 事件）
    func activateSource(id: String) async
    func deactivateSource()

    /// 用当前活动源解析音乐播放地址（action=musicUrl）
    func resolveMusicURL(source: String, musicInfo: MusicInfo, quality: String) async throws -> URL
    /// 用当前活动源解析歌词（action=lyric，脚本支持时）
    func resolveLyric(source: String, musicInfo: MusicInfo) async throws -> LyricInfo?
}

public enum CustomSourceError: LocalizedError {
    case notActivated
    case noCapability(source: String, action: String)
    case scriptError(String)
    case invalidResult(String)
    case timeout(String)
    case ioError(String)

    public var errorDescription: String? {
        switch self {
        case .notActivated: return "尚未激活自定义源"
        case .noCapability(let source, let action): return "当前源不支持 \(source) 的 \(action)"
        case .scriptError(let message): return "源脚本执行失败：\(message)"
        case .invalidResult(let message): return "源脚本返回无效结果：\(message)"
        case .timeout(let message): return "操作超时：\(message)"
        case .ioError(let message): return "IO 错误：\(message)"
        }
    }
}

// MARK: - 下载服务（Phase 2：下载引擎 + 标签写入由 MeloData 实现，MeloApp 注入）

@MainActor
public protocol DownloadService: AnyObject {
    /// 任务进度/状态变化时回调（AppModel 用它刷新下载页）
    var onTasksChanged: (() -> Void)? { get set }
    var tasks: [DownloadTaskInfo] { get }

    @discardableResult
    func enqueue(music: MusicInfo, quality: String, url: URL, saveDirectory: URL,
                 fileName: String, fileExtension: String,
                 embedPicture: Bool, embedLyrics: Bool,
                 lyrics: LyricInfo?, pictureURL: URL?) -> String
    func pause(id: String)
    func resume(id: String)
    func cancel(id: String)
    func remove(id: String)
    /// 重启后从 download_list 恢复任务（暂停态，用户可手动继续）
    func restore(tasks: [DownloadTaskInfo])
    /// 下载完成后额外保存 .lrc 歌词文件（原版 download.isDownloadLrc）
    func setLrcFile(taskID: String, content: String, encoding: String)
}

public extension DownloadService {
    func restore(tasks: [DownloadTaskInfo]) {}
    func setLrcFile(taskID: String, content: String, encoding: String) {}
}

// MARK: - 内置元数据源服务（Phase 1：JavaScriptCore 复用原版 musicSdk）

/// 内置音乐源元数据（搜索/歌单/榜单/歌词/评论）。
/// 实现由 `MeloJS.JSMetadataService` 提供：把原版 `src/renderer/utils/musicSdk` 打包为 JS bundle
/// 放在 JavaScriptCore 中运行，Swift 只负责 HTTP/crypto/zlib 桥接与 JSON 模型化。
@MainActor
public protocol MetadataService: AnyObject {
    /// JS bundle 是否已加载、可调用
    var isReady: Bool { get }
    /// 内置源列表（酷我、酷狗、QQ、网易、咪咕）
    var sources: [MusicSourceInfo] { get }

    /// 预加载 JS 运行时（幂等；MeloApp 启动时调用）
    func prepare() async throws

    /// 热搜词
    func hotSearch(source: String) async throws -> [String]

    /// 单曲搜索；source = "all" 时聚合全部源
    func searchMusic(keyword: String, source: String, page: Int, limit: Int) async throws -> SearchPage<MusicInfo>

    /// 歌单搜索
    func searchSongList(keyword: String, source: String, page: Int, limit: Int) async throws -> SearchPage<SongListItem>

    /// 排行榜列表（id 为原版的 `${source}__${bangId}` 复合 id）
    func leaderboards(source: String) async throws -> [LeaderboardInfo]

    /// 排行榜单页歌曲；boardId 为 `${source}__${bangId}`
    func leaderboardMusics(boardId: String, page: Int, limit: Int) async throws -> SearchPage<MusicInfo>

    /// 歌单广场排序选项（如 最新/最热）
    func songListSorts(source: String) async throws -> [SongListSort]

    /// 歌单广场标签
    func songListTags(source: String) async throws -> SongListTags

    /// 歌单广场列表
    func songLists(source: String, tagId: String, sortId: String, page: Int, limit: Int) async throws -> SearchPage<SongListItem>

    /// 歌单详情（含歌曲分页）
    func songListDetail(id: String, source: String, page: Int, limit: Int) async throws -> SongListDetail

    /// 歌词（内置源，支持逐字歌词）
    func lyric(musicInfo: MusicInfo) async throws -> LyricInfo?

    /// 评论（分页）；源不支持时抛 MetadataError.unsupported
    func comments(musicInfo: MusicInfo, page: Int, limit: Int) async throws -> CommentPage
    /// 热门评论；源不支持时抛 MetadataError.unsupported
    func hotComments(musicInfo: MusicInfo, limit: Int) async throws -> CommentPage
}

public enum MetadataError: LocalizedError {
    case notReady
    case unsupported(String)
    case invalidResult(String)
    case scriptError(String)
    case timeout(String)

    public var errorDescription: String? {
        switch self {
        case .notReady: return "内置音源尚未就绪"
        case .unsupported(let message): return message
        case .invalidResult(let message): return "音源返回无效数据：\(message)"
        case .scriptError(let message): return "音源脚本执行失败：\(message)"
        case .timeout(let message): return "音源请求超时：\(message)"
        }
    }
}

public extension CustomSourceService {
    /// 默认实现：运行时未提供在线导入能力时抛错（真实实现见 MeloJS）
    @discardableResult
    func importSource(fromRemoteURL url: URL) async throws -> UserSourceInfo {
        throw CustomSourceError.invalidResult("当前自定义源运行时不支持在线导入")
    }
}


// MARK: - 网络代理（MeloJS 实现：自定义源/内置元数据请求走代理）

@MainActor
public protocol ProxyConfiguring: AnyObject {
    func configureProxy(_ settings: ProxySettings)
}

// MARK: - 应用数据存储（MeloData 实现：LxDatas/data.json，兼容原版 playInfo / listUpdateInfo）

@MainActor
public protocol AppDataStore: AnyObject {
    func loadPlayInfo() -> PlayInfoSnapshot?
    func savePlayInfo(_ snapshot: PlayInfoSnapshot)
    func loadListUpdateInfo() -> [String: ListUpdateInfo]
    func saveListUpdateInfo(_ info: [String: ListUpdateInfo])
}

// MARK: - 缓存管理（MeloData.CacheManager 实现，MeloUI 只依赖 MeloCore 模型）

public struct CacheCategoryInfo: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var sizeBytes: Int64
    public var fileCount: Int

    public init(id: String, name: String, sizeBytes: Int64, fileCount: Int) {
        self.id = id
        self.name = name
        self.sizeBytes = sizeBytes
        self.fileCount = fileCount
    }

    public var displaySize: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
}

@MainActor
public protocol CacheManaging: AnyObject {
    func cacheCategories() -> [CacheCategoryInfo]
    func clearCache(categoryID: String) throws -> Int
    var totalCacheSizeBytes: Int64 { get }
}

// MARK: - 音频输出设备选择（MeloAudio 实现，MeloUI 只依赖 MeloCore 模型）

public struct AudioOutputDeviceInfo: Identifiable, Hashable, Sendable {
    public var id: String      // 设备 UID
    public var name: String
    public var isDefault: Bool

    public init(id: String, name: String, isDefault: Bool) {
        self.id = id
        self.name = name
        self.isDefault = isDefault
    }
}

@MainActor
public protocol AudioOutputDeviceSelecting: AnyObject {
    func availableOutputDevices() -> [AudioOutputDeviceInfo]
    /// nil 表示系统默认设备
    func currentOutputDeviceUID() -> String?
    func applyOutputDevice(uid: String?) throws
}

// MARK: - 备份文件服务（MeloCore 内置实现：读取/写入 .lxmc= gzip(JSON) 或 .json）

@MainActor
public protocol BackupProviding: AnyObject {
    func export(kind: BackupKind, to url: URL) throws
    func importBackup(from url: URL) throws -> BackupImportSummary
}

// MARK: - 开放 API（本地 HTTP 服务由 MeloJS 实现，AppModel 提供状态/命令）

@MainActor
public protocol OpenAPIHost: AnyObject {
    func openAPIStatus() -> OpenAPIStatus
    func openAPICommand(_ command: String, arguments: [String: String]) async -> OpenAPICommandResult
    /// 原版开放 API 的 player_status 字段（status/name/singer/.../lyricLineText 等），用于 /status?filter= 与 SSE
    func openAPIPlayerStatus() -> [String: JSONValue]
    /// 原版开放 API 的歌词包（lyric/tlyric/rlyric/lxlyric 原文）
    func openAPILyricBundle() -> [String: String]
}

@MainActor
public protocol OpenAPIServing: AnyObject {
    var isRunning: Bool { get }
    var lastError: String? { get }
    func start(port: UInt16, token: String?, host: OpenAPIHost) throws
    /// 原版兼容：允许局域网访问（bindLan=true 时监听 0.0.0.0）
    func start(port: UInt16, token: String?, bindLan: Bool, host: OpenAPIHost) throws
    func stop()
}

public extension OpenAPIServing {
    var lastError: String? { nil }
    func start(port: UInt16, token: String?, bindLan: Bool, host: OpenAPIHost) throws {
        try start(port: port, token: token, host: host)
    }
}


public extension MetadataService {
    func comments(musicInfo: MusicInfo, page: Int, limit: Int) async throws -> CommentPage {
        throw MetadataError.unsupported("当前音源不支持评论")
    }

    func hotComments(musicInfo: MusicInfo, limit: Int) async throws -> CommentPage {
        throw MetadataError.unsupported("当前音源不支持评论")
    }
}
