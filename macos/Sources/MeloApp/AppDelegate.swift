import AppKit
import MeloCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var model: AppModel?
    /// 冷启动时先到达的 Scheme URL（App 尚未完成 bootstrap）
    static var pendingURLs: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSWindow.allowsAutomaticWindowTabbing = false
        NSApp.activate(ignoringOtherApps: true)
        MeloLog.info("Melo 启动，资源目录: \(ResourceLocator.resourcesDirectory().path)")
        MeloLog.info("数据目录: \(ResourceLocator.defaultDataDirectory().path)")
        MainActor.assumeIsolated {
            setupHotKeys()
            AutoLaunchManager.syncFromSettings()
            openAtLoginObserver = NotificationCenter.default.addObserver(
                forName: .meloOpenAtLoginChanged, object: nil, queue: .main
            ) { _ in
                Task { @MainActor in AutoLaunchManager.syncFromSettings() }
            }
        }
        // 冷启动时 LaunchServices 可能在 didFinishLaunching 之前投递 URL（已缓存）
        if !Self.pendingURLs.isEmpty, let model = Self.model, model.isBootstrapped {
            Task { @MainActor in await Self.drainPendingURLs(model: model) }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Self.model?.persistCurrentPlayInfo()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // 开启托盘时，关闭主窗口不退出；Phase 0 先按设置简单处理
        !(Self.model?.settings.bool(SettingKeys.trayEnable) ?? false)
    }

    /// 兼容原版 `lxmusic://` Scheme URL：解析并执行（搜索/播放/歌单/播放控制）
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme?.lowercased() == "lxmusic" {
            MeloLog.info("收到 Scheme URL: \(url.absoluteString)")
            if let model = Self.model, model.isBootstrapped {
                Task { @MainActor in await DeeplinkHandler.handle(url: url, app: model) }
            } else {
                Self.pendingURLs.append(url)
            }
        }
    }

    // MARK: - 快捷键

    private var hotKeyObserver: NSObjectProtocol?
    private var openAtLoginObserver: NSObjectProtocol?

    @MainActor
    private func setupHotKeys() {
        GlobalHotKeyManager.shared.actionHandler = { action in
            Self.performHotKeyAction(action)
        }
        hotKeyObserver = NotificationCenter.default.addObserver(
            forName: .meloHotKeysChanged, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in
                GlobalHotKeyManager.shared.reload(config: Self.model?.hotKeys ?? HotKeyStore.defaultConfig)
            }
        }
        Task { @MainActor in
            GlobalHotKeyManager.shared.reload(config: Self.model?.hotKeys ?? HotKeyStore.defaultConfig)
        }
    }

    @MainActor
    static func performHotKeyAction(_ action: String) {
        switch action {
        case "common_min":
            NSApp.keyWindow?.miniaturize(nil)
        case "common_toggle_min":
            if let window = NSApp.keyWindow {
                if window.isMiniaturized { window.deminiaturize(nil) } else { window.miniaturize(nil) }
            }
        case "common_toggle_hide":
            if NSApp.isHidden {
                NSApp.unhide(nil)
                NSApp.activate(ignoringOtherApps: true)
            } else {
                NSApp.hide(nil)
            }
        case "common_toggle_close":
            NSApp.terminate(nil)
        default:
            if let model = model {
                _ = model.performHotKeyAction(action)
            }
        }
    }

    /// 主窗口 bootstrap 完成后调用，处理冷启动期间缓存的 Scheme URL
    @MainActor
    static func drainPendingURLs(model: AppModel) async {
        guard !pendingURLs.isEmpty else { return }
        let urls = pendingURLs
        pendingURLs.removeAll()
        for url in urls {
            await DeeplinkHandler.handle(url: url, app: model)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            AppWindows.showMain()
        }
        return true
    }
}
