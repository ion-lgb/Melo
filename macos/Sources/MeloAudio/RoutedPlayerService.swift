import Foundation
import MeloCore

/// Phase 2 播放器路由：根据当前音效设置，在两个播放引擎之间选择并转发 `PlayerService` 调用。
///
/// - **无音效**（10 段 EQ 全 0 且 pitchShifterRate == 1）→ `AVPlayerService`：
///   原生 AVPlayer 流式播放，支持远程 URL，省内存；
/// - **有音效**（任一段 EQ 非 0 / pitchShifterRate != 1 / 卷积混响 / 3D 环绕）→ `EffectsAudioEngine`：
///   AVAudioEngine + 10 段 EQ + 变速变调 + IR 卷积混响 + 3D 环绕；
/// - 注意 `playbackRate` 单独变化**不触发**音效引擎（AVPlayer 原生支持倍速）。
///
/// 路由会在播放中随 `applyAudioEffects` 实时切换：切引擎前记录当前 url/music/position，
/// 新引擎起播后 seek 回原位置，保持 UI 无感。
///
/// **Now Playing / 媒体键**：router 是唯一的系统媒体集成管理者。
/// 初始化时接管 `AVPlayerService` 的 Now Playing 管理权（引擎内部不再注册媒体键/清空信息），
/// 由 router 在播放/暂停/seek/换曲/切换引擎时统一更新 `MPNowPlayingInfoCenter` 与
/// `MPRemoteCommandCenter`，因此音效引擎播放时系统控制中心仍显示当前歌曲，媒体键作用于当前引擎。
@MainActor
public final class RoutedPlayerService: NSObject, PlayerService, AudioEffectApplying, AudioVisualizerProviding {

    /// 当前活动的播放引擎。
    enum ActiveEngineKind: String {
        case avPlayer
        case effects
    }

    // MARK: - PlayerService

    public var eventHandler: ((PlayerEvent) -> Void)?
    public private(set) var status: PlayerStatus = .stopped
    public private(set) var currentMusic: MusicInfo?
    public private(set) var currentTime: TimeInterval = 0
    public private(set) var duration: TimeInterval = 0

    public var volume: Double = 1 {
        didSet {
            avPlayer.volume = volume
            effectsPlayer.volume = volume
        }
    }

    public var isMuted: Bool = false {
        didSet {
            avPlayer.isMuted = isMuted
            effectsPlayer.isMuted = isMuted
        }
    }

    public var playbackRate: Double = 1 {
        didSet {
            avPlayer.playbackRate = playbackRate
            effectsPlayer.playbackRate = playbackRate
            updateNowPlaying(force: true)
        }
    }

    public var onNextRequested: (() -> Void)? {
        didSet { avPlayer.onNextRequested = onNextRequested }
    }

    public var onPreviousRequested: (() -> Void)? {
        didSet { avPlayer.onPreviousRequested = onPreviousRequested }
    }

    // MARK: - 系统集成（Now Playing / 媒体键）

    /// 系统 Now Playing / 媒体键集成开关。XCTest 进程默认关闭，应用内默认开启。
    public var systemIntegrationEnabled: Bool {
        didSet {
            guard systemIntegrationEnabled != oldValue else { return }
            nowPlaying.setEnabled(systemIntegrationEnabled)
            updateNowPlaying(force: true)
        }
    }

    /// 最近一次投递给系统的 Now Playing 快照（集成关闭时也会维护，便于测试/调试）。
    public var nowPlayingSnapshot: NowPlayingSnapshot? { nowPlaying.snapshot }

    // MARK: - 音频可视化（实验性；仅音效引擎提供频谱）

    /// 当前频谱（转发 effectsPlayer；AVPlayer 路径无频谱时为 nil）。
    public var currentSpectrum: AudioSpectrum? { effectsPlayer.currentSpectrum }
    /// 是否具备可视化能力（音效引擎已加载音频时才有）。
    public var isVisualizerAvailable: Bool { effectsPlayer.isVisualizerAvailable }

    // MARK: - 子引擎 / 状态

    /// AVPlayer 引擎（无音效 / 普通流播放）。其 Now Playing 管理权由 router 接管。
    public let avPlayer: AVPlayerService
    /// AVAudioEngine 音效引擎（EQ + 变速变调）。
    public let effectsPlayer: EffectsAudioEngine

