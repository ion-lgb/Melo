import CoreFoundation
import Foundation
import MeloCore

// MARK: - 下载事件 / 请求

/// 下载过程中回推的事件（与 AppModel / UI 解耦）。
public enum DownloadEvent: Sendable {
    case progress(taskId: String, downloaded: Int64, total: Int64, speed: Double)
    case completed(taskId: String, filePath: String)
    case failed(taskId: String, error: String)
    /// status 使用原版 `DOWNLOAD_STATUS` 词汇：waiting / run / pause / error / completed（另有 removed）
    case statusChanged(taskId: String, status: String)
}

/// 单个下载任务请求。约定：
/// - `fileName` 建议由 `MediaFileName.makeFileName` 生成（含扩展名；引擎也会补齐并过滤非法字符）；
/// - `fileExtension` 用于标签写入分支（mp3 / flac）与任务 id；
/// - `embedPicture` / `embedLyrics` 为 true 时，下载完成后把 `pictureURL` 图片、`lyrics` 歌词写进音频标签。
public struct DownloadRequest: Sendable {
    public var music: MusicInfo
    public var quality: String
    public var url: URL
    public var saveDirectory: URL
    public var fileName: String
    public var fileExtension: String
    public var embedPicture: Bool
    public var embedLyrics: Bool
    public var lyrics: LyricInfo?
    public var pictureURL: URL?

    public init(
        music: MusicInfo,
        quality: String,
        url: URL,
        saveDirectory: URL,
        fileName: String,
        fileExtension: String,
        embedPicture: Bool = false,
        embedLyrics: Bool = false,
        lyrics: LyricInfo? = nil,
        pictureURL: URL? = nil
    ) {
        self.music = music
        self.quality = quality
        self.url = url
        self.saveDirectory = saveDirectory
        self.fileName = fileName
        self.fileExtension = fileExtension
        self.embedPicture = embedPicture
        self.embedLyrics = embedLyrics
        self.lyrics = lyrics
        self.pictureURL = pictureURL
    }
}

// MARK: - 下载引擎

/// 原生下载引擎（对齐原版 `src/common/utils/download/Downloader.ts`）：
/// - `URLSessionDataTask` + `FileHandle` 追加写；
/// - 断点续传：`Range: bytes=<size-10>-`，末尾 10 字节重叠校验，校验失败/416 删除文件重下；
/// - 20s 空闲看门狗（可注入）、最多 3 并发、任务级重试 2 次；
/// - 同名文件（>100 字节）跳过；文件名非法字符过滤/截断；
/// - 下载完成后按需写 MP3/FLAC 标签（标题/歌手/专辑恒写，封面/歌词按请求）。
///
/// 线程模型：引擎本身 `@MainActor`（与 AppModel/UI 一致）；网络数据在独立串行队列落盘，
/// 只把进度/完成事件回投到主线程，避免大文件写盘阻塞 UI。
///
/// 事件顺序约定（AppModel 依赖该顺序在状态变化时写库）：
/// - 成功：`statusChanged("completed")` → `completed`（此前会有一个最终 `progress`）；
/// - 失败：`statusChanged("error")` → `failed`（重试期间会先有 `statusChanged("waiting")`/`("run")`）；
/// - 取消/暂停只发 `statusChanged`，不发终态 `failed`/`completed`。
@MainActor
public final class DownloadEngine {
    // MARK: 对外状态

    public var eventHandler: ((DownloadEvent) -> Void)?

    /// 所有任务（按入队顺序，status/进度实时更新）
    public var tasks: [DownloadTaskInfo] { records.map(makeTaskInfo) }

    // MARK: 内部状态

    private enum Status: String {
        case waiting = "waiting"
        case running = "run"
        case paused = "pause"
        case completed = "completed"
        case failed = "error"
    }

    private enum PendingAction {
        case pause
        case cancel
        case remove
        case timeout
    }

    private final class TaskRecord {
        let id: String
        let request: DownloadRequest
        let destination: URL

        var status: Status = .waiting
        var statusText = "待下载"
        var downloaded: Int64 = 0
        var total: Int64 = 0
        var isCompleted = false
        var attempts = 0
        var retries = 0
        var position = 0
        /// 从磁盘历史恢复的 waiting 任务：不参与自动调度，等用户 resume 后再开始
        var requiresUserResume = false
        var transfer: DownloadTransfer?
        var pendingAction: PendingAction?
        var retryAt: Date?
        var tagInProgress = false
        var lastActivity = Date()
        var lastProgressEmit = Date.distantPast
        /// 最近 2.5s 的 (采样时间, 已下载字节) 滑窗，用于计算 speed/ETA
        var speedSamples: [(time: Date, bytes: Int64)] = []
        var speedBytesPerSecond: Double?
        var etaSeconds: Double?

