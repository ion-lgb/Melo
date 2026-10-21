import Foundation

// MARK: - 音乐

public struct MusicQuality: Codable, Hashable, Sendable {
    public var type: String
    public var size: String?

    public init(type: String, size: String? = nil) {
        self.type = type
        self.size = size
    }

    public init?(json: JSONValue) {
        guard let type = json["type"]?.stringValue else { return nil }
        self.type = type
        self.size = json["size"]?.stringValue
    }

    public var json: JSONValue {
        var obj: [String: JSONValue] = ["type": .string(type)]
        if let size { obj["size"] = .string(size) }
        return .object(obj)
    }
}

/// 与 LX Music 原版数据结构保持一致：
/// `id` = `<source>_<songId>`；`meta` 是结构不固定的 JSON（songId/albumName/picUrl/qualitys/_qualitys/...），
/// 用 JSONValue 原样承载，保证从原版数据库/接口读写时不丢字段。
public struct MusicInfo: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var singer: String
    public var source: String
    public var interval: String?
    public var meta: JSONValue

    public init(id: String, name: String, singer: String, source: String, interval: String?, meta: JSONValue) {
        self.id = id
        self.name = name
        self.singer = singer
        self.source = source
        self.interval = interval
        self.meta = meta
    }

    public var songId: String? {
        meta["songId"]?.stringValue
    }

    public var albumName: String {
        meta["albumName"]?.stringValue ?? ""
    }

    public var picUrl: String? {
        guard let url = meta["picUrl"]?.stringValue, !url.isEmpty else { return nil }
        return url
    }

    public var qualitys: [MusicQuality] {
        (meta["qualitys"]?.arrayValue ?? []).compactMap(MusicQuality.init(json:))
    }

    /// meta._qualitys 的 key 集合（原版用于判断可用音质）
    public var availableQualityKeys: [String] {
        meta["_qualitys"]?.objectValue?.keys.sorted() ?? []
    }

    public var filePath: String? { meta["filePath"]?.stringValue }
    public var fileExt: String? { meta["ext"]?.stringValue }
    public var albumId: String? { meta["albumId"]?.stringValue }

    public var displayInterval: String { interval ?? "--:--" }
    public var isLocal: Bool { source == "local" }

    /// 原版列表中的展示：歌名 + 音质标签等由 UI 决定，这里只提供音质列表
    public var qualityBadges: [String] { qualitys.isEmpty ? availableQualityKeys : qualitys.map(\.type) }

    public static func makeID(source: String, songId: String) -> String {
        "\(source)_\(songId)"
    }

    public var jsonObject: JSONValue {
        if let data = try? JSONEncoder().encode(self), let value = JSONValue(jsonData: data) { return value }
        return .object([:])
    }
}

public struct ListInfo: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var source: String?
    public var sourceListId: String?
    public var position: Int
    public var locationUpdateTime: Int64?

    public init(id: String, name: String, source: String? = nil, sourceListId: String? = nil, position: Int = 0, locationUpdateTime: Int64? = nil) {
        self.id = id
        self.name = name
        self.source = source
        self.sourceListId = sourceListId
        self.position = position
        self.locationUpdateTime = locationUpdateTime
    }
}

public enum ListIDs {
    public static let `default` = "default"
    public static let love = "love"
    public static let temp = "temp"
    public static let download = "download"

    /// 原版内置列表（不在 my_list 表中，但展示时永远存在）
    public static let builtin: [ListInfo] = [
        ListInfo(id: ListIDs.default, name: "试听列表", position: -3),
        ListInfo(id: ListIDs.love, name: "我的收藏", position: -2),
        ListInfo(id: ListIDs.temp, name: "临时列表", position: -1),
    ]

    public static func isBuiltin(_ id: String) -> Bool {
        [ListIDs.default, ListIDs.love, ListIDs.temp].contains(id)
    }

    public static func defaultName(_ id: String) -> String {
        switch id {
        case ListIDs.default: return "试听列表"
        case ListIDs.love: return "我的收藏"
        case ListIDs.temp: return "临时列表"
        default: return id
        }
    }
}

// MARK: - 歌词

public struct LyricInfo: Codable, Hashable, Sendable {
    public var lyric: String
    public var tlyric: String?
    public var rlyric: String?
    public var lxlyric: String?

    public init(lyric: String = "", tlyric: String? = nil, rlyric: String? = nil, lxlyric: String? = nil) {
        self.lyric = lyric
        self.tlyric = tlyric
        self.rlyric = rlyric
        self.lxlyric = lxlyric
    }

    public var isEmpty: Bool {
        lyric.isEmpty && (tlyric?.isEmpty ?? true) && (rlyric?.isEmpty ?? true) && (lxlyric?.isEmpty ?? true)
    }
}

public struct LyricWord: Codable, Hashable, Sendable {
    public var startMs: Int
    public var durationMs: Int
    public var text: String

    public init(startMs: Int, durationMs: Int, text: String) {
        self.startMs = startMs
        self.durationMs = durationMs
        self.text = text
    }
}

