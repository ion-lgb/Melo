import Foundation

/// 资源定位：兼容 .app bundle、`swift run` 与测试三种运行方式。
///
/// 查找顺序：
/// 1. 环境变量 `MELO_RESOURCES`（开发/测试显式指定）
/// 2. `Bundle.main.resourceURL`（打包成 Melo.app 后）
/// 3. 可执行文件向上回溯找到 `Resources`（`swift run` 时 .build/<config>/Melo）
public enum ResourceLocator {
    public static func resourcesDirectory() -> URL {
        if let env = ProcessInfo.processInfo.environment["MELO_RESOURCES"], !env.isEmpty {
            return URL(fileURLWithPath: env, isDirectory: true)
        }
        if let res = Bundle.main.resourceURL,
           FileManager.default.fileExists(atPath: res.appendingPathComponent("themes.json").path) {
            return res
        }
        // 开发期回溯：<pkg>/.build/release/Melo -> <pkg>/.build -> <pkg> -> <pkg>/Resources
        var candidates: [URL] = []
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        var dir = exe.deletingLastPathComponent()
        for _ in 0..<6 {
            candidates.append(dir.appendingPathComponent("Resources", isDirectory: true))
            dir = dir.deletingLastPathComponent()
        }
        // 兜底：以当前工作目录为包根
        candidates.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources"))
        for c in candidates where FileManager.default.fileExists(atPath: c.appendingPathComponent("themes.json").path) {
            return c
        }
        return exe.deletingLastPathComponent().appendingPathComponent("Resources", isDirectory: true)
    }

    public static func url(_ relativePath: String) -> URL {
        resourcesDirectory().appendingPathComponent(relativePath)
    }

    public static var themesURL: URL { url("themes.json") }
    public static var defaultSettingsURL: URL { url("default-settings.json") }
    public static var langDirectory: URL { url("lang") }
    public static var preludeJS: URL { url("js/prelude.js") }
    public static var themeImagesDirectory: URL { url("images") }

    /// 用户数据目录（默认沿用原版 LX Music 的 macOS 路径，保证数据可直接兼容）
    public static func defaultDataDirectory() -> URL {
        if let env = ProcessInfo.processInfo.environment["MELO_DATA_DIR"], !env.isEmpty {
            return URL(fileURLWithPath: env, isDirectory: true)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent("lx-music-desktop", isDirectory: true)
    }

    /// 原版 `global.lxDataPath`：<userData>/LxDatas
    public static func lxDatasDirectory(in userDataDirectory: URL) -> URL {
        userDataDirectory.appendingPathComponent("LxDatas", isDirectory: true)
    }
}
