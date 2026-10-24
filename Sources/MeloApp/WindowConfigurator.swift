import SwiftUI
import AppKit
import MeloCore

/// 把 SwiftUI 窗口配置成桌面歌词需要的形态：透明、无边框、可置顶、多空间可见、可拖动；
/// 并跟随设置同步「置顶 / 锁定（鼠标穿透）」与位置尺寸。
@MainActor
final class LyricWindowBehavior {
    static let shared = LyricWindowBehavior()

    private weak var window: NSWindow?
    private var observers: [NSObjectProtocol] = []
    private var syncTimer: Timer?
    private var saveWork: DispatchWorkItem?
    private var isApplyingFrame = false
    private var hiddenByPause = false

    private var settings: SettingsStore? { AppDelegate.model?.settings }

    private func debugLog(_ message: String) {
        guard ProcessInfo.processInfo.environment["MELO_VERBOSE"] == "1" else { return }
        let line = "[lyric-window] \(message)\n"
        if let data = line.data(using: .utf8) {
            let url = URL(fileURLWithPath: "/tmp/melo-lyric-window.log")
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }

    func attach(_ window: NSWindow) {
        guard self.window !== window else { return }
        debugLog("attach frame=\(window.frame) class=\(type(of: window)) style=\(window.styleMask.rawValue)")
        detach()
        self.window = window
        configureStatic(window)
        restoreFrame(window)
        installObservers(for: window)
        startTimer()
        syncFromSettings()
        MeloLog.info("桌面歌词窗口已接管")
    }

    func detach() {
        syncTimer?.invalidate()
        syncTimer = nil
        saveWork?.cancel()
        let center = NotificationCenter.default
        for token in observers { center.removeObserver(token) }
        observers.removeAll()
        window = nil
    }

    /// 设置变化（锁定/置顶/位置）后立即同步
    func syncFromSettings() {
        guard let window, let settings else { return }
        let locked = settings.bool("desktopLyric.isLock")
        let alwaysOnTop = settings.bool("desktopLyric.isAlwaysOnTop")
        window.ignoresMouseEvents = locked
        if alwaysOnTop {
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)))
        } else {
            window.level = .normal
        }
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.isMovableByWindowBackground = !locked

        // 「暂停时隐藏」：暂停期间 orderOut，恢复播放后重新显示
        let pauseHide = settings.bool(SettingKeys.desktopLyricPauseHide)
        let isPlaying = AppDelegate.model?.isPlaying ?? true
        if pauseHide && !isPlaying {
            if window.isVisible {
                window.orderOut(nil)
                hiddenByPause = true
            }
        } else if hiddenByPause {
            window.orderFront(nil)
            hiddenByPause = false
        }

        // SwiftUI 可能在窗口显示后重新应用默认样式，这里同步再压一次
        configureStatic(window)
    }

    private func configureStatic(_ window: NSWindow) {
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        // NSHostingView 默认会绘制窗口背景色，改成透明层，否则桌面歌词窗口会发灰
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
        debugLog("configureStatic opaque=\(window.isOpaque) titleVisible=\(window.titleVisibility.rawValue) closeHidden=\(window.standardWindowButton(.closeButton)?.isHidden ?? true)")
    }

    private func restoreFrame(_ window: NSWindow) {
        guard let settings else { return }
        let width = settings.double("desktopLyric.width", default: 620)
        let height = settings.double("desktopLyric.height", default: 220)
        let size = NSSize(width: max(240, width), height: max(90, height))
        if let x = settings.value("desktopLyric.x")?.doubleValue,
           let y = settings.value("desktopLyric.y")?.doubleValue,
           x.isFinite, y.isFinite {
            isApplyingFrame = true
            window.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: size), display: true)
            isApplyingFrame = false
        } else {
            window.setContentSize(size)
            window.center()
        }
    }

    private func installObservers(for window: NSWindow) {
        let center = NotificationCenter.default
        let frameChanged: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let window = self.window else { return }
                self.scheduleSaveFrame(window)
            }
        }
        observers.append(center.addObserver(forName: NSWindow.didMoveNotification, object: window, queue: .main, using: frameChanged))
        observers.append(center.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main, using: frameChanged))
        let willClose: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.detach() }
        }
        observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main, using: willClose))
    }

    private func scheduleSaveFrame(_ window: NSWindow) {
        guard !isApplyingFrame else { return }
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let window = self.window, let settings = self.settings else { return }
            let frame = window.frame
            settings.set("desktopLyric.x", .double(frame.origin.x))
            settings.set("desktopLyric.y", .double(frame.origin.y))
            settings.set("desktopLyric.width", .double(frame.size.width))
            settings.set("desktopLyric.height", .double(frame.size.height))
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func startTimer() {
        syncTimer?.invalidate()
        // 设置变化没有 KVO，0.4s 轮询足够轻量（与原版 500ms 置顶循环类似）
        syncTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.syncFromSettings() }
        }
        if let timer = syncTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }
}

/// 拿到窗口后回调的探针视图：`viewDidMoveToWindow` 比 makeNSView 里的异步 dispatch 可靠。
final class WindowProbeView: NSView {
    var onWindow: ((NSWindow) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window { onWindow?(window) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// 桌面歌词窗口的 SwiftUI 桥：拿到 NSWindow 后交给 LyricWindowBehavior。
struct LyricWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = WindowProbeView()
        view.onWindow = { window in
            DispatchQueue.main.async { LyricWindowBehavior.shared.attach(window) }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let probe = nsView as? WindowProbeView else { return }
        if let window = probe.window {
            DispatchQueue.main.async { LyricWindowBehavior.shared.attach(window) }
        }
    }
}

/// 主窗口外观：透明标题栏 + 统一工具栏，窗口本身透明以便侧边栏毛玻璃透出桌面。
struct MainWindowConfigurator: NSViewRepresentable {
    var isImmersive: Bool = false

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { configure(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { configure(nsView.window) }
    }

    private func configure(_ window: NSWindow?) {
        guard let window else { return }
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)
        window.toolbarStyle = .unified
        // 播放详情铺满窗口时隐藏工具栏，退出后恢复
        if let toolbar = window.toolbar, toolbar.isVisible == isImmersive {
            toolbar.isVisible = !isImmersive
        }
        // Apple Music 侧边栏透出桌面：窗口不透明关闭，内容区自行铺纯色底
        window.isOpaque = false
        window.backgroundColor = .clear
        window.minSize = NSSize(width: 1000, height: 620)
        if window.frameAutosaveName.isEmpty {
            window.setFrameAutosaveName("MeloMainWindow")
        }
    }
}
