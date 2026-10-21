import Foundation
import AVFoundation
import AudioToolbox
import CryptoKit
import MeloCore

/// Phase 2 音效播放引擎：`AVAudioEngine` 图 = playerNode → 10 段 EQ → TimePitch → mainMixer。
///
/// 使用场景：当前设置存在 EQ / 变调效果时，由 `RoutedPlayerService` 把播放路由到本引擎；
/// 无音效时仍使用 `AVPlayerService`（原生流式播放、省内存）。
///
/// 实现要点：
/// - EQ：`AVAudioUnitEQ` 10 个 `.parametric` band，频率取 `SettingKeys.eqFrequencies`
///   （31…16000Hz）、bandwidth 1.0、0dB 时 `bypass = true`；
/// - 变速变调：`AVAudioUnitTimePitch`，rate = 播放倍速（0.5–2.0），
///   pitch = `AudioEffectSettings.pitchSemitones * 100`（即原版 1200*log2(pitchShifterRate) 音分）；
/// - 本地文件：`AVAudioFile` 直接读取播放；
/// - 远程 URL：AVAudioEngine 不能直接流式播网络 URL，先下载到
///   `~/Library/Caches/Melo/EffectsAudio/<sha256>.<ext>`（已存在且 >1KB 复用）再播，
///   下载期间发 `.status(.loading)`；
/// - pause/resume/stop/seek/volume/mute/playbackRate/进度/结束/错误 与 `PlayerService` 语义一致；
/// - 播放时 `ProcessInfo.beginActivity` 防系统休眠，暂停/停止/出错/播完时结束。
///
/// Phase 2b 新增：
/// - **环境混响**：真实 IR 卷积（vDSP FFT 重叠相加，分块流式），dry*mainGain + wet*sendGain
///   离线渲染成 32-bit float WAV 缓存后继续走 EQ/timePitch/panner 图；IR 位于
///   `resourcesDirectory/SoundEffect/convolution/`，支持绝对路径；key = 音频 + IR + 增益 hash；
/// - **3D 环绕**：`mainMixerNode.pan` 余弦/正弦 LFO（30Hz 定时器），speed 1–50 → 0.01–0.5 圈/秒，
///   soundR 1–30 → 幅度 0.1–1.0；暂停/切歌/关闭时复位 pan。
///
/// 性能说明：卷积在后台线程分块处理（默认 16384 帧/块），内存不随曲目长度增长；
/// 处理期间状态为 `.loading`，处理完成后从原位置继续（播放中切换 IR 会有一次重处理延迟）。
@MainActor
public final class EffectsAudioEngine: NSObject, PlayerService, AudioEffectApplying, AudioVisualizerProviding {

    // MARK: - PlayerService

    public var eventHandler: ((PlayerEvent) -> Void)?
    public private(set) var status: PlayerStatus = .stopped
    public private(set) var currentMusic: MusicInfo?
    public var onNextRequested: (() -> Void)?
    public var onPreviousRequested: (() -> Void)?

    public var volume: Double {
        get { volumeValue }
        set {
            volumeValue = Self.clamp(newValue, 0, 1)
            applyVolume()
        }
    }

    public var isMuted: Bool {
        get { mutedValue }
        set {
            mutedValue = newValue
            applyVolume()
        }
    }

    public var playbackRate: Double {
        get { rateValue }
        set {
            rateValue = Self.clamp(newValue, 0.5, 2.0)
            timePitch.rate = Float(rateValue)
        }
    }

    /// 当前播放时间（秒）：由 playerNode 的 lastRenderTime/playerTime 换算，叠加 seek 起点。
    public var currentTime: TimeInterval { currentTimeValue }
    /// 当前曲目时长（秒）：`AVAudioFile.length / processingFormat.sampleRate`。
    public var duration: TimeInterval { durationValue }

    // MARK: - 额外公开能力

    /// 当前原始播放地址（远程 URL 为原始地址，不是缓存路径）。
    public private(set) var currentURL: URL?
    /// 实际交给 AVAudioFile 的文件地址（远程为缓存文件）。
    public private(set) var loadedFileURL: URL?
    /// 音效引擎的远程音频缓存目录。
    public let cacheDirectory: URL
    /// 缓存容量上限（字节），默认 2GB；internal 便于测试配置小上限。
    var cacheCapacityBytes: UInt64 = 2 * 1024 * 1024 * 1024
    /// 资源目录（其中 `SoundEffect/convolution/` 存放混响 IR）；测试可注入临时目录。
    public let resourcesDirectory: URL
    /// 远程下载使用的 User-Agent。
    public var httpUserAgent: String = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    // MARK: - 输出设备（CoreAudio）

    /// 设置音频输出设备。
    ///
    /// - Parameter uid: CoreAudio 设备 UID；`nil` / 空串 / `"default"` 表示跟随系统默认设备。
    /// - 正在播放 / 暂停时切换会重启音频图，并从原播放位置继续；非法 UID 抛可读中文错误。
    public func setOutputDevice(uid: String?) throws {
        let trimmed = uid?.trimmingCharacters(in: .whitespacesAndNewlines)
        let usesDefault = (trimmed == nil
            || trimmed!.isEmpty
            || trimmed!.caseInsensitiveCompare("default") == .orderedSame)

        var targetID: AudioDeviceID?
        var resolvedUID: String?
        if usesDefault {
            targetID = AudioOutputDevices.defaultAudioDeviceID()
            resolvedUID = nil
        } else {
            let requested = trimmed!
            guard let device = AudioOutputDevices.outputDevice(forUID: requested) else {
                if AudioOutputDevices.deviceID(forUID: requested) != nil {
                    throw AudioOutputDeviceError.notOutputDevice(requested)
                }
                throw AudioOutputDeviceError.notFound(requested)
            }
            targetID = device.deviceID
            resolvedUID = device.uid
        }

        guard let targetID else {
            // 系统没有默认输出设备：仅记录「跟随默认」，下次准备引擎时不指定设备
            outputDeviceID = nil
            outputDeviceUID = nil
            appliedOutputDeviceID = nil
            return
        }

        if audioFile != nil, status == .playing || status == .paused {
            try rebuildEngine(outputDeviceID: targetID, outputDeviceUID: resolvedUID)
        } else {
            outputDeviceID = targetID
            outputDeviceUID = resolvedUID
            // 引擎尚未启动时 outputNode.audioUnit 可能为 nil，起播 prepareEngine 时再应用
            try applyOutputDeviceIfPossible(deviceID: targetID)
        }
    }