public struct LyricLine: Codable, Hashable, Identifiable, Sendable {
    public var id: Int { timeMs }
    public var timeMs: Int
    public var text: String
    public var extended: [String]
    public var words: [LyricWord]
    /// 逐字歌词的行原文（含 <start,dur> 标签），用于 UI 需要时解析
    public var rawText: String?

    public init(timeMs: Int, text: String, extended: [String] = [], words: [LyricWord] = [], rawText: String? = nil) {
        self.timeMs = timeMs
        self.text = text
        self.extended = extended
        self.words = words
        self.rawText = rawText
    }

    public var time: TimeInterval { TimeInterval(timeMs) / 1000.0 }
}

public struct LyricDocument: Equatable, Sendable {
    public var lines: [LyricLine]
    /// LRC `[offset:]` 标签（毫秒）
    public var offsetMs: Int

    public init(lines: [LyricLine], offsetMs: Int = 0) {
        self.lines = lines
        self.offsetMs = offsetMs
    }

    public static let empty = LyricDocument(lines: [])

    public var isEmpty: Bool { lines.isEmpty }

    /// 返回给定播放时间（秒）应高亮的行下标；无匹配返回 nil。
    public func lineIndex(at time: TimeInterval) -> Int? {
        guard !lines.isEmpty else { return nil }
        let ms = Int((time * 1000).rounded()) + offsetMs
        if ms <= 0 { return 0 }
        var low = 0
        var high = lines.count - 1
        var result = 0
        while low <= high {
            let mid = (low + high) / 2
            if lines[mid].timeMs <= ms {
                result = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return result
    }
}

// MARK: - 下载 / 不喜欢

public struct DownloadTaskInfo: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var isCompleted: Bool
    public var status: String
    public var statusText: String
    public var progressDownloaded: Int64
    public var progressTotal: Int64
    public var url: String?
    public var quality: String
    public var ext: String
    public var fileName: String
    public var filePath: String
    public var musicInfo: MusicInfo
    public var position: Int
    /// 当前下载速度（字节/秒）；未知时为 nil
    public var speedBytesPerSecond: Double?
    /// 预计剩余秒数；未知时为 nil
    public var etaSeconds: Double?

    public init(id: String, isCompleted: Bool, status: String, statusText: String, progressDownloaded: Int64, progressTotal: Int64, url: String?, quality: String, ext: String, fileName: String, filePath: String, musicInfo: MusicInfo, position: Int, speedBytesPerSecond: Double? = nil, etaSeconds: Double? = nil) {
        self.id = id
        self.isCompleted = isCompleted
        self.status = status
        self.statusText = statusText
        self.progressDownloaded = progressDownloaded
        self.progressTotal = progressTotal
        self.url = url
        self.quality = quality
        self.ext = ext
        self.fileName = fileName
        self.filePath = filePath
        self.musicInfo = musicInfo
        self.position = position
        self.speedBytesPerSecond = speedBytesPerSecond
        self.etaSeconds = etaSeconds
    }
}

public struct DislikeInfo: Codable, Hashable, Sendable {
    public var type: String
    public var content: String
    public var meta: JSONValue?

    public init(type: String, content: String, meta: JSONValue? = nil) {
        self.type = type
        self.content = content
        self.meta = meta
    }
}

// MARK: - 自定义源

public struct UserSourceInfo: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var description: String?
    public var version: String?
    public var author: String?
    public var homepage: String?
    public var script: String
    public var isActive: Bool

    public init(id: String, name: String, description: String? = nil, version: String? = nil, author: String? = nil, homepage: String? = nil, script: String = "", isActive: Bool = false) {
        self.id = id
        self.name = name
        self.description = description
        self.version = version
        self.author = author
        self.homepage = homepage
        self.script = script
        self.isActive = isActive
    }
}

public struct SourceCapability: Codable, Hashable, Sendable {
    public var source: String
    public var name: String?
    public var actions: [String]
    public var qualitys: [String]

    public init(source: String, name: String? = nil, actions: [String], qualitys: [String]) {
        self.source = source
        self.name = name
        self.actions = actions
        self.qualitys = qualitys
    }
}

public enum SourceRuntimeStatus: Equatable, Sendable {
    case idle
    case loading
    case ready([SourceCapability])
    case error(String)

    public var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

public enum CustomSourceEvent: Sendable {
    case status(SourceRuntimeStatus)
    case log(String)
    case updateAlert(log: String, updateUrl: String?)
}

// MARK: - 播放器

public enum PlayerStatus: String, Codable, Sendable {
    case stopped
    case loading
    case playing
    case paused
    case error

    public var isPlaying: Bool { self == .playing }
}

public enum PlayerEvent: Sendable {
    case status(PlayerStatus)
    case progress(current: TimeInterval, duration: TimeInterval)
    case ended
    case error(String)
}

// MARK: - 路由 / 列表

public enum AppRoute: Hashable, Sendable {
    case search
    case leaderboard
    case songList
    case songListDetail(id: String, source: String)
    case myList(listId: String)
    case download
    case settings
    case test

