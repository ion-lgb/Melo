import Foundation
import AppKit
import MediaPlayer
import MeloCore

/// 系统「正在播放」信息快照。
///
/// 与 `MPNowPlayingInfoCenter` 解耦、可独立断言（单元测试进程无法/不应抢占系统媒体键，
/// 但快照始终会被维护，便于测试与调试）。
public struct NowPlayingSnapshot: Equatable, Sendable {
    public var title: String
    public var artist: String
    public var album: String?
    public var duration: TimeInterval
    public var elapsed: TimeInterval
    public var playbackRate: Double
    public var isPlaying: Bool
    public var artworkURL: String?

    public init(title: String,
                artist: String,
                album: String? = nil,
                duration: TimeInterval = 0,
                elapsed: TimeInterval = 0,
                playbackRate: Double = 1,
                isPlaying: Bool = false,
                artworkURL: String? = nil) {
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.elapsed = elapsed
        self.playbackRate = playbackRate
        self.isPlaying = isPlaying
        self.artworkURL = artworkURL
    }
}

/// 系统媒体集成：Now Playing 信息 + 媒体键远程命令。
///
/// 只负责「把状态投递给系统」和「把系统按键转成闭包回调」，不持有播放器状态。
/// 在 XCTest 进程里默认禁用（避免测试进程注册全局媒体键），应用内默认启用。
@MainActor
final class NowPlayingController {
    private(set) var snapshot: NowPlayingSnapshot?
    private(set) var isEnabled: Bool

    /// 媒体键 / 控制中心回调（由 AVPlayerService 注入，均在主线程调用）。
    var onPlay: (() -> Void)?
    var onPause: (() -> Void)?
    var onTogglePlayPause: (() -> Void)?
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onSeek: ((TimeInterval) -> Void)?
    /// 快进/快退（秒，恒为正数；由系统 `skipForwardCommand`/`skipBackwardCommand` 触发）。
    var onSkipForward: ((TimeInterval) -> Void)?
    var onSkipBackward: ((TimeInterval) -> Void)?

    private var commandTargets: [(command: MPRemoteCommand, token: Any)] = []
    private var artworkCache: [String: MPMediaItemArtwork] = [:]
    private var pendingArtworkURL: String?

    /// 是否已注册系统媒体键（供路由器/测试判断）。
    var hasRegisteredCommands: Bool { !commandTargets.isEmpty }

    init(enabled: Bool) {
        self.isEnabled = enabled
        if enabled { registerCommands() }
    }