    /// 当前活动引擎（测试可见；UI 一般不需要）。
    private(set) var activeEngineKind: ActiveEngineKind = .avPlayer
    /// 当前是否在音效引擎上播放。
    public var isUsingEffectsEngine: Bool { activeEngineKind == .effects }

    private let settings: SettingsStore
    private var effectSettings: AudioEffectSettings = .flat
    private let nowPlaying: NowPlayingController
    private var lastNowPlayingRefresh = Date.distantPast

    private var activePlayer: any PlayerService {
        activeEngineKind == .effects ? effectsPlayer : avPlayer
    }

    // MARK: - 初始化

    public init(settings: SettingsStore,
                avPlayer: AVPlayerService,
                effectsPlayer: EffectsAudioEngine) {
        self.settings = settings
        self.avPlayer = avPlayer
        self.effectsPlayer = effectsPlayer
        self.nowPlaying = NowPlayingController(enabled: false)
        self.systemIntegrationEnabled = false
        super.init()

        avPlayer.eventHandler = { [weak self] event in
            self?.handle(event, from: .avPlayer)
        }
        effectsPlayer.eventHandler = { [weak self] event in
            self?.handle(event, from: .effects)
        }

        // 接管系统 Now Playing / 媒体键：AVPlayerService 不再自己管理（避免它 stop 时清空信息）。
        avPlayer.nowPlayingDelegatedToOwner = true

        nowPlaying.onPlay = { [weak self] in self?.handlePlayCommand() }
        nowPlaying.onPause = { [weak self] in self?.handlePauseCommand() }
        nowPlaying.onTogglePlayPause = { [weak self] in self?.handleTogglePlayPauseCommand() }
        nowPlaying.onNext = { [weak self] in self?.handleNextCommand() }
        nowPlaying.onPrevious = { [weak self] in self?.handlePreviousCommand() }
        nowPlaying.onSeek = { [weak self] time in self?.handleSeekCommand(time) }
        nowPlaying.onSkipForward = { [weak self] interval in self?.handleSkipForwardCommand(interval) }
        nowPlaying.onSkipBackward = { [weak self] interval in self?.handleSkipBackwardCommand(interval) }

        // 初始状态同步到两个引擎，保证切换后音量/静音/倍速一致。
        avPlayer.volume = volume
        avPlayer.isMuted = isMuted
        avPlayer.playbackRate = playbackRate
        effectsPlayer.volume = volume
        effectsPlayer.isMuted = isMuted
        effectsPlayer.playbackRate = playbackRate

        // 应用内默认开启系统集成；XCTest 默认关闭（测试可显式开启）。
        systemIntegrationEnabled = !AudioEnvironment.isRunningUnderXCTest
    }

    // MARK: - 路由

    /// 是否应使用音效引擎：
    /// EQ 任一段非 0 / 变调 / 卷积混响 / 3D 环绕 / 指定了自定义输出设备。
    /// playbackRate 单独变化不触发（AVPlayer 原生支持倍速播放）。
    private func shouldUseEffectsEngine() -> Bool {
        if Self.requiresEffects(effectSettings) { return true }

        // AVPlayer 无法指定输出设备：设置了非默认设备时必须走音效引擎。
        if resolvedMediaDeviceUID() != nil { return true }

        // 音频可视化依赖 AVAudioEngine tap：任一可视化开关开启时必须走音效引擎。
        if isAudioVisualizationEnabled() { return true }

        let eqActive = SettingKeys.eqBandKeys.contains {
            abs(settings.double($0, default: 0)) > 0.01
        }
        if eqActive { return true }

        let shifterRate = settings.double(SettingKeys.pitchShifterRate, default: 1)
        if abs(shifterRate - 1) > 0.001 { return true }

        // 卷积混响 / 3D 环绕只在音效引擎（AVAudioEngine）中实现，同样需要路由过去。
        if settings.bool(SettingKeys.pannerEnable) { return true }
        let convolutionName = settings.string(SettingKeys.convolutionFileName)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let convolutionName, !convolutionName.isEmpty { return true }
        return false
    }

