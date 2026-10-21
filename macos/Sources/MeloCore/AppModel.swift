import Foundation
import Observation

/// 应用根状态：持有各服务、UI 状态与业务动作。
/// UI 仅依赖本类型（及其引用的 MeloCore 模型），具体服务实现由 MeloApp 装配。
@MainActor
@Observable
public final class AppModel {
    // MARK: - 服务

    public let settings: SettingsStore
    public let theme: ThemeManager
    public let localizer: Localizer
    public let data: DataService
    public let player: PlayerService
    public let customSources: CustomSourceService
    public let metadata: MetadataService
    public let downloads: DownloadService
    public let backup: BackupService
    private let openAPI: OpenAPIServing?
    private let cacheManager: CacheManaging?
    private let appData: AppDataStore?
    public private(set) var hotKeys: HotKeyConfigAll = HotKeyStore.defaultConfig

    // MARK: - 应用数据 / 列表更新 / 定时暂停

    public private(set) var listUpdateInfo: [String: ListUpdateInfo] = [:]
    public private(set) var updatingListIds: Set<String> = []
    public private(set) var dislikeRules = DislikeRules()
    public private(set) var lastPlayInfo: PlayInfoSnapshot?
    public private(set) var playTimeoutRemaining: TimeInterval?
    public private(set) var playTimeoutWaitsForSongEnd = false
    private var playTimeoutTask: Task<Void, Never>?
    private var lastSavedPlayTime: TimeInterval = -1
    private var consecutivePlaybackErrors = 0

    // MARK: - 导航

    public var route: AppRoute = .myList(listId: ListIDs.default)
    public var isShowingPlayDetail: Bool = false
    public var isShowingSettings: Bool { route == .settings }

    // MARK: - 曲库

    public private(set) var userLists: [ListInfo] = []
    public private(set) var musicCounts: [String: Int] = [:]
    public private(set) var currentMusics: [MusicInfo] = []
    public private(set) var loveMusicIDs: Set<String> = []
    public var selectedListId: String = ListIDs.default
    public private(set) var libraryError: String?

    // MARK: - 播放器镜像状态

    public private(set) var playerStatus: PlayerStatus = .stopped
    public private(set) var currentMusic: MusicInfo?
    public private(set) var currentTime: TimeInterval = 0
    public private(set) var duration: TimeInterval = 0
    public private(set) var volume: Double
    public private(set) var isMuted: Bool
    public private(set) var playbackRate: Double
    public private(set) var playQueue: [MusicInfo] = []
    public private(set) var playQueueIndex: Int = 0
    public private(set) var isResolvingMusic: Bool = false
    public private(set) var playbackError: String?

    // MARK: - 歌词

    public private(set) var lyric: LyricInfo = LyricInfo()
    public private(set) var lyricDocument: LyricDocument = .empty
    public private(set) var currentLyricIndex: Int?
    public private(set) var isLoadingLyric = false
    public private(set) var comments: [CommentInfo] = []
    public private(set) var hotComments: [CommentInfo] = []
    public private(set) var commentsTotal = 0
    public private(set) var commentsPage = 0
    public private(set) var commentsMaxPage = 0
    public private(set) var isLoadingComments = false
    public private(set) var commentsError: String?
    public private(set) var commentsMusicId: String?

    // MARK: - 自定义源

    public private(set) var sources: [UserSourceInfo] = []
    public private(set) var isImportingSource = false
    public private(set) var sourceStatus: SourceRuntimeStatus = .idle
    public private(set) var activeSourceId: String?
    public private(set) var activeCapabilities: [SourceCapability] = []
    public private(set) var isSwitchingSource = false
    public private(set) var sourceLogs: [String] = []

    // MARK: - 提示 / 启动

    public private(set) var toastMessage: String?
    public private(set) var isBootstrapped = false
    public private(set) var bootstrapError: String?
    private var toastTask: Task<Void, Never>?

    public init(settings: SettingsStore,
                theme: ThemeManager,
                localizer: Localizer,
                data: DataService,
                player: PlayerService,
                customSources: CustomSourceService,
                metadata: MetadataService,
                downloads: DownloadService,
                openAPI: OpenAPIServing? = nil,
                cache: CacheManaging? = nil,
                appData: AppDataStore? = nil) {
        self.settings = settings
        self.theme = theme
        self.localizer = localizer
        self.data = data
        self.player = player
        self.customSources = customSources
        self.metadata = metadata
        self.downloads = downloads
        self.backup = BackupService(data: data, settings: settings)
        self.openAPI = openAPI
        self.cacheManager = cache
        self.appData = appData
        self.hotKeys = HotKeyStore.load(from: data.dataDirectory)
        self.volume = settings.double(SettingKeys.playerVolume, default: 1)
        self.isMuted = settings.bool(SettingKeys.playerMute)
        self.playbackRate = settings.double(SettingKeys.playbackRate, default: 1)
    }

    // MARK: - 启动

    public func bootstrap() {
        guard !isBootstrapped else { return }
        do {
            try data.bootstrap()
        } catch {
            bootstrapError = error.localizedDescription
            MeloLog.error("数据库初始化失败: \(error.localizedDescription)")
        }

        player.eventHandler = { [weak self] event in
            Task { @MainActor in self?.handlePlayerEvent(event) }
        }
        customSources.eventHandler = { [weak self] event in
            Task { @MainActor in self?.handleSourceEvent(event) }
        }

        player.volume = volume
        player.isMuted = isMuted
        player.playbackRate = playbackRate
        player.onNextRequested = { [weak self] in Task { @MainActor in self?.next() } }
        player.onPreviousRequested = { [weak self] in Task { @MainActor in self?.previous() } }
        downloads.onTasksChanged = { [weak self] in
            Task { @MainActor in self?.refreshDownloadTasks() }
        }
        refreshDownloadTasks()
        applyAudioEffects()

        refreshLibrary()
        reloadSources()
        reloadDislikes()
        applyProxySettings()
        loadDownloadHistory()
        downloads.restore(tasks: downloadHistory.filter { !$0.isCompleted })
        refreshDownloadTasks()
        restoreLastPlayInfo()
        loadListUpdateInfo()
        restartOpenAPI()
        refreshCacheInfo()
        NotificationCenter.default.post(name: .meloHotKeysChanged, object: nil)
        builtinSources = metadata.sources
        Task { @MainActor in
            do {
                try await metadata.prepare()
                metadataReady = metadata.isReady
                builtinSources = metadata.sources
                await loadHotSearch()
                if self.settings.bool(SettingKeys.startupAutoPlay) {
                    await self.startupPlayback()
                }
                await self.autoUpdateSourceLists()
            } catch {
                metadataError = error.localizedDescription
                MeloLog.warn("内置音源初始化失败: \(error.localizedDescription)")
            }
        }

        // 与原版一致：启动时自动激活上次选中的自定义源
        if let api = settings.string(SettingKeys.apiSource), api.hasPrefix("user_api_"),
           sources.contains(where: { $0.id == api }) {
            Task { @MainActor in await self.activateSource(id: api) }
        }
        isBootstrapped = true
    }

    public func refreshLibrary() {
        do {
            userLists = try data.loadUserLists()
            musicCounts = try data.loadMusicCounts()
            loveMusicIDs = Set(try data.loadMusics(listId: ListIDs.love).map(\.id))
            libraryError = nil
        } catch {
            libraryError = error.localizedDescription
            MeloLog.error("加载曲库失败: \(error.localizedDescription)")
        }
        if !allLists.contains(where: { $0.id == selectedListId }) {
            selectedListId = ListIDs.default
        }
        loadMusicsForSelectedList()
    }

    public var allLists: [ListInfo] {
        ListIDs.builtin + userLists
    }

    public func listName(_ id: String) -> String {
        allLists.first { $0.id == id }?.name ?? ListIDs.defaultName(id)
    }

    public func selectList(_ id: String) {
        selectedListId = id
        route = .myList(listId: id)
        loadMusicsForSelectedList()
    }

    public func loadMusicsForSelectedList() {
        do {
            currentMusics = try data.loadMusics(listId: selectedListId)
        } catch {
            currentMusics = []
            MeloLog.error("加载列表歌曲失败: \(error.localizedDescription)")
        }
    }

    public func createList(name: String) {
        do {
            let info = try data.createList(name: name)
            refreshLibrary()
            selectList(info.id)
            showToast("已创建列表「\(name)」")
        } catch {
            showToast("创建列表失败：\(error.localizedDescription)")
        }
    }

    public func renameList(id: String, name: String) {
        do {
            try data.renameList(id: id, name: name)
            refreshLibrary()
        } catch {
            showToast("重命名失败：\(error.localizedDescription)")
        }
    }

