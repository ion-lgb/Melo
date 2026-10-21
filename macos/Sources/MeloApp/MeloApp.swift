import SwiftUI
import AppKit
import MeloCore
import MeloData
import MeloAudio
import MeloJS
import MeloUI

@main
struct MeloDesktopApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model: AppModel

    init() {
        let userData = ResourceLocator.defaultDataDirectory()
        let lxData = ResourceLocator.lxDatasDirectory(in: userData)
        try? FileManager.default.createDirectory(at: lxData, withIntermediateDirectories: true)

        let settings = SettingsStore(dataDirectory: lxData)
        let theme = ThemeManager(
            resourcesDirectory: ResourceLocator.resourcesDirectory(),
            settings: settings,
            dataDirectory: lxData
        )
        let localizer = Localizer(resourcesDirectory: ResourceLocator.resourcesDirectory(), settings: settings)
        Localizer.install(localizer)
        let data = SQLiteDataService(dataDirectory: lxData)
        let avPlayer = AVPlayerService()
        let effectsPlayer = EffectsAudioEngine(resourcesDirectory: ResourceLocator.resourcesDirectory())
        let player = RoutedPlayerService(settings: settings, avPlayer: avPlayer, effectsPlayer: effectsPlayer)
        let sources = JSCustomSourceService(dataDirectory: lxData, settings: settings)
        let metadata = JSMetadataService(resourcesDirectory: ResourceLocator.resourcesDirectory())
        let downloads = MeloDownloadService(maxConcurrent: settings.int(SettingKeys.downloadMaxNumber, default: 3))
        let openAPI = OpenAPIServer()
        let cache = MeloCacheService(dataDirectory: lxData)
        let appDataStore = AppDataFileStore(dataDirectory: lxData)

        let appModel = AppModel(
            settings: settings,
            theme: theme,
            localizer: localizer,
            data: data,
            player: player,
            customSources: sources,
            metadata: metadata,
            downloads: downloads,
            openAPI: openAPI,
            cache: cache,
            appData: appDataStore
        )
        _model = State(initialValue: appModel)
        AppDelegate.model = appModel
    }

    var body: some Scene {
        Window("Melo", id: "main") {
            MainWindowHost(model: model)
        }
        .defaultSize(width: 1260, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("播放") {
                Button(model.isPlaying ? "暂停" : "播放") { model.togglePlayPause() }
                    .keyboardShortcut("p", modifiers: [.command])
                Button("上一首") { model.previous() }
                    .keyboardShortcut(.leftArrow, modifiers: [.command])
                Button("下一首") { model.next() }
                    .keyboardShortcut(.rightArrow, modifiers: [.command])
                Divider()
                Button("播放详情") { model.openPlayDetail() }
                    .keyboardShortcut("d", modifiers: [.command])
            }
            CommandGroup(replacing: .appSettings) {
                Button("设置…") {
                    model.route = .settings
                    AppWindows.showMain()
                }
                .keyboardShortcut(",", modifiers: [.command])
            }
            CommandGroup(after: .appInfo) {
                Divider()
                Button("显示主窗口") { AppWindows.showMain() }
                    .keyboardShortcut("0", modifiers: [.command])
            }
        }

        Window("桌面歌词", id: "desktop-lyric") {
            DesktopLyricView(app: model)
                .background(LyricWindowConfigurator())
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 620, height: 220)
        .windowResizability(.contentSize)

        MenuBarExtra {
            MenuBarContent(model: model)
        } label: {
            Image(systemName: "music.note")
        }
    }
}

/// 主窗口宿主：负责生命周期 bootstrap、冷启动 Scheme URL、菜单通知桥接。
struct MainWindowHost: View {
    @Environment(\.openWindow) private var openWindow
    let model: AppModel

