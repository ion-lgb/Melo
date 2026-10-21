import Foundation
import MeloCore
import MeloAudio
import MeloJS

/// 用户真实自定义源联调：
/// 导入源 → 激活 → 内置元数据搜索出一首真实歌曲 → 用源解析 musicUrl →
/// 校验远程音频可访问 → AVPlayer 实际播放。
@MainActor
final class UserSourceSmokeRunner {
    let box: SmokeBox
    let sourcePath: String
    let dataRoot: URL
    let query: String
    let sourceID: String
    let quality: String
    let resources: URL

    init(sourcePath: String, dataRoot: URL, query: String, sourceID: String, quality: String, resources: URL, box: SmokeBox) {
        self.sourcePath = sourcePath
        self.dataRoot = dataRoot
        self.query = query
        self.sourceID = sourceID
        self.quality = quality
        self.resources = resources
        self.box = box
    }

    private var lxData: URL { dataRoot.appendingPathComponent("LxDatas", isDirectory: true) }

    func run() async throws {
        try? FileManager.default.createDirectory(at: lxData, withIntermediateDirectories: true)
        let settings = SettingsStore(dataDirectory: lxData)
        let sources = JSCustomSourceService(dataDirectory: dataRoot, settings: settings)

        // 1. 导入 / 复用自定义源
        try sources.reloadSources()
        var source = sources.sources.first(where: { $0.name.contains("聆澜") })
        if source == nil {
            source = try sources.importSource(from: URL(fileURLWithPath: sourcePath))
            box.lines.append("已导入源：\(source?.name ?? "?") v\(source?.version ?? "?")")
        } else {
            box.lines.append("复用已导入源：\(source!.name) v\(source?.version ?? "?")")
        }
        guard let source else { throw SmokeError("自定义源导入失败") }

        // 2. 激活并打印能力
        await sources.activateSource(id: source.id)
        box.check(sources.status.isReady, "自定义源激活（\(sources.status)）")
        for capability in sources.capabilities {
            box.lines.append("能力：\(capability.source) qualitys=\(capability.qualitys.joined(separator: ",")) actions=\(capability.actions.joined(separator: ","))")
        }
        settings.set(SettingKeys.apiSource, .string(source.id))
        if !sources.capabilities.contains(where: { $0.source == sourceID }) {
            throw SmokeError("源未声明 \(sourceID) 能力")
        }

        // 3. 真实搜索取一首歌
        let metadata = JSMetadataService(resourcesDirectory: resources)
        try await metadata.prepare()
        let page = try await metadata.searchMusic(keyword: query, source: sourceID, page: 1, limit: 10)
        guard let song = page.list.first else { throw SmokeError("搜索无结果：\(query)") }
        box.lines.append("搜索到：\(song.name) - \(song.singer) id=\(song.id) songId=\(song.songId ?? "?")")
        if let qualities = sources.capabilities.first(where: { $0.source == sourceID })?.qualitys, !qualities.isEmpty {
            box.lines.append("源支持音质：\(qualities.joined(separator: ","))")
        }

        // 4. 用真实源解析播放地址（优先请求音质，不在能力列表则退回第一个）
        var requested = quality
        if let qualitys = sources.capabilities.first(where: { $0.source == sourceID })?.qualitys,
           !qualitys.contains(requested), let first = qualitys.first {
            requested = first
        }
        let started = Date()
        let url = try await sources.resolveMusicURL(source: sourceID, musicInfo: song, quality: requested)
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        box.lines.append("解析到 URL（\(requested)，\(elapsed)ms）：\(url.absoluteString)")
        box.check(MeloUtils.isHTTPURL(url.absoluteString), "URL 为 http(s)")

        // 5. 校验远程音频（Range 拉取头部，避免下载整首）
        var request = URLRequest(url: url)
        request.setValue("bytes=0-2047", forHTTPHeaderField: "Range")
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        let contentType = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? "-"
        box.check(status == 200 || status == 206, "音频可访问（HTTP \(status)，\(data.count) bytes，Content-Type: \(contentType)）")

        // 6. AVPlayer 实际播放 3 秒
        let player = AVPlayerService()
        try player.play(url: url, music: song)
        try await Task.sleep(nanoseconds: 3_000_000_000)
        box.check(player.status == .playing, "AVPlayer 状态 \(player.status.rawValue)")
        box.check(player.currentTime > 0.3, "播放进度 \(String(format: "%.2f", player.currentTime))s / \(String(format: "%.1f", player.duration))s")
        player.pause()

        if !box.failures.isEmpty {
            throw SmokeError("\(box.failures.count) 项检查失败")
        }
    }
}
