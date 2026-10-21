import AVFoundation
import CryptoKit
import Foundation
import MeloCore

// MARK: - 本地音乐扫描

/// 扫描本地音频文件/文件夹，生成可直接加入列表并播放的 `MusicInfo`（`source = "local"`）。
///
/// 行为约定：
/// - 支持扩展名：mp3 / flac / m4a / aac / wav / aiff / aif / ogg / opus（大小写不敏感）；
/// - 输入可混合文件与目录，目录递归；跳过隐藏文件/目录、`node_modules` 等无意义目录与 package（.app 等）；
/// - 同一路径去重，结果按绝对路径排序（稳定）；
/// - 不存在的路径直接跳过，不抛错（空输入返回空数组）；
/// - 元数据：mp3/flac 走 `MediaTagWriter` 标签；m4a/aac/wav/aiff 走 AVFoundation 元数据；
///   缺失时 title 回退文件名、artist/album 回退空串；
/// - 时长：优先标签（MP3 TLEN / FLAC STREAMINFO）或 AVFoundation 元数据时长，其次 AVAudioFile，读不到则 nil；
/// - 封面：mp3/flac 的内嵌图片与 AVFoundation 元数据图片统一写到
///   `<coversDirectory>/<sha256(文件路径)>.<jpg|png|gif|webp>`（按 magic bytes 判扩展名），
///   并把 `meta.picUrl` 设为该文件的绝对路径；无封面或未注入 coversDirectory 时为 ""；
/// - 只生成模型，不写数据库、不移动/修改音频文件本身。
public enum LocalMusicScanner {
    /// 支持的音频扩展名（小写）
    public static let supportedExtensions: Set<String> = [
        "mp3", "flac", "m4a", "aac", "wav", "aiff", "aif", "ogg", "opus",
    ]

    /// 使用 AVFoundation 读取元数据/时长的扩展名（其余格式走标签或文件名回退）
    private static let avFoundationMetadataExtensions: Set<String> = ["m4a", "aac", "wav", "aiff", "aif"]

    /// 递归时跳过的无意义目录（小写比较）
    private static let ignoredDirectoryNames: Set<String> = [
        "node_modules", "__macosx", "library", "system", "caches", "logs", "trash",
    ]

    // MARK: - 对外入口

    /// 扫描给定 URL 数组（文件/目录混合）并返回排序去重后的本地音乐。
    /// - Parameter coversDirectory: 封面提取目录（通常为 `<LxDatas>/covers`）。
    ///   为 nil 时只解析内嵌封面标记、不落盘，`meta.picUrl` 保持空串。
    public static func scan(at urls: [URL], coversDirectory: URL? = nil) -> [MusicInfo] {
        guard !urls.isEmpty else { return [] }

        var collectedPaths = Set<String>()
        var files: [URL] = []
        for url in urls {
            for fileURL in audioFiles(in: url) {
                let path = fileURL.standardizedFileURL.path
                guard collectedPaths.insert(path).inserted else { continue }
                files.append(URL(fileURLWithPath: path, isDirectory: false))
            }
        }

        // 稳定排序：绝对路径字典序
        files.sort { $0.path < $1.path }
        return files.compactMap { makeMusicInfo(for: $0, coversDirectory: coversDirectory) }
    }

    // MARK: - 文件收集

    private static func audioFiles(in url: URL) -> [URL] {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return [] // 不存在的路径安全跳过
        }