    /// 恢复系统默认输出设备（等价 `setOutputDevice(uid: nil)`）。
    public func resetOutputDevice() throws {
        try setOutputDevice(uid: nil)
    }

    // MARK: - 引擎图

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let eqNode: AVAudioUnitEQ
    private let timePitch = AVAudioUnitTimePitch()

    private var audioFile: AVAudioFile?
    private var graphConfigured = false
    private var connectedSampleRate: Double = 0
    private var connectedChannels: AVAudioChannelCount = 0

    // MARK: - 播放状态

    private var currentTimeValue: TimeInterval = 0
    private var durationValue: TimeInterval = 0
    private var volumeValue: Double = 1
    private var mutedValue = false
    private var rateValue: Double = 1
    private var scheduledStartFrame: AVAudioFramePosition = 0
    /// 本次调度开始时间（wall clock），用于过滤 AVAudioPlayerNode 在调度阶段提前回调的 completion。
    private var segmentScheduledAt: Date?
    /// 已播放结束（再 resume 时从头开始）
    private var hasFinished = false
    /// 远程下载中用户按了暂停：下载完成后不自动播放
    private var isPausedBeforeReady = false
    /// 远程下载中用户 seek：下载完成后从该位置起播
    private var pendingSeekTime: TimeInterval?
    /// 是否已上报错误，避免重复
    private var hasReportedError = false

    private var progressTimer: Timer?
    private var activityToken: NSObjectProtocol?

    // MARK: - 下载状态

    private var downloadTask: Task<Void, Never>?
    private var downloadGeneration: UInt64 = 0
    private var scheduleGeneration: UInt64 = 0

    // MARK: - 卷积混响 / 3D 环绕状态

    private var convolutionTask: Task<ConvolutionRenderResult, Error>?
    private var convolutionGeneration: UInt64 = 0
    /// 原始音频文件（本地路径或远程下载缓存），切换 IR 时用于重新处理。
    private var sourceFileURL: URL?
    /// 当前播放的卷积输出文件（未启用混响时为 nil）。
    private var processedFileURL: URL?
    /// 最近一次混响回退/失败的可读提示（nil = 无异常）。
    public private(set) var lastProcessingWarning: String?

    private var pannerTimer: Timer?
    private var pannerAngle: Double = 0
    private var pannerEnabledValue = false
    private var pannerSpeedValue = 25
    private var pannerSoundRValue = 5

    // MARK: - 输出设备

    /// 当前指定的输出设备 UID（nil = 跟随系统默认设备）。
    public private(set) var outputDeviceUID: String?
    /// 是否指定了非默认输出设备（指定后必须走音效引擎）。
    public var hasCustomOutputDevice: Bool { outputDeviceUID != nil }
    /// 当前要应用/已应用的 CoreAudio 输出设备 ID（nil = 系统默认）。
    private var outputDeviceID: AudioDeviceID?
    /// 最近一次成功应用到 AudioUnit 的设备 ID（避免重复设置）。
    private var appliedOutputDeviceID: AudioDeviceID?

    // MARK: - 音频可视化（实验性）

    /// 当前频谱（主线程读写；无数据 / 停止 / 暂停后为 nil）。
    public private(set) var currentSpectrum: AudioSpectrum?
    /// 是否具备可视化能力：已加载音频且处于播放/暂停状态。
    public var isVisualizerAvailable: Bool {
        audioFile != nil && (status == .playing || status == .paused)
    }
    /// tap 是否已安装（只在主线程读写）。
    private var isVisualizerTapInstalled = false
    /// 音频线程复用的 FFT 分析器（tap 安装时创建，随 tap 移除释放）。
    private var spectrumAnalyzer: AudioSpectrumAnalyzer?
    /// 可视化 FFT 长度（≈2048 帧 → 44.1k 下约 21fps、48k 下约 23fps）。
    private static let visualizerFFTSize = 2048

    // MARK: - 音效参数

    private var effectSettings: AudioEffectSettings = .flat

    // MARK: - 初始化

    /// - Parameters:
    ///   - cacheDirectory: 音频/卷积输出缓存目录；默认 `~/Library/Caches/Melo/EffectsAudio`（测试可注入临时目录）。
    ///   - resourcesDirectory: 资源目录（IR 在 `SoundEffect/convolution/`）；默认 `ResourceLocator.resourcesDirectory()`。
    public init(cacheDirectory: URL? = nil, resourcesDirectory: URL? = nil) {
        let resolvedCache = cacheDirectory ?? Self.defaultCacheDirectory()
        self.cacheDirectory = resolvedCache
        self.resourcesDirectory = resourcesDirectory ?? ResourceLocator.resourcesDirectory()
        self.eqNode = AVAudioUnitEQ(numberOfBands: SettingKeys.eqFrequencies.count)
        super.init()
        configureGraphNodes()
        applyVolume()
        // 启动时按容量上限做一次 LRU 清理（默认 2GB；目录不存在时无操作）。
        enforceCacheLimit()
    }

