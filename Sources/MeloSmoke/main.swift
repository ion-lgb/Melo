import Foundation
import MeloCore
import MeloData
import MeloAudio
import MeloJS

/// 无界面端到端冒烟测试（开发/CI 用）：
/// 数据层（原版 DDL）→ 导入/激活自定义源（JavaScriptCore）→ 解析 musicUrl →
/// 校验远程 URL → AVPlayer 实际播放 → 解析歌词。全部通过输出 PASS 并退出 0。
///
/// 用法:
///   swift run MeloSmoke --data-dir /tmp/melo-smoke-data \
///       --source TestAssets/demo-source.js \
///       --music-file TestAssets/sample-music-info.json --index 0 \
///       --server http://127.0.0.1:27331/health
@main
struct MeloSmoke {
    static func main() {
        let args = CommandLine.arguments
        func arg(_ name: String, default fallback: String) -> String {
            if let index = args.firstIndex(of: name), index + 1 < args.count {
                return args[index + 1]
            }
            return fallback
        }
        let dataRoot = URL(fileURLWithPath: arg("--data-dir", default: "/tmp/melo-smoke-data"))
        let sourcePath = arg("--source", default: "TestAssets/demo-source.js")
        let musicFile = arg("--music-file", default: "TestAssets/sample-music-info.json")
        let musicIndex = Int(arg("--index", default: "0")) ?? 0
        let serverHealth = arg("--server", default: "http://127.0.0.1:27331/health")

        // 模式：列出音频输出设备（CoreAudio）
        if args.contains("--audio-devices") {
            let devices = AudioOutputDevices.list()
            print("音频输出设备（默认标 *）：")
            for device in devices {
                print("  \(device.isDefault ? "*" : " ") \(device.name)  uid=\(device.uid)  id=\(device.deviceID)")
            }
            if devices.isEmpty { print("  （未发现输出设备）") }
            print("默认设备 UID: \(AudioOutputDevices.defaultDeviceID() ?? "nil")")
            exit(0)
        }

        // 模式三：用户真实自定义源联调（导入→激活→搜索→取链→播放）
        if args.contains("--user-source") {
            let sourcePath = arg("--user-source", default: "")
            guard !sourcePath.isEmpty else {
                print("FAIL: 缺少 --user-source <file.js>")
                exit(2)
            }
            let dataRoot = URL(fileURLWithPath: arg("--data-dir", default: "/tmp/melo-user-source-test"))
            let resources = URL(fileURLWithPath: arg("--resources", default: "Resources"))
            let query = arg("--search", default: "晴天 周杰伦")
            let sourceID = arg("--source", default: "kw")
            let quality = arg("--quality", default: "320k")
            let box = SmokeBox()
            let runner = MainActor.assumeIsolated {
                UserSourceSmokeRunner(sourcePath: sourcePath, dataRoot: dataRoot, query: query,
                                      sourceID: sourceID, quality: quality, resources: resources, box: box)
            }
            Task { @MainActor in
                do {
                    try await runner.run()
                    box.finish(error: nil)
                } catch {
                    box.finish(error: error)
                }
            }
            let deadline = Date().addingTimeInterval(90)
            while !box.done && Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
            if !box.done {
                print("FAIL: 用户源联调超时（90s）")
                exit(2)
            }
            if let error = box.error {
                print("FAIL: \(error)")
                for line in box.lines { print("  \(line)") }
                for failure in box.failures { print("  - \(failure)") }
                exit(1)
            }
            print("PASS: 用户自定义源联调通过")
            for line in box.lines { print("  · \(line)") }
            exit(0)
        }

        // 模式二：仅验证内置元数据源（JSC musicSdk + 真实网络）
        if args.contains("--metadata-only") {
            let query = arg("--metadata-query", default: "周杰伦")
            let resources = URL(fileURLWithPath: arg("--resources", default: "Resources"))
            let box = SmokeBox()
            let runner = MainActor.assumeIsolated {
                MetadataSmokeRunner(query: query, resources: resources, box: box)
            }
            Task { @MainActor in
                do {
                    try await runner.run()
                    box.finish(error: nil)
                } catch {
                    box.finish(error: error)
                }
            }
            let deadline = Date().addingTimeInterval(120)
            while !box.done && Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
            if !box.done {
                print("FAIL: 元数据冒烟测试超时（120s）")
                exit(2)
            }
            if let error = box.error {
                print("FAIL: \(error)")
                for line in box.lines { print("  \(line)") }
                for failure in box.failures { print("  - \(failure)") }
                exit(1)
            }
            print("PASS: 内置元数据源冒烟测试通过")
            for line in box.lines { print("  · \(line)") }
            exit(0)
        }

        let box = SmokeBox()
        let runner = MainActor.assumeIsolated {
            SmokeRunner(dataRoot: dataRoot, sourcePath: sourcePath,
                        musicFile: musicFile, musicIndex: musicIndex, serverHealth: serverHealth, box: box)
        }
        Task { @MainActor in
            do {
                try await runner.run()
                box.finish(error: nil)
            } catch {
                box.finish(error: error)
            }
        }
        let deadline = Date().addingTimeInterval(60)
        while !box.done && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        if !box.done {
            print("FAIL: 冒烟测试超时（60s）")
            exit(2)
        }
        if let error = box.error {
            print("FAIL: \(error)")
            for failure in box.failures { print("  - \(failure)") }
            exit(1)
        }
        print("PASS: MeloSmoke 全部检查通过")
        for line in box.lines { print("  · \(line)") }
        exit(0)
    }
}

