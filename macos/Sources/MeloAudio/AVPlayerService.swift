import Foundation
import AVFoundation
import MeloCore

/// 基于 AVPlayer 的播放服务（Phase 0 直放；EQ / 音效 / 变调留到 Phase 2）。
///
/// 实现 `PlayerService` 协议：
/// - 远程 URL（http/https，可带自定义 UA 头）与本地文件（file://）统一走 AVPlayer；
/// - 事件通过 `eventHandler(PlayerEvent)` 在主线程回推：`.status` / `.progress` / `.ended` / `.error`；
/// - 进度以 0.25s 周期回调（`.progress(current:duration:)`），供播放条 / 歌词时间轴消费；
/// - 系统集成：MPNowPlayingInfoCenter（标题/歌手/专辑/封面/时长/进度/速率/播放状态）
///   + MPRemoteCommandCenter（play/pause/togglePlayPause/next/previous/skipForward/skipBackward/changePlaybackPosition）；
/// - 播放期间用 `ProcessInfo.beginActivity` 阻止系统休眠，暂停 / 停止 / 出错 / 播完时结束。
///
/// 线程约定：所有 API 与事件都在主线程（MainActor）上；AVFoundation 的 KVO / 通知
/// 会切回主线程再处理。
@MainActor
public final class AVPlayerService: NSObject, PlayerService {

    // MARK: - PlayerService

    public var eventHandler: ((PlayerEvent) -> Void)?
    public private(set) var status: PlayerStatus = .stopped
    public private(set) var currentMusic: MusicInfo?
    public var onNextRequested: (() -> Void)?
    public var onPreviousRequested: (() -> Void)?

    public var volume: Double {
        get { volumeValue }
        set {
            volumeValue = Self.clampVolume(newValue)
            player.volume = Float(volumeValue)
        }
    }

    public var isMuted: Bool {
        get { mutedValue }
        set {
            mutedValue = newValue
            player.isMuted = newValue
        }
    }

    public var playbackRate: Double {
        get { rateValue }
        set {
            rateValue = Self.clampRate(newValue)
            applyPlaybackRate()
            updateNowPlaying(force: true)
        }
    }

    /// 当前播放时间（秒）。事件驱动的镜像值：每 0.25s 进度回调 / seek / 暂停 / 结束时更新。
    public var currentTime: TimeInterval { currentTimeValue }
    /// 当前曲目总时长（秒）。优先取 AVPlayerItem 的真实时长，取不到时回退到 `MusicInfo.interval`。
    public var duration: TimeInterval { durationValue }

    // MARK: - 额外公开能力（协议之外，供 UI / 测试 / 调试）

    /// 当前播放地址（stop 后为 nil）。
    public private(set) var currentURL: URL?
    /// 远程流请求使用的 User-Agent（自定义源返回的 URL 常需浏览器 UA）。
    public var httpUserAgent: String = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
    /// 系统 Now Playing / 媒体键集成开关。XCTest 进程默认关闭，应用内默认开启。
    public var systemIntegrationEnabled: Bool {
        didSet {
            guard systemIntegrationEnabled != oldValue else { return }
            applySystemIntegrationEnabled()
            updateNowPlaying(force: true)
        }
    }
    /// 最近一次投递给系统的 Now Playing 快照（集成关闭时也会维护，便于测试/调试）。
    public var nowPlayingSnapshot: NowPlayingSnapshot? { nowPlaying.snapshot }

    /// 是否把系统 Now Playing / 媒体键的管理权交给上层（RoutedPlayerService）。
    ///
    /// 路由器在初始化时置为 true：AVPlayerService 不再注册/注销媒体键、不再读写系统
    /// Now Playing（避免音效引擎播放时被本引擎的 `stop()` 清空），由 router 统一管理。
    var nowPlayingDelegatedToOwner: Bool = false {
        didSet {
            guard nowPlayingDelegatedToOwner != oldValue else { return }
            applySystemIntegrationEnabled()
        }
    }

    /// 实际是否启用系统集成：用户开关 && 未被上层接管。
    private var effectiveSystemIntegrationEnabled: Bool {
        systemIntegrationEnabled && !nowPlayingDelegatedToOwner
    }

    private func applySystemIntegrationEnabled() {
        nowPlaying.setEnabled(effectiveSystemIntegrationEnabled)
    }

    // MARK: - 内部状态

    private let player = AVPlayer()
    private let nowPlaying: NowPlayingController
    private var item: AVPlayerItem?
    private var itemStatusObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    private var notificationObservers: [NSObjectProtocol] = []
    private var timeObserverToken: Any?