    /// 默认缓存目录：`~/Library/Caches/Melo/EffectsAudio/`
    public static func defaultCacheDirectory() -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("Melo", isDirectory: true)
            .appendingPathComponent("EffectsAudio", isDirectory: true)
    }

    private func configureGraphNodes() {
        engine.attach(playerNode)
        engine.attach(eqNode)
        engine.attach(timePitch)

        for (index, frequency) in SettingKeys.eqFrequencies.enumerated() where index < eqNode.bands.count {
            let band = eqNode.bands[index]
            band.filterType = .parametric
            band.frequency = Float(frequency)
            band.bandwidth = 1.0
            band.gain = 0
            band.bypass = true
        }
        timePitch.rate = 1
        timePitch.pitch = 0
        applyEQ(bands: effectSettings.eqBands)
    }

    // MARK: - AudioEffectApplying

    /// 实时更新 EQ / 变速变调 / 环绕参数；卷积混响配置变化时重新离线处理当前音频。
    /// 未起播时同样生效（节点常驻），起播后立即可闻。
    public func applyAudioEffects(_ settings: AudioEffectSettings) {
        let previousConvolution = Self.convolutionConfiguration(of: effectSettings)
        effectSettings = settings
        applyEQ(bands: settings.eqBands)
        playbackRate = settings.playbackRate
        let cents = Float(settings.pitchSemitones * 100)
        timePitch.pitch = min(max(cents, -2400), 2400)
        applyPanner(settings: settings)

        if previousConvolution != Self.convolutionConfiguration(of: settings) {
            reprocessForConvolutionChange()
        }
    }

    // MARK: - 播放控制

    /// 开始播放远程 / 本地 URL。
    ///
    /// - 本地文件：同步打开 AVAudioFile 并开始播放（打不开会 throw `PlayerError`）；
    /// - 远程 URL：进入 `.loading`，下载完成后异步开始播放，失败发 `.error`。
    public func play(url: URL, music: MusicInfo) throws {
        try validate(url)

        // 本地文件先在改动播放状态前打开（打不开直接 throw，状态保持原样，与 AVPlayerService 一致）。
        let localFile: AVAudioFile?
        if url.isFileURL {
            localFile = try openAudioFile(url)
        } else {
            localFile = nil
        }

        resetForNewPlayback()
        currentMusic = music
        currentURL = url
        currentTimeValue = 0
        let interval = MeloUtils.parseInterval(music.interval)
        durationValue = interval > 0 ? interval : 0
        setStatus(.loading)

        if let localFile {
            sourceFileURL = url
            if convolutionIsActive {
                beginConvolutionPlayback(sourceFile: url, fallbackFile: localFile, startPosition: 0)
            } else {
                do {
                    try startPlayback(file: localFile, fileURL: url, from: 0)
                } catch {
                    // 引擎启动失败等运行期问题：走异步错误事件（play 本身已通过同步校验）
                    reportPlaybackError(error)
                }
            }
        } else {
            startRemoteDownload(url: url)
        }
    }

    public func pause() {
        if status == .loading, audioFile == nil {
            isPausedBeforeReady = true
            setStatus(.paused)
            return
        }
        guard let file = audioFile, status == .playing else { return }

        currentTimeValue = playerCurrentTime(file: file)
        playerNode.pause()
        removeVisualizerTap()
        stopPannerTimer()
        stopProgressTimer()
        endPowerSaveActivity()
        setStatus(.paused)
        eventHandler?(.progress(current: currentTimeValue, duration: durationValue))
    }

    public func resume() {
        // 远程下载中先暂停了：恢复为「下载完成后自动播放」
        if audioFile == nil, status == .paused, downloadTask != nil {
            isPausedBeforeReady = false
            setStatus(.loading)
            return
        }
        guard audioFile != nil else { return }

        if hasFinished {
            hasFinished = false
            scheduleSegment(from: 0)
            currentTimeValue = 0
        }

        do {
            try ensureEngineRunning()
        } catch {
            reportPlaybackError(error)
            return
        }
        installVisualizerTapIfNeeded()
        playerNode.play()
        setStatus(.playing)
        beginPowerSaveActivity()
        startProgressTimer()
        startPannerIfNeeded()
        eventHandler?(.progress(current: currentTimeValue, duration: durationValue))
    }

    public func stop() {
        cancelDownload()
        cancelConvolutionProcessing()
        stopPannerTimer()
        scheduleGeneration &+= 1
        playerNode.stop()
        audioFile = nil
        loadedFileURL = nil
        currentMusic = nil
        currentURL = nil
        currentTimeValue = 0
        durationValue = 0
        hasFinished = false
        isPausedBeforeReady = false
        pendingSeekTime = nil
        hasReportedError = false
        sourceFileURL = nil
        processedFileURL = nil
        lastProcessingWarning = nil
        removeVisualizerTap()
        stopProgressTimer()
        endPowerSaveActivity()
        if engine.isRunning { engine.pause() }
        setStatus(.stopped)
        eventHandler?(.progress(current: 0, duration: 0))
    }

    public func seek(to time: TimeInterval) {
        let requested = time.isFinite ? time : 0
        var target = max(requested, 0)
        if durationValue > 0 { target = min(target, durationValue) }

        // 远程下载中：记录目标位置，下载完成后再 seek
        if status == .loading, audioFile == nil {
            pendingSeekTime = target
            currentTimeValue = target
            return
        }
        guard audioFile != nil else { return }

        let wasPlaying = status == .playing
        hasFinished = false
        scheduleSegment(from: target)
        currentTimeValue = min(target, durationValue)
        eventHandler?(.progress(current: currentTimeValue, duration: durationValue))

        if wasPlaying {
            if !engine.isRunning {
                do { try ensureEngineRunning() } catch {
                    reportPlaybackError(error)
                    return
                }
            }
            playerNode.play()
        }
    }

    // MARK: - 图 / 文件

    private func openAudioFile(_ url: URL) throws -> AVAudioFile {
        do {
            let file = try AVAudioFile(forReading: url)
            guard file.length > 0 else {
                throw PlayerError.playbackFailed("音频文件为空：\(url.lastPathComponent)")
            }
            return file
        } catch let error as PlayerError {
            throw error
        } catch {
            throw PlayerError.playbackFailed(
                "无法打开音频文件（\(error.localizedDescription)）：\(url.lastPathComponent)"
            )
        }
    }

    private func duration(of file: AVAudioFile) -> TimeInterval {
        let sampleRate = file.processingFormat.sampleRate
        guard sampleRate > 0 else { return 0 }
        return Double(file.length) / sampleRate
    }

    private func startPlayback(file: AVAudioFile, fileURL: URL, from time: TimeInterval) throws {
        audioFile = file
        loadedFileURL = fileURL
        durationValue = duration(of: file)
        try prepareEngine(format: file.processingFormat)
        installVisualizerTapIfNeeded()
        scheduleSegment(from: time)
        currentTimeValue = min(max(time, 0), durationValue)

        if isPausedBeforeReady {
            setStatus(.paused)
            eventHandler?(.progress(current: currentTimeValue, duration: durationValue))
            return
        }

        playerNode.play()
        setStatus(.playing)
        beginPowerSaveActivity()
        startProgressTimer()
        startPannerIfNeeded()
        eventHandler?(.progress(current: currentTimeValue, duration: durationValue))
    }

    private func prepareEngine(format: AVAudioFormat) throws {
        // 引擎 stop/start 前先移除 tap（避免重复安装或回调访问失效节点）
        removeVisualizerTap()
        let sameFormat = graphConfigured
            && abs(connectedSampleRate - format.sampleRate) < 0.5
            && connectedChannels == format.channelCount

        if sameFormat {
            try ensureEngineRunning()
            return
        }

        engine.stop()
        reconnectGraph(format: format)
        engine.prepare()
        try applyStoredOutputDeviceIfNeeded()
        do {
            try engine.start()
        } catch {
            throw PlayerError.playbackFailed("音频引擎启动失败：\(error.localizedDescription)")
        }
        installVisualizerTapIfNeeded()
    }

    private func ensureEngineRunning() throws {
        guard !engine.isRunning else { return }
        removeVisualizerTap()
        engine.prepare()
        try applyStoredOutputDeviceIfNeeded()
        do {
            try engine.start()
        } catch {
            throw PlayerError.playbackFailed("音频引擎启动失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 音频可视化（AVAudioNode tap）

    /// 在 `timePitch` 输出安装频谱 tap（仅主线程；重复调用幂等）。
    ///
    /// tap 放在 EQ/变速变调之后、mainMixer 之前：这样输出音量/静音/声道平衡不会影响频谱数据
    /// （用户静音时仍能看到可视化）；比直接 tap mainMixer 更适合可视化场景。
    private func installVisualizerTapIfNeeded() {
        guard !isVisualizerTapInstalled, engine.isRunning, graphConfigured else { return }
        let format = timePitch.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return }
        if spectrumAnalyzer == nil
            || abs((spectrumAnalyzer?.sampleRate ?? 0) - format.sampleRate) > 0.5 {
            spectrumAnalyzer = AudioSpectrumAnalyzer(sampleRate: format.sampleRate,
                                                     fftSize: Self.visualizerFFTSize)
        }
        guard let analyzer = spectrumAnalyzer else { return }

        timePitch.installTap(
            onBus: 0,
            bufferSize: AVAudioFrameCount(Self.visualizerFFTSize),
            format: nil
        ) { [weak self] buffer, _ in
            // 音频线程：只做 FFT 计算，然后投递主线程更新（不在音频线程碰 MainActor 状态）
            let bands = analyzer.analyze(buffer)
            Task { @MainActor [weak self] in
                self?.handleVisualizerBands(bands)
            }
        }
        isVisualizerTapInstalled = true
    }

    /// 移除频谱 tap 并清空当前频谱（幂等；stop/暂停/切歌/引擎重启时调用）。
    private func removeVisualizerTap() {
        if isVisualizerTapInstalled {
            timePitch.removeTap(onBus: 0)
            isVisualizerTapInstalled = false
        }
        spectrumAnalyzer = nil
        currentSpectrum = nil
    }

    /// 主线程应用一帧频谱（tap 移除后丢弃迟到帧）。
    private func handleVisualizerBands(_ bands: [Float]) {
        guard isVisualizerTapInstalled else { return }
        currentSpectrum = AudioSpectrum(bands: bands)
    }

    // MARK: - 输出设备切换（AudioUnit）

    /// 把设备 ID 设置到 `engine.outputNode.audioUnit` 的 `kAudioOutputUnitProperty_CurrentDevice`。
    /// 输出单元尚未创建（引擎未准备）时只记录，等 `prepareEngine` 时再应用。
    private func applyOutputDeviceIfPossible(deviceID: AudioDeviceID) throws {
        guard let audioUnit = engine.outputNode.audioUnit else { return }
        var target = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &target,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            throw AudioOutputDeviceError.switchFailed("AudioUnitSetProperty(CurrentDevice) 返回 \(status)")
        }
        appliedOutputDeviceID = deviceID
    }

    private func applyStoredOutputDeviceIfNeeded() throws {
        guard let deviceID = outputDeviceID, appliedOutputDeviceID != deviceID else { return }
        try applyOutputDeviceIfPossible(deviceID: deviceID)
    }

    /// 播放中断/暂停时切设备：停止引擎 → 设置设备 → 重启并从原位置重排。
    private func rebuildEngine(outputDeviceID: AudioDeviceID, outputDeviceUID: String?) throws {
        guard let file = audioFile else { return }
        let position = min(max(currentTimeValue, 0), durationValue)
        let wasPlaying = status == .playing
        let wasPaused = status == .paused

        scheduleGeneration &+= 1
        playerNode.stop()
        stopProgressTimer()
        endPowerSaveActivity()
        stopPannerTimer()
        removeVisualizerTap()
        if engine.isRunning { engine.stop() }

        let previousDeviceID = self.outputDeviceID
        let previousDeviceUID = self.outputDeviceUID
        do {
            try applyOutputDeviceIfPossible(deviceID: outputDeviceID)
        } catch {
            // 应用失败：回滚设置，并用原设备尝试恢复播放，再向上抛错
            self.outputDeviceID = previousDeviceID
            self.outputDeviceUID = previousDeviceUID
            restorePlaybackAfterDeviceChange(file: file, position: position,
                                             wasPlaying: wasPlaying, wasPaused: wasPaused)
            throw error
        }

        self.outputDeviceID = outputDeviceID
        self.outputDeviceUID = outputDeviceUID
        restorePlaybackAfterDeviceChange(file: file, position: position,
                                         wasPlaying: wasPlaying, wasPaused: wasPaused)
    }

    private func restorePlaybackAfterDeviceChange(file: AVAudioFile,
                                                  position: TimeInterval,
                                                  wasPlaying: Bool,
                                                  wasPaused: Bool) {
        do {
            try prepareEngine(format: file.processingFormat)
        } catch {
            reportPlaybackError(error)
            return
        }
        scheduleSegment(from: position)
        currentTimeValue = min(max(position, 0), durationValue)
        if wasPlaying {
            playerNode.play()
            setStatus(.playing)
            beginPowerSaveActivity()
            startProgressTimer()
            startPannerIfNeeded()
            eventHandler?(.progress(current: currentTimeValue, duration: durationValue))
        } else if wasPaused {
            setStatus(.paused)
            eventHandler?(.progress(current: currentTimeValue, duration: durationValue))
        }
    }

    private func reconnectGraph(format: AVAudioFormat) {
        if graphConfigured {
            engine.disconnectNodeOutput(playerNode)
            engine.disconnectNodeOutput(eqNode)
            engine.disconnectNodeOutput(timePitch)
            engine.disconnectNodeInput(engine.mainMixerNode)
        }
        engine.connect(playerNode, to: eqNode, format: format)
        engine.connect(eqNode, to: timePitch, format: format)
        engine.connect(timePitch, to: engine.mainMixerNode, format: format)
        graphConfigured = true
        connectedSampleRate = format.sampleRate
        connectedChannels = format.channelCount
    }

    // MARK: - 调度

    private func scheduleSegment(from time: TimeInterval) {
        guard let file = audioFile else { return }
        let sampleRate = file.processingFormat.sampleRate
        guard sampleRate > 0, file.length > 0 else { return }

        let requestedFrame = AVAudioFramePosition((max(time, 0) * sampleRate).rounded())
        let startFrame = max(0, min(requestedFrame, file.length - 1))
        let remainingFrames = max(file.length - startFrame, 1)
        // AVAudioFrameCount 是 UInt32，超长音频（>27h@44.1kHz）时防御性截断，避免溢出 trap。
        let frameCount = AVAudioFrameCount(min(remainingFrames, AVAudioFramePosition(UInt32.max)))

        scheduleGeneration &+= 1
        let generation = scheduleGeneration
        scheduledStartFrame = startFrame
        segmentScheduledAt = Date()

        // 先作废旧调度（generation 已递增，旧 completion 会被忽略），再挂新调度。
        playerNode.stop()
        playerNode.scheduleSegment(
            file,
            startingFrame: startFrame,
            frameCount: frameCount,
            at: nil
        ) { [weak self] in
            onMainActor { [weak self] in self?.handleSegmentCompleted(generation: generation) }
        }
    }

    private func handleSegmentCompleted(generation: UInt64) {
        guard generation == scheduleGeneration, status == .playing else { return }
        // AVAudioPlayerNode 在部分场景（引擎启动/格式切换/短音频）会在 schedule 阶段就提前
        // 回调 completion；用「调度后实际经过的 wall clock 时间」过滤，避免刚起播就误判结束。
        let elapsed = Date().timeIntervalSince(segmentScheduledAt ?? .distantPast)
        guard elapsed >= 0.1 else { return }
        // completion 在内部命令队列回调中执行；若此时同步调用 playerNode.stop() 会与
        // AVAudioPlayerNodeImpl::StopImpl 重入（Libdispatch trap），延迟到下一个 main actor 周期收尾。
        Task { @MainActor [weak self] in
            guard let self, generation == self.scheduleGeneration, self.status == .playing else { return }
            self.finishPlayback()
        }
    }

    private func finishPlayback() {
        guard audioFile != nil else { return }
        hasFinished = true
        currentTimeValue = durationValue
        playerNode.stop()
        removeVisualizerTap()
        stopPannerTimer()
        stopProgressTimer()
        endPowerSaveActivity()
        setStatus(.stopped)
        eventHandler?(.progress(current: durationValue, duration: durationValue))
        eventHandler?(.ended)
    }

    // MARK: - 进度

    private func startProgressTimer() {
        stopProgressTimer()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            onMainActor { [weak self] in self?.handleProgressTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        progressTimer = timer
    }

    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    private func handleProgressTick() {
        guard status == .playing, let file = audioFile else { return }
        currentTimeValue = playerCurrentTime(file: file)
        // 兜底：播放到结尾（completion 被过滤/丢失时）也能发 .ended。
        if durationValue > 0, currentTimeValue >= durationValue - 0.03 {
            finishPlayback()
            return
        }
        eventHandler?(.progress(current: currentTimeValue, duration: durationValue))
    }

    /// 当前时间 = 本次调度起点（seek 偏移）+ playerNode 已渲染的采样数。
    private func playerCurrentTime(file: AVAudioFile) -> TimeInterval {
        let sampleRate = file.processingFormat.sampleRate
        guard sampleRate > 0 else { return currentTimeValue }
        guard let nodeTime = playerNode.lastRenderTime,
              nodeTime.isSampleTimeValid,
              let playerTime = playerNode.playerTime(forNodeTime: nodeTime) else {
            return currentTimeValue
        }
        let playedSeconds = Double(playerTime.sampleTime) / sampleRate
        let offsetSeconds = Double(scheduledStartFrame) / sampleRate
        let time = offsetSeconds + max(playedSeconds, 0)
        if durationValue > 0 { return min(max(time, 0), durationValue) }
        return max(time, 0)
    }

    // MARK: - 远程下载 / 缓存

    /// 远程音频缓存文件路径：`<sha256(url) >.<ext>`。
    func cacheFileURL(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        var ext = url.pathExtension.lowercased()
        if ext.isEmpty || ext.count > 8 || !ext.allSatisfy({ $0.isLetter || $0.isNumber }) {
            ext = "audio"
        }
        return cacheDirectory.appendingPathComponent("\(hex).\(ext)")
    }

    /// 缓存是否可用：存在且大小 > 1KB。
    static func isUsableCacheFile(_ url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else { return false }
        return size.intValue > 1024
    }

    // MARK: - 卷积混响处理

    /// 当前混响配置（用于判断设置变化是否需要重新处理）。
    private struct ConvolutionConfiguration: Equatable {
        var fileName: String?
        var mainGain: Double
        var sendGain: Double
    }

    private static func convolutionConfiguration(of settings: AudioEffectSettings) -> ConvolutionConfiguration {
        let trimmed = settings.convolutionFileName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fileName = (trimmed?.isEmpty == false) ? trimmed : nil
        return ConvolutionConfiguration(
            fileName: fileName,
            mainGain: settings.convolutionMainGain,
            sendGain: settings.convolutionSendGain
        )
    }

    private var convolutionIsActive: Bool {
        Self.convolutionConfiguration(of: effectSettings).fileName != nil
    }

    /// IR 文件解析：绝对路径直接使用；否则 `resourcesDirectory/SoundEffect/convolution/<fileName>`。
    func impulseResponseURL(for fileName: String) -> URL {
        let trimmed = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("/") { return URL(fileURLWithPath: trimmed) }
        return resourcesDirectory
            .appendingPathComponent("SoundEffect", isDirectory: true)
            .appendingPathComponent("convolution", isDirectory: true)
            .appendingPathComponent(trimmed)
    }

    /// 卷积输出缓存路径：
    /// key = SHA256("conv-v1|源文件路径+大小|IR 文件名|干声增益|湿声增益")，扩展名 `.conv.wav`。
    func processedCacheFileURL(sourceFileURL: URL, settings: AudioEffectSettings) -> URL {
        var sourceIdentity = sourceFileURL.standardizedFileURL.path
        if let size = try? sourceFileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
            sourceIdentity += "|\(size)"
        }
        let trimmed = settings.convolutionFileName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let mainGain = String(format: "%.4f", settings.convolutionMainGain)
        let sendGain = String(format: "%.4f", settings.convolutionSendGain)
        let payload = "conv-v1|\(sourceIdentity)|\(trimmed)|\(mainGain)|\(sendGain)"
        let digest = SHA256.hash(data: Data(payload.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return cacheDirectory.appendingPathComponent("\(hex).conv.wav")
    }

    /// 校验 IR 是否存在且可读；返回可读中文警告（nil 表示可用）。
    private func validateImpulseResponse(fileName: String) -> (url: URL, warning: String?) {
        let url = impulseResponseURL(for: fileName)
        if !FileManager.default.fileExists(atPath: url.path) {
            return (url, "混响 IR 文件不存在：\(fileName)（\(url.path)），已回退为无混响播放")
        }
        do {
            let file = try AVAudioFile(forReading: url,
                                       commonFormat: .pcmFormatFloat32,
                                       interleaved: false)
            if file.length <= 0 || file.processingFormat.channelCount == 0 {
                return (url, "混响 IR 文件无效（没有音频数据）：\(fileName)，已回退为无混响播放")
            }
        } catch {
            return (url, "混响 IR 文件无法读取：\(fileName)（\(error.localizedDescription)），已回退为无混响播放")
        }
        return (url, nil)
    }

    /// 播放前准备：命中卷积输出缓存直接播；否则后台渲染（.loading）后再播。
    /// IR 缺失/非法时回退无混响播放并记录可读警告。
    private func beginConvolutionPlayback(sourceFile: URL,
                                          fallbackFile: AVAudioFile?,
                                          startPosition: TimeInterval) {
        cancelConvolutionProcessing()

        let configuration = Self.convolutionConfiguration(of: effectSettings)
        guard let fileName = configuration.fileName else {
            finishSourceReady(fileURL: sourceFile,
                              startPosition: startPosition,
                              autoplay: !isPausedBeforeReady)
            return
        }

        let outputURL = processedCacheFileURL(sourceFileURL: sourceFile, settings: effectSettings)
        // 缓存文件可能因上次进程中断而截断（大小足够但 WAV 头/数据无效），用 AVAudioFile 实际校验一次
        let cacheIsPlayable = Self.isUsableCacheFile(outputURL)
            && ((try? AVAudioFile(forReading: outputURL))?.length ?? 0) > 0
        if Self.isUsableCacheFile(outputURL) && !cacheIsPlayable {
            try? FileManager.default.removeItem(at: outputURL)
        }
        if cacheIsPlayable {
            markCacheFileUsed(outputURL)
            processedFileURL = outputURL
            let start = pendingSeekTime ?? startPosition
            pendingSeekTime = nil
            finishSourceReady(fileURL: outputURL,
                              startPosition: start,
                              autoplay: !isPausedBeforeReady)
            return
        }

        let irInfo = validateImpulseResponse(fileName: fileName)
        if let warning = irInfo.warning {
            fallbackToUnprocessed(sourceFile: sourceFile,
                                  fallbackFile: fallbackFile,
                                  startPosition: startPosition,
                                  warning: warning)
            return
        }

        convolutionGeneration &+= 1
        let generation = convolutionGeneration
        let mainGain = configuration.mainGain
        let sendGain = configuration.sendGain
        let irURL = irInfo.url
        setStatus(.loading)

        let renderTask = Task.detached(priority: .userInitiated) {
            try ConvolutionReverb.render(sourceURL: sourceFile,
                                         impulseResponseURL: irURL,
                                         mainGain: mainGain,
                                         sendGain: sendGain,
                                         outputURL: outputURL,
                                         shouldCancel: { Task.isCancelled })
        }
        convolutionTask = renderTask

        Task { [weak self] in
            do {
                let result = try await renderTask.value
                onMainActor { [weak self] in
                    guard let self, generation == self.convolutionGeneration else { return }
                    self.convolutionTask = nil
                    self.processedFileURL = result.outputURL
                    MeloLog.info("卷积混响完成：\(result.duration) 秒音频，耗时 \(String(format: "%.2f", result.renderSeconds)) 秒")
                    // 卷积输出也纳入 LRU（保护刚生成的文件）
                    self.enforceCacheLimit(protecting: result.outputURL)
                    let start = self.pendingSeekTime ?? startPosition
                    self.pendingSeekTime = nil
                    self.finishSourceReady(fileURL: result.outputURL,
                                           startPosition: start,
                                          autoplay: !self.isPausedBeforeReady)
                }
            } catch {
                onMainActor { [weak self] in
                    guard let self, generation == self.convolutionGeneration else { return }
                    self.convolutionTask = nil
                    if case ConvolutionReverbError.cancelled = error { return }
                    let warning = "混响处理失败（已回退为无混响播放）：\(error.localizedDescription)"
                    self.fallbackToUnprocessed(sourceFile: sourceFile,
                                               fallbackFile: fallbackFile,
                                               startPosition: startPosition,
                                               warning: warning)
                }
            }
        }
    }

    /// 回退为无混响播放（记录可读警告，不打断播放）。
    private func fallbackToUnprocessed(sourceFile: URL,
                                       fallbackFile: AVAudioFile?,
                                       startPosition: TimeInterval,
                                       warning: String) {
        lastProcessingWarning = warning
        processedFileURL = nil
        MeloLog.warn(warning)
        do {
            let file: AVAudioFile
            if let fallbackFile {
                file = fallbackFile
            } else {
                file = try openAudioFile(sourceFile)
            }
            let start = pendingSeekTime ?? startPosition
            pendingSeekTime = nil
            try startPlayback(file: file, fileURL: sourceFile, from: start)
        } catch {
            reportPlaybackError(error)
        }
    }

    /// 打开最终要播放的文件（原文件或卷积输出缓存）并从指定位置起播。
    private func finishSourceReady(fileURL: URL, startPosition: TimeInterval, autoplay: Bool) {
        do {
            let file = try openAudioFile(fileURL)
            isPausedBeforeReady = !autoplay
            try startPlayback(file: file, fileURL: fileURL, from: startPosition)
        } catch {
            reportPlaybackError(error)
        }
    }

    private func cancelConvolutionProcessing() {
        convolutionGeneration &+= 1
        convolutionTask?.cancel()
        convolutionTask = nil
    }

    /// 播放中混响配置变化：重新处理当前源音频并从原位置继续（会有一段 .loading 延迟）。
    private func reprocessForConvolutionChange() {
        guard currentMusic != nil, let source = sourceFileURL else { return }
        guard !hasFinished, status != .error else { return }
        // 远程下载尚未完成：下载完成后会使用最新设置处理
        if downloadTask != nil, audioFile == nil { return }

        let position = currentTimeValue
        let wasPlaying = status == .playing || status == .loading

        // 先作废旧调度，再 stop：AVAudioPlayerNode.stop() 会同步触发旧调度 completion，
        // generation 不匹配时直接忽略，避免在 stop 回调栈内再次 stop（AVFAudio 会 trap）。
        scheduleGeneration &+= 1
        playerNode.stop()
        audioFile = nil
        stopProgressTimer()
        endPowerSaveActivity()
        stopPannerTimer()
        isPausedBeforeReady = !wasPlaying
        currentTimeValue = position
        pendingSeekTime = nil
        setStatus(.loading)

        if convolutionIsActive {
            beginConvolutionPlayback(sourceFile: source, fallbackFile: nil, startPosition: position)
        } else {
            processedFileURL = nil
            do {
                let file = try openAudioFile(source)
                try startPlayback(file: file, fileURL: source, from: position)
            } catch {
                reportPlaybackError(error)
            }
        }
    }

    // MARK: - 3D 环绕（mainMixer.pan LFO）

    /// speed 1–50 → 0.01–0.5 圈/秒（默认 25 ≈ 0.25 圈/秒，约 4 秒一圈）；
    /// soundR 1–30 → pan 幅度 0.1–1.0（1 距离最小、30 最大）。
    private func applyPanner(settings: AudioEffectSettings) {
        pannerEnabledValue = settings.pannerEnabled
        pannerSpeedValue = max(1, min(settings.pannerSpeed, 50))
        pannerSoundRValue = max(1, min(settings.pannerSoundR, 30))
        guard pannerEnabledValue else {
            stopPannerTimer()
            return
        }
        if status == .playing { startPannerIfNeeded() }
    }

    private func startPannerIfNeeded() {
        guard pannerEnabledValue, status == .playing, pannerTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            onMainActor { [weak self] in self?.tickPanner() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pannerTimer = timer
    }

    /// 停止环绕 LFO 并复位 pan（暂停/切歌/关闭混响或环绕时调用）。
    private func stopPannerTimer() {
        pannerTimer?.invalidate()
        pannerTimer = nil
        pannerAngle = 0
        engine.mainMixerNode.pan = 0
    }

    private func tickPanner() {
        guard pannerEnabledValue, status == .playing else { return }
        let turnsPerSecond = 0.01 * Double(pannerSpeedValue)
        pannerAngle += 2.0 * .pi * turnsPerSecond / 30.0
        if pannerAngle >= 2.0 * .pi { pannerAngle -= 2.0 * .pi }
        let amplitude = 0.1 + (Double(pannerSoundRValue) - 1.0) / 29.0 * 0.9
        engine.mainMixerNode.pan = Float(sin(pannerAngle) * amplitude)
    }

    // MARK: - 缓存容量管理（LRU）

    /// 当前缓存目录内文件总大小（字节）。
    var cacheTotalSizeBytes: UInt64 {
        cacheEntries().reduce(UInt64(0)) { $0 + $1.size }
    }

    /// 按 LRU（mtime 最旧优先）清理缓存，直到总大小不超过 `cacheCapacityBytes`。
    ///
    /// - Parameter protectedFile: 不参与删除的文件（本次下载目标 / 正在播放的缓存文件）。
    /// - Returns: 被删除的文件列表。
    /// - Note: 删除失败的文件跳过（不阻塞播放）；容量设为 0 表示不限制。
    @discardableResult
    func enforceCacheLimit(protecting protectedFile: URL? = nil) -> [URL] {
        let capacity = cacheCapacityBytes
        guard capacity > 0 else { return [] }

        let protectedPath = protectedFile?.standardizedFileURL.path
        var entries = cacheEntries()
        // 受保护文件不参与删除，但它的体积仍占用容量（下载完成/正在播放的缓存会保留）。
        var total = entries.reduce(UInt64(0)) { $0 + $1.size }
        if let protectedPath {
            entries.removeAll { $0.url.standardizedFileURL.path == protectedPath }
        }
        guard total > capacity else { return [] }

        entries.sort { $0.modifiedAt < $1.modifiedAt }
        var deleted: [URL] = []
        for entry in entries {
            guard total > capacity else { break }
            guard (try? FileManager.default.removeItem(at: entry.url)) != nil else { continue }
            total -= min(total, entry.size)
            deleted.append(entry.url)
        }
        return deleted
    }

    /// 标记缓存文件「最近使用」（刷新 mtime），LRU 清理时优先保留（失败忽略）。
    func markCacheFileUsed(_ fileURL: URL) {
        try? FileManager.default.setAttributes(
            [.modificationDate: Date()],
            ofItemAtPath: fileURL.path
        )
    }

    private func cacheEntries() -> [(url: URL, size: UInt64, modifiedAt: Date)] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return [] }

        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  let fileSize = values.fileSize,
                  fileSize > 0 else { return nil }
            return (url, UInt64(fileSize), values.contentModificationDate ?? .distantPast)
        }
    }

    private func startRemoteDownload(url: URL) {
        downloadGeneration &+= 1
        let generation = downloadGeneration
        let targetURL = cacheFileURL(for: url)

        if Self.isUsableCacheFile(targetURL) {
            // 命中缓存：刷新 mtime（LRU）并直接播放。
            markCacheFileUsed(targetURL)
            handleDownloadedFile(targetURL, generation: generation)
            return
        }

        // 下载前先按容量上限删除最旧缓存，给新文件腾空间。
        enforceCacheLimit(protecting: targetURL)

        downloadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let (temporaryURL, response) = try await Self.downloadAudio(
                    url: url,
                    userAgent: self.httpUserAgent
                )
                guard !Task.isCancelled else { return }
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    throw PlayerError.playbackFailed("音频下载失败：HTTP \(http.statusCode)")
                }
                do {
                    try FileManager.default.createDirectory(
                        at: self.cacheDirectory,
                        withIntermediateDirectories: true
                    )
                    if FileManager.default.fileExists(atPath: targetURL.path) {
                        try? FileManager.default.removeItem(at: targetURL)
                    }
                    try FileManager.default.moveItem(at: temporaryURL, to: targetURL)
                } catch {
                    throw PlayerError.playbackFailed("音频缓存写入失败：\(error.localizedDescription)")
                }
                onMainActor { [weak self] in
                    guard let self else { return }
                    // 下载完成后再按实际大小清一次（保护刚下载的目标文件）。
                    self.enforceCacheLimit(protecting: targetURL)
                    self.handleDownloadedFile(targetURL, generation: generation)
                }
            } catch {
                guard !Task.isCancelled else { return }
                onMainActor { [weak self] in
                    self?.handleDownloadFailure(error, generation: generation)
                }
            }
        }
    }

    private static func downloadAudio(url: URL, userAgent: String) async throws -> (URL, URLResponse) {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30
        return try await URLSession.shared.download(for: request)
    }

    private func handleDownloadedFile(_ fileURL: URL, generation: UInt64) {
        guard generation == downloadGeneration, currentMusic != nil else { return }
        downloadTask = nil
        sourceFileURL = fileURL
        if convolutionIsActive {
            // 混响开启：下载完成后进入离线卷积处理（期间保持 .loading）
            beginConvolutionPlayback(sourceFile: fileURL,
                                     fallbackFile: nil,
                                     startPosition: pendingSeekTime ?? 0)
        } else {
            let startTime = pendingSeekTime ?? 0
            pendingSeekTime = nil
            finishSourceReady(fileURL: fileURL,
                              startPosition: startTime,
                              autoplay: !isPausedBeforeReady)
        }
    }

    private func handleDownloadFailure(_ error: Error, generation: UInt64) {
        guard generation == downloadGeneration, currentMusic != nil else { return }
        downloadTask = nil
        if let playerError = error as? PlayerError {
            reportPlaybackError(playerError)
        } else {
            reportPlaybackError(PlayerError.playbackFailed("音频下载失败：\(error.localizedDescription)"))
        }
    }

    private func cancelDownload() {
        downloadGeneration &+= 1
        downloadTask?.cancel()
        downloadTask = nil
    }

    // MARK: - 状态 / 错误

    private func setStatus(_ newStatus: PlayerStatus) {
        guard status != newStatus else { return }
        status = newStatus
        eventHandler?(.status(newStatus))
    }

    private func reportPlaybackError(_ error: Error) {
        guard !hasReportedError else { return }
        hasReportedError = true

        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        MeloLog.error("音效播放失败: \(message)")

        playerNode.stop()
        removeVisualizerTap()
        stopPannerTimer()
        stopProgressTimer()
        endPowerSaveActivity()
        setStatus(.error)
        eventHandler?(.error(message))
    }

    // MARK: - 音效 / 音量

    private func applyEQ(bands: [Double]) {
        for (index, band) in eqNode.bands.enumerated() {
            guard index < SettingKeys.eqFrequencies.count else { break }
            let gain = index < bands.count ? bands[index] : 0
            let clamped = min(max(gain, -24), 24)
            band.gain = Float(clamped)
            band.bypass = abs(clamped) < 0.01
        }
    }

    private func applyVolume() {
        engine.mainMixerNode.outputVolume = mutedValue ? 0 : Float(volumeValue)
    }

    private static func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
        guard value.isFinite else { return 1 }
        return min(max(value, lower), upper)
    }

    // MARK: - 防休眠

    private func beginPowerSaveActivity() {
        guard activityToken == nil else { return }
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Melo 正在播放音频（音效引擎）"
        )
    }

    private func endPowerSaveActivity() {
        guard let token = activityToken else { return }
        activityToken = nil
        ProcessInfo.processInfo.endActivity(token)
    }

    // MARK: - 生命周期

    private func resetForNewPlayback() {
        cancelDownload()
        cancelConvolutionProcessing()
        stopPannerTimer()
        scheduleGeneration &+= 1
        playerNode.stop()
        audioFile = nil
        loadedFileURL = nil
        sourceFileURL = nil
        processedFileURL = nil
        lastProcessingWarning = nil
        hasFinished = false
        isPausedBeforeReady = false
        pendingSeekTime = nil
        hasReportedError = false
        stopProgressTimer()
        endPowerSaveActivity()
    }

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
                throw PlayerError.playbackFailed("播放地址是一个目录，不是音频文件：\(url.path)")
            }
        case "http", "https":
            guard let host = url.host, !host.isEmpty else {
                throw PlayerError.invalidURL(url.absoluteString)
            }
        default:
            throw PlayerError.unsupportedScheme(scheme)
        }
    }

    // MARK: - 测试/调试辅助（internal）

    /// 各 EQ band 频率（Hz）。
    var eqBandFrequencies: [Float] { eqNode.bands.map(\.frequency) }
    /// 各 EQ band 带宽（octave）。
    var eqBandwidths: [Float] { eqNode.bands.map(\.bandwidth) }
    /// 各 EQ band 当前增益（dB）。
    var eqGainValues: [Float] { eqNode.bands.map(\.gain) }
    /// 各 EQ band 当前是否被 bypass（0dB 时为 true）。
    var eqBypassValues: [Bool] { eqNode.bands.map(\.bypass) }
    /// TimePitch 当前变调（音分）。
    var currentPitchCents: Float { timePitch.pitch }
    /// TimePitch 当前速率。
    var currentTimePitchRate: Float { timePitch.rate }
    /// 当前已应用的音效设置。
    var appliedEffectSettings: AudioEffectSettings { effectSettings }
    /// 本地播放时记录实际文件路径（远程为缓存文件；开启混响时为处理后的缓存文件）。
    var currentLoadedFileURL: URL? { loadedFileURL }
    /// 主混音器当前 pan（-1…1），3D 环绕测试用。
    var mainMixerPanValue: Float { engine.mainMixerNode.pan }
    /// 环绕 LFO 定时器是否在运行。
    var isPannerTimerRunning: Bool { pannerTimer != nil }
    /// 卷积渲染任务是否在运行。
    var isConvolutionRendering: Bool { convolutionTask != nil }
    /// 当前播放的卷积输出缓存（未启用混响时 nil）。
    var currentProcessedFileURL: URL? { processedFileURL }
    /// 当前原始音频文件（本地路径 / 远程下载缓存）。
    var currentSourceFileURL: URL? { sourceFileURL }
    /// 已应用到 AudioUnit 的输出设备 ID（nil = 默认/尚未应用）。
    var appliedOutputDeviceIDForTesting: AudioDeviceID? { appliedOutputDeviceID }
    /// 频谱 tap 是否已安装（可视化测试用）。
    var isVisualizerTapInstalledForTesting: Bool { isVisualizerTapInstalled }
}