    var body: some View {
        RootWindowView(app: model)
            .frame(minWidth: 1000, minHeight: 620)
            .background(MainWindowConfigurator())
            .onReceive(NotificationCenter.default.publisher(for: .meloToggleDesktopLyric)) { _ in
                toggleDesktopLyric()
            }
            .onReceive(NotificationCenter.default.publisher(for: .meloToggleDesktopLyricWindow)) { _ in
                toggleDesktopLyric()
            }
            .onReceive(NotificationCenter.default.publisher(for: .meloDesktopLyricSettingsChanged)) { _ in
                LyricWindowBehavior.shared.syncFromSettings()
            }
            .onReceive(NotificationCenter.default.publisher(for: .meloShowAbout)) { _ in
                model.route = .settings
            }
            .task {
                model.bootstrap()
                await AppDelegate.drainPendingURLs(model: model)
                // 开发期：切换音频输出设备（uid，空字符串=系统默认）
                if let device = ProcessInfo.processInfo.environment["MELO_OUTPUT_DEVICE"] {
                    model.setMediaDeviceId(device.isEmpty ? nil : device)
                }
                // 开发期：不喜欢规则 + 播放跳过验证
                if ProcessInfo.processInfo.environment["MELO_DISLIKE_TEST"] == "1" {
                    let dir = "/tmp/melo-local-music"
                    let audio = [
                        (dir + "/第一首.wav", "第一首"),
                        (dir + "/sub/Third Song.WAV", "Third Song"),
                        (dir + "/sub/第二首.m4a", "第二首"),
                    ].map { path, name in
                        MusicInfo(id: path, name: name, singer: "", source: "local", interval: "00:20",
                                  meta: .object(["albumName": .string(""), "filePath": .string(path),
                                                 "songId": .string(path), "picUrl": .string(""), "ext": .string("wav")]))
                    }
                    model.saveDislikeRulesText("Third Song")
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    model.play(audio[0], queue: audio)
                    MeloLog.info("[dev] 不喜欢测试：播放 \(audio[0].name)，下一首应跳过 \(audio[1].name)")
                }
                // 开发期：开机自启
                if let raw = ProcessInfo.processInfo.environment["MELO_OPEN_AT_LOGIN"] {
                    model.setOpenAtLogin(raw == "1")
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    MeloLog.info("[dev] 开机自启状态：\(AutoLaunchManager.isEnabled)")
                }
                // 开发期：设置定时暂停（分钟）
                if let raw = ProcessInfo.processInfo.environment["MELO_SLEEP_TIMER"], let minutes = Int(raw), minutes > 0 {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    model.setPlayTimeout(minutes: minutes, waitSongEnd: false)
                }
                // 开发期：更新所有在线用户列表（需 DB 里已有带 source/sourceListId 的列表）
                if ProcessInfo.processInfo.environment["MELO_UPDATE_LISTS"] == "1" {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    for list in model.onlineUserLists {
                        MeloLog.info("[dev] 开始更新列表：\(list.name) source=\(list.source ?? "") id=\(list.sourceListId ?? "")")
                        await model.updateSourceList(id: list.id)
                    }
                    MeloLog.info("[dev] 在线列表更新完成")
                }
                // 开发期：导出列表（文本/CSV）到目录
                if let dir = ProcessInfo.processInfo.environment["MELO_EXPORT_LISTS"], !dir.isEmpty {
                    let kind: ListExportKind = ProcessInfo.processInfo.environment["MELO_EXPORT_LISTS_KIND"] == "csv" ? .csv : .text
                    let merge = ProcessInfo.processInfo.environment["MELO_EXPORT_LISTS_MERGE"] != "0"
                    let urls = model.exportLists(kind: kind, merge: merge, to: URL(fileURLWithPath: dir))
                    MeloLog.info("[dev] 列表导出 \(urls.count) 个文件：\(urls.map(\.lastPathComponent).joined(separator: ", "))")
                }
                // 开发期：缓存统计（验证 CacheManager 接入）
                if ProcessInfo.processInfo.environment["MELO_CACHE_INFO"] == "1" {
                    model.refreshCacheInfo()
                    MeloLog.info("[dev] 缓存总占用 \(ByteCountFormatter.string(fromByteCount: model.totalCacheSize, countStyle: .file))")
                    for category in model.cacheCategories {
                        MeloLog.info("[dev] 缓存 \(category.name)：\(category.displaySize) / \(category.fileCount) 文件")
                    }
                }
                // 开发期：播放模式（循环/单曲/随机等）
                if let mode = ProcessInfo.processInfo.environment["MELO_PLAYMODE"], let parsed = PlayMode(rawValue: mode) {
                    model.setPlayMode(parsed)
                }
                // 开发期：绑定一个全局快捷键用于验证 Carbon 注册
                if ProcessInfo.processInfo.environment["MELO_TEST_HOTKEY"] == "1",
                   let definition = HotKeyStore.globalDefinitions.first(where: { $0.action == "player_next" }) {
                    model.bindHotKey("mod+alt+f12", to: definition, scope: .global)
                    model.setHotKeysEnabled(true, scope: .global)
                }
                // 开发期：备份导出/导入 + 开放 API 联调
                if let backupPath = ProcessInfo.processInfo.environment["MELO_EXPORT_BACKUP"], !backupPath.isEmpty {
                    model.exportBackup(kind: .allData, to: URL(fileURLWithPath: backupPath))
                }
                if let backupPath = ProcessInfo.processInfo.environment["MELO_IMPORT_BACKUP"], !backupPath.isEmpty {
                    model.importBackup(from: URL(fileURLWithPath: backupPath))
                }
                if ProcessInfo.processInfo.environment["MELO_OPENAPI"] == "1" {
                    model.setOpenAPI(enabled: true, port: 23333, token: "melo-test")
                }
                // 开发期：创建并应用用户主题（验证 theme.json 持久化 + 主题编辑器数据）
                if ProcessInfo.processInfo.environment["MELO_CREATE_THEME"] == "1" {
                    if let created = model.createUserTheme(name: "日落测试", baseThemeID: "orange", overrides: [
                        "--color-primary": "#ff6a3d",
                    ]) {
                        model.setTheme(id: created.id)
                    }
                }
                // 开发期：在线导入自定义源（URL）
                if let sourceURL = ProcessInfo.processInfo.environment["MELO_IMPORT_SOURCE_URL"], !sourceURL.isEmpty {
                    await model.importSourceFromURL(sourceURL)
                }
                // 开发期：导入本地音乐（文件或目录）
                if let localPath = ProcessInfo.processInfo.environment["MELO_IMPORT_LOCAL_DIR"], !localPath.isEmpty {
                    MeloLog.info("[dev] 导入本地音乐：\(localPath)")
                    await model.importLocalMusic(urls: [URL(fileURLWithPath: localPath)])
                    MeloLog.info("[dev] 导入后当前列表 \(model.currentMusics.count) 首")
                }
                // 开发期：导入后自动播放第一首本地音乐
                if ProcessInfo.processInfo.environment["MELO_PLAY_LOCAL_FIRST"] == "1" {
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    if let local = model.currentMusics.first(where: { $0.isLocal }) {
                        MeloLog.info("[dev] 播放本地音乐：\(local.name) file=\(local.filePath ?? "nil")")
                        model.play(local, queue: model.currentMusics)
                    } else {
                        MeloLog.warn("[dev] 未找到本地音乐")
                    }
                }
                // 开发期音效联调：设置 EQ 非平值 / 环境混响 / 3D 环绕，触发音效播放引擎
                if ProcessInfo.processInfo.environment["MELO_AUTO_EQ"] == "1" {
                    model.setEQBand(4, gain: 6)      // 500Hz +6dB
                    model.setEQBand(8, gain: -3)     // 8kHz -3dB
                }
                if ProcessInfo.processInfo.environment["MELO_AUTO_CONV"] == "1",
                   let preset = model.convolutionPresets.first(where: { $0.fileName == "s2_r4_bd.wav" }) {
                    model.applyConvolutionPreset(preset)
                }
                if ProcessInfo.processInfo.environment["MELO_AUTO_PANNER"] == "1" {
                    model.setPanner(enabled: true, speed: 32, soundR: 14)
                }
                // 开发期自动搜索/播放演示（仅当显式设置环境变量时）
                if let query = ProcessInfo.processInfo.environment["MELO_AUTO_SEARCH"], !query.isEmpty {
                    model.route = .search
                    for _ in 0..<75 where !model.metadataReady {
                        try? await Task.sleep(nanoseconds: 200_000_000)
                    }
                    let autoSource = ProcessInfo.processInfo.environment["MELO_AUTO_SEARCH_SOURCE"]
                    await model.performSearch(query, source: autoSource)
                    if ProcessInfo.processInfo.environment["MELO_AUTO_PLAY_SEARCH"] == "1" {
                        try? await Task.sleep(nanoseconds: 600_000_000)
                        if let first = model.searchMusicPage.list.first {
                            model.play(first, queue: model.searchMusicPage.list)
                        }
                    }
                    // 开发期自动下载首条搜索结果（验证下载引擎 + 标签写入）
                    if ProcessInfo.processInfo.environment["MELO_AUTO_DOWNLOAD"] == "1",
                       let first = model.searchMusicPage.list.first {
                        let dir = ProcessInfo.processInfo.environment["MELO_DOWNLOAD_DIR"] ?? "/tmp/melo-downloads"
                        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                        model.settings.set(SettingKeys.downloadEnable, .bool(true))
                        model.settings.set(SettingKeys.downloadSavePath, .string(dir))
                        model.settings.set(SettingKeys.downloadEmbedPic, .bool(false))
                        let wantLrc = ProcessInfo.processInfo.environment["MELO_DOWNLOAD_LRC"] == "1"
                        model.settings.set(SettingKeys.downloadEmbedLyric, .bool(wantLrc))
                        model.settings.set(SettingKeys.downloadEmbedLyricLx, .bool(wantLrc))
                        model.settings.set(SettingKeys.downloadEmbedLyricT, .bool(wantLrc))
                        model.settings.set(SettingKeys.downloadEmbedLyricR, .bool(wantLrc))
                        model.settings.set(SettingKeys.downloadSaveLrc, .bool(wantLrc))
                        model.settings.set(SettingKeys.downloadSaveLxLrc, .bool(wantLrc))
                        model.settings.set(SettingKeys.downloadSaveTLrc, .bool(wantLrc))
                        model.settings.set(SettingKeys.downloadSaveRLrc, .bool(wantLrc))
                        model.settings.set(SettingKeys.downloadLrcFormat, .string("utf8"))
                        _ = await model.startDownload(first)
                    }
                }
                // 开发期自动播放（当前列表第一首）
                if ProcessInfo.processInfo.environment["MELO_AUTOPLAY"] == "1" {
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    if let first = model.currentMusics.first {
                        model.play(first)
                    }
                }
                // 开发期路由钩子放在最后，避免被自动搜索改回搜索页
                if let route = ProcessInfo.processInfo.environment["MELO_ROUTE"] {
                    switch route {
                    case "settings": model.route = .settings
                    case "test": model.route = .test
                    case "download": model.route = .download
                    case "search": model.route = .search
                    case "list": model.route = .myList(listId: model.selectedListId)
                    default: break
                    }
                }
                // 开发期：播放中关闭音效，验证路由从 effects engine 切回 AVPlayer
                if ProcessInfo.processInfo.environment["MELO_TOGGLE_EQ"] == "1" {
                    try? await Task.sleep(nanoseconds: 12_000_000_000)
                    model.resetEQ()
                }
                // 开发期自动打开音效面板（验证 EQ UI + 音效引擎路由）
                if ProcessInfo.processInfo.environment["MELO_OPEN_EQ"] == "1" {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    NotificationCenter.default.post(name: .meloShowSoundEffectPanel, object: nil)
                }
                // 开发期：关联本地歌词（需在播放之后）
                if let lyricPath = ProcessInfo.processInfo.environment["MELO_ASSOCIATE_LYRIC"], !lyricPath.isEmpty {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    let ok = model.associateLocalLyricFile(URL(fileURLWithPath: lyricPath))
                    MeloLog.info("[dev] 关联本地歌词结果=\(ok)，歌词行数=\(model.lyricDocument.lines.count)")
                }
                // 开发期：歌词偏移调整（需在播放之后）
                if let raw = ProcessInfo.processInfo.environment["MELO_LYRIC_OFFSET"], let delta = Int(raw) {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    MeloLog.info("[dev] 调整歌词偏移 \(delta)ms，当前歌词行数 \(model.lyricDocument.lines.count)")
                    model.adjustLyricOffset(by: delta)
                }
                // 开发期：加载当前歌曲评论（内置元数据源）
                if ProcessInfo.processInfo.environment["MELO_LOAD_COMMENTS"] == "1" {
                    try? await Task.sleep(nanoseconds: 3_500_000_000)
                    await model.loadComments(hot: false, reset: true)
                }
                // 开发期：打开播放详情
                if ProcessInfo.processInfo.environment["MELO_OPEN_PLAY_DETAIL"] == "1" {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    model.openPlayDetail()
                }
                // 开发期自动打开桌面歌词窗口
                if ProcessInfo.processInfo.environment["MELO_SHOW_LYRIC"] == "1" {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    openWindow(id: "desktop-lyric")
                }
            }
    }