    /// 从 `AudioEffectSettings` 判断是否需要音效引擎
    /// （忽略 playbackRate / isPitchActive 的倍速部分；包含卷积混响与 3D 环绕）。
    static func requiresEffects(_ settings: AudioEffectSettings) -> Bool {
        let eqActive = settings.eqBands.contains { abs($0) > 0.01 }
        return eqActive
            || abs(settings.pitchSemitones) > 0.05
            || settings.isConvolutionActive
            || settings.pannerEnabled
    }

    /// 是否开启了音频可视化（播放器 / 桌面歌词任一开关）。
    private func isAudioVisualizationEnabled() -> Bool {
        settings.bool(SettingKeys.playerAudioVisualization)
            || settings.bool(SettingKeys.desktopLyricAudioVisualization)
    }

    /// 设置中的自定义输出设备 UID（nil = 跟随系统默认 / 未设置 / "default"）。
    private func resolvedMediaDeviceUID() -> String? {
        guard let raw = settings.string(SettingKeys.mediaDeviceId)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              raw.caseInsensitiveCompare("default") != .orderedSame else {
            return nil
        }
        return raw
    }

    /// 路由到音效引擎时把输出设备设置应用到引擎；失败回退系统默认设备并记录 warning。
    private func applyOutputDeviceSettingToEffectsPlayer() {
        let uid = resolvedMediaDeviceUID()
        do {
            try effectsPlayer.setOutputDevice(uid: uid)
        } catch {
            MeloLog.warn("切换输出设备失败（UID=\(uid ?? "default")）：\(error.localizedDescription)，已回退默认设备")
            try? effectsPlayer.setOutputDevice(uid: nil)
        }
    }

    // MARK: - 播放

    public func play(url: URL, music: MusicInfo) throws {
        let targetKind: ActiveEngineKind = shouldUseEffectsEngine() ? .effects : .avPlayer

        if targetKind != activeEngineKind {
            let previous = activeEngineKind
            activeEngineKind = targetKind
            stopEngine(previous)
        }
        // 防御：确保非目标引擎不会同时发声
        if targetKind == .effects {
            avPlayer.stop()
        } else {
            effectsPlayer.stop()
        }

        currentMusic = music
        currentTime = 0
        let interval = MeloUtils.parseInterval(music.interval)
        duration = interval > 0 ? interval : 0

        syncSettings(to: targetKind)
        if targetKind == .effects {
            effectsPlayer.applyAudioEffects(effectSettings)
            applyOutputDeviceSettingToEffectsPlayer()
        }

        try activePlayer.play(url: url, music: music)
        updateNowPlaying(force: true)
    }

    public func pause() {
        activePlayer.pause()
        updateNowPlaying(force: true)
    }

    public func resume() {
        activePlayer.resume()
        updateNowPlaying(force: true)
    }

    public func stop() {
        stopEngine(activeEngineKind)
        stopEngine(activeEngineKind == .avPlayer ? .effects : .avPlayer)

        if status != .stopped {
            status = .stopped
            eventHandler?(.status(.stopped))
        }
        currentMusic = nil
        currentTime = 0
        duration = 0
        updateNowPlaying(force: true)
    }

    public func seek(to time: TimeInterval) {
        activePlayer.seek(to: time)
        updateNowPlaying(force: true)
    }

    // MARK: - 音效

    /// 应用音效设置（AppModel 在设置变化时调用）。
    ///
    /// - 总是转发给 effectsPlayer（参数常驻，切换引擎后立即可闻）；
    /// - 若「有音效/无音效」状态发生变化且正在播放，实时切换引擎并 seek 回原位置；
    /// - 指定了自定义输出设备时同样必须使用音效引擎。
    public func applyAudioEffects(_ settings: AudioEffectSettings) {
        effectSettings = settings
        effectsPlayer.applyAudioEffects(settings)

        let wantsEffects = Self.requiresEffects(settings)
            || resolvedMediaDeviceUID() != nil
            || isAudioVisualizationEnabled()
        if wantsEffects != (activeEngineKind == .effects) {
            if wantsEffects {
                switchToEffects()
            } else {
                switchToAVPlayer()
            }
        }
        if activeEngineKind == .effects {
            applyOutputDeviceSettingToEffectsPlayer()
        }
        updateNowPlaying(force: true)
    }