        if isDirectory.boolValue {
            return audioFiles(inDirectory: url)
        }
        return isAudioFile(url) ? [url] : []
    }

    private static func audioFiles(inDirectory directory: URL) -> [URL] {
        let fileManager = FileManager.default
        let resourceKeys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey]
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { url, error in
                MeloLog.warn("本地音乐扫描：跳过无法读取的路径 \(url.path)：\(error.localizedDescription)")
                return true // 继续扫描其它路径
            }
        ) else {
            return []
        }

        var result: [URL] = []
        for case let item as URL in enumerator {
            let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if values?.isDirectory == true {
                let name = item.lastPathComponent.lowercased()
                if name.hasPrefix(".")
                    || ignoredDirectoryNames.contains(name)
                    || name.hasSuffix(".app")
                    || name.hasSuffix(".bundle")
                    || name.hasSuffix(".framework") {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard values?.isRegularFile == true, isAudioFile(item) else { continue }
            result.append(item)
        }
        return result
    }

    private static func isAudioFile(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        guard !name.isEmpty, !name.hasPrefix("."), !name.hasPrefix("._") else { return false }
        return supportedExtensions.contains(url.pathExtension.lowercased())
    }

    // MARK: - 元数据 → MusicInfo

    private static func makeMusicInfo(for url: URL, coversDirectory: URL?) -> MusicInfo? {
        let path = url.standardizedFileURL.path
        guard FileManager.default.isReadableFile(atPath: path) else {
            MeloLog.warn("本地音乐扫描：文件不可读，已跳过 \(path)")
            return nil
        }

        let fileExtension = url.pathExtension.lowercased()
        let fileBaseName = url.deletingPathExtension().lastPathComponent

        var taggedTitle: String?
        var taggedArtist: String?
        var taggedAlbum: String?
        var artwork: Data?
        var duration: TimeInterval?

        switch fileExtension {
        case "mp3", "flac":
            do {
                let metadata = try MediaTagWriter.readMetadata(path: path)
                taggedTitle = metadata.title
                taggedArtist = metadata.artist
                taggedAlbum = metadata.album
                artwork = metadata.artwork
            } catch {
                // 标签解析失败（例如损坏文件）不中断整批：回退文件名
                MeloLog.warn("本地音乐扫描：读取标签失败，回退文件名 \(path)：\(error.localizedDescription)")
            }
            duration = MediaTagWriter.readDuration(path: path)
        case _ where avFoundationMetadataExtensions.contains(fileExtension):
            if let metadata = AVAssetMetadataLoader.load(url: url) {
                taggedTitle = metadata.title
                taggedArtist = metadata.artist
                taggedAlbum = metadata.album
                artwork = metadata.artwork
                duration = metadata.duration
            }
        default:
            break
        }

        if duration == nil {
            duration = avFoundationDuration(for: url)
        }

        let title = firstNonEmpty(taggedTitle, fileBaseName) ?? fileBaseName
        let artist = normalizeArtist(taggedArtist)
        let album = taggedAlbum?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let interval = duration.flatMap { value -> String? in
            guard value.isFinite, value > 0 else { return nil }
            return MeloUtils.formatTime(value)
        }

        // 封面：统一落到 covers 目录（sha256(路径) 命名），失败忽略但不影响元数据。
        let artworkData = (artwork?.isEmpty == false) ? artwork : nil
        var picturePath = ""
        if let artworkData, let coversDirectory {
            if let coverURL = writeCoverIfNeeded(artworkData, sourcePath: path, coversDirectory: coversDirectory) {
                picturePath = coverURL.path
            }
        }

        let meta: JSONValue = .object([
            "albumName": .string(album),
            "filePath": .string(path),
            "songId": .string(path),
            "picUrl": .string(picturePath),
            "ext": .string(fileExtension),
            "hasEmbeddedPic": .bool(artworkData != nil),
        ])

        return MusicInfo(
            id: path,
            name: title,
            singer: artist,
            source: "local",
            interval: interval,
            meta: meta
        )
    }

    private static func firstNonEmpty(_ candidates: String?...) -> String? {
        for candidate in candidates {
            if let candidate {
                let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    /// 多歌手统一用 `、` 连接：标签里常见 `;` / `；` 分隔，转成 `、` 并去重空项。
    private static func normalizeArtist(_ artist: String?) -> String {
        guard let artist else { return "" }
        let parts = artist
            .split(whereSeparator: { $0 == ";" || $0 == "；" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return "" }
        return parts.joined(separator: "、")
    }

    /// AVAudioFile 时长（AVFoundation 不支持的 ogg/opus 会返回 nil）。
    private static func avFoundationDuration(for url: URL) -> TimeInterval? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let sampleRate = file.fileFormat.sampleRate
        let frames = file.length
        guard sampleRate > 0, frames > 0 else { return nil }
        return Double(frames) / sampleRate
    }

    // MARK: - 封面提取

    private static func writeCoverIfNeeded(_ artwork: Data, sourcePath: String, coversDirectory: URL) -> URL? {
        do {
            try FileManager.default.createDirectory(at: coversDirectory, withIntermediateDirectories: true)
            let fileName = sha256Hex(sourcePath) + "." + imageFileExtension(for: artwork)
            let coverURL = coversDirectory.appendingPathComponent(fileName, isDirectory: false)
            if !FileManager.default.fileExists(atPath: coverURL.path) {
                try artwork.write(to: coverURL, options: .atomic)
            }
            return coverURL
        } catch {
            MeloLog.warn("本地音乐扫描：写入封面失败（已忽略）\(sourcePath)：\(error.localizedDescription)")
            return nil
        }
    }

    private static func sha256Hex(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// 按图片 magic bytes 判断扩展名（未知格式回退 jpg，UI 按内容解码）。
    private static func imageFileExtension(for data: Data) -> String {
        let magic = [UInt8](data.prefix(12))
        if magic.count >= 3, magic[0] == 0xFF, magic[1] == 0xD8, magic[2] == 0xFF { return "jpg" }
        if magic.count >= 8, magic[0] == 0x89, magic[1] == 0x50, magic[2] == 0x4E, magic[3] == 0x47 { return "png" }
        if magic.count >= 4, magic[0] == 0x47, magic[1] == 0x49, magic[2] == 0x46, magic[3] == 0x38 { return "gif" }
        if magic.count >= 12,
           magic[8] == 0x57, magic[9] == 0x45, magic[10] == 0x42, magic[11] == 0x50 { return "webp" }
        return "jpg"
    }
}

// MARK: - AVFoundation 元数据（同步桥接）

/// 用 AVFoundation 读取 m4a/aac/wav/aiff 的 title/artist/album/artwork/duration。
///
/// 同步桥接说明：扫描 API 是同步的（`DataService.scanLocalMusic`），而 `AVAsset.load(...)` 是 async。
/// 这里在 **detached 后台任务** 中执行异步加载，调用线程用信号量等待——等待期间不会有任何
/// MainActor 依赖回调，因此不会出现「主线程等待主线程」的死锁；并设置 10s 超时兜底。
private enum AVAssetMetadataLoader {
    struct Metadata: Sendable {
        var title: String?
        var artist: String?
        var album: String?
        var artwork: Data?
        var duration: TimeInterval?
    }

    private final class ResultBox: @unchecked Sendable {
        var metadata: Metadata?
    }

    static func load(url: URL) -> Metadata? {
        let box = ResultBox()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached(priority: .utility) {
            box.metadata = await loadAsync(url: url)
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + 10) == .success else {
            MeloLog.warn("本地音乐扫描：AVFoundation 读取元数据超时 \(url.path)")
            return nil
        }
        return box.metadata
    }

    private static func loadAsync(url: URL) async -> Metadata? {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])
        var metadata = Metadata()
        var loadedAnything = false

        if let duration = try? await asset.load(.duration) {
            let seconds = CMTimeGetSeconds(duration)
            if seconds.isFinite, seconds > 0 {
                metadata.duration = seconds
                loadedAnything = true
            }
        }

        if let items = try? await asset.load(.commonMetadata) {
            for item in items {
                if isArtworkItem(item) {
                    if let artwork = await artworkData(from: item), !artwork.isEmpty {
                        metadata.artwork = artwork
                        loadedAnything = true
                    }
                    continue
                }
                guard let role = textRole(for: item) else { continue }
                guard let value = try? await item.load(.stringValue) else { continue }
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                switch role {
                case .title: metadata.title = trimmed
                case .artist: metadata.artist = trimmed
                case .album: metadata.album = trimmed
                }
                loadedAnything = true
            }
        }

        return loadedAnything ? metadata : nil
    }

    private enum TextRole {
        case title
        case artist
        case album
    }

    private static func textRole(for item: AVMetadataItem) -> TextRole? {
        if item.commonKey == .commonKeyTitle { return .title }
        if item.commonKey == .commonKeyArtist { return .artist }
        if item.commonKey == .commonKeyAlbumName { return .album }

        // 非标准/其它容器（如 WAV INFO、部分 m4a）回退到 key/identifier 字符串匹配
        let key = (item.key as? String)?.lowercased() ?? ""
        switch key {
        case "title", "©nam", "inam": return .title
        case "artist", "©art", "iart", "author": return .artist
        case "album", "©alb", "ialb": return .album
        default: break
        }
        let identifier = item.identifier?.rawValue.lowercased() ?? ""
        if identifier.contains("title") { return .title }
        if identifier.contains("artist") { return .artist }
        if identifier.contains("album") { return .album }
        return nil
    }

    private static func isArtworkItem(_ item: AVMetadataItem) -> Bool {
        if item.commonKey == .commonKeyArtwork { return true }
        if item.identifier == .commonIdentifierArtwork { return true }
        if let key = (item.key as? String)?.lowercased() {
            if key == "covr" || key == "artwork" || key == "apic" { return true }
        }
        return false
    }

    private static func artworkData(from item: AVMetadataItem) async -> Data? {
        if let data = try? await item.load(.dataValue), !data.isEmpty {
            return data
        }
        if let value = try? await item.load(.value) {
            if let data = value as? Data { return data }
            if let dictionary = value as? [String: Any] {
                if let data = dictionary["data"] as? Data { return data }
            }
        }
        return nil
    }
}