    public var titleKey: String {
        switch self {
        case .search: return "search"
        case .leaderboard: return "leaderboard"
        case .songList: return "song_list"
        case .songListDetail: return "song_list_detail"
        case .myList: return "my_list"
        case .download: return "download"
        case .settings: return "setting"
        case .test: return "自定义源测试"
        }
    }
}

public enum AddMusicLocationType: String, Sendable {
    case top
    case bottom
}

// MARK: - 设置键

public enum SettingKeys {
    public static let themeId = "theme.id"
    public static let lightThemeId = "theme.lightId"
    public static let darkThemeId = "theme.darkId"
    public static let langId = "common.langId"
    public static let fontSize = "common.fontSize"
    public static let apiSource = "common.apiSource"
    public static let playerVolume = "player.volume"
    public static let playerMute = "player.isMute"
    public static let playbackRate = "player.playbackRate"
    public static let playMode = "player.togglePlayMethod"
    public static let mediaDeviceId = "player.mediaDeviceId"
    public static let autoSkipOnError = "player.autoSkipOnError"
    public static let startupAutoPlay = "player.startupAutoPlay"
    public static let savePlayTime = "player.isSavePlayTime"
    public static let waitPlayEndStop = "player.waitPlayEndStop"
    public static let waitPlayEndStopTime = "player.waitPlayEndStopTime"
    public static let autoCleanPlayedList = "player.isAutoCleanPlayedList"
    public static let openAtLogin = "common.openAtLogin"
    public static let playerAudioVisualization = "player.audioVisualization"
    public static let desktopLyricAudioVisualization = "desktopLyric.audioVisualization"
    public static let proxyEnable = "network.proxy.enable"
    public static let proxyHost = "network.proxy.host"
    public static let proxyPort = "network.proxy.port"
    public static let proxyUsername = "network.proxy.username"
    public static let proxyPassword = "network.proxy.password"
    public static let preservesPitch = "player.preservesPitch"
    public static let playQuality = "player.playQuality"
    public static let showAnimation = "common.isShowAnimation"
    public static let transparentWindow = "common.transparentWindow"
    public static let trayEnable = "tray.enable"
    public static let desktopLyricEnable = "desktopLyric.enable"
    public static let desktopLyricFontSize = "desktopLyric.style.fontSize"
    public static let desktopLyricPlayedColor = "desktopLyric.style.lyricPlayedColor"
    public static let desktopLyricUnplayColor = "desktopLyric.style.lyricUnplayColor"
    public static let desktopLyricAlwaysOnTop = "desktopLyric.isAlwaysOnTop"
    public static let desktopLyricWidth = "desktopLyric.width"
    public static let desktopLyricHeight = "desktopLyric.height"
    public static let desktopLyricX = "desktopLyric.x"
    public static let desktopLyricY = "desktopLyric.y"
    public static let downloadEnable = "download.enable"
    public static let downloadSavePath = "download.savePath"
    public static let downloadFileName = "download.fileName"
    public static let downloadMaxNumber = "download.maxDownloadNum"
    public static let downloadEmbedPic = "download.isEmbedPic"
    public static let downloadEmbedLyric = "download.isEmbedLyric"
    public static let downloadSkipExistFile = "download.skipExistFile"
    public static let downloadSaveLrc = "download.isDownloadLrc"
    public static let downloadSaveLxLrc = "download.isDownloadLxLrc"
    public static let downloadSaveTLrc = "download.isDownloadTLrc"
    public static let downloadSaveRLrc = "download.isDownloadRLrc"
    public static let downloadLrcFormat = "download.lrcFormat"
    public static let downloadEmbedLyricLx = "download.isEmbedLyricLx"
    public static let downloadEmbedLyricT = "download.isEmbedLyricT"
    public static let downloadEmbedLyricR = "download.isEmbedLyricR"

    // 桌面歌词样式 / 行为
    public static let desktopLyricOpacity = "desktopLyric.style.opacity"
    public static let desktopLyricShadowColor = "desktopLyric.style.lyricShadowColor"
    public static let desktopLyricAlign = "desktopLyric.style.align"
    public static let desktopLyricLineGap = "desktopLyric.style.lineGap"
    public static let desktopLyricFontName = "desktopLyric.style.font"
    public static let desktopLyricPauseHide = "desktopLyric.pauseHide"
    public static let desktopLyricHoverHide = "desktopLyric.isHoverHide"
    public static let desktopLyricFullscreenHide = "desktopLyric.fullscreenHide"
    public static let desktopLyricDelayScroll = "desktopLyric.isDelayScroll"
    public static let desktopLyricScrollAlign = "desktopLyric.scrollAlign"
    public static let desktopLyricEllipsis = "desktopLyric.style.ellipsis"
    public static let desktopLyricDirection = "desktopLyric.direction"

    // 歌词显示开关
    public static let showLyricTranslation = "player.isShowLyricTranslation"
    public static let showLyricRoma = "player.isShowLyricRoma"
    public static let swapLyricTranslationAndRoma = "player.isSwapLyricTranslationAndRoma"
    public static let playWordByWordLyric = "player.isPlayLxlrc"
    public static let convertLyricS2T = "player.isS2t"
    public static let showStatusBarLyric = "player.isShowStatusBarLyric"
    public static let playDetailFontSize = "playDetail.style.fontSize"
    public static let playDetailAlign = "playDetail.style.align"