    private func toggleDesktopLyric() {
        if AppWindows.isDesktopLyricVisible() {
            for window in NSApp.windows where window.title == "桌面歌词" {
                window.close()
            }
        } else {
            openWindow(id: "desktop-lyric")
        }
    }
}

struct MenuBarContent: View {
    @Environment(\.openWindow) private var openWindow
    let model: AppModel

    private var locked: Bool { model.settings.bool("desktopLyric.isLock") }
    private var lyricVisible: Bool { AppWindows.isDesktopLyricVisible() }

    var body: some View {
        if let music = model.currentMusic {
            Text("\(music.name) - \(music.singer)")
            if !music.albumName.isEmpty {
                Text(music.albumName).foregroundStyle(.secondary)
            }
            Divider()
        } else {
            Text("未在播放").foregroundStyle(.secondary)
            Divider()
        }
        Button(model.isPlaying ? "暂停" : "播放") { model.togglePlayPause() }
        Button("上一首") { model.previous() }
        Button("下一首") { model.next() }
        Divider()
        Button("显示主窗口") { AppWindows.showMain() }
        Button("设置…") {
            model.route = .settings
            AppWindows.showMain()
        }
        Divider()
        Button(lyricVisible ? "关闭桌面歌词" : "打开桌面歌词") {
            if lyricVisible {
                for window in NSApp.windows where window.title == "桌面歌词" { window.close() }
            } else {
                openWindow(id: "desktop-lyric")
            }
        }
        Button(locked ? "解锁桌面歌词（允许鼠标操作）" : "锁定桌面歌词（鼠标穿透）") {
            model.settings.set("desktopLyric.isLock", .bool(!locked))
            LyricWindowBehavior.shared.syncFromSettings()
        }
        Divider()
        Button("退出 Melo") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

extension Notification.Name {
    static let meloToggleDesktopLyric = Notification.Name("melo.toggleDesktopLyric")
    static let meloShowAbout = Notification.Name("melo.showAbout")
}
