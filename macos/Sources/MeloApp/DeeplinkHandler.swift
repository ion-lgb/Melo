import Foundation
import AppKit
import MeloCore

/// 兼容原版 `lxmusic://` Scheme URL 的解析与执行。
///
/// 支持（对齐 FAQ 文档 + 原版 useDeeplink）：
/// - `lxmusic://music/search/{source}/{keywords}` 或 `?data=<URL 编码 JSON>`
/// - `lxmusic://music/play?data=<JSON>`（歌曲信息）
/// - `lxmusic://songlist/open?data={source,id|url}`
/// - `lxmusic://songlist/play?data={source,id|url,index}`
/// - `lxmusic://player/{play,pause,skipNext,skipPrev,togglePlay,collect,uncollect}`
enum DeeplinkHandler {
    enum Action {
        case search(keyword: String, source: String?)
        case play(MusicInfo)
        case player(String)
        case songListOpen(id: String, source: String)
        case songListPlay(id: String, source: String, index: Int)
    }

    static let sources = ["kw", "kg", "tx", "wy", "mg"]
    static let qualityTypes = ["128k", "320k", "flac", "flac24bit", "wav", "192k"]

    @MainActor
    static func handle(url: URL, app: AppModel) async {
        do {
            guard let action = try parse(url) else { return }
            await perform(action, app: app)
        } catch {
            MeloLog.warn("Scheme URL 处理失败：\(error.localizedDescription)")
            app.showToast("Scheme URL 处理失败：\(error.localizedDescription)")
        }
        AppWindows.showMain()
    }

    @MainActor
    private static func perform(_ action: Action, app: AppModel) async {
        switch action {
        case .search(let keyword, let source):
            app.route = .search
            var targetSource = "all"
            if let source, sources.contains(source) { targetSource = source }
            app.searchSource = targetSource
            await app.performSearch(keyword, source: targetSource)
        case .play(let music):
            app.play(music, queue: [music])
            app.route = .myList(listId: ListIDs.temp)
        case .player(let name):
            switch name {
            case "play": if !app.isPlaying { app.togglePlayPause() }
            case "pause": if app.isPlaying { app.togglePlayPause() }
            case "togglePlay": app.togglePlayPause()
            case "skipNext": app.next()
            case "skipPrev": app.previous()
            case "collect":
                if let music = app.currentMusic, !app.isFavorite(music) { app.toggleFavorite(music) }
            case "uncollect":
                if let music = app.currentMusic, app.isFavorite(music) { app.toggleFavorite(music) }
            default:
                app.showToast("暂不支持的 player 动作：\(name)")
            }
        case .songListOpen(let id, let source):
            await app.showSongListDetail(id: id, source: source)
        case .songListPlay(let id, let source, let index):
            await app.showSongListDetail(id: id, source: source)
            if let detail = app.songListDetail, !detail.page.list.isEmpty {
                let target = min(max(index, 0), detail.page.list.count - 1)
                app.playList(detail.page.list, startAt: target)
            }
        }
    }