    // 音效（原版设置键）
    public static let eqBandKeys = [
        "player.soundEffect.biquadFilter.hz31",
        "player.soundEffect.biquadFilter.hz62",
        "player.soundEffect.biquadFilter.hz125",
        "player.soundEffect.biquadFilter.hz250",
        "player.soundEffect.biquadFilter.hz500",
        "player.soundEffect.biquadFilter.hz1000",
        "player.soundEffect.biquadFilter.hz2000",
        "player.soundEffect.biquadFilter.hz4000",
        "player.soundEffect.biquadFilter.hz8000",
        "player.soundEffect.biquadFilter.hz16000",
    ]
    public static let eqFrequencies: [Double] = [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    public static let eqFrequencyLabels = ["31", "62", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]
    public static let pitchShifterRate = "player.soundEffect.pitchShifter.playbackRate"
    public static let convolutionFileName = "player.soundEffect.convolution.fileName"
    public static let convolutionMainGain = "player.soundEffect.convolution.mainGain"
    public static let convolutionSendGain = "player.soundEffect.convolution.sendGain"
    public static let pannerEnable = "player.soundEffect.panner.enable"
    public static let pannerSpeed = "player.soundEffect.panner.speed"
    public static let pannerSoundR = "player.soundEffect.panner.soundR"

    // 开放 API（本地 HTTP 控制，Melo 自有扩展）
    public static let openAPIEnable = "openAPI.enable"
    public static let openAPIBindLan = "openAPI.bindLan"
    public static let openAPIPort = "openAPI.port"
    public static let openAPIToken = "openAPI.token"
    public static let searchHistory = "searchHistoryList"
}

// MARK: - 内置元数据源模型（Phase 1，JSC 复用原版 musicSdk）

public struct MusicSourceInfo: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// 分页结果（与原版 musicSdk 返回的 { list, total, page, limit, allPage } 对齐）
public struct SearchPage<T: Codable & Identifiable & Hashable & Sendable>: Codable, Hashable, Sendable {
    public var list: [T]
    public var total: Int
    public var page: Int
    public var limit: Int
    public var allPage: Int
    public var source: String?

    public init(list: [T] = [], total: Int = 0, page: Int = 1, limit: Int = 30, allPage: Int = 0, source: String? = nil) {
        self.list = list
        self.total = total
        self.page = page
        self.limit = limit
        self.allPage = allPage
        self.source = source
    }

    public var isEmpty: Bool { list.isEmpty }
    public var hasMore: Bool { allPage > page }

    public mutating func append(_ other: SearchPage<T>) {
        list.append(contentsOf: other.list)
        total = other.total
        page = other.page
        limit = other.limit
        allPage = other.allPage
        source = other.source ?? source
    }
}

public struct LeaderboardInfo: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var source: String
    public var imgUrl: String?
    public var total: Int?

    public init(id: String, name: String, source: String, imgUrl: String? = nil, total: Int? = nil) {
        self.id = id
        self.name = name
        self.source = source
        self.imgUrl = imgUrl
        self.total = total
    }
}

public struct SongListSort: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public struct SongListTag: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var source: String?
    public init(id: String, name: String, source: String? = nil) {
        self.id = id
        self.name = name
        self.source = source
    }
}

public struct SongListTagGroup: Codable, Hashable, Sendable {
    public var name: String
    public var tags: [SongListTag]
    public init(name: String, tags: [SongListTag]) {
        self.name = name
        self.tags = tags
    }
}

public struct SongListTags: Codable, Hashable, Sendable {
    public var groups: [SongListTagGroup]
    public var hot: [SongListTag]

    public init(groups: [SongListTagGroup] = [], hot: [SongListTag] = []) {
        self.groups = groups
        self.hot = hot
    }

    public var isEmpty: Bool { groups.isEmpty && hot.isEmpty }
}

public struct SongListItem: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var source: String
    public var cover: String?
    public var creator: String?
    public var description: String?
    public var playCount: String?
    public var total: Int?
    /// 原版返回的额外字段（播放量、标签等），保留以便 UI 扩展
    public var raw: JSONValue?

    public init(id: String, name: String, source: String, cover: String? = nil, creator: String? = nil,
                description: String? = nil, playCount: String? = nil, total: Int? = nil, raw: JSONValue? = nil) {
        self.id = id
        self.name = name
        self.source = source
        self.cover = cover
        self.creator = creator
        self.description = description
        self.playCount = playCount
        self.total = total
        self.raw = raw
    }
}

public struct SongListDetail: Codable, Hashable, Sendable {
    public var info: SongListItem
    public var page: SearchPage<MusicInfo>

    public init(info: SongListItem, page: SearchPage<MusicInfo>) {
        self.info = info
        self.page = page
    }
}

public enum SearchTab: String, CaseIterable, Sendable {
    case music
    case songList
}


// MARK: - 音效（EQ / 变速变调）