    // MARK: - 开关

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        if enabled {
            registerCommands()
            if let snapshot { apply(snapshot) }
        } else {
            unregisterCommands()
            clearSystemInfo()
        }
    }

    // MARK: - 状态更新

    /// 更新当前曲目信息与播放进度（即使系统集成被禁用也会维护 `snapshot`）。
    func update(music: MusicInfo?,
                duration: TimeInterval,
                elapsed: TimeInterval,
                isPlaying: Bool,
                playbackRate: Double) {
        guard let music else {
            snapshot = nil
            if isEnabled { clearSystemInfo() }
            return
        }

        let newSnapshot = NowPlayingSnapshot(
            title: music.name,
            artist: music.singer,
            album: music.albumName.isEmpty ? nil : music.albumName,
            duration: max(duration, 0),
            elapsed: max(elapsed, 0),
            playbackRate: max(playbackRate, 0),
            isPlaying: isPlaying,
            artworkURL: music.picUrl
        )
        snapshot = newSnapshot
        guard isEnabled else { return }
        apply(newSnapshot)
    }

    // MARK: - Now Playing 信息中心

    private func clearSystemInfo() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
        pendingArtworkURL = nil
    }

    private func apply(_ snapshot: NowPlayingSnapshot) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: snapshot.title,
            MPMediaItemPropertyArtist: snapshot.artist,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: snapshot.elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: snapshot.isPlaying ? snapshot.playbackRate : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: snapshot.playbackRate,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if let album = snapshot.album { info[MPMediaItemPropertyAlbumTitle] = album }
        if snapshot.duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = snapshot.duration }
        if let artworkURL = snapshot.artworkURL, let artwork = artwork(for: artworkURL) {
            info[MPMediaItemPropertyArtwork] = artwork
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = snapshot.isPlaying ? .playing : .paused
    }

    // MARK: - 封面（异步加载，失败静默忽略）

    private func artwork(for urlString: String) -> MPMediaItemArtwork? {
        guard !urlString.isEmpty else { return nil }
        if let cached = artworkCache[urlString] { return cached }
        guard pendingArtworkURL != urlString, let url = URL(string: urlString) else { return nil }

        if url.isFileURL {
            if let image = NSImage(contentsOf: url) {
                return storeArtwork(image, for: urlString)
            }
            return nil
        }

        guard url.scheme == "http" || url.scheme == "https" else { return nil }
        pendingArtworkURL = urlString
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let image = data.flatMap({ NSImage(data: $0) }) else {
                onMainActor { [weak self] in
                    guard let self, self.pendingArtworkURL == urlString else { return }
                    self.pendingArtworkURL = nil
                }
                return
            }
            onMainActor { [weak self] in
                guard let self else { return }
                _ = self.storeArtwork(image, for: urlString)
                self.pendingArtworkURL = nil
                if let snapshot = self.snapshot { self.apply(snapshot) }
            }
        }.resume()
        return nil
    }

    @discardableResult
    private func storeArtwork(_ image: NSImage, for urlString: String) -> MPMediaItemArtwork {
        let size = image.size
        let bounds = CGSize(width: max(size.width, 1), height: max(size.height, 1))
        let artwork = MPMediaItemArtwork(boundsSize: bounds) { _ in image }
        if artworkCache.count >= 8 { artworkCache.removeAll() }
        artworkCache[urlString] = artwork
        return artwork
    }

    // MARK: - 媒体键 / 控制中心

    private func registerCommands() {
        guard commandTargets.isEmpty else { return }
        let center = MPRemoteCommandCenter.shared()

        func register(_ command: MPRemoteCommand,
                      handler: @escaping (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus) {
            let token = command.addTarget(handler: handler)
            commandTargets.append((command, token))
        }

        register(center.playCommand) { [weak self] _ in
            onMainActor { self?.onPlay?() }
            return .success
        }
        register(center.pauseCommand) { [weak self] _ in
            onMainActor { self?.onPause?() }
            return .success
        }
        register(center.togglePlayPauseCommand) { [weak self] _ in
            onMainActor { self?.onTogglePlayPause?() }
            return .success
        }
        register(center.nextTrackCommand) { [weak self] _ in
            onMainActor { self?.onNext?() }
            return .success
        }
        register(center.previousTrackCommand) { [weak self] _ in
            onMainActor { self?.onPrevious?() }
            return .success
        }
        register(center.changePlaybackPositionCommand) { [weak self] event in
            guard let positionEvent = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            let position = positionEvent.positionTime
            onMainActor { self?.onSeek?(position) }
            return .success
        }
        register(center.skipForwardCommand) { [weak self] event in
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? 15
            onMainActor { self?.onSkipForward?(interval) }
            return .success
        }
        register(center.skipBackwardCommand) { [weak self] event in
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? 15
            onMainActor { self?.onSkipBackward?(interval) }
            return .success
        }

        // 系统控制中心/媒体键展示的快进快退步长（原版热键默认 ±5s，系统常用 ±15s）
        center.skipForwardCommand.preferredIntervals = [15]
        center.skipBackwardCommand.preferredIntervals = [15]

        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.togglePlayPauseCommand.isEnabled = true
        center.nextTrackCommand.isEnabled = true
        center.previousTrackCommand.isEnabled = true
        center.changePlaybackPositionCommand.isEnabled = true
        center.skipForwardCommand.isEnabled = true
        center.skipBackwardCommand.isEnabled = true
    }

    /// 注销媒体键处理器（切换 Now Playing 管理者 / 关闭系统集成时调用）。
    private func unregisterCommands() {
        guard !commandTargets.isEmpty else { return }
        for entry in commandTargets {
            entry.command.removeTarget(entry.token)
        }
        commandTargets.removeAll()
    }
}