        init(id: String, request: DownloadRequest, destination: URL) {
            self.id = id
            self.request = request
            self.destination = destination
        }
    }

    private let maxConcurrent: Int
    private let idleTimeout: TimeInterval
    private let retryLimit: Int

    /// 重试前等待（测试可注入为 0）
    internal var retryDelay: TimeInterval = 0.2

    private var records: [TaskRecord] = []
    private var watchdogTimer: Timer?
    /// taskID → 待写入的 .lrc 内容与编码（AppModel 在 enqueue 后调用 setLrcFile 记录）
    private var pendingLrcFiles: [String: (content: String, encoding: String)] = [:]

    // MARK: 初始化

    public convenience init(maxConcurrent: Int = 3) {
        self.init(maxConcurrent: maxConcurrent, idleTimeout: 20, retryLimit: 2)
    }

    internal init(maxConcurrent: Int, idleTimeout: TimeInterval, retryLimit: Int) {
        self.maxConcurrent = max(1, maxConcurrent)
        self.idleTimeout = max(0.1, idleTimeout)
        self.retryLimit = max(0, retryLimit)
    }

    // MARK: - 入队 / 控制

    /// 入队一个下载任务，返回任务 id（`<musicId>_<quality>_<ext>`，与原版一致）。
    /// 相同 id 的任务已存在时直接返回其 id（不重复入队）。
    @discardableResult
    public func enqueue(_ request: DownloadRequest) -> String {
        let normalized = normalize(request)
        let id = "\(normalized.music.id)_\(normalized.quality)_\(normalized.fileExtension)"
        if let existing = records.first(where: { $0.id == id }) { return existing.id }

        let destination = normalized.saveDirectory.appendingPathComponent(normalized.fileName)
        let record = TaskRecord(id: id, request: normalized, destination: destination)
        record.position = records.count
        records.append(record)
        emit(.statusChanged(taskId: id, status: Status.waiting.rawValue))
        pump()
        return id
    }

    /// 暂停：保留已下载的部分文件，`resume` 时从断点继续。
    public func pause(id: String) {
        guard let record = records.first(where: { $0.id == id }) else { return }
        if record.tagInProgress { return } // 写标签阶段很快，忽略暂停
        switch record.status {
        case .running:
            record.pendingAction = .pause
            record.transfer?.stop(preserveFile: true)
        case .waiting:
            record.status = .paused
            record.statusText = "已暂停"
            emit(.statusChanged(taskId: record.id, status: Status.paused.rawValue))
        default:
            break
        }
    }

    /// 继续（暂停后断点续传；失败后重新尝试；重启恢复的 waiting 任务也由此手动启动）。
    public func resume(id: String) {
        guard let record = records.first(where: { $0.id == id }) else { return }
        let restoredWaiting = record.requiresUserResume && record.status == .waiting
        guard record.status == .paused || record.status == .failed || restoredWaiting, !record.isCompleted else { return }
        record.requiresUserResume = false
        record.status = .waiting
        record.statusText = "等待下载"
        record.retries = 0
        record.pendingAction = nil
        record.retryAt = nil
        emit(.statusChanged(taskId: record.id, status: Status.waiting.rawValue))
        pump()
    }

    /// 取消：停止传输并删除未完成的文件，任务保留为 error 状态。
    public func cancel(id: String) {
        guard let record = records.first(where: { $0.id == id }) else { return }
        guard !record.isCompleted else { return }
        if record.tagInProgress {
            record.pendingAction = .cancel
            return
        }
        record.pendingAction = .cancel
        if let transfer = record.transfer {
            transfer.stop(preserveFile: false)
        } else {
            record.pendingAction = nil
            removeFileIfExists(record.destination)
            record.downloaded = 0
            record.status = .failed
            record.statusText = "已取消"
            emit(.statusChanged(taskId: record.id, status: Status.failed.rawValue))
            pump()
        }
    }

    /// 从任务列表移除（下载中会先停止；未完成的文件会被删除）。
    public func remove(id: String) {
        guard let record = records.first(where: { $0.id == id }) else { return }
        if record.tagInProgress {
            record.pendingAction = .remove
            return
        }
        record.pendingAction = .remove
        if let transfer = record.transfer {
            transfer.stop(preserveFile: true)
        } else {
            if !record.isCompleted { removeFileIfExists(record.destination) }
            removeRecord(record)
            pump()
        }
    }

    // MARK: - 重启恢复

