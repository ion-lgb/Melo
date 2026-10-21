import Foundation

public enum MeloUtils {
    /// 秒 → `mm:ss`（超过 1 小时为 `hh:mm:ss`）
    public static func formatTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00" }
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%02d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }

    /// `mm:ss` / `hh:mm:ss` → 秒；解析失败返回 0
    public static func parseInterval(_ interval: String?) -> TimeInterval {
        guard let interval, !interval.isEmpty else { return 0 }
        let parts = interval.split(separator: ":").compactMap { Double($0) }
        guard !parts.isEmpty else { return 0 }
        var value: Double = 0
        for part in parts { value = value * 60 + part }
        return value
    }

    /// 原子写入文件（先写临时文件再 rename，避免半截文件损坏）
    public static func atomicWrite(_ data: Data, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let temp = dir.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: temp, options: .atomic)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
    }

    public static func atomicWriteString(_ string: String, to url: URL) throws {
        guard let data = string.data(using: .utf8) else { return }
        try atomicWrite(data, to: url)
    }

    public static func isHTTPURL(_ string: String) -> Bool {
        string.hasPrefix("http://") || string.hasPrefix("https://")
    }

    /// 过滤列表：去掉 id/name 为空与重复项（与原版 filterMusicList 一致）
    public static func filterMusicList(_ list: [MusicInfo]) -> [MusicInfo] {
        var ids = Set<String>()
        var result: [MusicInfo] = []
        for var music in list {
            guard !music.id.isEmpty, !music.name.isEmpty else { continue }
            guard ids.insert(music.id).inserted else { continue }
            if music.singer.isEmpty { music.singer = "" }
            result.append(music)
        }
        return result
    }

    /// 随机 user_api id，格式与原版一致：`user_api_<3位随机>_<时间戳>`
    public static func makeUserSourceID() -> String {
        let random = String(format: "%03d", Int.random(in: 0...999))
        return "user_api_\(random)_\(Int(Date().timeIntervalSince1970 * 1000))"
    }
}


public extension Notification.Name {
    /// 快捷键配置变化（App 层据此重新注册全局快捷键）
    static let meloHotKeysChanged = Notification.Name("melo.hotKeysChanged")
    /// 桌面歌词相关设置（锁定/置顶）变化，需要窗口行为层同步
    static let meloDesktopLyricSettingsChanged = Notification.Name("melo.desktopLyricSettingsChanged")
    /// 请求聚焦搜索框
    static let meloFocusSearchInput = Notification.Name("melo.focusSearchInput")
    /// 请求切换桌面歌词窗口
    static let meloToggleDesktopLyricWindow = Notification.Name("melo.toggleDesktopLyricWindow")
    /// 开机自启设置变化（App 层据此注册/取消 SMAppService）
    static let meloOpenAtLoginChanged = Notification.Name("melo.openAtLoginChanged")
    /// 代理设置变化（App 层据此应用到网络层）
    static let meloProxySettingsChanged = Notification.Name("melo.proxySettingsChanged")
}