    /// 音频可视化设置变化时调用（AppModel 写入 `player.audioVisualization` /
    /// `desktopLyric.audioVisualization` 后）：按新设置重新路由（播放中会切引擎并保留位置）。
    public func applyVisualizationSetting() {
        let wantsEffects = shouldUseEffectsEngine()
        if wantsEffects != (activeEngineKind == .effects) {
            if wantsEffects {
                switchToEffects()
            } else {
                switchToAVPlayer()
            }
        }
        updateNowPlaying(force: true)
    }

    /// 输出设备设置变化时调用（AppModel 写入 `player.mediaDeviceId` 后）：
    /// 按新设置重新路由（播放中会切引擎并保留位置），并应用输出设备。
    public func applyOutputDeviceSetting() {
        let wantsEffects = shouldUseEffectsEngine()
        if wantsEffects != (activeEngineKind == .effects) {
            if wantsEffects {
                switchToEffects()
            } else {
                switchToAVPlayer()
            }
        }
        if activeEngineKind == .effects {
            applyOutputDeviceSettingToEffectsPlayer()
        }
        updateNowPlaying(force: true)
    }

    private func switchToEffects() {
        guard activeEngineKind == .avPlayer else { return }

        // 没有正在播放的内容：只切路由，下次 play 直接走音效引擎
        guard let url = avPlayer.currentURL, let music = avPlayer.currentMusic else {
            activeEngineKind = .effects
            updateNowPlaying(force: true)
            return
        }

        let position = avPlayer.currentTime
        let wasPlaying = avPlayer.status == .playing || avPlayer.status == .loading
        let previousDuration = duration

        activeEngineKind = .effects
        avPlayer.stop()

        currentMusic = music
        currentTime = position
        if previousDuration > 0 { duration = previousDuration }
        syncSettings(to: .effects)
        effectsPlayer.applyAudioEffects(effectSettings)
        applyOutputDeviceSettingToEffectsPlayer()

        do {
            try effectsPlayer.play(url: url, music: music)
            if position > 0.15 {
                effectsPlayer.seek(to: position)
            }
            if !wasPlaying { effectsPlayer.pause() }
        } catch {
            // 切换失败：回退到 AVPlayer，并上报可读错误
            activeEngineKind = .avPlayer
            let message = Self.readableMessage(error)
            status = .error
            eventHandler?(.status(.error))
            eventHandler?(.error(message))
        }
        updateNowPlaying(force: true)
    }

    private func switchToAVPlayer() {
        guard activeEngineKind == .effects else { return }

        guard let url = effectsPlayer.currentURL, let music = effectsPlayer.currentMusic else {
            activeEngineKind = .avPlayer
            updateNowPlaying(force: true)
            return
        }

        let position = effectsPlayer.currentTime
        let wasPlaying = effectsPlayer.status == .playing || effectsPlayer.status == .loading
        let previousDuration = duration

        activeEngineKind = .avPlayer
        effectsPlayer.stop()

        currentMusic = music
        currentTime = position
        if previousDuration > 0 { duration = previousDuration }
        syncSettings(to: .avPlayer)

        do {
            try avPlayer.play(url: url, music: music)
            if position > 0.15 {
                avPlayer.seek(to: position)
            }
            if !wasPlaying { avPlayer.pause() }
        } catch {
            activeEngineKind = .effects
            let message = Self.readableMessage(error)
            status = .error
            eventHandler?(.status(.error))
            eventHandler?(.error(message))
        }
        updateNowPlaying(force: true)
    }

    // MARK: - 系统媒体键 / 控制中心（统一作用于当前活动引擎）

    /// 系统媒体键/控制中心命令（internal：NowPlayingController 回调与测试复用）。
    enum MediaCommand: Equatable {
        case play
        case pause
        case togglePlayPause
        case next
        case previous
        case changePlaybackPosition(TimeInterval)
        case skipForward(TimeInterval)
        case skipBackward(TimeInterval)
    }

    /// 默认快进/快退步长（与 `NowPlayingController` 的 preferredIntervals 保持一致）。
    nonisolated static let defaultSkipInterval: TimeInterval = 15

    /// 执行一条系统媒体键命令；全部作用于当前活动引擎（AVPlayer / 音效引擎）。
    func handleMediaCommand(_ command: MediaCommand) {
        switch command {
        case .play:
            resume()
        case .pause:
            pause()
        case .togglePlayPause:
            if status == .playing || status == .loading {
                pause()
            } else {
                resume()
            }
        case .next:
            onNextRequested?()
        case .previous:
            onPreviousRequested?()
        case .changePlaybackPosition(let position):
            seek(to: clampedPosition(position))
        case .skipForward(let interval):
            seek(to: clampedPosition(currentTime + normalizedSkipInterval(interval)))
        case .skipBackward(let interval):
            seek(to: clampedPosition(currentTime - normalizedSkipInterval(interval)))
        }
    }