    static func parse(_ url: URL) throws -> Action? {
        guard url.scheme?.lowercased() == "lxmusic" else { return nil }
        // URLComponents 能正确处理 percent 编码；路径中的中文/keywords 会被解码
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        // lxmusic://music/search/xxx 里 music 是 URL host，rest 在 path 中；原版直接对整串 split，
        // 这里把 host 也还原成第一段，保持同样的分段语义。
        var parts: [String] = []
        if let host = url.host, !host.isEmpty {
            parts.append(host.removingPercentEncoding ?? host)
        }
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        parts.append(contentsOf: path.split(separator: "/").map { String($0).removingPercentEncoding ?? String($0) })
        guard parts.count >= 2 else { throw DeeplinkError.invalid("路径不完整") }
        let type = parts.removeFirst().lowercased()
        let action = parts.removeFirst().lowercased()

        var params: [String: String] = [:]
        var data: [String: JSONValue]?
        for item in components?.queryItems ?? [] {
            if item.name == "data", let value = item.value,
               let decoded = value.removingPercentEncoding,
               let json = JSONValue(jsonString: decoded)?.objectValue {
                data = json
            } else if let value = item.value {
                params[item.name] = value
            }
        }

        switch (type, action) {
        case ("music", "search"):
            var keyword: String?
            var source: String?
            if let data {
                keyword = data["keywords"]?.stringValue
                source = data["source"]?.stringValue
            } else if parts.count >= 2 {
                source = parts[0]
                keyword = parts[1]
            } else if parts.count == 1 {
                keyword = parts[0]
            }
            guard let keyword, !keyword.isEmpty else { throw DeeplinkError.invalid("缺少搜索关键词") }
            if let source, !sources.contains(source) { throw DeeplinkError.invalid("不支持的源：\(source)") }
            return .search(keyword: String(keyword.prefix(128)), source: source)

        case ("music", "play"):
            guard let data else { throw DeeplinkError.invalid("music/play 需要 data 参数") }
            return .play(try makeMusicInfo(from: data))

        case ("player", _):
            return .player(action)

        case ("songlist", "open"), ("songlist", "play"):
            var source: String?
            var id: String?
            if let data {
                source = data["source"]?.stringValue
                id = data["id"]?.stringValue
                if id == nil, let rawURL = data["url"]?.stringValue, !rawURL.isEmpty, let source {
                    id = resolveSongListID(from: rawURL, source: source)
                }
            } else if parts.count >= 2 {
                source = parts[0]
                id = resolveSongListID(from: parts[1], source: parts[0]) ?? parts[1]
            } else if parts.count == 1 {
                id = parts[0]
            }
            guard let source, sources.contains(source) else { throw DeeplinkError.invalid("songlist 缺少合法 source") }
            guard let id, !id.isEmpty else { throw DeeplinkError.invalid("songlist 缺少 id") }
            if action == "open" {
                return .songListOpen(id: id, source: source)
            }
            var index = 0
            if let dataIndex = data?["index"]?.intValue {
                index = dataIndex
            } else if parts.count >= 3 {
                index = Int(parts[2]) ?? 0
            }
            return .songListPlay(id: id, source: source, index: max(0, index))

        default:
            throw DeeplinkError.invalid("不支持的 Scheme URL：lxmusic://\(type)/\(action)")
        }
    }

    /// 从各平台歌单分享链接里提取歌单 id（原版直接把 url 当作 id 传给源，很多源并不支持；
    /// 这里对常见分享链接做 id 归一化，失败再抛错）。
    static func resolveSongListID(from rawURL: String, source: String) -> String? {
        let url = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if url.isEmpty { return nil }
        if url.allSatisfy({ $0.isNumber }) { return url }
        switch source {
        case "kw":
            // https://www.kuwo.cn/playlist_detail/123456789
            if let range = url.range(of: #"playlist_detail/(\d+)"#, options: .regularExpression) {
                return String(url[range]).split(separator: "/").last.map { String($0) }
            }
        case "kg":
            // https://www.kugou.com/yy/special/single/123456.html 或 /mixsong/...
            if let range = url.range(of: #"(?:single|special|mixsong|album)/(\d+)"#, options: .regularExpression) {
                return String(url[range]).split(separator: "/").last.map { String($0) }
            }
            if let range = url.range(of: #"id=(\d+)"#, options: .regularExpression) {
                return String(url[range]).split(separator: "=").last.map { String($0) }
            }
        case "tx":
            // https://y.qq.com/n/ryqq/playlist/123456789
            if let range = url.range(of: #"playlist/(\d+)"#, options: .regularExpression) {
                return String(url[range]).split(separator: "/").last.map { String($0) }
            }
        case "wy":
            // https://music.163.com/#/playlist?id=123456789 或 /playlist/123456789
            if let range = url.range(of: #"id=(\d+)"#, options: .regularExpression) {
                return String(url[range]).split(separator: "=").last.map { String($0) }
            }
            if let range = url.range(of: #"playlist/(\d+)"#, options: .regularExpression) {
                return String(url[range]).split(separator: "/").last.map { String($0) }
            }
        case "mg":
            // https://music.migu.cn/v3/music/playlist/123456789
            if let range = url.range(of: #"playlist/(\d+)"#, options: .regularExpression) {
                return String(url[range]).split(separator: "/").last.map { String($0) }
            }
        default:
            break
        }
        // 兜底：任意 URL 里最长的数字串当 id（部分分享链接风格不一）
        let digits = url.split(whereSeparator: { !$0.isNumber }).filter { $0.count >= 5 }
        return digits.max(by: { $0.count < $1.count }).map { String($0) }
    }