final class SmokeBox {
    var done = false
    var error: Error?
    var failures: [String] = []
    var lines: [String] = []
    func finish(error: Error?) {
        self.error = error
        self.done = true
    }
    func check(_ condition: Bool, _ message: String) {
        if condition { lines.append("OK  \(message)") } else { failures.append(message); lines.append("FAIL \(message)") }
    }
}

@MainActor
final class SmokeRunner {
    let dataRoot: URL
    let sourcePath: String
    let musicFile: String
    let musicIndex: Int
    let serverHealth: String
    let box: SmokeBox
    private let lxData: URL
    private let settings: SettingsStore
    private let data: SQLiteDataService
    private let player: AVPlayerService
    private let sources: JSCustomSourceService

    init(dataRoot: URL, sourcePath: String, musicFile: String, musicIndex: Int, serverHealth: String, box: SmokeBox) {
        self.dataRoot = dataRoot
        self.sourcePath = sourcePath
        self.musicFile = musicFile
        self.musicIndex = musicIndex
        self.serverHealth = serverHealth
        self.box = box
        let lxData = dataRoot.appendingPathComponent("LxDatas", isDirectory: true)
        self.lxData = lxData
        self.settings = SettingsStore(dataDirectory: lxData)
        self.data = SQLiteDataService(dataDirectory: lxData)
        self.player = AVPlayerService()
        self.sources = JSCustomSourceService(dataDirectory: lxData, settings: settings)
    }