public struct AudioEffectSettings: Equatable, Sendable {
    /// 10 段 EQ 增益（dB，顺序见 SettingKeys.eqFrequencies）
    public var eqBands: [Double]
    /// 媒体播放速率（0.5–2.0，原版 player.playbackRate）
    public var playbackRate: Double
    /// 音效层变调（半音，由原版 pitch-shifter 的 playbackRate 换算：12*log2(rate)）
    public var pitchSemitones: Double
    /// 环境混响：IR 文件名（Resources/SoundEffect/convolution/ 下），空/nil 表示关闭
    public var convolutionFileName: String?
    /// 干声增益（实际倍率，原版设置值 / 10）
    public var convolutionMainGain: Double
    /// 湿声（卷积输出）增益倍率
    public var convolutionSendGain: Double
    /// 3D 立体环绕开关
    public var pannerEnabled: Bool
    /// 环绕速度（原版 1–50，默认 25）
    public var pannerSpeed: Int
    /// 声音距离（原版 1–30，默认 5）
    public var pannerSoundR: Int

    public init(eqBands: [Double], playbackRate: Double = 1, pitchSemitones: Double = 0,
                convolutionFileName: String? = nil, convolutionMainGain: Double = 1,
                convolutionSendGain: Double = 0, pannerEnabled: Bool = false,
                pannerSpeed: Int = 25, pannerSoundR: Int = 5) {
        self.eqBands = eqBands
        self.playbackRate = playbackRate
        self.pitchSemitones = pitchSemitones
        self.convolutionFileName = convolutionFileName
        self.convolutionMainGain = convolutionMainGain
        self.convolutionSendGain = convolutionSendGain
        self.pannerEnabled = pannerEnabled
        self.pannerSpeed = pannerSpeed
        self.pannerSoundR = pannerSoundR
    }

    public static let flat = AudioEffectSettings(eqBands: Array(repeating: 0, count: 10))

    public var isEQActive: Bool {
        eqBands.contains { abs($0) > 0.01 }
    }

    public var isPitchActive: Bool {
        abs(pitchSemitones) > 0.05 || abs(playbackRate - 1) > 0.001
    }

    public var isConvolutionActive: Bool {
        guard let name = convolutionFileName?.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        return !name.isEmpty
    }

    /// 是否存在需要进入「音效播放引擎」的效果
    public var isActive: Bool {
        isEQActive || isPitchActive || isConvolutionActive || pannerEnabled
    }
}


public extension MusicInfo {
    /// 原版 `toOldMusicInfo`：自定义源脚本收到的 `musicInfo` 是旧结构
    /// （songmid / types / _types / hash / strMediaMid / copyrightId 等），
    /// 新结构（meta.songId 等）直接传给脚本会导致取链失败。
    var legacyJSON: JSONValue {
        var object: [String: JSONValue] = [
            "name": .string(name),
            "singer": .string(singer),
            "source": .string(source),
            "songmid": meta["songId"] ?? .string(id),
            "interval": interval.map { .string($0) } ?? .null,
            "albumName": .string(albumName),
            "img": (meta["picUrl"].map { $0.isNull ? .string("") : $0 } ?? .string("")),
            "typeUrl": .object([:]),
        ]

        if source == "local" {
            object["filePath"] = meta["filePath"] ?? .string("")
            object["ext"] = meta["ext"] ?? .string("")
            object["albumId"] = .string("")
            object["types"] = .array([])
            object["_types"] = .object([:])
            return .object(object)
        }

        object["albumId"] = meta["albumId"] ?? .string("")
        object["types"] = meta["qualitys"] ?? .array([])
        object["_types"] = meta["_qualitys"] ?? .object([:])

        switch source {
        case "kg":
            object["hash"] = meta["hash"] ?? .null
            object["albumAudioId"] = meta["albumAudioId"] ?? .null
        case "tx":
            object["strMediaMid"] = meta["strMediaMid"] ?? .null
            object["albumMid"] = meta["albumMid"] ?? .null
            object["songId"] = meta["id"] ?? .null
        case "mg":
            object["copyrightId"] = meta["copyrightId"] ?? .null
            object["lrcUrl"] = meta["lrcUrl"] ?? .null
            object["mrcUrl"] = meta["mrcUrl"] ?? .null
            object["trcUrl"] = meta["trcUrl"] ?? .null
        default:
            break
        }
        return .object(object)
    }
}


// MARK: - 环境混响（原版内置 IR 预设，逐项对齐 src/renderer/plugins/player/index.ts convolutions）

public struct ConvolutionPreset: Identifiable, Hashable, Sendable {
    public var fileName: String
    public var name: String
    public var defaultMainGain: Double
    public var defaultSendGain: Double

    public var id: String { fileName }

    public init(fileName: String, name: String, defaultMainGain: Double, defaultSendGain: Double) {
        self.fileName = fileName
        self.name = name
        self.defaultMainGain = defaultMainGain
        self.defaultSendGain = defaultSendGain
    }