    private var currentTimeValue: TimeInterval = 0
    private var durationValue: TimeInterval = 0
    private var volumeValue: Double = 1
    private var mutedValue: Bool = false
    private var rateValue: Double = 1

    /// 是否已收到本曲的播放结束通知（避免重复 `.ended`）
    private var isEnded = false
    /// 是否已上报本曲错误（避免 status KVO 与 failedToPlayToEnd 通知重复上报）
    private var hasReportedError = false
    /// 防休眠 activity token
    private var activityToken: NSObjectProtocol?
    private var lastNowPlayingRefresh = Date.distantPast

    private static let progressInterval = CMTime(seconds: 0.25, preferredTimescale: 600)
    private static let httpHeaderFieldsKey = "AVURLAssetHTTPHeaderFieldsKey"

    // MARK: - 初始化

    public override init() {
        let underTest = AudioEnvironment.isRunningUnderXCTest
        self.nowPlaying = NowPlayingController(enabled: !underTest)
        self.systemIntegrationEnabled = !underTest
        super.init()
        configure()
    }

    private func configure() {
        player.actionAtItemEnd = .pause
        player.volume = Float(volumeValue)
        player.isMuted = mutedValue
        player.defaultRate = Float(rateValue)

        nowPlaying.onPlay = { [weak self] in self?.resume() }
        nowPlaying.onPause = { [weak self] in self?.pause() }
        nowPlaying.onTogglePlayPause = { [weak self] in self?.togglePlayPauseFromSystem() }
        nowPlaying.onNext = { [weak self] in self?.onNextRequested?() }
        nowPlaying.onPrevious = { [weak self] in self?.onPreviousRequested?() }
        nowPlaying.onSeek = { [weak self] time in self?.seek(to: time) }
        nowPlaying.onSkipForward = { [weak self] interval in self?.seek(by: interval) }
        nowPlaying.onSkipBackward = { [weak self] interval in self?.seek(by: -interval) }

        timeObserverToken = player.addPeriodicTimeObserver(
            forInterval: Self.progressInterval,
            queue: .main
        ) { [weak self] time in
            onMainActor { [weak self] in self?.handleProgressTick(time) }
        }

        timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            let newStatus = player.timeControlStatus
            onMainActor { [weak self] in self?.handleTimeControlStatus(newStatus) }
        }
    }

    // MARK: - 播放控制

    /// 开始播放远程 / 本地 URL。
    ///
    /// - 同步校验失败（协议不支持 / 文件不存在）会直接 throw `PlayerError`；
    /// - 解码 / 网络等异步错误通过 `.status(.error)` + `.error(message)` 事件上报。
    public func play(url: URL, music: MusicInfo) throws {
        try validate(url)

        // 彻底切换 item：先摘掉旧 item 的所有观察，避免旧事件污染新曲目。
        player.pause()
        detachItemObservers()
        isEnded = false
        hasReportedError = false
        endPowerSaveActivity()

        currentMusic = music
        currentURL = url
        currentTimeValue = 0
        let intervalDuration = MeloUtils.parseInterval(music.interval)
        durationValue = intervalDuration > 0 ? intervalDuration : 0

        let newItem = makePlayerItem(for: url)
        installItemObservers(for: newItem)
        item = newItem

        setStatus(.loading)
        player.replaceCurrentItem(with: newItem)
        player.volume = Float(volumeValue)
        player.isMuted = mutedValue
        player.defaultRate = Float(rateValue)
        player.play()

        updateNowPlaying(force: true)
    }

    public func pause() {
        guard item != nil else { return }
        player.pause()
        if let time = playerTime() { currentTimeValue = time }
        endPowerSaveActivity()
        setStatus(.paused)
        eventHandler?(.progress(current: currentTimeValue, duration: durationValue))
        updateNowPlaying(force: true)
    }

    /// 恢复播放。无 item（从未播放 / 已 stop）时忽略。
    public func resume() {
        guard item != nil, !hasReportedError, status != .error else { return }

        // 播放结束后再按播放：从 0 重新开始（与原版「重新播放当前曲」的直觉一致）。
        if isEnded {
            isEnded = false
            currentTimeValue = 0
            player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        }

        player.defaultRate = Float(rateValue)
        player.play()
        beginPowerSaveActivity()
        setStatus(.playing)
        updateNowPlaying(force: true)
    }

    public func stop() {
        player.pause()
        detachItemObservers()
        player.replaceCurrentItem(with: nil)

        item = nil
        isEnded = false
        hasReportedError = false
        currentTimeValue = 0
        durationValue = 0
        currentURL = nil
        currentMusic = nil

        endPowerSaveActivity()
        setStatus(.stopped)
        eventHandler?(.progress(current: 0, duration: 0))
        updateNowPlaying(force: true)
    }

    public func seek(to time: TimeInterval) {
        guard item != nil else { return }

        let requested = time.isFinite ? time : 0
        var target = max(requested, 0)
        if durationValue > 0 { target = min(target, durationValue) }

        currentTimeValue = target
        isEnded = false
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                    toleranceBefore: .zero,
                    toleranceAfter: .zero) { [weak self] _ in
            onMainActor { [weak self] in self?.updateNowPlaying(force: true) }
        }
        eventHandler?(.progress(current: target, duration: durationValue))
        updateNowPlaying(force: true)
    }

    private func togglePlayPauseFromSystem() {
        if status == .playing || status == .loading {
            pause()
        } else {
            resume()
        }
    }

    /// 相对当前位置 seek（快进为正、快退为负），夹在 [0, duration]。
    private func seek(by interval: TimeInterval) {
        guard item != nil else { return }
        let delta = interval.isFinite ? interval : 0
        var target = currentTimeValue + delta
        target = max(target, 0)
        if durationValue > 0 { target = min(target, durationValue) }
        seek(to: target)
    }

    // MARK: - 状态事件

    private func setStatus(_ newStatus: PlayerStatus) {
        guard status != newStatus else { return }
        status = newStatus
        eventHandler?(.status(newStatus))
    }

    // MARK: - AVPlayer 回调

    private func handleItemStatusChange(_ changedItem: AVPlayerItem) {
        guard changedItem === item else { return }
        switch changedItem.status {
        case .readyToPlay:
            refreshDurationFromItem()
            eventHandler?(.progress(current: currentTimeValue, duration: durationValue))
            updateNowPlaying(force: true)
        case .failed:
            reportPlaybackError(changedItem.error)
        case .unknown:
            break
        @unknown default:
            break
        }
    }

    private func handleTimeControlStatus(_ newStatus: AVPlayer.TimeControlStatus) {
        guard item != nil else { return }
        switch newStatus {
        case .playing:
            guard status != .playing else { return }
            beginPowerSaveActivity()
            setStatus(.playing)
            updateNowPlaying(force: true)
        case .waitingToPlayAtSpecifiedRate:
            // 网络缓冲中：回到 loading（仅当之前在播放，避免覆盖 paused 状态）
            if status == .playing { setStatus(.loading) }
        case .paused:
            if status == .playing && !isEnded { setStatus(.paused) }
        @unknown default:
            break
        }
    }

    private func handleProgressTick(_ time: CMTime) {
        guard item != nil else { return }
        refreshDurationFromItem()

        guard time.isValid, time.isNumeric else { return }
        let seconds = time.seconds
        guard seconds.isFinite, seconds >= 0 else { return }

        currentTimeValue = seconds
        guard status == .playing || status == .paused else { return }

        eventHandler?(.progress(current: seconds, duration: durationValue))
        updateNowPlaying()
    }

    private func handleItemDidPlayToEnd(_ notification: Notification) {
        guard let endedItem = notification.object as? AVPlayerItem,
              endedItem === item,
              !isEnded else { return }

        isEnded = true
        refreshDurationFromItem()
        if let time = playerTime() { currentTimeValue = time }
        if durationValue <= 0 { durationValue = currentTimeValue }

        player.pause()
        endPowerSaveActivity()
        setStatus(.stopped)
        eventHandler?(.progress(current: currentTimeValue, duration: durationValue))
        eventHandler?(.ended)
        updateNowPlaying(force: true)
    }

    private func handleItemFailedToPlayToEnd(_ notification: Notification) {
        guard let failedItem = notification.object as? AVPlayerItem, failedItem === item else { return }
        let error = (notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)
            ?? failedItem.error
        reportPlaybackError(error)
    }

    private func reportPlaybackError(_ error: Error?) {
        guard !hasReportedError else { return }
        hasReportedError = true

        let message = PlayerError.describe(error)
        MeloLog.error("播放失败: \(message)")

        player.pause()
        endPowerSaveActivity()
        setStatus(.error)
        eventHandler?(.error(message))
        updateNowPlaying(force: true)
    }

    // MARK: - Item 生命周期

    private func validate(_ url: URL) throws {
        guard let scheme = url.scheme?.lowercased(), !scheme.isEmpty else {
            throw PlayerError.invalidURL(url.absoluteString)
        }
        switch scheme {
        case "file":
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                throw PlayerError.fileNotFound(url.path)
            }
            guard !isDirectory.boolValue else {
                throw PlayerError.playbackFailed("本地播放地址是一个目录，不是音频文件：\(url.path)")
            }
        case "http", "https":
            guard let host = url.host, !host.isEmpty else {
                throw PlayerError.invalidURL(url.absoluteString)
            }
        default:
            throw PlayerError.unsupportedScheme(scheme)
        }
    }

    private func makePlayerItem(for url: URL) -> AVPlayerItem {
        let asset: AVURLAsset
        if url.isFileURL {
            asset = AVURLAsset(url: url)
        } else {
            let headers: [String: String] = [
                "User-Agent": httpUserAgent,
                "Accept": "*/*",
            ]
            asset = AVURLAsset(url: url, options: [Self.httpHeaderFieldsKey: headers])
        }
        let newItem = AVPlayerItem(asset: asset)
        // 倍速播放保持音调（等价于原版 Web Audio 的默认行为）
        newItem.audioTimePitchAlgorithm = .spectral
        return newItem
    }

    private func installItemObservers(for newItem: AVPlayerItem) {
        itemStatusObservation = newItem.observe(\.status, options: [.new]) { [weak self] changedItem, _ in
            onMainActor { [weak self] in self?.handleItemStatusChange(changedItem) }
        }

        let center = NotificationCenter.default
        notificationObservers.append(center.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: newItem,
            queue: .main
        ) { [weak self] notification in
            onMainActor { [weak self] in self?.handleItemDidPlayToEnd(notification) }
        })
        notificationObservers.append(center.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification,
            object: newItem,
            queue: .main
        ) { [weak self] notification in
            onMainActor { [weak self] in self?.handleItemFailedToPlayToEnd(notification) }
        })
    }

    private func detachItemObservers() {
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        notificationObservers.removeAll()
    }

    // MARK: - 数值工具

    private func applyPlaybackRate() {
        player.defaultRate = Float(rateValue)
        if status == .playing || status == .loading {
            // 播放中即时生效（AVPlayer.rate 会触发 timeControlStatus 更新）
            player.rate = Float(rateValue)
        }
    }

    private func playerTime() -> TimeInterval? {
        let time = player.currentTime()
        guard time.isValid, time.isNumeric else { return nil }
        let seconds = time.seconds
        guard seconds.isFinite, seconds >= 0 else { return nil }
        return seconds
    }

    private func refreshDurationFromItem() {
        guard let item else { return }
        let time = item.duration
        guard time.isValid, time.isNumeric else { return }
        let seconds = time.seconds
        guard seconds.isFinite, seconds > 0, abs(seconds - durationValue) > 0.01 else { return }
        durationValue = seconds
    }

    private static func clampVolume(_ value: Double) -> Double {
        guard value.isFinite else { return 1 }
        return min(max(value, 0), 1)
    }

    private static func clampRate(_ value: Double) -> Double {
        guard value.isFinite else { return 1 }
        // AVPlayer 对音频的可用倍速范围有限，Phase 0 限制在 0.25x ~ 2.0x
        return min(max(value, 0.25), 2.0)
    }

    // MARK: - 防休眠

    private func beginPowerSaveActivity() {
        guard activityToken == nil else { return }
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Melo 正在播放音频"
        )
    }

    private func endPowerSaveActivity() {
        guard let token = activityToken else { return }
        ProcessInfo.processInfo.endActivity(token)
        activityToken = nil
    }

    // MARK: - Now Playing 同步

    private func updateNowPlaying(force: Bool = false) {
        // 被 RoutedPlayerService 接管时不再读写系统 Now Playing（由 router 统一管理）。
        guard !nowPlayingDelegatedToOwner else { return }
        guard currentMusic != nil else {
            nowPlaying.update(music: nil, duration: 0, elapsed: 0, isPlaying: false, playbackRate: rateValue)
            return
        }
        if !force {
            let now = Date()
            guard now.timeIntervalSince(lastNowPlayingRefresh) >= 0.9 else { return }
            lastNowPlayingRefresh = now
        } else {
            lastNowPlayingRefresh = Date()
        }
        nowPlaying.update(
            music: currentMusic,
            duration: durationValue,
            elapsed: currentTimeValue,
            isPlaying: status == .playing,
            playbackRate: rateValue
        )
    }
}