    /// 按原版 toNewMusicInfo 的规则把 Scheme URL 的歌曲信息转成 MusicInfo。
    static func makeMusicInfo(from data: [String: JSONValue]) throws -> MusicInfo {
        guard let source = data["source"]?.stringValue, sources.contains(source) else {
            throw DeeplinkError.invalid("歌曲 source 缺失或不合法")
        }
        guard let name = data["name"]?.stringValue, !name.isEmpty else {
            throw DeeplinkError.invalid("歌曲 name 缺失")
        }
        guard let singer = data["singer"]?.stringValue else {
            throw DeeplinkError.invalid("歌曲 singer 缺失")
        }
        let songmid = data["songmid"]?.stringValue
            ?? data["songId"]?.stringValue
            ?? data["copyrightId"]?.stringValue
        guard let songmid, !songmid.isEmpty else {
            throw DeeplinkError.invalid("歌曲 songmid/songId/copyrightId 缺失")
        }

        var meta: [String: JSONValue] = [
            "songId": .string(songmid),
            "albumName": data["albumName"] ?? .null,
            "picUrl": data["img"] ?? .null,
        ]

        // 音质数组：原样写入 meta.qualitys（保留 kg 的 hash 等字段，供自定义源使用）
        var qualities: [JSONValue] = []
        var qualityMap: [String: JSONValue] = [:]
        if let types = data["types"]?.arrayValue {
            for item in types {
                guard let type = item["type"]?.stringValue, qualityTypes.contains(type) else { continue }
                if source == "kg", item["hash"]?.stringValue == nil { continue }
                var obj: [String: JSONValue] = ["type": .string(type), "size": item["size"] ?? .null]
                if let hash = item["hash"]?.stringValue { obj["hash"] = .string(hash) }
                qualities.append(.object(obj))
                qualityMap[type] = .object(["size": item["size"] ?? .null])
            }
        }
        meta["qualitys"] = .array(qualities)
        meta["_qualitys"] = .object(qualityMap)
        if let albumId = data["albumId"] { meta["albumId"] = albumId }

        switch source {
        case "kg":
            guard let hash = data["hash"]?.stringValue, !hash.isEmpty else {
                throw DeeplinkError.invalid("kg 歌曲缺少 hash")
            }
            meta["hash"] = .string(hash)
            if let albumAudioId = data["albumAudioId"] { meta["albumAudioId"] = albumAudioId }
        case "tx":
            meta["strMediaMid"] = data["strMediaMid"] ?? .null
            meta["albumMid"] = data["albumMid"] ?? .null
            if let songId = data["songId"] { meta["id"] = songId }
        case "mg":
            meta["copyrightId"] = .string(songmid)
            if let lrcUrl = data["lrcUrl"] { meta["lrcUrl"] = lrcUrl }
            if let mrcUrl = data["mrcUrl"] { meta["mrcUrl"] = mrcUrl }
            if let trcUrl = data["trcUrl"] { meta["trcUrl"] = trcUrl }
        case "bd":
            if let strMediaMid = data["strMediaMid"] { meta["strMediaMid"] = strMediaMid }
        default:
            break
        }

        let id: String
        if source == "kg", let hash = meta["hash"]?.stringValue {
            id = "\(songmid)_\(hash)"
        } else {
            id = "\(source)_\(songmid)"
        }

        return MusicInfo(
            id: id,
            name: String(name.prefix(200)),
            singer: String(singer.prefix(200)),
            source: source,
            interval: data["interval"]?.stringValue,
            meta: .object(meta)
        )
    }
}

enum DeeplinkError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        }
    }
}

/// 主窗口显示/激活辅助
enum AppWindows {
    @MainActor
    static func showMain() {
        NSApp.activate(ignoringOtherApps: true)
        if let main = NSApp.windows.first(where: { $0.title == "Melo" && $0.canBecomeMain }) {
            main.makeKeyAndOrderFront(nil)
        }
    }

    @MainActor
    static func isDesktopLyricVisible() -> Bool {
        NSApp.windows.contains { $0.title == "桌面歌词" && $0.isVisible }
    }
}