    public static let builtin: [ConvolutionPreset] = [
        .init(fileName: "filter-telephone.wav", name: "电话", defaultMainGain: 0.0, defaultSendGain: 3.0),
        .init(fileName: "s2_r4_bd.wav", name: "教堂", defaultMainGain: 1.8, defaultSendGain: 0.9),
        .init(fileName: "bright-hall.wav", name: "大厅", defaultMainGain: 0.8, defaultSendGain: 2.4),
        .init(fileName: "cinema-diningroom.wav", name: "电影院", defaultMainGain: 0.6, defaultSendGain: 2.3),
        .init(fileName: "dining-living-true-stereo.wav", name: "餐厅", defaultMainGain: 0.6, defaultSendGain: 1.8),
        .init(fileName: "living-bedroom-leveled.wav", name: "卫生间", defaultMainGain: 0.6, defaultSendGain: 2.1),
        .init(fileName: "spreader50-65ms.wav", name: "室内", defaultMainGain: 1.0, defaultSendGain: 2.5),
        .init(fileName: "s3_r1_bd.wav", name: "立体声", defaultMainGain: 1.8, defaultSendGain: 0.8),
        .init(fileName: "matrix-reverb1.wav", name: "矩阵混响（1）", defaultMainGain: 1.5, defaultSendGain: 0.9),
        .init(fileName: "matrix-reverb2.wav", name: "矩阵混响（2）", defaultMainGain: 1.3, defaultSendGain: 1.0),
        .init(fileName: "cardiod-35-10-spread.wav", name: "心形扩散", defaultMainGain: 1.8, defaultSendGain: 0.6),
        .init(fileName: "tim-omni-35-10-magnetic.wav", name: "磁性立体声", defaultMainGain: 1.0, defaultSendGain: 0.2),
        .init(fileName: "feedback-spring.wav", name: "反馈弹簧", defaultMainGain: 1.8, defaultSendGain: 0.8),
    ]

    public static func builtin(fileName: String) -> ConvolutionPreset? {
        builtin.first { $0.fileName == fileName }
    }
}


// MARK: - 备份与恢复（对齐原版 .lxmc 格式：gzip(JSON)，type=allData_v2 / playList_v2 / setting_v2）

public enum BackupKind: String, Sendable, CaseIterable {
    case allData
    case playlists
    case settings

    public var fileExtension: String { "lxmc" }

    public var defaultFileName: String {
        switch self {
        case .allData: return "lx_datas_v2.lxmc"
        case .playlists: return "lx_list_v2.lxmc"
        case .settings: return "lx_setting_v2.lxmc"
        }
    }
}

public struct BackupImportSummary: Sendable, Equatable {
    public var lists: Int
    public var musics: Int
    public var settingsImported: Bool
    public var sourceType: String

    public init(lists: Int = 0, musics: Int = 0, settingsImported: Bool = false, sourceType: String = "") {
        self.lists = lists
        self.musics = musics
        self.settingsImported = settingsImported
        self.sourceType = sourceType
    }
}

// MARK: - 开放 API（本地 HTTP 控制）

public struct OpenAPIMusic: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var singer: String
    public var albumName: String
    public var source: String
    public var duration: Double

    public init(id: String, name: String, singer: String, albumName: String, source: String, duration: Double) {
        self.id = id
        self.name = name
        self.singer = singer
        self.albumName = albumName
        self.source = source
        self.duration = duration
    }
}

public struct OpenAPIStatus: Codable, Sendable, Equatable {
    public var status: String
    public var isPlaying: Bool
    public var music: OpenAPIMusic?
    public var currentTime: Double
    public var duration: Double
    public var volume: Double
    public var isMuted: Bool
    public var playbackRate: Double
    public var quality: String?
    public var queueCount: Int

    public init(status: String, isPlaying: Bool, music: OpenAPIMusic?, currentTime: Double,
                duration: Double, volume: Double, isMuted: Bool, playbackRate: Double,
                quality: String?, queueCount: Int) {
        self.status = status
        self.isPlaying = isPlaying
        self.music = music
        self.currentTime = currentTime
        self.duration = duration
        self.volume = volume
        self.isMuted = isMuted
        self.playbackRate = playbackRate
        self.quality = quality
        self.queueCount = queueCount
    }
}

public struct OpenAPICommandResult: Sendable, Equatable {
    public var ok: Bool
    public var message: String?
    public var status: OpenAPIStatus?

    public init(ok: Bool, message: String? = nil, status: OpenAPIStatus? = nil) {
        self.ok = ok
        self.message = message
        self.status = status
    }
}