    func handlePlayCommand() {
        handleMediaCommand(.play)
    }

    func handlePauseCommand() {
        handleMediaCommand(.pause)
    }

    func handleTogglePlayPauseCommand() {
        handleMediaCommand(.togglePlayPause)
    }

    func handleNextCommand() {
        handleMediaCommand(.next)
    }

    func handlePreviousCommand() {
        handleMediaCommand(.previous)
    }

    func handleSeekCommand(_ time: TimeInterval) {
        handleMediaCommand(.changePlaybackPosition(time))
    }

    /// 快进（默认 ±15s，不超出 duration）。
    func handleSkipForwardCommand(_ interval: TimeInterval = RoutedPlayerService.defaultSkipInterval) {
        handleMediaCommand(.skipForward(interval))
    }

    /// 快退（默认 ±15s，不低于 0）。
    func handleSkipBackwardCommand(_ interval: TimeInterval = RoutedPlayerService.defaultSkipInterval) {
        handleMediaCommand(.skipBackward(interval))
    }

    /// seek 目标位置：非有限值按 0，夹在 [0, duration]。
    private func clampedPosition(_ position: TimeInterval) -> TimeInterval {
        let finite = position.isFinite ? position : 0
        var target = max(finite, 0)
        if duration > 0 { target = min(target, duration) }
        return target
    }

    /// 系统传入的间隔（NaN/0/负数 → 默认 15s）。
    private func normalizedSkipInterval(_ interval: TimeInterval) -> TimeInterval {
        guard interval.isFinite, interval > 0 else { return Self.defaultSkipInterval }
        return interval
    }

    // MARK: - 事件转发 / 状态镜像

    private func handle(_ event: PlayerEvent, from kind: ActiveEngineKind) {
        // 只转发当前活动引擎的事件；切换瞬间旧引擎的 stop 事件直接丢弃。
        guard kind == activeEngineKind else { return }

        switch event {
        case .status(let newStatus):
            status = newStatus
            eventHandler?(event)
            updateNowPlaying(force: true)
        case .progress(let current, let total):
            currentTime = current
            if total > 0 { duration = total }
            eventHandler?(event)
            updateNowPlaying()
        case .ended:
            currentTime = duration
            status = .stopped
            eventHandler?(event)
            updateNowPlaying(force: true)
        case .error:
            status = .error
            eventHandler?(event)
            updateNowPlaying(force: true)
        }
    }

    // MARK: - Now Playing 同步

    private func updateNowPlaying(force: Bool = false) {
        guard currentMusic != nil else {
            nowPlaying.update(music: nil, duration: 0, elapsed: 0, isPlaying: false, playbackRate: playbackRate)
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
            duration: duration,
            elapsed: currentTime,
            isPlaying: status == .playing,
            playbackRate: playbackRate
        )
    }

    // MARK: - 辅助

    private func stopEngine(_ kind: ActiveEngineKind) {
        switch kind {
        case .avPlayer: avPlayer.stop()
        case .effects: effectsPlayer.stop()
        }
    }

    private func syncSettings(to kind: ActiveEngineKind) {
        switch kind {
        case .avPlayer:
            avPlayer.volume = volume
            avPlayer.isMuted = isMuted
            avPlayer.playbackRate = playbackRate
        case .effects:
            effectsPlayer.volume = volume
            effectsPlayer.isMuted = isMuted
            effectsPlayer.playbackRate = playbackRate
        }
    }

    private static func readableMessage(_ error: Error) -> String {
        if let description = (error as? LocalizedError)?.errorDescription, !description.isEmpty {
            return description
        }
        return error.localizedDescription
    }

    // MARK: - 测试 / 调试辅助（internal）

    /// 当前已应用的音效设置。
    var appliedEffectSettings: AudioEffectSettings { effectSettings }
    /// 是否已注册系统媒体键（测试用）。
    var hasNowPlayingCommandsRegistered: Bool { nowPlaying.hasRegisteredCommands }
}