    /// 从持久化历史（download_list）恢复未完成任务到内存列表（应用重启时调用）。
    ///
    /// 规则：
    /// - 忽略 `isCompleted` / status == "completed" 的任务（历史只读展示）与同 id 已存在任务；
    /// - 按 `position` 升序追加，任务列表顺序随之稳定；重复调用幂等；
    /// - 文件存在且大小 > 0 → `pause`（可断点续传）；文件缺失/为空 → `waiting`（从头下载）；
    /// - 保留 progress 与全部任务字段，但**不自动开始**（restored waiting 需用户 resume 才进入调度）；
    /// - 内嵌封面/歌词等请求参数未持久化，恢复任务的后续完成只会写标题/歌手/专辑标签。
    public func restore(tasks: [DownloadTaskInfo]) {
        let sorted = tasks
            .filter { task in
                !task.id.isEmpty
                    && !task.isCompleted
                    && task.status != Status.completed.rawValue
            }
            .sorted { lhs, rhs in
                if lhs.position != rhs.position { return lhs.position < rhs.position }
                return lhs.id < rhs.id
            }

        var knownIDs = Set(records.map(\.id))
        for task in sorted {
            guard !knownIDs.contains(task.id) else { continue }
            guard let (request, destination) = makeRestoredTask(from: task) else { continue }
            knownIDs.insert(task.id)

            let record = TaskRecord(id: task.id, request: request, destination: destination)
            record.downloaded = max(0, task.progressDownloaded)
            record.total = max(0, task.progressTotal)
            record.isCompleted = false
            // 历史任务视为「已开始过」：resume 时不要触发「同名文件跳过」，否则会把部分文件当成已完成文件。
            record.attempts = 1
            record.position = records.count
            applyRestoredStatus(to: record)
            records.append(record)
        }
        // 注意：不调用 pump()/updateWatchdog() —— 恢复任务不自动开始下载。
    }

    /// 用持久化信息重建 `DownloadRequest` + 目标文件路径；filePath 为空时无法恢复，返回 nil。
    private func makeRestoredTask(from task: DownloadTaskInfo) -> (DownloadRequest, URL)? {
        let filePath = task.filePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !filePath.isEmpty else { return nil }

        let destination = URL(fileURLWithPath: filePath, isDirectory: false)
        let derivedExtension = URL(fileURLWithPath: filePath).pathExtension.lowercased()
        let fileExtension = task.ext.isEmpty ? derivedExtension : task.ext.lowercased()
        let fileName = task.fileName.isEmpty ? destination.lastPathComponent : task.fileName
        let saveDirectory = destination.deletingLastPathComponent()

        let url: URL
        if let parsed = URL(string: task.url ?? ""), !(task.url ?? "").isEmpty {
            url = parsed
        } else {
            // 历史任务可能没有可用 URL（例如等待取链时退出）：占位 URL，用户 resume 时会明确失败而不是崩溃。
            url = URL(string: "about:blank") ?? URL(fileURLWithPath: filePath)
        }

        let request = DownloadRequest(
            music: task.musicInfo,
            quality: task.quality,
            url: url,
            saveDirectory: saveDirectory,
            fileName: fileName,
            fileExtension: fileExtension,
            embedPicture: false,
            embedLyrics: false,
            lyrics: nil,
            pictureURL: nil
        )
        return (request, destination)
    }

    private func applyRestoredStatus(to record: TaskRecord) {
        let attributes = try? FileManager.default.attributesOfItem(atPath: record.destination.path)
        let fileSize = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        if FileManager.default.fileExists(atPath: record.destination.path), fileSize > 0 {
            record.status = .paused
            record.statusText = "已暂停（恢复自上次运行）"
        } else {
            record.status = .waiting
            record.statusText = "已恢复，等待继续"
            record.requiresUserResume = true
        }
    }

    // MARK: - .lrc 歌词文件

    /// 预约任务完成后写 `.lrc` 文件（AppModel 在 enqueue 后调用；MeloCore `DownloadService.setLrcFile`）。
    ///
    /// - `encoding` 支持 `utf8`（默认，写 UTF-8 BOM）与 `gbk`/`gb2312`/`gb18030`（GB18030 转码，无 BOM）；
    ///   GBK 转码不可用时回退 UTF-8 并记录警告；
    /// - 未知 taskID 仅告警；任务已完成时立即写入；写文件失败只告警，不影响音频下载完成。
    public func setLrcFile(taskID: String, content: String, encoding: String) {
        guard let record = records.first(where: { $0.id == taskID }) else {
            MeloLog.warn("setLrcFile：未知下载任务 \(taskID)，已忽略")
            return
        }
        pendingLrcFiles[taskID] = (content: content, encoding: encoding)
        if record.isCompleted {
            writeLrcFileIfNeeded(record)
        }
    }