    func run() async throws {
        // 0. 测试服务可用性
        let (healthData, healthResponse) = try await URLSession.shared.data(from: URL(string: serverHealth)!)
        guard (healthResponse as? HTTPURLResponse)?.statusCode == 200,
              String(data: healthData, encoding: .utf8)?.contains("melo-demo-server") == true else {
            throw SmokeError("测试服务未启动：\(serverHealth)（请先运行 node Scripts/demo-server.mjs）")
        }
        box.lines.append("测试服务可用: \(serverHealth)")

        // 1. 数据层：原版 DDL / 列表读取
        try data.bootstrap()
        let lists = try data.loadUserLists()
        let counts = try data.loadMusicCounts()
        box.check(!lists.isEmpty, "用户列表读取（\(lists.count) 个）")
        box.check((counts[listIDs: "love"] ?? 0) > 0, "收藏列表歌曲数 > 0")
        let allMusics = try data.loadMusics(listId: "testlist")
        box.check(!allMusics.isEmpty, "测试列表歌曲读取（\(allMusics.count) 首）")
        if let first = allMusics.first {
            box.lines.append("示例歌曲: \(first.name) - \(first.singer) [\(first.source)]")
        }

        // 2. 自定义源：导入 / 激活
        try sources.reloadSources()
        var source = sources.sources.first(where: { $0.name.contains("Melo 测试源") })
        if source == nil {
            source = try sources.importSource(from: URL(fileURLWithPath: sourcePath))
            box.lines.append("已导入自定义源: \(source?.name ?? "?")")
        } else {
            box.lines.append("复用已存在自定义源: \(source!.name)")
        }
        guard let source else { throw SmokeError("自定义源导入失败") }
        await sources.activateSource(id: source.id)
        box.check(sources.status.isReady, "自定义源激活（\(sources.status)）")
        let capabilities = sources.capabilities
        box.check(!capabilities.isEmpty, "源能力声明（\(capabilities.count) 个 source）")
        if let kw = capabilities.first(where: { $0.source == "kw" }) {
            box.lines.append("kw qualitys: \(kw.qualitys.joined(separator: ",")) actions: \(kw.actions.joined(separator: ","))")
        }

        // 3. 取链：musicUrl
        let musicJSONData = try Data(contentsOf: URL(fileURLWithPath: musicFile))
        guard let array = JSONValue(jsonData: musicJSONData)?.arrayValue, array.indices.contains(musicIndex) else {
            throw SmokeError("测试 MusicInfo 文件无效: \(musicFile)")
        }
        guard let musicValue = array[musicIndex].jsonString(), let musicData = musicValue.data(using: .utf8) else {
            throw SmokeError("测试 MusicInfo 解析失败")
        }
        let music = try JSONDecoder().decode(MusicInfo.self, from: musicData)
        box.lines.append("测试歌曲: \(music.name) / source=\(music.source) songId=\(music.songId ?? "?")")
        let quality = music.availableQualityKeys.contains("128k") || music.qualitys.contains(where: { $0.type == "128k" }) ? "128k" : "320k"
        let url = try await sources.resolveMusicURL(source: music.source, musicInfo: music, quality: quality)
        box.check(url.absoluteString.hasPrefix("http"), "musicUrl 解析成功: \(url.absoluteString)")
        if let cached = try? data.getMusicURL(musicId: music.id, quality: quality) {
            box.check(cached.isEmpty, "URL 缓存写入前为空（Phase 0 检查）")
        }
        try? data.saveMusicURL(musicId: music.id, quality: quality, url: url.absoluteString)
        let cached = try data.getMusicURL(musicId: music.id, quality: quality)
        box.check(cached == url.absoluteString, "URL 缓存读写一致")

        // 4. 远程 URL 校验（真实请求）
        let (mediaData, mediaResponse) = try await URLSession.shared.data(from: url)
        let status = (mediaResponse as? HTTPURLResponse)?.statusCode ?? -1
        box.check(status == 200, "远程音频可访问（HTTP \(status)）")
        box.check(mediaData.count > 44 && mediaData.prefix(4).elementsEqual("RIFF".utf8), "远程音频为合法 WAV（\(mediaData.count) bytes）")

        // 5. 播放器：实际播放 + 进度
        player.volume = 0
        player.isMuted = true
        try player.play(url: url, music: music)
        try await Task.sleep(nanoseconds: 1_800_000_000)
        box.check(player.status == .playing, "AVPlayer 播放状态 = \(player.status.rawValue)")
        box.check(player.currentTime > 0.3, "播放进度推进 = \(String(format: "%.2f", player.currentTime))s")
        player.seek(to: 1.0)
        try await Task.sleep(nanoseconds: 400_000_000)
        box.check(abs(player.currentTime - 1.0) < 0.8, "seek 生效 = \(String(format: "%.2f", player.currentTime))s")
        box.check(player.duration > 10, "时长识别 = \(String(format: "%.1f", player.duration))s")
        player.pause()

        // 6. 歌词：LRC 解析 + 数据库缓存往返（自定义源按原版白名单只提供 musicUrl）
        if let kw = capabilities.first(where: { $0.source == "kw" }) {
            box.check(kw.actions == ["musicUrl"], "源能力过滤符合原版白名单（kw.actions=\(kw.actions)）")
        }
        let lyricPath = "TestAssets/demo-lyric.lrc"
        if let lyricText = try? String(contentsOfFile: lyricPath, encoding: .utf8) {
            let document = LyricParser.parse(lyricText)
            box.check(!document.isEmpty, "LRC 解析（\(document.lines.count) 行）")
            let index = document.lineIndex(at: 3.0)
            box.check(index != nil, "当前歌词行定位（3s → 第 \((index ?? 0) + 1) 行）")
            try? data.saveLyric(musicId: music.id, source: "raw", type: "lyric", text: lyricText)
            let readBack = try data.getLyric(musicId: music.id, source: "raw", type: "lyric")
            box.check(readBack == lyricText, "歌词缓存往返一致")
        } else {
            box.failures.append("读取歌词测试文件失败: \(lyricPath)")
        }

        box.check(dataRoot.path.count > 0, "数据目录: \(lxData.path)")
        if !box.failures.isEmpty {
            throw SmokeError("\(box.failures.count) 项检查失败")
        }
    }
}

private extension Dictionary where Key == String, Value == Int {
    subscript(listIDs key: String) -> Int? { self[key] }
}

struct SmokeError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
