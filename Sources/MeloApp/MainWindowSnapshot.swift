import AppKit
import SwiftUI
import MeloCore

/// 开发期 UI 走查：把主窗口内容直接绘制成 PNG。
/// 走 `NSView.cacheDisplay`，因此不需要系统的「屏幕录制」权限。
/// 用法：`MELO_SNAPSHOT=/tmp/a.png MELO_SNAPSHOT_DELAY=3 MELO_ROUTE=list open build/Melo.app`
@MainActor
enum MainWindowSnapshot {
    static func capture(to url: URL) {
        guard let window = mainWindow else {
            MeloLog.warn("[snapshot] 未找到可截取的主窗口")
            return
        }
        // MELO_SNAPSHOT_SHEET=1 时截取主窗口的第一个 Sheet（音效面板等）。
        if ProcessInfo.processInfo.environment["MELO_SNAPSHOT_SHEET"] == "1" {
            let sheet = window.attachedSheet
                ?? window.childWindows?.first(where: { ($0.contentView?.frame.width ?? 0) > 300 })
                ?? NSApp.windows.first { $0 !== window && ($0.contentView?.frame.width ?? 0) > 300 && $0.isVisible }
            guard let sheet else {
                MeloLog.warn("[snapshot] 未找到打开中的 Sheet 窗口")
                return
            }
            capture(window: sheet, to: url)
            return
        }
        capture(window: window, to: url)
    }

    private static func capture(window: NSWindow, to url: URL) {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        guard let content = window.contentView else { return }
        // MELO_SNAPSHOT_FULL=1 时截取整个窗口框架（含工具栏与红绿灯），否则只截内容区。
        let target = (ProcessInfo.processInfo.environment["MELO_SNAPSHOT_FULL"] == "1"
                      ? content.superview : nil) ?? content
        let bounds = target.bounds
        guard let rep = target.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        target.cacheDisplay(in: bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            MeloLog.warn("[snapshot] PNG 编码失败")
            return
        }
        do {
            try data.write(to: url)
            MeloLog.info("[snapshot] 已写出 \(url.path)")
        } catch {
            MeloLog.error("[snapshot] 写入失败：\(error.localizedDescription)")
        }
    }

    private static var mainWindow: NSWindow? {
        NSApp.windows
            .filter { $0.contentView != nil && $0.frame.width > 500 && $0.title != "桌面歌词" }
            .max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }
}