    private func writeLrcFileIfNeeded(_ record: TaskRecord) {
        guard let lrc = pendingLrcFiles.removeValue(forKey: record.id) else { return }
        guard !lrc.content.isEmpty else { return }
        let lrcURL = Self.lrcFileURL(for: record.destination)
        do {
            let data = try Self.encodeLrcData(content: lrc.content, encoding: lrc.encoding)
            try data.write(to: lrcURL, options: .atomic)
        } catch {
            MeloLog.warn("保存 .lrc 歌词失败（已忽略）：\(lrcURL.path)：\(error.localizedDescription)")
        }
    }

    private static func lrcFileURL(for audioURL: URL) -> URL {
        audioURL.deletingPathExtension().appendingPathExtension("lrc")
    }

    private static func encodeLrcData(content: String, encoding: String) throws -> Data {
        switch encoding.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "gbk", "gb2312", "gb18030", "cp936":
            if let gbkData = gb18030Data(content) {
                return gbkData
            }
            MeloLog.warn("GBK 转码不可用，回退 UTF-8（带 BOM）：\(encoding)")
            return utf8LrcData(content)
        default:
            return utf8LrcData(content)
        }
    }

    /// 与原版 iconv(utf8, { addBOM: true }) 一致：EF BB BF + UTF-8
    private static func utf8LrcData(_ content: String) -> Data {
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(Data(content.utf8))
        return data
    }

    /// GB18030（兼容 GBK/GB2312）转码；转码失败返回 nil 由调用方回退。
    private static func gb18030Data(_ content: String) -> Data? {
        let cfEncoding = CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        guard let cfData = CFStringCreateExternalRepresentation(
            kCFAllocatorDefault,
            content as CFString,
            cfEncoding,
            0
        ) else {
            return nil
        }
        return cfData as Data
    }

    // MARK: - 调度

    private var activeCount: Int {
        records.reduce(0) { $0 + ($1.transfer == nil ? 0 : 1) }
    }

    private func pump() {
        while activeCount < maxConcurrent {
            let now = Date()
            guard let record = records.first(where: { candidate in
                guard candidate.status == .waiting, candidate.transfer == nil,
                      !candidate.tagInProgress, !candidate.requiresUserResume else { return false }
                if let retryAt = candidate.retryAt, retryAt > now { return false }
                return true
            }) else { break }
            start(record)
        }
        updateWatchdog()
    }

    private func start(_ record: TaskRecord) {
        let isFirstAttempt = record.attempts == 0
        record.attempts += 1
        record.retryAt = nil
        record.status = .running
        record.statusText = "下载中"
        record.lastActivity = Date()
        record.lastProgressEmit = .distantPast
        clearSpeedEstimate(record)
        emit(.statusChanged(taskId: record.id, status: Status.running.rawValue))

        let transfer = DownloadTransfer(
            request: record.request,
            destination: record.destination,
            skipsExistingFile: isFirstAttempt,
            onProgress: { [weak self, weak record] downloaded, total, speed in
                Task { @MainActor in
                    guard let self, let record else { return }
                    self.handleProgress(record, downloaded: downloaded, total: total, speed: speed)
                }
            },
            onFinished: { [weak self, weak record] outcome in
                Task { @MainActor in
                    guard let self, let record else { return }
                    self.handleFinished(record, outcome: outcome)
                }
            }
        )
        record.transfer = transfer
        transfer.start()
    }

    private func handleProgress(_ record: TaskRecord, downloaded: Int64, total: Int64, speed: Double) {
        guard record.status == .running, record.transfer != nil else { return }
        record.downloaded = downloaded
        record.total = total
        record.lastActivity = Date()
        updateSpeedEstimate(record, downloaded: downloaded, total: total)
        let now = Date()
        guard downloaded >= total || now.timeIntervalSince(record.lastProgressEmit) >= 0.2 else { return }
        record.lastProgressEmit = now
        emit(.progress(
            taskId: record.id,
            downloaded: downloaded,
            total: total,
            speed: record.speedBytesPerSecond ?? speed
        ))
    }

    /// 2.5s 滑动窗口估算下载速度与剩余时间（ETA）；采样不足时保持 nil。
    private func updateSpeedEstimate(_ record: TaskRecord, downloaded: Int64, total: Int64) {
        let now = Date()
        record.speedSamples.append((now, downloaded))
        let window: TimeInterval = 2.5
        while let first = record.speedSamples.first, now.timeIntervalSince(first.time) > window {
            record.speedSamples.removeFirst()
        }
        guard let first = record.speedSamples.first else { return }
        let elapsed = now.timeIntervalSince(first.time)
        let bytes = downloaded - first.bytes
        guard elapsed >= 0.4, bytes > 0 else { return }
        let currentSpeed = Double(bytes) / elapsed
        guard currentSpeed > 0 else { return }
        record.speedBytesPerSecond = currentSpeed
        record.etaSeconds = total > downloaded ? Double(total - downloaded) / currentSpeed : nil
    }

    private func clearSpeedEstimate(_ record: TaskRecord) {
        record.speedSamples.removeAll()
        record.speedBytesPerSecond = nil
        record.etaSeconds = nil
    }

    private func handleFinished(_ record: TaskRecord, outcome: DownloadTransfer.Outcome) {
        guard records.contains(where: { $0 === record }) else { return }
        let action = record.pendingAction
        record.pendingAction = nil
        record.transfer = nil
        clearSpeedEstimate(record)

        if let action {
            switch action {
            case .pause:
                record.status = .paused
                record.statusText = "已暂停"
                emit(.statusChanged(taskId: record.id, status: Status.paused.rawValue))
            case .cancel:
                removeFileIfExists(record.destination)
                record.downloaded = 0
                record.status = .failed
                record.statusText = "已取消"
                emit(.statusChanged(taskId: record.id, status: Status.failed.rawValue))
            case .remove:
                removeFileIfExists(record.destination)
                removeRecord(record)
            case .timeout:
                retryOrFail(record, errorMessage: "下载超时（\(Int(idleTimeout)) 秒无数据）")
            }
            pump()
            return
        }

        switch outcome {
        case .completed(let total):
            record.downloaded = total
            record.total = total
            record.lastActivity = Date()
            emit(.progress(taskId: record.id, downloaded: total, total: total, speed: 0))
            finalizeCompleted(record)
            return
        case .skippedExisting:
            record.status = .failed
            record.statusText = "存在同名文件，跳过下载"
            emit(.statusChanged(taskId: record.id, status: Status.failed.rawValue))
            emit(.failed(taskId: record.id, error: "存在同名文件，跳过下载"))
        case .failed(let message):
            retryOrFail(record, errorMessage: message)
        case .needsRestart(let message):
            removeFileIfExists(record.destination)
            record.downloaded = 0
            record.total = 0
            retryOrFail(record, errorMessage: message)
        case .stopped:
            break
        }
        pump()
    }

    private func retryOrFail(_ record: TaskRecord, errorMessage: String) {
        record.retries += 1
        guard record.retries <= retryLimit else {
            record.status = .failed
            record.statusText = "下载失败"
            // 0 字节文件没有续传价值，失败后删除，避免用户目录里留下同名空文件；
            // 已有数据的部分文件保留，等待用户 resume/retry 时断点续传。
            removeZeroByteFileIfNeeded(at: record.destination)
            emit(.statusChanged(taskId: record.id, status: Status.failed.rawValue))
            emit(.failed(taskId: record.id, error: errorMessage))
            return
        }
        record.status = .waiting
        record.statusText = "重试中（\(record.retries)/\(retryLimit)）"
        emit(.statusChanged(taskId: record.id, status: Status.waiting.rawValue))
        let delay = retryDelay
        if delay > 0 {
            record.retryAt = Date().addingTimeInterval(delay)
            Task { @MainActor [weak self, weak record] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard let self, let record else { return }
                record.retryAt = nil
                self.pump()
            }
        }
    }

    // MARK: - 完成（写标签）

    private func finalizeCompleted(_ record: TaskRecord) {
        guard records.contains(where: { $0 === record }) else { return }
        record.tagInProgress = true
        let pictureURL = record.request.embedPicture ? record.request.pictureURL : nil
        if let pictureURL {
            Task { @MainActor [weak self, weak record] in
                var artwork: Data?
                if let (data, _) = try? await URLSession.shared.data(from: pictureURL) {
                    artwork = data
                }
                guard let self, let record else { return }
                self.finishCompleted(record, artwork: artwork)
            }
        } else {
            finishCompleted(record, artwork: nil)
        }
    }

    private func finishCompleted(_ record: TaskRecord, artwork: Data?) {
        guard records.contains(where: { $0 === record }), record.status == .running else { return }
        if let action = record.pendingAction {
            record.pendingAction = nil
            record.tagInProgress = false
            switch action {
            case .cancel:
                removeFileIfExists(record.destination)
                record.downloaded = 0
                record.status = .failed
                record.statusText = "已取消"
                emit(.statusChanged(taskId: record.id, status: Status.failed.rawValue))
            case .remove:
                removeFileIfExists(record.destination)
                removeRecord(record)
            case .pause, .timeout:
                break
            }
            pump()
            return
        }
        let request = record.request
        let fileExtension = request.fileExtension.lowercased()
        if fileExtension == "mp3" || fileExtension == "flac" {
            let music = request.music
            let artist = music.singer.replacingOccurrences(of: "、", with: ";")
            let album = music.albumName.isEmpty ? nil : music.albumName
            let lyrics = request.embedLyrics ? request.lyrics?.lyric : nil
            do {
                if fileExtension == "mp3" {
                    try MediaTagWriter.writeMP3Tags(
                        path: record.destination.path,
                        title: music.name,
                        artist: artist,
                        album: album,
                        lyrics: lyrics,
                        artwork: artwork
                    )
                } else {
                    try MediaTagWriter.writeFLACTags(
                        path: record.destination.path,
                        title: music.name,
                        artist: artist,
                        album: album,
                        lyrics: lyrics,
                        artwork: artwork
                    )
                }
            } catch {
                MeloLog.warn("下载完成但写入媒体标签失败：\(error.localizedDescription)")
            }
        }

        // 标签写入完成后落盘 .lrc 歌词文件（AppModel 通过 setLrcFile 预约）；失败只告警，不影响下载完成
        writeLrcFileIfNeeded(record)

        record.tagInProgress = false
        record.isCompleted = true
        record.status = .completed
        record.statusText = "已完成"
        record.downloaded = record.total
        emit(.progress(taskId: record.id, downloaded: record.total, total: record.total, speed: 0))
        emit(.statusChanged(taskId: record.id, status: Status.completed.rawValue))
        emit(.completed(taskId: record.id, filePath: record.destination.path))
        pump()
    }

    // MARK: - 看门狗

    private func updateWatchdog() {
        let hasActive = records.contains { $0.transfer != nil }
        guard hasActive else {
            watchdogTimer?.invalidate()
            watchdogTimer = nil
            return
        }
        guard watchdogTimer == nil else { return }
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkIdleTasks() }
        }
    }

    private func checkIdleTasks() {
        let now = Date()
        for record in records {
            guard let transfer = record.transfer, record.status == .running else { continue }
            if now.timeIntervalSince(record.lastActivity) >= idleTimeout {
                record.pendingAction = .timeout
                transfer.stop(preserveFile: true)
            }
        }
        updateWatchdog()
    }

    // MARK: - 工具

    private func normalize(_ request: DownloadRequest) -> DownloadRequest {
        var result = request
        var fileExtension = result.fileExtension.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if fileExtension.hasPrefix(".") { fileExtension.removeFirst() }
        if fileExtension.isEmpty { fileExtension = result.url.pathExtension.lowercased() }
        if fileExtension.isEmpty { fileExtension = "mp3" }
        result.fileExtension = fileExtension

        var fileName = result.fileName
        if fileName.isEmpty {
            fileName = MediaFileName.makeFileName(template: "歌名 - 歌手", music: result.music, ext: fileExtension)
        } else {
            fileName = MediaFileName.sanitizeFileName(fileName)
        }
        let suffix = ".\(fileExtension)"
        if !fileName.lowercased().hasSuffix(suffix) {
            if fileName.count > 150 { fileName = String(fileName.prefix(150)) }
            fileName += suffix
        }
        setNonEmptyFileName(&result, fileName)
        return result
    }

    private func setNonEmptyFileName(_ request: inout DownloadRequest, _ fileName: String) {
        var candidate = fileName
        if candidate.isEmpty || candidate == ".\(request.fileExtension)" {
            candidate = "\(request.music.id.isEmpty ? "music" : request.music.id).\(request.fileExtension)"
        }
        request.fileName = candidate
    }

    private func makeTaskInfo(_ record: TaskRecord) -> DownloadTaskInfo {
        DownloadTaskInfo(
            id: record.id,
            isCompleted: record.isCompleted,
            status: record.status.rawValue,
            statusText: record.statusText,
            progressDownloaded: record.downloaded,
            progressTotal: record.total,
            url: record.request.url.absoluteString,
            quality: record.request.quality,
            ext: record.request.fileExtension,
            fileName: record.request.fileName,
            filePath: record.destination.path,
            musicInfo: record.request.music,
            position: record.position,
            speedBytesPerSecond: record.speedBytesPerSecond,
            etaSeconds: record.etaSeconds
        )
    }

    private func removeRecord(_ record: TaskRecord) {
        guard let index = records.firstIndex(where: { $0 === record }) else { return }
        pendingLrcFiles.removeValue(forKey: record.id)
        records.remove(at: index)
        for (position, item) in records.enumerated() { item.position = position }
        emit(.statusChanged(taskId: record.id, status: "removed"))
    }

    private func removeFileIfExists(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// 仅当文件存在且大小为 0 时删除；非 0 字节的部分下载保留用于断点续传。
    private func removeZeroByteFileIfNeeded(at url: URL) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let fileSize = (attributes[.size] as? NSNumber)?.int64Value,
              fileSize == 0 else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private func emit(_ event: DownloadEvent) {
        eventHandler?(event)
    }
}