public extension MusicInfo {
    /// 从原版旧结构 `musicInfo`（songmid/types/hash/strMediaMid...）还原为内部新结构，
    /// 用于导入旧版备份/歌单分享数据。
    init?(legacyJSON value: JSONValue) {
        func text(_ key: String) -> String? {
            if let string = value[key]?.stringValue { return string }
            if let int = value[key]?.intValue { return String(int) }
            return nil
        }
        guard let source = value["source"]?.stringValue, !source.isEmpty,
              let name = value["name"]?.stringValue, !name.isEmpty,
              let songmid = text("songmid") ?? text("songId") ?? text("copyrightId") ?? text("id"),
              !songmid.isEmpty else { return nil }

        let singer = value["singer"]?.stringValue ?? ""
        var meta: [String: JSONValue] = [
            "songId": .string(songmid),
            "albumName": value["albumName"] ?? .string(""),
            "picUrl": value["img"].flatMap { $0.isNull ? nil : $0 } ?? .string(""),
            "albumId": value["albumId"] ?? .string(""),
            "qualitys": value["types"] ?? .array([]),
            "_qualitys": value["_types"] ?? .object([:]),
        ]
        for key in ["hash", "albumAudioId", "strMediaMid", "albumMid", "copyrightId",
                    "lrcUrl", "mrcUrl", "trcUrl", "filePath", "ext"] {
            if let item = value[key], !item.isNull { meta[key] = item }
        }
        switch source {
        case "tx":
            if let songId = value["songId"], !songId.isNull { meta["id"] = songId }
        default:
            break
        }

        let id: String
        if source == "local" {
            id = text("filePath") ?? songmid
        } else if source == "kg", let hash = meta["hash"]?.stringValue, !hash.isEmpty {
            id = "\(songmid)_\(hash)"
        } else {
            id = "\(source)_\(songmid)"
        }
        self.init(id: id, name: name, singer: singer, source: source,
                  interval: value["interval"]?.stringValue, meta: .object(meta))
    }
}


// MARK: - 列表导出（对齐原版 worker/main/list.ts exportPlayListToText / ToCSV）

public enum ListExportKind: String, Sendable, CaseIterable {
    case text
    case csv

    public var label: String {
        switch self {
        case .text: return "文本 (.txt)"
        case .csv: return "CSV (.csv)"
        }
    }
}

// MARK: - 播放模式（对齐原版 player.togglePlayMethod）

public enum PlayMode: String, CaseIterable, Codable, Sendable {
    case listLoop = "listLoop"   // 列表循环
    case random = "random"       // 随机播放
    case singleLoop = "singleLoop" // 单曲循环
    case list = "list"           // 顺序播放（播完列表停止）
    case none = "none"           // 不循环（播放完当前歌曲停止）

    public var label: String {
        switch self {
        case .listLoop: return "列表循环"
        case .random: return "随机播放"
        case .singleLoop: return "单曲循环"
        case .list: return "顺序播放"
        case .none: return "不循环"
        }
    }

    public var systemImage: String {
        switch self {
        case .listLoop: return "repeat"
        case .random: return "shuffle"
        case .singleLoop: return "repeat.1"
        case .list: return "arrow.right.to.line"
        case .none: return "arrow.forward.to.line"
        }
    }

    /// 播放条按钮循环顺序（对齐原版交互：列表循环→随机→单曲→顺序→不循环）
    public var next: PlayMode {
        switch self {
        case .listLoop: return .random
        case .random: return .singleLoop
        case .singleLoop: return .list
        case .list: return .none
        case .none: return .listLoop
        }
    }
}

// MARK: - 列表排序（对齐原版 ListSortModal：字段 name/singer/albumName/interval/source，方向 up/down/random）

public enum MusicSortField: String, CaseIterable, Sendable {
    case name
    case singer
    case albumName
    case interval
    case source

    public var label: String {
        switch self {
        case .name: return "歌曲名"
        case .singer: return "歌手"
        case .albumName: return "专辑"
        case .interval: return "时长"
        case .source: return "音源"
        }
    }
}

public enum MusicSortDirection: String, CaseIterable, Sendable {
    case up
    case down
    case random

    public var label: String {
        switch self {
        case .up: return "升序"
        case .down: return "降序"
        case .random: return "随机"
        }
    }
}


// MARK: - 歌曲评论（内置元数据源；原版仅网易云等源提供）

public struct CommentReply: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var text: String
    public var userName: String
    public var avatar: String?
    public var userId: String?
    public var likedCount: Int?
    public var location: String?

    public init(id: String, text: String, userName: String, avatar: String? = nil,
                userId: String? = nil, likedCount: Int? = nil, location: String? = nil) {
        self.id = id
        self.text = text
        self.userName = userName
        self.avatar = avatar
        self.userId = userId
        self.likedCount = likedCount
        self.location = location
    }
}

public struct CommentInfo: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var text: String
    /// 秒（原版 time 字段是秒级时间戳）
    public var time: Double?
    public var timeStr: String?
    public var location: String?
    public var userName: String
    public var avatar: String?
    public var userId: String?
    public var likedCount: Int
    public var reply: CommentReply?

    public init(id: String, text: String, time: Double? = nil, timeStr: String? = nil,
                location: String? = nil, userName: String, avatar: String? = nil,
                userId: String? = nil, likedCount: Int = 0, reply: CommentReply? = nil) {
        self.id = id
        self.text = text
        self.time = time
        self.timeStr = timeStr
        self.location = location
        self.userName = userName
        self.avatar = avatar
        self.userId = userId
        self.likedCount = likedCount
        self.reply = reply
    }
}

public struct CommentPage: Codable, Sendable {
    public var source: String
    public var comments: [CommentInfo]
    public var total: Int
    public var page: Int
    public var limit: Int
    public var maxPage: Int

    public init(source: String, comments: [CommentInfo], total: Int, page: Int, limit: Int, maxPage: Int) {
        self.source = source
        self.comments = comments
        self.total = total
        self.page = page
        self.limit = limit
        self.maxPage = maxPage
    }
}