    /// 上移/下移用户列表（侧边栏右键菜单用）
    public func moveUserList(id: String, direction: Int) {
        guard let index = userLists.firstIndex(where: { $0.id == id }) else { return }
        let target = index + direction
        guard userLists.indices.contains(target) else { return }
        var lists = userLists
        let item = lists.remove(at: index)
        lists.insert(item, at: target)
        do {
            for (position, list) in lists.enumerated() {
                try data.updateListPosition(id: list.id, position: position)
            }
            refreshLibrary()
        } catch {
            showToast("调整顺序失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 列表排序 / 复制（对齐原版 ListSortModal）

    public func sortList(id: String? = nil, field: MusicSortField, direction: MusicSortDirection) {
        let target = id ?? selectedListId
        do {
            var musics = try data.loadMusics(listId: target)
            guard !musics.isEmpty else {
                showToast("列表为空，无需排序")
                return
            }
            if direction == .random {
                musics.shuffle()
            } else {
                musics.sort { lhs, rhs in
                    compareMusic(lhs, rhs, field: field, ascending: direction == .up)
                }
            }
            try data.updateMusicOrder(in: target, orderedMusicIDs: musics.map(\.id))
            if target == selectedListId { loadMusicsForSelectedList() }
            showToast("已按「\(field.label)·\(direction.label)」排序")
        } catch {
            showToast("排序失败：\(error.localizedDescription)")
        }
    }

    private func compareMusic(_ lhs: MusicInfo, _ rhs: MusicInfo, field: MusicSortField, ascending: Bool) -> Bool {
        func less<T: Comparable>(_ a: T?, _ b: T?) -> Bool {
            switch (a, b) {
            case let (a?, b?):
                return ascending ? a < b : a > b
            case (nil, .some):
                return false
            case (.some, nil):
                return true
            default:
                return false
            }
        }
        switch field {
        case .name, .singer, .source:
            let lhsValue = field == .name ? lhs.name : (field == .singer ? lhs.singer : lhs.source)
            let rhsValue = field == .name ? rhs.name : (field == .singer ? rhs.singer : rhs.source)
            let result = lhsValue.localizedStandardCompare(rhsValue)
            return ascending ? result == .orderedAscending : result == .orderedDescending
        case .albumName:
            let result = lhs.albumName.localizedStandardCompare(rhs.albumName)
            return ascending ? result == .orderedAscending : result == .orderedDescending
        case .interval:
            return less(MeloUtils.parseInterval(lhs.interval), MeloUtils.parseInterval(rhs.interval))
        }
    }

    public func duplicateList(id: String, name: String? = nil) {
        do {
            let musics = try data.loadMusics(listId: id)
            let sourceList = userLists.first { $0.id == id }
            let baseName = sourceList?.name ?? "列表"
            let newName = name ?? "\(baseName) 副本"
            let info = try data.createList(name: newName)
            if !musics.isEmpty {
                try data.overwriteList(listId: info.id, musics: musics)
            }
            refreshLibrary()
            selectList(info.id)
            showToast("已复制列表「\(newName)」（\(musics.count) 首）")
        } catch {
            showToast("复制列表失败：\(error.localizedDescription)")
        }
    }

    public func removeList(id: String) {
        guard !ListIDs.isBuiltin(id) else { return }
        do {
            try data.removeList(id: id)
            if selectedListId == id { selectedListId = ListIDs.default }
            refreshLibrary()
            loadMusicsForSelectedList()
        } catch {
            showToast("删除列表失败：\(error.localizedDescription)")
        }
    }

    public func addMusic(_ music: MusicInfo, to listId: String? = nil) {
        let target = listId ?? (ListIDs.isBuiltin(selectedListId) ? ListIDs.default : selectedListId)
        do {
            try data.addMusic(music, to: target, location: .bottom)
            refreshLibrary()
            showToast("已添加到「\(listName(target))」")
        } catch {
            showToast("添加失败：\(error.localizedDescription)")
        }
    }

    public func addMusics(_ musics: [MusicInfo], to listId: String? = nil) {
        let target = listId ?? (ListIDs.isBuiltin(selectedListId) ? ListIDs.default : selectedListId)
        var added = 0
        do {
            for music in musics {
                try data.addMusic(music, to: target, location: .bottom)
                added += 1
            }
            refreshLibrary()
            showToast("已添加 \(added) 首到「\(listName(target))」")
        } catch {
            showToast("添加失败：\(error.localizedDescription)")
        }
    }

    public func removeMusics(ids: [String], from listId: String? = nil) {
        let target = listId ?? selectedListId
        guard !ids.isEmpty else { return }
        do {
            try data.removeMusic(ids: ids, from: target)
            if target == selectedListId { loadMusicsForSelectedList() }
            refreshLibrary()
            showToast("已移除 \(ids.count) 首")
        } catch {
            showToast("移除失败：\(error.localizedDescription)")
        }
    }

    /// 拖拽排序：把当前选中列表中的 `source` 位置集合移动到 `destination`
    public func moveMusics(in listId: String? = nil, fromOffsets source: IndexSet, toOffset destination: Int) {
        let target = listId ?? selectedListId
        guard target == selectedListId else { return }
        var musics = currentMusics
        let moving = source.sorted().compactMap { index in musics.indices.contains(index) ? musics[index] : nil }
        guard moving.count == source.count, !moving.isEmpty else { return }
        for index in source.sorted(by: >) where musics.indices.contains(index) {
            musics.remove(at: index)
        }
        let adjusted = destination - source.filter { $0 < destination }.count
        let insertIndex = min(max(adjusted, 0), musics.count)
        musics.insert(contentsOf: moving, at: insertIndex)
        do {
            try data.updateMusicOrder(in: target, orderedMusicIDs: musics.map(\.id))
            currentMusics = musics
            loadMusicsForSelectedList()
        } catch {
            showToast("排序失败：\(error.localizedDescription)")
        }
    }

    public func removeMusic(_ music: MusicInfo, from listId: String? = nil) {
        let target = listId ?? selectedListId
        do {
            try data.removeMusic(ids: [music.id], from: target)
            if target == selectedListId { loadMusicsForSelectedList() }
            refreshLibrary()
        } catch {
            showToast("删除失败：\(error.localizedDescription)")
        }
    }

    public func isFavorite(_ music: MusicInfo) -> Bool {
        loveMusicIDs.contains(music.id)
    }

    public func toggleFavorite(_ music: MusicInfo) {
        if isFavorite(music) {
            do {
                try data.removeMusic(ids: [music.id], from: ListIDs.love)
                loveMusicIDs.remove(music.id)
            } catch { showToast("操作失败：\(error.localizedDescription)") }
        } else {
            do {
                try data.addMusic(music, to: ListIDs.love, location: .top)
                loveMusicIDs.insert(music.id)
            } catch { showToast("操作失败：\(error.localizedDescription)") }
        }
        refreshLibrary()
    }

    // MARK: - 播放

    public var isPlaying: Bool { playerStatus == .playing }
    public var progressFraction: Double {
        guard duration > 0 else { return 0 }
        return min(max(currentTime / duration, 0), 1)
    }

    public var currentLyricLine: LyricLine? {
        guard let index = currentLyricIndex, lyricDocument.lines.indices.contains(index) else { return nil }
        return lyricDocument.lines[index]
    }

    public func playNext(_ music: MusicInfo) {
        if let current = currentMusic, let index = playQueue.firstIndex(where: { $0.id == current.id }) {
            playQueue.insert(music, at: min(index + 1, playQueue.count))
        } else {
            playQueue.insert(music, at: 0)
        }
        showToast("已加入下一首播放：\(music.name)")
    }

    public func isCurrent(_ music: MusicInfo) -> Bool {
        currentMusic?.id == music.id
    }

    public func play(_ music: MusicInfo, queue: [MusicInfo]? = nil) {
        if let queue {
            playQueue = queue
            playQueueIndex = queue.firstIndex(where: { $0.id == music.id }) ?? 0
        } else if playQueue.isEmpty || !playQueue.contains(where: { $0.id == music.id }) {
            playQueue = currentMusics.isEmpty ? [music] : currentMusics
            playQueueIndex = playQueue.firstIndex(where: { $0.id == music.id }) ?? 0
        } else {
            playQueueIndex = playQueue.firstIndex(where: { $0.id == music.id }) ?? 0
        }
        Task { @MainActor in
            await resolveAndPlay(music)
        }
    }

    public func playList(_ musics: [MusicInfo], startAt index: Int) {
        guard musics.indices.contains(index) else { return }
        playQueue = musics
        playQueueIndex = index
        let music = musics[index]
        Task { @MainActor in await resolveAndPlay(music) }
    }

    private func pickQuality(for music: MusicInfo) -> String {
        let preferred = settings.string(SettingKeys.playQuality) ?? "128k"
        let capabilityQuality = activeCapabilities.first(where: { $0.source == music.source })?.qualitys ?? []
        let available = music.availableQualityKeys.isEmpty
            ? Set(music.qualitys.map(\.type))
            : Set(music.availableQualityKeys)
        let order = ["flac24bit", "flac", "wav", "320k", "192k", "128k"]
        if (available.isEmpty || available.contains(preferred)) &&
            (capabilityQuality.isEmpty || capabilityQuality.contains(preferred)) {
            return preferred
        }
        for quality in order where (available.isEmpty || available.contains(quality)) &&
            (capabilityQuality.isEmpty || capabilityQuality.contains(quality)) {
            return quality
        }
        return preferred
    }

    private func resolveAndPlay(_ music: MusicInfo) async {
        currentMusic = music
        playbackError = nil
        currentTime = 0
        duration = MeloUtils.parseInterval(music.interval)
        lyric = LyricInfo()
        lyricDocument = .empty
        currentLyricIndex = nil

        if let localPath = music.filePath, music.isLocal {
            let url = URL(fileURLWithPath: localPath)
            guard FileManager.default.fileExists(atPath: localPath) else {
                playbackError = "本地文件不存在：\(localPath)"
                showToast(playbackError!)
                return
            }
            do { try player.play(url: url, music: music) } catch {
                playbackError = error.localizedDescription
                showToast("播放失败：\(error.localizedDescription)")
            }
            loadLyric(for: music)
            return
        }

        isResolvingMusic = true
        defer { isResolvingMusic = false }

        let quality = pickQuality(for: music)
        var url: URL?
        if let cached = try? data.getMusicURL(musicId: music.id, quality: quality), let cachedURL = URL(string: cached) {
            if MeloUtils.isHTTPURL(cachedURL.absoluteString) { url = cachedURL }
        }
        if url == nil {
            guard !activeCapabilities.isEmpty else {
                playbackError = "未激活可用的自定义源，无法获取播放地址"
                showToast(playbackError!)
                return
            }
            do {
                url = try await customSources.resolveMusicURL(source: music.source, musicInfo: music, quality: quality)
            } catch {
                playbackError = error.localizedDescription
                showToast("获取播放地址失败：\(error.localizedDescription)")
                return
            }
        }
        guard let url else { return }
        try? data.saveMusicURL(musicId: music.id, quality: quality, url: url.absoluteString)
        do {
            try player.play(url: url, music: music)
        } catch {
            playbackError = error.localizedDescription
            showToast("播放失败：\(error.localizedDescription)")
        }
        loadLyric(for: music)
    }

    public func togglePlayPause() {
        switch playerStatus {
        case .playing:
            player.pause()
        case .paused, .stopped, .error:
            player.resume()
        case .loading:
            break
        }
    }

    // MARK: - 播放模式

    public var playMode: PlayMode {
        guard let raw = settings.string(SettingKeys.playMode), let mode = PlayMode(rawValue: raw) else {
            return .listLoop
        }
        return mode
    }

    public func setPlayMode(_ mode: PlayMode) {
        settings.set(SettingKeys.playMode, .string(mode.rawValue))
        showToast("播放模式：\(mode.label)")
    }

    public func cyclePlayMode() {
        setPlayMode(playMode.next)
    }

    // MARK: - 播放队列

    /// 跳到队列中的某一首并播放
    public func playQueueItem(at index: Int) {
        guard playQueue.indices.contains(index) else { return }
        playQueueIndex = index
        let music = playQueue[index]
        Task { @MainActor in await resolveAndPlay(music) }
    }

    public func removePlayQueueItem(at index: Int) {
        guard playQueue.indices.contains(index) else { return }
        if playQueue.count <= 1 {
            showToast("播放队列至少保留一首歌曲")
            return
        }
        playQueue.remove(at: index)
        if index < playQueueIndex {
            playQueueIndex -= 1
        } else if index == playQueueIndex {
            playQueueIndex = min(playQueueIndex, playQueue.count - 1)
            Task { @MainActor in await resolveAndPlay(playQueue[playQueueIndex]) }
        }
    }

    /// 移动队列项；`destination` 是移动后的最终下标（UI 上移传 index-1，下移传 index+1）
    public func movePlayQueueItem(from source: Int, to destination: Int) {
        guard playQueue.indices.contains(source) else { return }
        let target = max(0, min(destination, playQueue.count - 1))
        if target == source { return }
        let current = playQueueIndex < playQueue.count ? playQueue[playQueueIndex] : nil
        let item = playQueue.remove(at: source)
        playQueue.insert(item, at: min(target, playQueue.count))
        if let current, let newIndex = playQueue.firstIndex(where: { $0.id == current.id }) {
            playQueueIndex = newIndex
        }
    }

    public func clearPlayQueue() {
        player.stop()
        playQueue = []
        playQueueIndex = 0
    }

    public func next() {
        advanceQueue(isAuto: false)
    }

    public func previous() {
        guard !playQueue.isEmpty else { return }
        let mode = playMode
        if playQueueIndex > 0 {
            playQueueIndex -= 1
        } else if mode == .listLoop || mode == .random || mode == .singleLoop {
            playQueueIndex = playQueue.count - 1
        } else {
            return
        }
        if !dislikeRules.isEmpty, dislikeRules.matches(playQueue[playQueueIndex]) {
            var checked = 0
            var index = playQueueIndex
            while checked < playQueue.count - 1, dislikeRules.matches(playQueue[index]) {
                checked += 1
                index = (index - 1 + playQueue.count) % playQueue.count
            }
            if checked < playQueue.count - 1, !dislikeRules.matches(playQueue[index]) {
                playQueueIndex = index
            }
        }
        let music = playQueue[playQueueIndex]
        Task { @MainActor in await resolveAndPlay(music) }
    }

    /// 自动/手动切歌；auto 时遵循播放模式
    private func advanceQueue(isAuto: Bool) {
        guard !playQueue.isEmpty else { return }
        let mode = playMode
        switch mode {
        case .singleLoop where isAuto:
            let music = playQueue[min(playQueueIndex, playQueue.count - 1)]
            Task { @MainActor in await resolveAndPlay(music) }
            return
        case .none where isAuto:
            playerStatus = .stopped
            currentTime = 0
            return
        case .random:
            if playQueue.count > 1 {
                var candidates = playQueue.indices.filter { $0 != playQueueIndex && !dislikeRules.matches(playQueue[$0]) }
                if candidates.isEmpty {
                    candidates = playQueue.indices.filter { $0 != playQueueIndex }
                }
                playQueueIndex = candidates.randomElement() ?? ((playQueueIndex + 1) % playQueue.count)
            }
        default:
            if playQueueIndex + 1 < playQueue.count {
                playQueueIndex += 1
            } else if mode == .listLoop || mode == .singleLoop {
                playQueueIndex = 0
            } else {
                playerStatus = .stopped
                currentTime = 0
                return
            }
            // 跳过「不喜欢」的歌曲（最多绕队列一圈；全是则保持原值）
            if !dislikeRules.isEmpty, dislikeRules.matches(playQueue[playQueueIndex]) {
                var checked = 0
                var index = playQueueIndex
                while checked < playQueue.count - 1, dislikeRules.matches(playQueue[index]) {
                    checked += 1
                    index = (index + 1) % playQueue.count
                }
                if checked < playQueue.count - 1, !dislikeRules.matches(playQueue[index]) {
                    MeloLog.info("跳过不喜欢的歌曲 \(checked) 首")
                    playQueueIndex = index
                }
            }
        }
        let music = playQueue[playQueueIndex]
        Task { @MainActor in await resolveAndPlay(music) }
    }

    public func seek(to time: TimeInterval) {
        player.seek(to: min(max(time, 0), duration))
        currentTime = time
    }

    public func setVolume(_ value: Double) {
        let clamped = min(max(value, 0), 1)
        volume = clamped
        player.volume = clamped
        settings.set(SettingKeys.playerVolume, .double(clamped))
        if clamped > 0, isMuted {
            isMuted = false
            player.isMuted = false
            settings.set(SettingKeys.playerMute, .bool(false))
        }
    }

    public func toggleMute() {
        isMuted.toggle()
        player.isMuted = isMuted
        settings.set(SettingKeys.playerMute, .bool(isMuted))
    }

    public var playQuality: String {
        settings.string(SettingKeys.playQuality) ?? "128k"
    }

    public func setPlayQuality(_ quality: String) {
        settings.set(SettingKeys.playQuality, .string(quality))
    }

    public func setPlaybackRate(_ rate: Double) {
        playbackRate = min(max(rate, 0.5), 2.0)
        player.playbackRate = playbackRate
        settings.set(SettingKeys.playbackRate, .double(playbackRate))
        applyAudioEffects()
    }

    private func handlePlayerEvent(_ event: PlayerEvent) {
        switch event {
        case .status(let status):
            playerStatus = status
            if status == .playing { consecutivePlaybackErrors = 0 }
            if status == .error || status == .stopped, savePlayTimeEnabled {
                saveCurrentPlayInfo(force: true)
            }
        case .progress(let current, let total):
            currentTime = current
            if total > 0 { duration = total }
            currentLyricIndex = lyricDocument.lineIndex(at: current)
            recordPlayInfoProgress(current)
        case .ended:
            if playTimeoutRemaining == 0 {
                finishPlayTimeout(waitForSongEnd: true)
                return
            }
            advanceQueue(isAuto: true)
        case .error(let message):
            playbackError = message
            playerStatus = .error
            if autoSkipOnError, playQueue.count > 1, consecutivePlaybackErrors < 3 {
                consecutivePlaybackErrors += 1
                showToast("播放出错，自动切换下一首：\(message)")
                next()
            } else {
                showToast("播放出错：\(message)")
            }
        }
    }

    private func restoreLastPlayInfo() {
        lastPlayInfo = appData?.loadPlayInfo()
    }

    // MARK: - 播放信息记忆 / 启动自动播放

    public var autoSkipOnError: Bool { settings.bool(SettingKeys.autoSkipOnError, default: true) }
    public var startupAutoPlayEnabled: Bool { settings.bool(SettingKeys.startupAutoPlay) }
    public var savePlayTimeEnabled: Bool { settings.bool(SettingKeys.savePlayTime) }
    public var waitSongEndOnTimeout: Bool { settings.bool(SettingKeys.waitPlayEndStop) }

    private func recordPlayInfoProgress(_ time: TimeInterval) {
        guard savePlayTimeEnabled, currentMusic != nil else { return }
        guard abs(time - lastSavedPlayTime) >= 2 else { return }
        lastSavedPlayTime = time
        saveCurrentPlayInfo(force: false)
    }

    /// App 退出前强制保存当前播放进度
    public func persistCurrentPlayInfo() {
        guard savePlayTimeEnabled else { return }
        saveCurrentPlayInfo(force: true)
    }

    private func saveCurrentPlayInfo(force: Bool) {
        guard let music = currentMusic, savePlayTimeEnabled else { return }
        let snapshot = PlayInfoSnapshot(
            time: currentTime,
            maxTime: duration,
            musicInfo: music,
            listId: selectedListId
        )
        lastPlayInfo = snapshot
        appData?.savePlayInfo(snapshot)
    }

    /// 启动自动播放：优先恢复上次播放歌曲与进度，否则播放当前列表第一首
    private func startupPlayback() async {
        if let saved = lastPlayInfo, let music = saved.musicInfo {
            let queue = currentMusics.isEmpty ? [music] : currentMusics
            play(music, queue: queue.contains(where: { $0.id == music.id }) ? queue : [music])
            for _ in 0..<40 {
                if playerStatus == .playing || playerStatus == .paused { break }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            if saved.time > 1, playerStatus == .playing || playerStatus == .paused {
                seek(to: min(saved.time, max(duration - 1, 0)))
            }
            return
        }
        if let first = currentMusics.first {
            play(first, queue: currentMusics)
        }
    }

    // MARK: - 定时暂停（原版 play_timeout）

    public var playTimeoutMinutes: Int {
        Int(settings.string(SettingKeys.waitPlayEndStopTime) ?? "") ?? 0
    }

    public func setPlayTimeout(minutes: Int, waitSongEnd: Bool) {
        cancelPlayTimeout()
        guard minutes > 0 else { return }
        settings.set(SettingKeys.waitPlayEndStop, .bool(waitSongEnd))
        settings.set(SettingKeys.waitPlayEndStopTime, .string(String(minutes)))
        playTimeoutWaitsForSongEnd = waitSongEnd
        playTimeoutRemaining = TimeInterval(minutes * 60)
        showToast("定时暂停：\(minutes) 分钟后\(waitSongEnd ? "（等待当前歌曲结束）" : "")暂停")
        playTimeoutTask = Task { @MainActor [weak self] in
            while let self, let remaining = self.playTimeoutRemaining {
                if remaining <= 0 { break }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                guard let current = self.playTimeoutRemaining else { return }
                if current <= 1 {
                    self.playTimeoutRemaining = 0
                    if !self.playTimeoutWaitsForSongEnd {
                        self.finishPlayTimeout(waitForSongEnd: false)
                    }
                    return
                }
                self.playTimeoutRemaining = current - 1
            }
        }
    }

    public func cancelPlayTimeout() {
        playTimeoutTask?.cancel()
        playTimeoutTask = nil
        playTimeoutRemaining = nil
        playTimeoutWaitsForSongEnd = false
        settings.set(SettingKeys.waitPlayEndStopTime, .string(""))
    }

    private func finishPlayTimeout(waitForSongEnd: Bool) {
        MeloLog.info("定时暂停触发（等待本曲结束=\(waitForSongEnd)）")
        playTimeoutTask?.cancel()
        playTimeoutTask = nil
        playTimeoutRemaining = nil
        playTimeoutWaitsForSongEnd = false
        settings.set(SettingKeys.waitPlayEndStopTime, .string(""))
        if playerStatus == .playing { togglePlayPause() }
        showToast("定时暂停：已暂停播放")
    }

    // MARK: - 在线列表更新（源歌单/排行榜同步）

    public var onlineUserLists: [ListInfo] {
        userLists.filter {
            guard let source = $0.source, !source.isEmpty,
                  let sourceListId = $0.sourceListId, !sourceListId.isEmpty else { return false }
            return true
        }
    }

    public func loadListUpdateInfo() {
        listUpdateInfo = appData?.loadListUpdateInfo() ?? [:]
    }

    public func setListAutoUpdate(listId: String, enabled: Bool) {
        var info = listUpdateInfo
        var target = info[listId] ?? ListUpdateInfo()
        target.isAutoUpdate = enabled
        info[listId] = target
        listUpdateInfo = info
        appData?.saveListUpdateInfo(info)
        showToast(enabled ? "已开启「\(self.userLists.first { $0.id == listId }?.name ?? listId)」自动更新" : "已关闭自动更新")
    }

    public func updateSourceList(id: String) async {
        guard let list = userLists.first(where: { $0.id == id }),
              let source = list.source, !source.isEmpty,
              let sourceListId = list.sourceListId, !sourceListId.isEmpty else { return }
        guard !updatingListIds.contains(id) else { return }
        updatingListIds.insert(id)
        defer { updatingListIds.remove(id) }
        do {
            let musics = try await fetchAllSourceListMusics(source: source, sourceListId: sourceListId)
            guard !musics.isEmpty else {
                showToast("列表更新失败：没有获取到歌曲")
                return
            }
            try data.overwriteList(listId: id, musics: musics)
            if selectedListId == id { loadMusicsForSelectedList() }
            refreshLibrary()
            var info = listUpdateInfo
            var target = info[id] ?? ListUpdateInfo()
            target.updateTime = Int64(Date().timeIntervalSince1970 * 1000)
            info[id] = target
            listUpdateInfo = info
            appData?.saveListUpdateInfo(info)
            showToast("已更新列表「\(list.name)」：\(musics.count) 首")
        } catch {
            showToast("列表更新失败：\(error.localizedDescription)")
        }
    }

    private func fetchAllSourceListMusics(source: String, sourceListId: String) async throws -> [MusicInfo] {
        var result: [MusicInfo] = []
        var seen: Set<String> = []
        let limit = 100
        for page in 1...100 {
            let pageData: SearchPage<MusicInfo>
            if sourceListId.hasPrefix("board__") {
                let boardId = String(sourceListId.dropFirst("board__".count))
                pageData = try await metadata.leaderboardMusics(boardId: boardId, page: page, limit: limit)
            } else {
                let detail = try await metadata.songListDetail(id: sourceListId, source: source, page: page, limit: limit)
                pageData = detail.page
            }
            for music in pageData.list where !seen.contains(music.id) {
                seen.insert(music.id)
                result.append(music)
            }
            if pageData.list.count < limit { break }
            if pageData.total > 0, result.count >= pageData.total { break }
        }
        return result
    }

    private func autoUpdateSourceLists() async {
        let targets = onlineUserLists.filter { listUpdateInfo[$0.id]?.isAutoUpdate == true }
        guard !targets.isEmpty else { return }
        MeloLog.info("自动更新在线列表：\(targets.count) 个")
        for list in targets {
            await updateSourceList(id: list.id)
        }
    }

    // MARK: - 歌词

    private func loadLyric(for music: MusicInfo) {
        isLoadingLyric = true
        defer { isLoadingLyric = false }
        var info = LyricInfo()
        // 本地音乐优先读取同名 .lrc（原版行为）
        if music.isLocal, let filePath = music.filePath {
            let base = URL(fileURLWithPath: filePath).deletingPathExtension()
            for candidate in [base.appendingPathExtension("lrc"), base.appendingPathExtension("LRC")] {
                if let text = try? String(contentsOf: candidate, encoding: .utf8), !text.isEmpty {
                    info.lyric = text
                    break
                }
            }
        }
        for type in ["lyric", "tlyric", "rlyric", "lxlyric"] {
            // 优先读取用户编辑过的歌词（原版 DB lyric 表 source='edited'）
            let edited = try? data.getLyric(musicId: music.id, source: "edited", type: type)
            let raw = try? data.getLyric(musicId: music.id, source: "raw", type: type)
            if let text = (edited?.isEmpty == false ? edited : raw), !text.isEmpty {
                switch type {
                case "lyric": info.lyric = text
                case "tlyric": info.tlyric = text
                case "rlyric": info.rlyric = text
                case "lxlyric": info.lxlyric = text
                default: break
                }
            }
        }

        if info.isEmpty {
            Task { @MainActor in
                var remote: LyricInfo?
                if let custom = try? await customSources.resolveLyric(source: music.source, musicInfo: music), !custom.isEmpty {
                    remote = custom
                } else if metadataReady, let builtin = try? await metadata.lyric(musicInfo: music), !builtin.isEmpty {
                    remote = builtin
                }
                if let remote {
                    applyLyric(remote, for: music)
                    persistLyric(remote, for: music)
                } else {
                    applyLyric(info, for: music)
                }
            }
        } else {
            applyLyric(info, for: music)
        }
    }

    private func applyLyric(_ info: LyricInfo, for music: MusicInfo) {
        guard currentMusic?.id == music.id else { return }
        lyric = info
        lyricDocument = LyricParser.parse(
            info.lyric,
            translated: info.tlyric,
            roman: info.rlyric,
            wordByWord: info.lxlyric
        )
        currentLyricIndex = lyricDocument.lineIndex(at: currentTime)
    }

    private func persistLyric(_ info: LyricInfo, for music: MusicInfo) {
        guard !info.isEmpty else { return }
        let parts: [(String, String?)] = [
            ("lyric", info.lyric.isEmpty ? nil : info.lyric),
            ("tlyric", info.tlyric),
            ("rlyric", info.rlyric),
            ("lxlyric", info.lxlyric),
        ]
        for (type, text) in parts {
            guard let text, !text.isEmpty else { continue }
            try? data.saveLyric(musicId: music.id, source: "raw", type: type, text: text)
        }
    }

    // MARK: - 自定义源

    public func reloadSources() {
        do {
            try customSources.reloadSources()
            sources = customSources.sources
            activeSourceId = customSources.activeSourceId
            sourceStatus = customSources.status
            activeCapabilities = customSources.capabilities
        } catch {
            showToast("读取自定义源失败：\(error.localizedDescription)")
        }
    }

    public func importSource(url: URL) async {
        do {
            let info = try customSources.importSource(from: url)
            sources = customSources.sources
            showToast("已导入自定义源「\(info.name)」")
            await activateSource(id: info.id)
        } catch {
            showToast("导入失败：\(error.localizedDescription)")
        }
    }

    /// 在线导入自定义源（http/https 链接，下载脚本后按原版规则解析头部并入库）
    public func importSourceFromURL(_ urlString: String) async {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else {
            showToast("请输入合法的 http(s) 链接")
            return
        }
        isImportingSource = true
        defer { isImportingSource = false }
        do {
            let info = try await customSources.importSource(fromRemoteURL: url)
            sources = customSources.sources
            showToast("已导入自定义源：\(info.name)")
            await activateSource(id: info.id)
        } catch {
            showToast("在线导入失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 本地音乐导入

    public private(set) var isImportingLocalMusic = false

    /// 导入本地文件/文件夹（递归扫描音频），加入当前选中的列表（默认列表兜底）
    public func importLocalMusic(urls: [URL]) async {
        guard !urls.isEmpty else { return }
        isImportingLocalMusic = true
        defer { isImportingLocalMusic = false }
        do {
            let scanned = try data.scanLocalMusic(at: urls)
            guard !scanned.isEmpty else {
                showToast("没有找到可导入的音频文件")
                return
            }
            let targetListId = selectedListId
            let existing = Set((try? data.loadMusics(listId: targetListId))?.compactMap(\.filePath) ?? [])
            let fresh = scanned.filter { music in
                guard let path = music.filePath else { return false }
                return !existing.contains(path)
            }
            let duplicateCount = scanned.count - fresh.count
            if fresh.isEmpty {
                showToast("选中的 \(scanned.count) 首本地音乐已全部存在")
                return
            }
            addMusics(fresh, to: targetListId)
            if duplicateCount > 0 {
                showToast("已导入 \(fresh.count) 首本地音乐（跳过 \(duplicateCount) 首已存在）")
            } else {
                showToast("已导入 \(fresh.count) 首本地音乐")
            }
        } catch {
            showToast("导入本地音乐失败：\(error.localizedDescription)")
        }
    }

    /// 导入单个文件夹
    public func importLocalMusic(folder: URL) async {
        await importLocalMusic(urls: [folder])
    }

    public func activateSource(id: String) async {
        guard !isSwitchingSource else { return }
        isSwitchingSource = true
        defer { isSwitchingSource = false }
        await customSources.activateSource(id: id)
        sources = customSources.sources
        if customSources.status.isReady {
            settings.set(SettingKeys.apiSource, .string(id))
        }
        activeSourceId = customSources.activeSourceId
        sourceStatus = customSources.status
        activeCapabilities = customSources.capabilities
    }

    public func removeSource(id: String) {
        do {
            try customSources.removeSource(id: id)
            reloadSources()
        } catch {
            showToast("删除源失败：\(error.localizedDescription)")
        }
    }

    private func handleSourceEvent(_ event: CustomSourceEvent) {
        switch event {
        case .status(let status):
            sourceStatus = status
            sourceCapabilitiesRefresh()
        case .log(let message):
            sourceLogs.append(message)
            if sourceLogs.count > 300 { sourceLogs.removeFirst(sourceLogs.count - 300) }
            MeloLog.info("[source] \(message)")
        case .updateAlert(let log, let url):
            showToast("源更新提醒：\(log)\(url.map { " \($0)" } ?? "")")
        }
    }

    private func sourceCapabilitiesRefresh() {
        activeCapabilities = customSources.capabilities
        activeSourceId = customSources.activeSourceId
    }

    /// 测试面板：用活动源按给定音乐信息解析 URL（不经过列表/搜索）
    public func testResolve(musicInfo: MusicInfo) async -> URL? {
        guard !activeCapabilities.isEmpty else {
            showToast("请先导入并激活一个自定义源")
            return nil
        }
        isResolvingMusic = true
        defer { isResolvingMusic = false }
        do {
            let quality = pickQuality(for: musicInfo)
            let url = try await customSources.resolveMusicURL(source: musicInfo.source, musicInfo: musicInfo, quality: quality)
            currentMusic = musicInfo
            try player.play(url: url, music: musicInfo)
            return url
        } catch {
            showToast("解析失败：\(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - 设置 / 主题 / 语言

    public func setTheme(id: String) {
        theme.selectTheme(id: id)
    }

    // MARK: 自定义主题（存 LxDatas/theme.json，原版格式）

    public var allThemes: [Theme] { theme.allThemes }
    public var userThemes: [Theme] { theme.userThemes }
    public var currentTheme: Theme { theme.current }

    public func createUserTheme(name: String, baseThemeID: String, overrides: [String: String]) -> Theme? {
        guard let created = theme.createUserTheme(name: name, baseThemeID: baseThemeID, overrides: overrides) else {
            showToast("创建主题失败：基础主题不存在")
            return nil
        }
        do {
            try theme.saveUserTheme(created)
            showToast("已创建主题「\(created.name)」")
            return created
        } catch {
            showToast("保存主题失败：\(error.localizedDescription)")
            return nil
        }
    }

    public func saveUserTheme(_ updated: Theme) -> Bool {
        do {
            try theme.saveUserTheme(updated)
            showToast("已保存主题「\(updated.name)」")
            return true
        } catch {
            showToast("保存主题失败：\(error.localizedDescription)")
            return false
        }
    }

    public func removeUserTheme(id: String) {
        do {
            try theme.removeUserTheme(id: id)
            showToast("已删除主题")
        } catch {
            showToast("删除主题失败：\(error.localizedDescription)")
        }
    }

    public func exportThemeJSON(id: String) -> String? {
        theme.exportThemeJSON(id: id)
    }

    public func importThemeJSON(_ text: String) -> Theme? {
        do {
            let imported = try theme.importThemeJSON(text)
            showToast("已导入主题「\(imported.name)」")
            return imported
        } catch {
            showToast("导入主题失败：\(error.localizedDescription)")
            return nil
        }
    }

    public func setLanguage(id: String) {
        localizer.setLanguage(id)
    }

    public var appColors: AppColors { theme.colors }

    // MARK: - 提示

    public func showToast(_ message: String) {
        toastMessage = message
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_800_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.toastMessage = nil }
        }
    }

    public func clearToast() {
        toastTask?.cancel()
        toastMessage = nil
    }

    // MARK: - 播放详情

    public func openPlayDetail() {
        isShowingPlayDetail = true
    }

    public func closePlayDetail() {
        isShowingPlayDetail = false
    }

    // MARK: - 内置元数据：搜索 / 榜单 / 歌单（Phase 1）

    public private(set) var metadataReady = false
    public private(set) var metadataError: String?
    public private(set) var builtinSources: [MusicSourceInfo] = []
    public private(set) var hotSearchWords: [String] = []

    public var searchTab: SearchTab = .music
    public var searchSource: String = "all"
    public private(set) var searchKeyword: String = ""
    public private(set) var searchMusicPage: SearchPage<MusicInfo> = .init()
    public private(set) var searchSongListPage: SearchPage<SongListItem> = .init()
    public private(set) var isSearching = false
    public private(set) var searchError: String?
    public var searchHistory: [String] {
        (settings.value(SettingKeys.searchHistory)?.arrayValue ?? []).compactMap(\.stringValue)
    }

    public var metadataSourcesWithAll: [MusicSourceInfo] {
        [MusicSourceInfo(id: "all", name: "聚合搜索")] + builtinSources
    }

    public func loadHotSearch(source: String? = nil) async {
        guard metadataReady else { return }
        do {
            let words = try await metadata.hotSearch(source: source ?? (searchSource == "all" ? "kw" : searchSource))
            hotSearchWords = words
        } catch is CancellationError {
            // 视图生命周期变化导致的取消：静默忽略
        } catch {
            MeloLog.warn("加载热搜失败: \(error.localizedDescription)")
        }
    }

    public func performSearch(_ keyword: String, tab: SearchTab? = nil, source: String? = nil, page: Int = 1) async {
        let text = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            searchKeyword = ""
            searchMusicPage = .init()
            searchSongListPage = .init()
            return
        }
        if let tab { searchTab = tab }
        if let source { searchSource = source }
        searchKeyword = text
        isSearching = true
        searchError = nil
        defer { isSearching = false }
        do {
            switch searchTab {
            case .music:
                let result = try await metadata.searchMusic(keyword: text, source: searchSource, page: page, limit: 30)
                if page <= 1 { searchMusicPage = result } else { searchMusicPage.append(result) }
            case .songList:
                let result = try await metadata.searchSongList(keyword: text, source: searchSource, page: page, limit: 30)
                if page <= 1 { searchSongListPage = result } else { searchSongListPage.append(result) }
            }
            recordSearchHistory(text)
        } catch {
            searchError = error.localizedDescription
        }
    }

    public func loadMoreSearch() async {
        guard !searchKeyword.isEmpty, !isSearching else { return }
        switch searchTab {
        case .music:
            await performSearch(searchKeyword, page: searchMusicPage.page + 1)
        case .songList:
            await performSearch(searchKeyword, page: searchSongListPage.page + 1)
        }
    }

    public func setSearchSource(_ source: String) async {
        searchSource = source
        if !searchKeyword.isEmpty {
            await performSearch(searchKeyword, source: source, page: 1)
        }
    }

    public func setSearchTab(_ tab: SearchTab) async {
        searchTab = tab
        if !searchKeyword.isEmpty {
            await performSearch(searchKeyword, tab: tab, page: 1)
        }
    }

    public func clearSearchHistory() {
        settings.set(SettingKeys.searchHistory, .array([]))
    }

    private func recordSearchHistory(_ keyword: String) {
        var history = searchHistory.filter { $0 != keyword }
        history.insert(keyword, at: 0)
        settings.set(SettingKeys.searchHistory, .array(history.prefix(20).map { .string($0) }))
    }

    // MARK: 排行榜

    public var leaderboardSource: String = "kw"
    public private(set) var leaderboards: [LeaderboardInfo] = []
    public private(set) var selectedLeaderboardId: String?
    public private(set) var leaderboardPage: SearchPage<MusicInfo> = .init()
    public private(set) var isLoadingLeaderboard = false
    public private(set) var leaderboardError: String?

    public func loadLeaderboards(source: String? = nil) async {
        if let source { leaderboardSource = source }
        guard metadataReady else { return }
        isLoadingLeaderboard = true
        leaderboardError = nil
        defer { isLoadingLeaderboard = false }
        do {
            leaderboards = try await metadata.leaderboards(source: leaderboardSource)
            if selectedLeaderboardId == nil || !leaderboards.contains(where: { $0.id == selectedLeaderboardId }) {
                if let first = leaderboards.first {
                    await selectLeaderboard(first)
                }
            }
        } catch {
            leaderboardError = error.localizedDescription
        }
    }

    public func selectLeaderboard(_ board: LeaderboardInfo) async {
        selectedLeaderboardId = board.id
        leaderboardPage = .init()
        await loadLeaderboardMusics(page: 1)
    }

    public func loadLeaderboardMusics(page: Int = 1) async {
        guard let boardId = selectedLeaderboardId, metadataReady else { return }
        isLoadingLeaderboard = true
        leaderboardError = nil
        defer { isLoadingLeaderboard = false }
        do {
            let result = try await metadata.leaderboardMusics(boardId: boardId, page: page, limit: 100)
            if page <= 1 {
                leaderboardPage = result
            } else {
                leaderboardPage.append(result)
            }
        } catch {
            leaderboardError = error.localizedDescription
        }
    }

    public func loadMoreLeaderboardMusics() async {
        guard !isLoadingLeaderboard, leaderboardPage.page > 0 else { return }
        await loadLeaderboardMusics(page: leaderboardPage.page + 1)
    }

    // MARK: 歌单广场

    public var songListSource: String = "kw"
    public private(set) var songListSorts: [SongListSort] = []
    public private(set) var songListTags: SongListTags = .init()
    public var selectedSongListTagId: String = ""
    public private(set) var selectedSongListSortId: String = ""
    public private(set) var songListPage: SearchPage<SongListItem> = .init()
    public private(set) var songListDetail: SongListDetail?
    public private(set) var isLoadingSongList = false
    public private(set) var isLoadingSongListDetail = false
    public private(set) var songListError: String?

    public func loadSongListHub(source: String? = nil) async {
        if let source { songListSource = source }
        guard metadataReady else { return }
        isLoadingSongList = true
        songListError = nil
        defer { isLoadingSongList = false }
        do {
            async let sortsTask = metadata.songListSorts(source: songListSource)
            async let tagsTask = metadata.songListTags(source: songListSource)
            songListSorts = try await sortsTask
            songListTags = try await tagsTask
            if selectedSongListSortId.isEmpty || !songListSorts.contains(where: { $0.id == selectedSongListSortId }) {
                selectedSongListSortId = songListSorts.first?.id ?? ""
            }
            await loadSongLists(page: 1)
        } catch {
            songListError = error.localizedDescription
        }
    }

    public func selectSongListTag(_ tagId: String) async {
        selectedSongListTagId = tagId
        await loadSongLists(page: 1)
    }

    public func selectSongListSort(_ sortId: String) async {
        selectedSongListSortId = sortId
        await loadSongLists(page: 1)
    }

    public func loadSongLists(page: Int = 1) async {
        guard metadataReady else { return }
        isLoadingSongList = true
        songListError = nil
        defer { isLoadingSongList = false }
        do {
            let result = try await metadata.songLists(
                source: songListSource,
                tagId: selectedSongListTagId,
                sortId: selectedSongListSortId,
                page: page,
                limit: 20
            )
            if page <= 1 {
                songListPage = result
            } else {
                songListPage.append(result)
            }
        } catch {
            songListError = error.localizedDescription
        }
    }

    public func loadMoreSongLists() async {
        guard !isLoadingSongList, songListPage.page > 0 else { return }
        await loadSongLists(page: songListPage.page + 1)
    }

    public func showSongListDetail(id: String, source: String) async {
        route = .songListDetail(id: id, source: source)
        await openSongListDetail(id: id, source: source)
    }

    public func backToSongList() {
        route = .songList
    }

    public func openSearch() {
        route = .search
    }

    public func openSongListDetail(id: String, source: String, page: Int = 1) async {
        isLoadingSongListDetail = true
        songListError = nil
        defer { isLoadingSongListDetail = false }
        do {
            let detail = try await metadata.songListDetail(id: id, source: source, page: page, limit: 200)
            songListDetail = detail
        } catch {
            songListError = error.localizedDescription
        }
    }

    public func loadMoreSongListDetail() async {
        guard let detail = songListDetail, !isLoadingSongListDetail, detail.page.hasMore else { return }
        let source = detail.info.source
        let id = detail.info.id
        await openSongListDetail(id: id, source: source, page: detail.page.page + 1)
    }


    // MARK: - 下载（Phase 2）

    public private(set) var downloadTasks: [DownloadTaskInfo] = []

    public var isDownloadEnabled: Bool { settings.bool(SettingKeys.downloadEnable) }

    public func refreshDownloadTasks() {
        downloadTasks = downloads.tasks
        persistDownloadTasksIfNeeded()
    }

    public func startDownload(_ music: MusicInfo, quality: String? = nil) async -> Bool {
        guard isDownloadEnabled else {
            showToast("请先在「设置 → 下载」中开启下载功能")
            return false
        }
        guard !music.isLocal else {
            showToast("本地音乐无需下载")
            return false
        }
        let targetQuality = quality ?? pickQuality(for: music)
        guard let url = await resolveDownloadURL(music: music, quality: targetQuality) else { return false }

        let ext = downloadExtension(for: targetQuality)
        let configuredSavePath = settings.string(SettingKeys.downloadSavePath) ?? ""
        let savePath = configuredSavePath.isEmpty
            ? (FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first?.path ?? NSHomeDirectory())
            : configuredSavePath
        let template = settings.string(SettingKeys.downloadFileName) ?? "歌名 - 歌手"
        let fileName = makeDownloadFileName(template: template, music: music)
        let embedPic = settings.bool(SettingKeys.downloadEmbedPic)
        let embedLyric = settings.bool(SettingKeys.downloadEmbedLyric)
            || settings.bool(SettingKeys.downloadEmbedLyricLx)
            || settings.bool(SettingKeys.downloadEmbedLyricT)
            || settings.bool(SettingKeys.downloadEmbedLyricR)
        let saveLrcFile = settings.bool(SettingKeys.downloadSaveLrc)
        var lyricSource: LyricInfo?
        if embedLyric || saveLrcFile {
            lyricSource = await fetchLyricForDownload(music: music)
        }
        // 嵌入标签：按原版 isEmbedLyricLx/T/R 合并为单个歌词文本
        var lyric: LyricInfo?
        if embedLyric, let source = lyricSource {
            let merged = LyricExporter.buildMergedLyric(
                source,
                includeWordByWord: settings.bool(SettingKeys.downloadEmbedLyricLx),
                includeTranslation: settings.bool(SettingKeys.downloadEmbedLyricT),
                includeRoman: settings.bool(SettingKeys.downloadEmbedLyricR)
            )
            lyric = merged.isEmpty ? nil : LyricInfo(lyric: merged)
        }
        let pictureURL = music.picUrl.flatMap { URL(string: $0) }

        let taskID = downloads.enqueue(
            music: music,
            quality: targetQuality,
            url: url,
            saveDirectory: URL(fileURLWithPath: savePath, isDirectory: true),
            fileName: fileName,
            fileExtension: ext,
            embedPicture: embedPic,
            embedLyrics: embedLyric,
            lyrics: lyric,
            pictureURL: pictureURL
        )
        if saveLrcFile, let source = lyricSource {
            let lrcText = LyricExporter.buildMergedLyric(
                source,
                includeWordByWord: settings.bool(SettingKeys.downloadSaveLxLrc),
                includeTranslation: settings.bool(SettingKeys.downloadSaveTLrc),
                includeRoman: settings.bool(SettingKeys.downloadSaveRLrc)
            )
            if !lrcText.isEmpty {
                downloads.setLrcFile(taskID: taskID,
                                     content: lrcText,
                                     encoding: settings.string(SettingKeys.downloadLrcFormat) ?? "utf8")
            }
        }
        refreshDownloadTasks()
        showToast("已加入下载：\(music.name)")
        return true
    }

    public func startDownloads(_ musics: [MusicInfo]) async {
        guard isDownloadEnabled else {
            showToast("请先在「设置 → 下载」中开启下载功能")
            return
        }
        var added = 0
        for music in musics {
            if await startDownload(music) { added += 1 }
        }
        if musics.count > 1 {
            showToast("已加入 \(added) 首到下载队列")
        }
    }

    public func pauseDownload(id: String) {
        downloads.pause(id: id)
        refreshDownloadTasks()
    }

    public func resumeDownload(id: String) {
        downloads.resume(id: id)
        refreshDownloadTasks()
    }

    public func cancelDownload(id: String) {
        downloads.cancel(id: id)
        refreshDownloadTasks()
    }

    public func removeDownload(id: String) {
        downloads.remove(id: id)
        try? data.removeDownloadTasks(ids: [id])
        persistedDownloadStatus.removeValue(forKey: id)
        refreshDownloadTasks()
    }

    public func pauseAllDownloads() {
        for task in downloadTasks where task.status == "run" || task.status == "waiting" {
            downloads.pause(id: task.id)
        }
        refreshDownloadTasks()
    }

    public func resumeAllDownloads() {
        for task in downloadTasks where task.status == "pause" || task.status == "waiting" {
            downloads.resume(id: task.id)
        }
        refreshDownloadTasks()
    }

    /// 从历史记录中删除指定任务（仅清 DB 记录，不删音频文件）
    public func removeDownloadHistory(ids: [String]) {
        guard !ids.isEmpty else { return }
        do {
            try data.removeDownloadTasks(ids: ids)
            loadDownloadHistory()
            showToast("已删除 \(ids.count) 条下载记录")
        } catch {
            showToast("删除下载记录失败：\(error.localizedDescription)")
        }
    }

    /// 清空全部已完成下载历史（仅清 DB 记录）
    public func clearDownloadHistory() {
        do {
            try data.clearCompletedDownloadTasks()
            loadDownloadHistory()
            showToast("已清空已完成下载记录")
        } catch {
            showToast("清空下载记录失败：\(error.localizedDescription)")
        }
    }

    public func removeCompletedDownloads() {
        let completedIDs = downloadTasks.filter(\.isCompleted).map(\.id)
        for id in completedIDs {
            downloads.remove(id: id)
        }
        try? data.clearCompletedDownloadTasks()
        for id in completedIDs { persistedDownloadStatus.removeValue(forKey: id) }
        refreshDownloadTasks()
    }

    private func downloadExtension(for quality: String) -> String {
        switch quality {
        case "flac", "flac24bit": return "flac"
        case "wav": return "wav"
        case "ape": return "ape"
        default: return "mp3"
        }
    }

    private func makeDownloadFileName(template: String, music: MusicInfo) -> String {
        var name = template
            .replacingOccurrences(of: "歌名", with: music.name)
            .replacingOccurrences(of: "歌手", with: music.singer)
        let illegal = CharacterSet(charactersIn: "\\/:*?\"<>|")
        name = name.components(separatedBy: illegal).joined(separator: "_")
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { name = "\(music.name) - \(music.singer)" }
        return String(name.prefix(150))
    }

    private func resolveDownloadURL(music: MusicInfo, quality: String) async -> URL? {
        if let cached = try? data.getMusicURL(musicId: music.id, quality: quality),
           let cachedURL = URL(string: cached), MeloUtils.isHTTPURL(cachedURL.absoluteString) {
            return cachedURL
        }
        guard !activeCapabilities.isEmpty else {
            showToast("未激活可用的自定义源，无法获取下载地址")
            return nil
        }
        do {
            let url = try await customSources.resolveMusicURL(source: music.source, musicInfo: music, quality: quality)
            try? data.saveMusicURL(musicId: music.id, quality: quality, url: url.absoluteString)
            return url
        } catch {
            showToast("获取下载地址失败：\(error.localizedDescription)")
            return nil
        }
    }

    private func fetchLyricForDownload(music: MusicInfo) async -> LyricInfo? {
        var info = LyricInfo()
        for type in ["lyric", "tlyric", "rlyric", "lxlyric"] {
            // 优先读取用户编辑过的歌词（原版 DB lyric 表 source='edited'）
            let edited = try? data.getLyric(musicId: music.id, source: "edited", type: type)
            let raw = try? data.getLyric(musicId: music.id, source: "raw", type: type)
            if let text = (edited?.isEmpty == false ? edited : raw), !text.isEmpty {
                switch type {
                case "lyric": info.lyric = text
                case "tlyric": info.tlyric = text
                case "rlyric": info.rlyric = text
                case "lxlyric": info.lxlyric = text
                default: break
                }
            }
        }
        if info.isEmpty, metadataReady, let remote = try? await metadata.lyric(musicInfo: music), !remote.isEmpty {
            return remote
        }
        return info.isEmpty ? nil : info
    }


    // MARK: - 音效（EQ / 变速变调）

    /// 当前音效设置（由原版设置键换算）
    public var audioEffects: AudioEffectSettings {
        let bands = SettingKeys.eqBandKeys.map { settings.double($0, default: 0) }
        let shifterRate = settings.double(SettingKeys.pitchShifterRate, default: 1)
        let semitones = shifterRate > 0 ? 12 * log2(shifterRate) : 0
        let rawFileName = settings.string(SettingKeys.convolutionFileName)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let convolutionName = (rawFileName?.isEmpty == false) ? rawFileName : nil
        return AudioEffectSettings(
            eqBands: bands,
            playbackRate: playbackRate,
            pitchSemitones: semitones,
            convolutionFileName: convolutionName,
            convolutionMainGain: settings.double(SettingKeys.convolutionMainGain, default: 10) / 10,
            convolutionSendGain: settings.double(SettingKeys.convolutionSendGain, default: 0) / 10,
            pannerEnabled: settings.bool(SettingKeys.pannerEnable),
            pannerSpeed: max(1, min(settings.int(SettingKeys.pannerSpeed, default: 25), 50)),
            pannerSoundR: max(1, min(settings.int(SettingKeys.pannerSoundR, default: 5), 30))
        )
    }

    // MARK: 环境混响 / 3D 环绕（Phase 2b）

    public var convolutionPresets: [ConvolutionPreset] { ConvolutionPreset.builtin }

    public var convolutionFileName: String? { audioEffects.convolutionFileName }

    public func setConvolutionFileName(_ fileName: String?) {
        let value = fileName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        settings.set(SettingKeys.convolutionFileName, .string(value))
        applyAudioEffects()
    }

    public func applyConvolutionPreset(_ preset: ConvolutionPreset) {
        settings.set([
            SettingKeys.convolutionFileName: .string(preset.fileName),
            SettingKeys.convolutionMainGain: .int(Int64((preset.defaultMainGain * 10).rounded())),
            SettingKeys.convolutionSendGain: .int(Int64((preset.defaultSendGain * 10).rounded())),
        ])
        applyAudioEffects()
    }

    /// 传入百分比数值（原版设置值 0–50，实际增益 = 值/10）
    public func setConvolutionGains(main: Double, send: Double) {
        settings.set([
            SettingKeys.convolutionMainGain: .int(Int64(min(max(main, 0), 50).rounded())),
            SettingKeys.convolutionSendGain: .int(Int64(min(max(send, 0), 50).rounded())),
        ])
        applyAudioEffects()
    }

    public var pannerEnabled: Bool { audioEffects.pannerEnabled }
    public var pannerSpeed: Int { audioEffects.pannerSpeed }
    public var pannerSoundR: Int { audioEffects.pannerSoundR }

    public func setPanner(enabled: Bool? = nil, speed: Int? = nil, soundR: Int? = nil) {
        var updates: [String: JSONValue] = [:]
        if let enabled { updates[SettingKeys.pannerEnable] = .bool(enabled) }
        if let speed { updates[SettingKeys.pannerSpeed] = .int(Int64(max(1, min(speed, 50)))) }
        if let soundR { updates[SettingKeys.pannerSoundR] = .int(Int64(max(1, min(soundR, 30)))) }
        guard !updates.isEmpty else { return }
        settings.set(updates)
        applyAudioEffects()
    }

    public var isAudioEffectsActive: Bool { audioEffects.isActive }

    /// 把当前设置应用到支持音效的播放器（RoutedPlayerService）
    public func applyAudioEffects() {
        (player as? AudioEffectApplying)?.applyAudioEffects(audioEffects)
    }

    /// 设置某段 EQ 增益（dB，-15...15）
    public func setEQBand(_ index: Int, gain: Double) {
        guard SettingKeys.eqBandKeys.indices.contains(index) else { return }
        let clamped = min(max(gain, -15), 15)
        settings.set(SettingKeys.eqBandKeys[index], .double(clamped))
        applyAudioEffects()
    }

    public func resetEQ() {
        var updates: [String: JSONValue] = [:]
        for key in SettingKeys.eqBandKeys { updates[key] = .double(0) }
        settings.set(updates)
        applyAudioEffects()
    }

    /// 原版音效层变调：0.5–1.5 倍的 pitch-shifter playbackRate
    public func setPitchShifterRate(_ rate: Double) {
        let clamped = min(max(rate, 0.5), 1.5)
        settings.set(SettingKeys.pitchShifterRate, .double(clamped))
        applyAudioEffects()
    }

    public var pitchShifterRate: Double {
        settings.double(SettingKeys.pitchShifterRate, default: 1)
    }

    /// 应用 EQ 预设（[dB x 10]）
    public func applyEQPreset(_ bands: [Double]) {
        guard bands.count == SettingKeys.eqBandKeys.count else { return }
        var updates: [String: JSONValue] = [:]
        for (index, key) in SettingKeys.eqBandKeys.enumerated() {
            updates[key] = .double(min(max(bands[index], -15), 15))
        }
        settings.set(updates)
        applyAudioEffects()
    }

    // MARK: - 列表导出（原版文本/CSV 导出）

    @discardableResult
    public func exportLists(kind: ListExportKind, merge: Bool, to directory: URL) -> [URL] {
        do {
            let playlists = try data.exportPlaylistsBackup()
            let urls = try ListTransferService.export(playlists: playlists, kind: kind, merge: merge, to: directory)
            if urls.isEmpty {
                showToast("没有可导出的列表内容")
            } else {
                showToast("已导出 \(urls.count) 个列表文件到 \(directory.lastPathComponent)")
            }
            return urls
        } catch {
            showToast("导出列表失败：\(error.localizedDescription)")
            return []
        }
    }

    // MARK: - 下载持久化

    public private(set) var downloadHistory: [DownloadTaskInfo] = []
    private var persistedDownloadStatus: [String: String] = [:]

    private func loadDownloadHistory() {
        do {
            downloadHistory = try data.loadDownloadTasks().sorted { $0.position < $1.position }
            for task in downloadHistory { persistedDownloadStatus[task.id] = task.status }
        } catch {
            MeloLog.warn("读取下载历史失败：\(error.localizedDescription)")
        }
    }

    /// 任务状态变化时落库（progress 不逐字节写入，避免频繁 IO）
    private func persistDownloadTasksIfNeeded() {
        for task in downloadTasks {
            let previous = persistedDownloadStatus[task.id]
            if previous != task.status || previous == nil {
                do {
                    try data.saveDownloadTask(task)
                    persistedDownloadStatus[task.id] = task.status
                } catch {
                    MeloLog.warn("保存下载任务失败：\(error.localizedDescription)")
                }
            }
        }
        // 清理已从引擎移除的任务（只清理记录，不删文件）
        let alive = Set(downloadTasks.map(\.id))
        let removed = persistedDownloadStatus.keys.filter { !alive.contains($0) }
        if !removed.isEmpty {
            try? data.removeDownloadTasks(ids: removed)
            for id in removed { persistedDownloadStatus.removeValue(forKey: id) }
        }
    }


    // MARK: - 不喜欢的歌曲

    public func reloadDislikes() {
        let dislikes = (try? data.loadDislikes()) ?? []
        dislikeRules = DislikeRules(dislikes: dislikes)
    }

    /// 不喜欢当前/指定歌曲（歌曲名 + 歌手规则）
    public func dislike(_ music: MusicInfo?) {
        guard let music else { return }
        do {
            try data.addDislikeMusic(name: music.name, singer: music.singer)
            reloadDislikes()
            showToast("已加入「不喜欢的歌曲」：\(music.name)")
        } catch {
            showToast("操作失败：\(error.localizedDescription)")
        }
    }

    public func saveDislikeRulesText(_ text: String) {
        do {
            try data.saveDislikeRulesText(text)
            reloadDislikes()
            showToast("已保存不喜欢规则（\(dislikeRules.count) 条）")
        } catch {
            showToast("保存失败：\(error.localizedDescription)")
        }
    }

    public func clearDislikes() {
        do {
            try data.clearDislikes()
            reloadDislikes()
            showToast("已清空不喜欢的歌曲规则")
        } catch {
            showToast("清空失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 网络代理（原版 network.proxy.*）

    public var proxySettings: ProxySettings {
        ProxySettings(
            enabled: settings.bool(SettingKeys.proxyEnable),
            host: settings.string(SettingKeys.proxyHost) ?? "",
            port: settings.int(SettingKeys.proxyPort, default: 0),
            username: settings.string(SettingKeys.proxyUsername) ?? "",
            password: settings.string(SettingKeys.proxyPassword) ?? ""
        )
    }

    public func applyProxySettings() {
        let proxy = proxySettings
        (metadata as? ProxyConfiguring)?.configureProxy(proxy)
        (customSources as? ProxyConfiguring)?.configureProxy(proxy)
        NotificationCenter.default.post(name: .meloProxySettingsChanged, object: nil)
    }

    public func setProxy(enabled: Bool, host: String, port: Int, username: String = "", password: String = "") {
        settings.set([
            SettingKeys.proxyEnable: .bool(enabled),
            SettingKeys.proxyHost: .string(host.trimmingCharacters(in: .whitespaces)),
            SettingKeys.proxyPort: .int(Int64(max(0, min(port, 65535)))),
            SettingKeys.proxyUsername: .string(username),
            SettingKeys.proxyPassword: .string(password),
        ])
        applyProxySettings()
        showToast(enabled ? "代理已启用：\(host):\(port)" : "代理已关闭")
    }

    // MARK: - 开机自启

    public var openAtLogin: Bool { settings.bool(SettingKeys.openAtLogin) }

    public func setOpenAtLogin(_ enabled: Bool) {
        settings.set(SettingKeys.openAtLogin, .bool(enabled))
        NotificationCenter.default.post(name: .meloOpenAtLoginChanged, object: nil)
        showToast(enabled ? "已开启开机自启" : "已关闭开机自启")
    }

    // MARK: - 缓存管理

    public private(set) var cacheCategories: [CacheCategoryInfo] = []
    public private(set) var totalCacheSize: Int64 = 0

    public func refreshCacheInfo() {
        cacheCategories = cacheManager?.cacheCategories() ?? []
        totalCacheSize = cacheManager?.totalCacheSizeBytes ?? 0
    }

    @discardableResult
    public func clearCache(categoryID: String) -> Int {
        guard let cacheManager else { return 0 }
        do {
            let freed = try cacheManager.clearCache(categoryID: categoryID)
            refreshCacheInfo()
            showToast("已清理缓存，释放 \(ByteCountFormatter.string(fromByteCount: Int64(freed), countStyle: .file))")
            return freed
        } catch {
            showToast("清理缓存失败：\(error.localizedDescription)")
            return 0
        }
    }

    // MARK: - 音频输出设备（原版 player.mediaDeviceId）

    public var availableOutputDevices: [AudioOutputDeviceInfo] {
        (player as? AudioOutputDeviceSelecting)?.availableOutputDevices() ?? []
    }

    /// "default" 或设备 UID
    public var mediaDeviceId: String {
        settings.string(SettingKeys.mediaDeviceId) ?? "default"
    }

    public var currentOutputDeviceName: String {
        let uid = mediaDeviceId
        if uid == "default" || uid.isEmpty { return "系统默认" }
        return availableOutputDevices.first { $0.id == uid }?.name ?? uid
    }

    /// 选择音频输出设备；uid 传 nil 表示系统默认。
    /// 注意：AVPlayer 无法指定输出设备，选择自定义设备时播放会走音效引擎（远程音频需先缓存）。
    public func setMediaDeviceId(_ uid: String?) {
        let value = (uid?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? "default"
        settings.set(SettingKeys.mediaDeviceId, .string(value))
        do {
            try (player as? AudioOutputDeviceSelecting)?.applyOutputDevice(uid: value == "default" ? nil : value)
            showToast(value == "default" ? "音频输出：系统默认" : "音频输出：\(currentOutputDeviceName)")
        } catch {
            showToast("切换音频输出设备失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 备份与恢复（原版 .lxmc 格式）

    public func exportBackup(kind: BackupKind, to url: URL) {
        do {
            try backup.export(kind: kind, to: url)
            showToast("已导出备份：\(url.lastPathComponent)")
        } catch {
            showToast("导出备份失败：\(error.localizedDescription)")
        }
    }

    public func importBackup(from url: URL) {
        do {
            let summary = try backup.importBackup(from: url)
            reloadSettingsAfterRestore()
            refreshLibrary()
            loadMusicsForSelectedList()
            loadDownloadHistory()
            theme.reloadUserThemes()
            showToast("已恢复备份：\(summary.lists) 个列表 / \(summary.musics) 首歌曲\(summary.settingsImported ? " / 设置" : "")")
        } catch {
            showToast("恢复备份失败：\(error.localizedDescription)")
        }
    }

    /// 恢复设置后把受影响的运行时状态重新应用一遍
    private func reloadSettingsAfterRestore() {
        volume = min(max(settings.double(SettingKeys.playerVolume, default: 1), 0), 1)
        isMuted = settings.bool(SettingKeys.playerMute)
        playbackRate = min(max(settings.double(SettingKeys.playbackRate, default: 1), 0.5), 2)
        player.volume = volume
        player.isMuted = isMuted
        player.playbackRate = playbackRate
        theme.refreshCurrent()
        if let language = settings.languageID { localizer.setLanguage(language) }
        applyAudioEffects()
        try? (player as? AudioOutputDeviceSelecting)?.applyOutputDevice(uid: mediaDeviceId == "default" ? nil : mediaDeviceId)
    }

    // MARK: - 开放 API（本地 HTTP 服务）

    public private(set) var openAPIRunning = false
    public private(set) var openAPIError: String?

    public var openAPIEnabled: Bool { settings.bool(SettingKeys.openAPIEnable) }
    public var openAPIPort: Int { max(1, min(settings.int(SettingKeys.openAPIPort, default: 23330), 65535)) }
    public var openAPIToken: String { settings.string(SettingKeys.openAPIToken) ?? "" }
    public var openAPIBindLan: Bool { settings.bool(SettingKeys.openAPIBindLan) }

    public func restartOpenAPI() {
        openAPI?.stop()
        openAPIRunning = false
        openAPIError = nil
        guard settings.bool(SettingKeys.openAPIEnable), let server = openAPI else { return }
        do {
            try server.start(port: UInt16(openAPIPort), token: openAPIToken.isEmpty ? nil : openAPIToken,
                             bindLan: openAPIBindLan, host: self)
            openAPIRunning = server.isRunning
        } catch {
            openAPIError = error.localizedDescription
            openAPIRunning = false
            MeloLog.warn("开放 API 启动失败：\(error.localizedDescription)")
        }
    }

    public func setOpenAPI(enabled: Bool, port: Int? = nil, token: String? = nil, bindLan: Bool? = nil) {
        var updates: [String: JSONValue] = [SettingKeys.openAPIEnable: .bool(enabled)]
        if let port { updates[SettingKeys.openAPIPort] = .int(Int64(max(1, min(port, 65535)))) }
        if let token { updates[SettingKeys.openAPIToken] = .string(token) }
        if let bindLan { updates[SettingKeys.openAPIBindLan] = .bool(bindLan) }
        settings.set(updates)
        restartOpenAPI()
        if enabled {
            showToast(openAPIRunning ? "开放 API 已启动：127.0.0.1:\(openAPIPort)" : "开放 API 启动失败：\(openAPIError ?? "未知错误")")
        } else {
            showToast("开放 API 已关闭")
        }
    }

}


extension AppModel: OpenAPIHost {
    public func openAPIStatus() -> OpenAPIStatus {
        let music = currentMusic.map { item in
            OpenAPIMusic(
                id: item.id,
                name: item.name,
                singer: item.singer,
                albumName: item.albumName,
                source: item.source,
                duration: duration > 0 ? duration : MeloUtils.parseInterval(item.interval)
            )
        }
        return OpenAPIStatus(
            status: playerStatus.rawValue,
            isPlaying: isPlaying,
            music: music,
            currentTime: currentTime,
            duration: duration,
            volume: volume,
            isMuted: isMuted,
            playbackRate: playbackRate,
            quality: currentMusic.map { pickQuality(for: $0) } ?? settings.string(SettingKeys.playQuality),
            queueCount: playQueue.count
        )
    }

    public func openAPICommand(_ command: String, arguments: [String: String]) async -> OpenAPICommandResult {
        switch command.lowercased() {
        case "play":
            if playerStatus != .playing { togglePlayPause() }
            return OpenAPICommandResult(ok: true, status: openAPIStatus())
        case "pause":
            if playerStatus == .playing { togglePlayPause() }
            return OpenAPICommandResult(ok: true, status: openAPIStatus())
        case "toggle", "toggleplay", "toggleplaypause":
            togglePlayPause()
            return OpenAPICommandResult(ok: true, status: openAPIStatus())
        case "next", "skipnext":
            next()
            return OpenAPICommandResult(ok: true, status: openAPIStatus())
        case "previous", "prev", "skipprev":
            previous()
            return OpenAPICommandResult(ok: true, status: openAPIStatus())
        case "seek":
            if let raw = arguments["position"], let seconds = Double(raw) {
                seek(to: seconds)
            } else if let percent = arguments["percent"].flatMap(Double.init) {
                seek(to: duration * max(0, min(percent, 100)) / 100)
            } else {
                return OpenAPICommandResult(ok: false, message: "seek 需要 position(秒) 或 percent(0-100) 参数")
            }
            return OpenAPICommandResult(ok: true, status: openAPIStatus())
        case "mute":
            if let raw = arguments["mute"] {
                let want: Bool?
                switch raw.lowercased() {
                case "true", "1", "yes": want = true
                case "false", "0", "no": want = false
                default: want = nil
                }
                guard let want else {
                    return OpenAPICommandResult(ok: false, message: "mute 需要 true/false 参数")
                }
                if want != isMuted { toggleMute() }
            } else {
                toggleMute()
            }
            return OpenAPICommandResult(ok: true, status: openAPIStatus())
        case "volume", "setvolume":
            guard let raw = arguments["volume"], let value = Double(raw) else {
                return OpenAPICommandResult(ok: false, message: "volume 需要 0-1 参数")
            }
            setVolume(value)
            return OpenAPICommandResult(ok: true, status: openAPIStatus())
        case "collect", "like":
            if let music = currentMusic, !isFavorite(music) { toggleFavorite(music) }
            return OpenAPICommandResult(ok: true, status: openAPIStatus())
        case "uncollect", "unlike":
            if let music = currentMusic, isFavorite(music) { toggleFavorite(music) }
            return OpenAPICommandResult(ok: true, status: openAPIStatus())
        default:
            return OpenAPICommandResult(ok: false, message: "不支持的命令：\(command)")
        }
    }

    // MARK: - 快捷键（hot_key.json）

    private var hotKeyDataDirectory: URL { settings.fileURL.deletingLastPathComponent() }

    public var hotKeyLocalDefinitions: [HotKeyDefinition] { HotKeyStore.localDefinitions }
    public var hotKeyGlobalDefinitions: [HotKeyDefinition] { HotKeyStore.globalDefinitions }

    public func hotKeyBinding(for action: String, scope: HotKeyScope) -> String? {
        let config = scope == .local ? hotKeys.local : hotKeys.global
        return config.keys.first { $0.value.action == action }?.key
    }

    public func hotKeyDisplayName(for action: String, scope: HotKeyScope) -> String {
        guard let shortcut = hotKeyBinding(for: action, scope: scope) else { return "" }
        return HotKeyStore.displayName(for: shortcut)
    }

    public func setHotKeysEnabled(_ enabled: Bool, scope: HotKeyScope) {
        var config = hotKeys
        if scope == .local { config.local.enable = enabled } else { config.global.enable = enabled }
        persistHotKeys(config)
    }

    /// 绑定快捷键：同 scope 内同 action 的旧绑定会被移除；同一快捷键已被其它动作占用时会被覆盖（原版行为）
    public func bindHotKey(_ shortcut: String, to definition: HotKeyDefinition, scope: HotKeyScope) {
        let normalized = HotKeyStore.normalize(shortcut)
        guard !normalized.isEmpty else { return }
        var config = hotKeys
        var keys = scope == .local ? config.local.keys : config.global.keys
        keys = keys.filter { $0.value.action != definition.action }
        keys[normalized] = HotKeyBinding(type: definition.type, name: definition.action, action: definition.action)
        if scope == .local { config.local.keys = keys } else { config.global.keys = keys }
        persistHotKeys(config)
        showToast("已绑定「\(definition.label)」：\(HotKeyStore.displayName(for: normalized))")
    }

    public func unbindHotKey(for action: String, scope: HotKeyScope) {
        var config = hotKeys
        var keys = scope == .local ? config.local.keys : config.global.keys
        keys = keys.filter { $0.value.action != action }
        if scope == .local { config.local.keys = keys } else { config.global.keys = keys }
        persistHotKeys(config)
    }

    public func resetHotKeys() {
        persistHotKeys(HotKeyStore.defaultConfig)
        showToast("快捷键已恢复默认")
    }

    public func reloadHotKeys() {
        hotKeys = HotKeyStore.load(from: hotKeyDataDirectory)
        NotificationCenter.default.post(name: .meloHotKeysChanged, object: nil)
    }

    private func persistHotKeys(_ config: HotKeyConfigAll) {
        hotKeys = config
        do {
            try HotKeyStore.save(config, to: hotKeyDataDirectory)
        } catch {
            showToast("保存快捷键设置失败：\(error.localizedDescription)")
        }
        NotificationCenter.default.post(name: .meloHotKeysChanged, object: nil)
    }

    /// 执行快捷键动作；窗口类动作返回 false 由 App 层处理。
    public func performHotKeyAction(_ action: String) -> Bool {
        switch action {
        case "player_toggle_play":
            togglePlayPause()
        case "player_next":
            next()
        case "player_prev":
            previous()
        case "player_seekbackward":
            seek(to: max(0, currentTime - 5))
        case "player_seekforward":
            seek(to: min(duration, currentTime + 5))
        case "player_volume_up":
            setVolume(min(1, volume + 0.05))
        case "player_volume_down":
            setVolume(max(0, volume - 0.05))
        case "player_volume_mute":
            toggleMute()
        case "player_music_love":
            if let music = currentMusic, !isFavorite(music) { toggleFavorite(music) }
        case "player_music_unlove":
            if let music = currentMusic, isFavorite(music) { toggleFavorite(music) }
        case "player_music_dislike":
            showToast("暂不支持「不喜欢」功能")
        case "desktop_lyric_toggle_lock":
            let locked = settings.bool("desktopLyric.isLock")
            settings.set("desktopLyric.isLock", .bool(!locked))
            NotificationCenter.default.post(name: .meloDesktopLyricSettingsChanged, object: nil)
        case "desktop_lyric_toggle_always_top":
            let top = settings.bool("desktopLyric.isAlwaysOnTop")
            settings.set("desktopLyric.isAlwaysOnTop", .bool(!top))
            NotificationCenter.default.post(name: .meloDesktopLyricSettingsChanged, object: nil)
        case "desktop_lyric_toggle_visible":
            NotificationCenter.default.post(name: .meloToggleDesktopLyricWindow, object: nil)
        case "common_focus_search_input":
            route = .search
            NotificationCenter.default.post(name: .meloFocusSearchInput, object: nil)
        default:
            return false
        }
        return true
    }

}


extension AppModel {
    public func openAPIPlayerStatus() -> [String: JSONValue] {
        let originalStatus: String
        switch playerStatus {
        case .playing: originalStatus = "playing"
        case .paused: originalStatus = "paused"
        case .error: originalStatus = "error"
        case .loading: originalStatus = "playing"
        case .stopped: originalStatus = "stoped"
        }
        let currentLine = currentLyricIndex.flatMap { index in
            lyricDocument.lines.indices.contains(index) ? lyricDocument.lines[index].text : nil
        } ?? ""
        return [
            "status": .string(originalStatus),
            "name": .string(currentMusic?.name ?? ""),
            "singer": .string(currentMusic?.singer ?? ""),
            "albumName": .string(currentMusic?.albumName ?? ""),
            "picUrl": .string(currentMusic?.picUrl ?? ""),
            "progress": .double(currentTime),
            "duration": .double(duration),
            "playbackRate": .double(playbackRate),
            "lyricLineText": .string(currentLine),
            "lyricLineAllText": .string(currentLine),
            "lyric": .string(lyric.lyric),
            "tlyric": .string(lyric.tlyric ?? ""),
            "rlyric": .string(lyric.rlyric ?? ""),
            "lxlyric": .string(lyric.lxlyric ?? ""),
            "collect": .bool(currentMusic.map { isFavorite($0) } ?? false),
            "volume": .double(volume),
            "mute": .bool(isMuted),
        ]
    }

    public func openAPILyricBundle() -> [String: String] {
        [
            "lyric": lyric.lyric,
            "tlyric": lyric.tlyric ?? "",
            "rlyric": lyric.rlyric ?? "",
            "lxlyric": lyric.lxlyric ?? "",
        ]
    }

    // MARK: - 本地歌词关联 / 歌词重新加载

    public func reloadCurrentLyric() {
        guard let music = currentMusic else { return }
        loadLyric(for: music)
    }

    /// 关联本地歌词文件（保存到原版 lyric 表 source='edited'，优先于在线歌词）
    @discardableResult
    public func associateLocalLyricFile(_ url: URL) -> Bool {
        guard let music = currentMusic else {
            MeloLog.warn("关联本地歌词失败：当前没有播放歌曲")
            showToast("请先播放一首歌曲")
            return false
        }
        do {
            let text = try Self.readLyricFile(url)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                showToast("歌词文件为空：\(url.lastPathComponent)")
                return false
            }
            try data.saveLyric(musicId: music.id, source: "edited", type: "lyric", text: text)
            for type in ["tlyric", "rlyric", "lxlyric"] {
                try? data.removeLyric(musicId: music.id, source: "edited", type: type)
            }
            loadLyric(for: music)
            showToast("已关联本地歌词：\(url.lastPathComponent)")
            return true
        } catch {
            MeloLog.warn("关联本地歌词失败：\(error.localizedDescription)")
            showToast("关联本地歌词失败：\(error.localizedDescription)")
            return false
        }
    }

    public func removeLocalLyricAssociation() {
        guard let music = currentMusic else { return }
        for type in ["lyric", "tlyric", "rlyric", "lxlyric"] {
            try? data.removeLyric(musicId: music.id, source: "edited", type: type)
        }
        loadLyric(for: music)
        showToast("已取消本地歌词关联")
    }

    private static func readLyricFile(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        if let text = String(data: data, encoding: .utf8) { return text }
        if let text = String(data: data, encoding: .utf16) { return text }
        let gb = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        if let text = String(data: data, encoding: String.Encoding(rawValue: gb)) { return text }
        throw CocoaError(.fileReadInapplicableStringEncoding)
    }

    // MARK: - 音频可视化（实验性；仅音效引擎播放时可用）

    public var isAudioVisualizationEnabled: Bool { settings.bool(SettingKeys.playerAudioVisualization) }

    /// 修改音频可视化开关（写设置并通知播放器重新路由）
    public func setAudioVisualizationEnabled(_ enabled: Bool, desktopLyric: Bool = false) {
        settings.set(desktopLyric ? SettingKeys.desktopLyricAudioVisualization : SettingKeys.playerAudioVisualization,
                     .bool(enabled))
        (player as? AudioVisualizationRouting)?.applyVisualizationSetting()
        showToast(enabled ? "音频可视化已开启（音效引擎播放时生效）" : "音频可视化已关闭")
    }
    public var isDesktopLyricAudioVisualizationEnabled: Bool { settings.bool(SettingKeys.desktopLyricAudioVisualization) }
    public var currentSpectrum: AudioSpectrum? { (player as? AudioVisualizerProviding)?.currentSpectrum }
    public var isVisualizerAvailable: Bool { (player as? AudioVisualizerProviding)?.isVisualizerAvailable ?? false }

    // MARK: - 歌词显示开关（原版设置键）

    public var showLyricTranslation: Bool { settings.bool(SettingKeys.showLyricTranslation) }
    public var showLyricRoma: Bool { settings.bool(SettingKeys.showLyricRoma) }
    public var swapLyricTranslationAndRoma: Bool { settings.bool(SettingKeys.swapLyricTranslationAndRoma) }
    public var playWordByWordLyric: Bool { settings.bool(SettingKeys.playWordByWordLyric) }
    public var convertLyricS2T: Bool { settings.bool(SettingKeys.convertLyricS2T) }
    public var showStatusBarLyric: Bool { settings.bool(SettingKeys.showStatusBarLyric) }

    public func setLyricDisplayOption(_ key: String, enabled: Bool) {
        settings.set(key, .bool(enabled))
    }

    // MARK: - 桌面歌词样式设置（原版 desktopLyric.* 设置键）

    public var desktopLyricFontSize: Double { settings.double(SettingKeys.desktopLyricFontSize, default: 20) }
    public var desktopLyricOpacity: Double { settings.double(SettingKeys.desktopLyricOpacity, default: 95) }
    public var desktopLyricLineGap: Double { settings.double(SettingKeys.desktopLyricLineGap, default: 15) }
    public var desktopLyricAlign: String { settings.string(SettingKeys.desktopLyricAlign) ?? "center" }
    public var desktopLyricPlayedColor: String { settings.string(SettingKeys.desktopLyricPlayedColor) ?? "rgba(7, 197, 86, 1)" }
    public var desktopLyricUnplayColor: String { settings.string(SettingKeys.desktopLyricUnplayColor) ?? "rgba(255, 255, 255, 1)" }
    public var desktopLyricShadowColor: String { settings.string(SettingKeys.desktopLyricShadowColor) ?? "rgba(0, 0, 0, 0.18)" }
    public var desktopLyricPauseHide: Bool { settings.bool(SettingKeys.desktopLyricPauseHide) }
    public var desktopLyricHoverHide: Bool { settings.bool(SettingKeys.desktopLyricHoverHide) }
    public var desktopLyricFullscreenHide: Bool { settings.bool(SettingKeys.desktopLyricFullscreenHide) }
    public var desktopLyricDelayScroll: Bool { settings.bool(SettingKeys.desktopLyricDelayScroll) }
    public var desktopLyricEllipsis: Bool { settings.bool(SettingKeys.desktopLyricEllipsis) }

    public func setDesktopLyricFontSize(_ value: Double) {
        settings.set(SettingKeys.desktopLyricFontSize, .double(min(max(value, 10), 60)))
    }

    public func setDesktopLyricOpacity(_ value: Double) {
        settings.set(SettingKeys.desktopLyricOpacity, .double(min(max(value, 10), 100)))
    }

    public func setDesktopLyricLineGap(_ value: Double) {
        settings.set(SettingKeys.desktopLyricLineGap, .double(min(max(value, 0), 60)))
    }

    public func setDesktopLyricAlign(_ value: String) {
        guard ["left", "center", "right"].contains(value) else { return }
        settings.set(SettingKeys.desktopLyricAlign, .string(value))
    }

    public func setDesktopLyricColors(played: String?, unplay: String?, shadow: String?) {
        var updates: [String: JSONValue] = [:]
        if let played { updates[SettingKeys.desktopLyricPlayedColor] = .string(played) }
        if let unplay { updates[SettingKeys.desktopLyricUnplayColor] = .string(unplay) }
        if let shadow { updates[SettingKeys.desktopLyricShadowColor] = .string(shadow) }
        guard !updates.isEmpty else { return }
        settings.set(updates)
    }

    public func setDesktopLyricBehavior(_ key: String, enabled: Bool) {
        settings.set(key, .bool(enabled))
    }

    // MARK: - 歌词偏移（写回原版 lyric 表 source='edited'）

    public var lyricOffsetMs: Int { lyricDocument.offsetMs }

    public func adjustLyricOffset(by delta: Int) {
        guard currentMusic != nil, !lyric.lyric.isEmpty else {
            MeloLog.warn("调整歌词偏移失败：当前没有可调整的歌词（currentMusic=\(currentMusic?.name ?? "nil")）")
            showToast("当前没有可调整的歌词")
            return
        }
        setLyricOffset(lyricOffsetMs + delta)
    }

    public func resetLyricOffset() {
        guard let music = currentMusic else { return }
        for type in ["lyric", "tlyric", "rlyric", "lxlyric"] {
            try? data.removeLyric(musicId: music.id, source: "edited", type: type)
        }
        loadLyric(for: music)
        showToast("歌词偏移已重置")
    }

    private func setLyricOffset(_ offsetMs: Int) {
        guard let music = currentMusic else { return }
        let clamped = min(max(offsetMs, -60_000), 60_000)
        var lines = lyric.lyric
            .components(separatedBy: .newlines)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return !(trimmed.hasPrefix("[offset:") && trimmed.hasSuffix("]"))
            }
        if clamped != 0 {
            lines.insert("[offset:\(clamped)]", at: 0)
        }
        let newText = lines.joined(separator: "\n")
        do {
            try data.saveLyric(musicId: music.id, source: "edited", type: "lyric", text: newText)
        } catch {
            showToast("保存歌词偏移失败：\(error.localizedDescription)")
            return
        }
        lyric.lyric = newText
        lyricDocument = LyricParser.parse(
            lyric.lyric,
            translated: lyric.tlyric,
            roman: lyric.rlyric,
            wordByWord: lyric.lxlyric
        )
        currentLyricIndex = lyricDocument.lineIndex(at: currentTime)
        showToast("歌词偏移：\(clamped > 0 ? "+" : "")\(clamped)ms")
    }

    // MARK: - 歌曲评论（内置元数据源）


    public func clearComments() {
        comments = []
        hotComments = []
        commentsTotal = 0
        commentsPage = 0
        commentsMaxPage = 0
        commentsError = nil
        commentsMusicId = nil
    }

    /// hot=true 加载热门评论，否则加载最新评论；reset=true 从第一页开始
    public func loadComments(hot: Bool = false, reset: Bool = false) async {
        guard let music = currentMusic else { return }
        if reset || commentsMusicId != music.id {
            comments = []
            hotComments = []
            commentsTotal = 0
            commentsPage = 0
            commentsMaxPage = 0
            commentsError = nil
            commentsMusicId = music.id
        }
        guard metadataReady else {
            commentsError = "内置音源尚未就绪"
            return
        }
        isLoadingComments = true
        defer { isLoadingComments = false }
        do {
            if hot {
                if !hotComments.isEmpty { return }
                let page = try await metadata.hotComments(musicInfo: music, limit: 30)
                hotComments = page.comments
                MeloLog.info("热门评论加载：\(music.name) \(page.comments.count) 条")
            } else {
                let nextPage = commentsPage + 1
                let page = try await metadata.comments(musicInfo: music, page: nextPage, limit: 20)
                comments += page.comments
                commentsPage = page.page
                commentsTotal = page.total
                commentsMaxPage = page.maxPage
                MeloLog.info("评论加载：\(music.name) 第 \(page.page) 页，\(page.comments.count) 条 / 共 \(page.total) 条")
            }
        } catch {
            commentsError = error.localizedDescription
        }
    }

    public func loadMoreComments() async {
        guard !isLoadingComments else { return }
        await loadComments(hot: false, reset: false)
    }

}