// MARK: - 单任务传输（URLSessionDataDelegate，串行队列落盘）

/// 每个任务一个 URLSession（最多 3 个并发，成本可接受），delegate 回调在自己的串行队列，
/// 文件写入与重叠校验都在该队列完成；进度/完成通过闭包回投主线程。
final class DownloadTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    enum Outcome {
        case completed(total: Int64)
        case skippedExisting
        case failed(String)
        case needsRestart(String)
        case stopped
    }

    let request: DownloadRequest
    private let destination: URL
    private let skipsExistingFile: Bool
    private let onProgress: (Int64, Int64, Double) -> Void
    private let onFinished: (Outcome) -> Void

    private let lock = NSLock()
    private let delegateQueue: OperationQueue
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var fileHandle: FileHandle?
    private var downloaded: Int64 = 0
    private var total: Int64 = 0
    private var resumeOverlap: Data?
    private var pendingOverlapBytes = 0
    private var resumeStart: Int64 = 0
    private var isResuming = false
    private var finished = false
    private var stopRequested = false
    private var preserveFileOnStop = true
    private var lastSpeedTime = Date()
    private var lastSpeedBytes: Int64 = 0
    private var lastProgressReport = Date.distantPast

    init(
        request: DownloadRequest,
        destination: URL,
        skipsExistingFile: Bool,
        onProgress: @escaping (Int64, Int64, Double) -> Void,
        onFinished: @escaping (Outcome) -> Void
    ) {
        self.request = request
        self.destination = destination
        self.skipsExistingFile = skipsExistingFile
        self.onProgress = onProgress
        self.onFinished = onFinished
        let queue = OperationQueue()
        queue.name = "cn.melo.download.transfer"
        queue.maxConcurrentOperationCount = 1
        self.delegateQueue = queue
        super.init()
    }

    // MARK: 启动

    func start() {
        do {
            guard try prepareForDownload() else { return }
            lock.lock()
            let shouldStop = stopRequested
            let resuming = isResuming
            let startOffset = resumeStart
            lock.unlock()
            guard !shouldStop else {
                finish(.stopped)
                return
            }

            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 60
            configuration.timeoutIntervalForResource = 3600
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
            var urlRequest = URLRequest(url: request.url)
            urlRequest.httpMethod = "GET"
            urlRequest.setValue(
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36",
                forHTTPHeaderField: "User-Agent"
            )
            if resuming {
                urlRequest.setValue("bytes=\(startOffset)-", forHTTPHeaderField: "Range")
            }
            lock.lock()
            self.session = session
            lock.unlock()
            let dataTask = session.dataTask(with: urlRequest)
            lock.lock()
            self.task = dataTask
            lock.unlock()
            reportProgress(force: true)
            dataTask.resume()
        } catch {
            finish(.failed("下载初始化失败：\(error.localizedDescription)"))
        }
    }

    /// 准备目标文件：首次下载时做同名跳过检查；有部分文件时读取末尾 10 字节作为续传校验数据。
    /// 返回 false 表示已经结束（例如同名跳过），无需发起请求。
    private func prepareForDownload() throws -> Bool {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

        let attributes = try? fileManager.attributesOfItem(atPath: destination.path)
        let existingSize = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        if skipsExistingFile && existingSize > 100 {
            finish(.skippedExisting)
            return false
        }

        if existingSize >= 10 {
            let reader = try FileHandle(forReadingFrom: destination)
            try reader.seek(toOffset: UInt64(existingSize - 10))
            let lastBytes = try reader.read(upToCount: 10) ?? Data()
            try reader.close()
            if lastBytes.count == 10 {
                let writer = try FileHandle(forWritingTo: destination)
                try writer.seekToEnd()
                lock.lock()
                resumeOverlap = lastBytes
                pendingOverlapBytes = lastBytes.count
                resumeStart = existingSize - 10
                isResuming = true
                downloaded = existingSize
                fileHandle = writer
                lock.unlock()
                return true
            }
        }

        if fileManager.fileExists(atPath: destination.path) {
            try? fileManager.removeItem(at: destination)
        }
        guard fileManager.createFile(atPath: destination.path, contents: nil) else {
            throw NSError(
                domain: "MeloDownload",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "无法创建下载文件：\(destination.path)"]
            )
        }
        let writer = try FileHandle(forWritingTo: destination)
        lock.lock()
        isResuming = false
        downloaded = 0
        fileHandle = writer
        lock.unlock()
        return true
    }

    // MARK: 停止

    /// `preserveFile = true` 时保留已下载部分（暂停/超时后续传）；false 时删除目标文件（取消/重下）。
    func stop(preserveFile: Bool) {
        lock.lock()
        if finished {
            lock.unlock()
            return
        }
        stopRequested = true
        preserveFileOnStop = preserveFile
        let task = self.task
        lock.unlock()
        if let task {
            task.cancel()
        } else {
            finish(.stopped)
        }
    }

    // MARK: URLSessionDataDelegate

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        if statusCode == 416 {
            finish(.needsRestart("服务器拒绝断点续传（416）"))
            completionHandler(.cancel)
            return
        }
        guard statusCode == 200 || statusCode == 206 else {
            finish(.failed("HTTP 状态码 \(statusCode)"))
            completionHandler(.cancel)
            return
        }

        lock.lock()
        let resuming = isResuming
        let existingDownloaded = downloaded
        lock.unlock()

        if resuming && statusCode == 200 {
            finish(.needsRestart("服务器不支持断点续传"))
            completionHandler(.cancel)
            return
        }

        let contentLength = response.expectedContentLength
        guard contentLength > 0 else {
            finish(.failed("无法获取文件大小"))
            completionHandler(.cancel)
            return
        }
        let expectedTotal: Int64
        if statusCode == 206 && resuming {
            expectedTotal = (existingDownloaded - 10) + contentLength
        } else if statusCode == 206 {
            expectedTotal = contentLength
        } else {
            expectedTotal = contentLength
        }
        lock.lock()
        total = expectedTotal
        lock.unlock()
        reportProgress(force: true)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !data.isEmpty else { return }
        var chunk = data

        lock.lock()
        if pendingOverlapBytes > 0, let overlap = resumeOverlap {
            let need = min(pendingOverlapBytes, chunk.count)
            let consumed = overlap.count - pendingOverlapBytes
            let expected = overlap.subdata(in: consumed..<(consumed + need))
            let actual = Data(chunk.prefix(need))
            guard actual == expected else {
                lock.unlock()
                finish(.needsRestart("续传数据校验失败"))
                return
            }
            pendingOverlapBytes -= need
            chunk = Data(chunk.dropFirst(need))
            if chunk.isEmpty {
                lock.unlock()
                return
            }
        }
        let handle = fileHandle
        lock.unlock()
        guard let handle else { return }

        do {
            try handle.write(contentsOf: chunk)
        } catch {
            finish(.failed("写入文件失败：\(error.localizedDescription)"))
            return
        }
        lock.lock()
        downloaded += Int64(chunk.count)
        lock.unlock()
        reportProgress(force: false)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        if finished {
            lock.unlock()
            return
        }
        finished = true
        let handle = fileHandle
        fileHandle = nil
        let wasStopped = stopRequested
        let preserve = preserveFileOnStop
        let currentDownloaded = downloaded
        let currentTotal = total
        lock.unlock()

        try? handle?.close()
        session.invalidateAndCancel()

        if wasStopped {
            if !preserve {
                try? FileManager.default.removeItem(at: destination)
            }
            onFinished(.stopped)
            return
        }
        if let error {
            onFinished(.failed(error.localizedDescription))
            return
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: destination.path)
        let fileSize = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        if currentTotal > 0, currentDownloaded >= currentTotal, fileSize == currentTotal {
            onFinished(.completed(total: currentTotal))
        } else if currentTotal == 0 {
            onFinished(.failed("无法获取文件大小"))
        } else {
            onFinished(.needsRestart("下载不完整"))
        }
    }

    // MARK: 内部

    private func finish(_ outcome: Outcome) {
        lock.lock()
        if finished {
            lock.unlock()
            return
        }
        finished = true
        let handle = fileHandle
        fileHandle = nil
        let session = self.session
        let task = self.task
        lock.unlock()

        try? handle?.close()
        task?.cancel()
        session?.invalidateAndCancel()
        onFinished(outcome)
    }

    private func reportProgress(force: Bool) {
        lock.lock()
        let downloadedValue = downloaded
        let totalValue = total
        lock.unlock()
        guard totalValue > 0 else { return }
        let now = Date()
        let isFinal = downloadedValue >= totalValue
        lock.lock()
        let elapsed = now.timeIntervalSince(lastProgressReport)
        guard force || isFinal || elapsed >= 0.25 else {
            lock.unlock()
            return
        }
        lastProgressReport = now
        var speed: Double = 0
        let speedElapsed = now.timeIntervalSince(lastSpeedTime)
        if speedElapsed > 0.05 {
            speed = Double(downloadedValue - lastSpeedBytes) / speedElapsed
            lastSpeedBytes = downloadedValue
            lastSpeedTime = now
        }
        lock.unlock()
        onProgress(downloadedValue, totalValue, speed)
    }
}