// MARK: - 应用数据存储（原版 LxDatas/data.json：electron-store 根键 playInfo / listUpdateInfo）

public struct PlayInfoSnapshot: Codable, Sendable, Equatable {
    public var time: Double
    public var maxTime: Double
    public var musicInfo: MusicInfo?
    public var listId: String?

    public init(time: Double, maxTime: Double, musicInfo: MusicInfo?, listId: String?) {
        self.time = time
        self.maxTime = maxTime
        self.musicInfo = musicInfo
        self.listId = listId
    }
}

public struct ListUpdateInfo: Codable, Sendable, Equatable {
    public var updateTime: Int64
    public var isAutoUpdate: Bool

    public init(updateTime: Int64 = 0, isAutoUpdate: Bool = false) {
        self.updateTime = updateTime
        self.isAutoUpdate = isAutoUpdate
    }
}


// MARK: - 不喜欢的歌曲规则（原版 dislike_list 表：content 为规则文本）

public struct DislikeRules: Sendable, Equatable {
    /// "歌曲名@歌手"（normalized 后）
    public var names: Set<String> = []
    public var musicNames: Set<String> = []
    public var singerNames: Set<String> = []
    /// 原始规则文本（每行一条）
    public var rulesText: String = ""

    public static let separator: Character = "@"
    public static let alias: Character = "#"

    public init() {}

    public init(rulesText: String) {
        // 原版规则文本：每行 `歌曲名@歌手` / `歌曲名` / `@歌手`；
        // 名字/歌手中字面量 `@` 用 `#` 表示（匹配时把实际歌曲的 `@` 换成 `#` 再比较）。
        var unique: [String] = []
        for rawLine in rulesText.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            let parts = line.split(separator: Self.separator, maxSplits: 1, omittingEmptySubsequences: false)
                .map { Self.normalize(String($0)) }
            if parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty {
                names.insert("\(parts[0])@\(parts[1])")
                unique.append("\(parts[0])@\(parts[1])")
            } else if parts.count == 2, parts[0].isEmpty, !parts[1].isEmpty {
                singerNames.insert(parts[1])
                unique.append("@\(parts[1])")
            } else if parts.count == 2, !parts[0].isEmpty, parts[1].isEmpty {
                musicNames.insert(parts[0])
                unique.append(parts[0])
            } else if parts.count == 1, !parts[0].isEmpty {
                musicNames.insert(parts[0])
                unique.append(parts[0])
            }
        }
        var seen: Set<String> = []
        self.rulesText = unique.filter { seen.insert($0).inserted }
            .joined(separator: "\n")
    }

    public init(dislikes: [DislikeInfo]) {
        self.init(rulesText: dislikes.map(\.content).joined(separator: "\n"))
    }

    public var count: Int { names.count + musicNames.count + singerNames.count }

    public var isEmpty: Bool { count == 0 }

    private static func normalize(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func normalizeForMatch(_ text: String) -> String {
        normalize(text).replacingOccurrences(of: "@", with: "#")
    }

    public func matches(_ music: MusicInfo) -> Bool {
        let name = Self.normalizeForMatch(music.name)
        let singer = Self.normalizeForMatch(music.singer)
        return musicNames.contains(name)
            || singerNames.contains(singer)
            || names.contains("\(name)@\(singer)")
    }

    public func filter(_ musics: [MusicInfo]) -> [MusicInfo] {
        guard !isEmpty else { return musics }
        return musics.filter { !matches($0) }
    }

    public func toDislikeInfos() -> [DislikeInfo] {
        rulesText.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { DislikeInfo(type: "", content: $0, meta: nil) }
    }
}

// MARK: - 网络代理（原版 network.proxy.*）

public struct ProxySettings: Sendable, Equatable {
    public var enabled: Bool
    public var host: String
    public var port: Int
    public var username: String
    public var password: String

    public init(enabled: Bool = false, host: String = "", port: Int = 0,
                username: String = "", password: String = "") {
        self.enabled = enabled
        self.host = host
        self.port = port
        self.username = username
        self.password = password
    }

    public var isValid: Bool { enabled && !host.isEmpty && port > 0 && port <= 65535 }
}


// MARK: - 音频可视化（播放器/桌面歌词，实验性）

public struct AudioSpectrum: Sendable, Equatable {
    /// 各频段幅度（0...1，按低频→高频排列）
    public var bands: [Float]
    /// 采样时间戳（秒，便于 UI 判断是否过期）
    public var timestamp: TimeInterval

    public init(bands: [Float], timestamp: TimeInterval = Date().timeIntervalSince1970) {
        self.bands = bands
        self.timestamp = timestamp
    }
}

@MainActor
public protocol AudioVisualizationRouting: AnyObject {
    /// 可视化开关变化后重新决定播放引擎（播放中会保留位置切换）
    func applyVisualizationSetting()
}

@MainActor
public protocol AudioVisualizerProviding: AnyObject {
    /// 当前频谱（无数据时 nil）
    var currentSpectrum: AudioSpectrum? { get }
    /// 是否具备可视化能力（音效引擎播放时才有）
    var isVisualizerAvailable: Bool { get }
}
