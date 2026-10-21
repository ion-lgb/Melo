import SwiftUI
import AppKit
import MeloCore

// MARK: - 自定义源测试页（Phase 0 联调入口）

struct TestView: View {
    let app: AppModel

    @Environment(\.meloColors) private var colors

    @State private var presetSource = "kw"
    @State private var selectedQuality = "128k"
    @State private var jsonText = TestPresets.json(for: "kw")
    @State private var resolvedURL: String?
    @State private var localError: String?
    @State private var isRunning = false
    @State private var parsedSummary: String?
    @State private var showRawJSON = false

    private let preferredQualityOrder = ["128k", "320k", "flac", "flac24bit"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                PhaseBanner(text: "测试用源不内置：请先在「设置 → 自定义源」导入并激活你拥有的 .js 源脚本。本页调用 app.testResolve(musicInfo:) 走 musicUrl 能力取链并交给播放器；Phase 1 会接入真实搜索/列表数据。")
                controlCard
                jsonCard
                resultCard
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .frame(maxWidth: 980, alignment: .leading)
        }
        .onAppear { syncFromCapabilities() }
        .onChange(of: app.activeCapabilities) { _, _ in syncFromCapabilities() }
        .onChange(of: presetSource) { _, newValue in
            jsonText = TestPresets.json(for: newValue)
            parsedSummary = nil
            resolvedURL = nil
            localError = nil
        }
        .onChange(of: selectedQuality) { _, newValue in
            app.settings.set(SettingKeys.playQuality, .string(newValue))
        }
    }

    // MARK: 头部

    private var header: some View {
        HStack(alignment: .top) {
            PageTitle("自定义源测试", subtitle: "musicUrl 取链联调（app.testResolve）")
            Spacer()
            Button {
                app.route = .settings
            } label: {
                Label("管理自定义源", systemImage: "puzzlepiece.extension")
                    .font(.system(size: 11))
            }
            .buttonStyle(.bordered)
        }
    }

    // MARK: 源与音质

    private var controlCard: some View {
        MeloCard(title: "源与音质", subtitle: nil, systemImage: "antenna.radiowaves.left.and.right") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 14) {
                    Text("测试音源")
                        .font(.system(size: 12))
                        .frame(width: 72, alignment: .leading)
                    Picker("测试音源", selection: $presetSource) {
                        ForEach(presetSources, id: \.self) { source in
                            Text(sourceLabel(source)).tag(source)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 180)

                    Text("音质")
                        .font(.system(size: 12))
                        .frame(width: 44, alignment: .leading)
                    Picker("音质", selection: $selectedQuality) {
                        ForEach(qualityOptions, id: \.self) { quality in
                            Text(qualityLabel(quality)).tag(quality)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 150)

                    Text("（音质选项来自当前活动源声明的 capabilities）")
                        .font(.system(size: 10))
                        .foregroundStyle(colors.fontTertiary)
                    Spacer()
                }

                HStack(spacing: 10) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 7, height: 7)
                    Text(statusText)
                        .font(.system(size: 11))
                        .foregroundStyle(colors.fontSecondary)

                    if app.activeCapabilities.isEmpty {
                        Button("去设置导入源") { app.route = .settings }
                            .buttonStyle(.borderedProminent)
                            .tint(colors.primary)
                            .controlSize(.small)
                    } else {
                        Button("刷新源") { app.reloadSources() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                    Spacer()
                    if app.isSwitchingSource {
                        ProgressView().controlSize(.small)
                    }
                }

                if !app.activeCapabilities.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(app.activeCapabilities, id: \.source) { cap in
                                HStack(spacing: 5) {
                                    Text(cap.source)
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(colors.badgePrimary)
                                    Text(cap.qualitys.joined(separator: " / "))
                                        .font(.system(size: 9.5, design: .monospaced))
                                        .foregroundStyle(colors.fontSecondary)
                                    Text(cap.actions.joined(separator: ", "))
                                        .font(.system(size: 9))
                                        .foregroundStyle(colors.fontTertiary)
                                }
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(colors.badgePrimary.opacity(0.10), in: Capsule())
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: JSON 编辑

    private var jsonCard: some View {
        MeloCard(
            title: "MusicInfo JSON",
            subtitle: "直接编辑原版 MusicInfo 结构（id / name / singer / source / interval / meta）。meta 为宽松 JSON，可粘贴真实抓包数据。",
            systemImage: "curlybraces"
        ) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Button {
                        jsonText = TestPresets.json(for: presetSource)
                        parsedSummary = nil
                        localError = nil
                    } label: {
                        Label("恢复预设", systemImage: "arrow.counterclockwise")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.bordered)

                    Button {
                        if let formatted = formatJSON() {
                            jsonText = formatted
                            parsedSummary = nil
                            localError = nil
                        }
                    } label: {
                        Label("格式化", systemImage: "text.alignleft")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.bordered)

                    Button {
                        if let music = app.currentMusic,
                           let data = try? JSONEncoder().encode(music),
                           let json = String(data: data, encoding: .utf8) {
                            jsonText = json
                            parsedSummary = "已填入当前播放歌曲：\(music.name)"
                        }
                    } label: {
                        Label("使用当前播放歌曲", systemImage: "music.note")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.bordered)
                    .disabled(app.currentMusic == nil)

                    Spacer()

                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(jsonText, forType: .string)
                        app.showToast("已复制 JSON")
                    } label: {
                        Label("复制", systemImage: "doc.on.doc")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.bordered)
                }

                TextEditor(text: $jsonText)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(colors.font)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(height: 240)
                    .background(
                        colors.fontTertiary.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(colors.border, lineWidth: 1)
                    )

                if let parsedSummary {
                    Label(parsedSummary, systemImage: "checkmark.circle")
                        .font(.system(size: 10.5))
                        .foregroundStyle(colors.fontSecondary)
                }
            }
        }
    }

    // MARK: 结果

    private var resultCard: some View {
        MeloCard(title: "解析与播放", subtitle: "点击「解析并播放」后：取链 → 播放器加载 → 状态与错误会实时显示", systemImage: "waveform") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Button {
                        resolveAndPlay()
                    } label: {
                        Label(isRunning ? "解析中…" : "解析并播放", systemImage: "play.fill")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(colors.primary)
                    .disabled(isRunning || app.activeCapabilities.isEmpty)

                    if isRunning || app.isResolvingMusic {
                        ProgressView().controlSize(.small)
                    }

                    Button {
                        app.togglePlayPause()
                    } label: {
                        Label(app.isPlaying ? Localizer.tr("player__pause") : Localizer.tr("list__play"), systemImage: app.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.bordered)
                    .disabled(app.currentMusic == nil)

                    Spacer()

                    if app.isPlaying {
                        Label("正在播放", systemImage: "speaker.wave.2.fill")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(colors.primary)
                    } else {
                        Text(playerStatusLabel)
                            .font(.system(size: 10.5))
                            .foregroundStyle(colors.fontTertiary)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    infoRow("播放状态", playerStatusLabel)
                    infoRow("当前歌曲", currentMusicLabel)
                    infoRow("播放进度", "\(MeloUtils.formatTime(app.currentTime)) / \(MeloUtils.formatTime(app.duration))")
                    if let url = resolvedURL {
                        infoRow("解析 URL", url, selectable: true)
                    }
                    if let error = localError {
                        infoRow("错误", error, isError: true)
                    } else if let playbackError = app.playbackError {
                        infoRow("播放器错误", playbackError, isError: true)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    colors.fontTertiary.opacity(0.05),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )

                DisclosureGroup(isExpanded: $showRawJSON) {
                    Text(app.lyric.isEmpty ? "当前无歌词数据" : "已加载歌词：主歌词 \(app.lyric.lyric.count) 字符，翻译 \(app.lyric.tlyric?.count ?? 0) 字符")
                        .font(.system(size: 10.5))
                        .foregroundStyle(colors.fontSecondary)
                        .padding(.top, 6)
                } label: {
                    Text("检查详情")
                        .font(.system(size: 11))
                }
            }
        }
    }

    private func infoRow(_ title: String, _ value: String, selectable: Bool = false, isError: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(colors.fontTertiary)
                .frame(width: 70, alignment: .leading)
            if selectable {
                Text(value)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(isError ? .red : colors.fontSecondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
            } else {
                Text(value)
                    .font(.system(size: 10.5))
                    .foregroundStyle(isError ? .red : (title == "当前歌曲" ? colors.font : colors.fontSecondary))
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: 逻辑

    private var presetSources: [String] {
        let caps = Array(Set(app.activeCapabilities.map(\.source))).sorted()
        return caps.isEmpty ? TestPresets.sources : caps
    }

    private var qualityOptions: [String] {
        var qualities = Set(app.activeCapabilities.flatMap(\.qualitys))
        if qualities.isEmpty {
            for preset in TestPresets.fallbackQualityOrder { qualities.insert(preset) }
        }
        let ordered = preferredQualityOrder.filter { qualities.contains($0) }
        let rest = qualities.subtracting(ordered).sorted()
        return ordered + rest
    }

    private var statusText: String {
        switch app.sourceStatus {
        case .idle:
            return "未加载自定义源"
        case .loading:
            return "自定义源加载中…"
        case .ready(let caps):
            return "自定义源已就绪 · \(caps.count) 个能力（musicUrl / lyric）"
        case .error(let message):
            return "自定义源错误：\(message)"
        }
    }

    private var statusColor: Color {
        switch app.sourceStatus {
        case .ready: return colors.badgePrimary
        case .loading: return colors.badgeTertiary
        case .error: return .red
        case .idle: return colors.fontTertiary
        }
    }

    private var playerStatusLabel: String {
        switch app.playerStatus {
        case .stopped: return "停止"
        case .loading: return "加载中"
        case .playing: return "播放中"
        case .paused: return Localizer.tr("download__paused")
        case .error: return "错误"
        }
    }

    private var currentMusicLabel: String {
        guard let music = app.currentMusic else { return "—" }
        return "\(music.name) - \(music.singer)"
    }

    private func sourceLabel(_ source: String) -> String {
        switch source {
        case "kw": return "酷我 (kw)"
        case "kg": return "酷狗 (kg)"
        case "tx": return "QQ 音乐 (tx)"
        case "wy": return "网易云 (wy)"
        case "mg": return "咪咕 (mg)"
        default: return source
        }
    }

    private func qualityLabel(_ quality: String) -> String {
        switch quality {
        case "128k": return "128K"
        case "192k": return "192K"
        case "320k": return "320K"
        case "flac": return "无损 FLAC"
        case "flac24bit": return "无损 24BIT"
        default: return quality.uppercased()
        }
    }

    private func syncFromCapabilities() {
        let sources = presetSources
        if let first = sources.first, !sources.contains(presetSource) {
            presetSource = first
            jsonText = TestPresets.json(for: first)
        }
        let qualities = qualityOptions
        if !qualities.contains(selectedQuality) {
            selectedQuality = qualities.contains("128k") ? "128k" : (qualities.first ?? "128k")
        }
    }

    private func formatJSON() -> String? {
        guard let value = JSONValue(jsonString: jsonText) else {
            localError = "JSON 语法错误，无法格式化"
            return nil
        }
        return value.jsonString(pretty: true)
    }

    private func resolveAndPlay() {
        guard let data = jsonText.data(using: .utf8) else { return }
        let music: MusicInfo
        do {
            music = try JSONDecoder().decode(MusicInfo.self, from: data)
        } catch {
            localError = "MusicInfo JSON 解析失败：\(error.localizedDescription)"
            parsedSummary = nil
            return
        }
        guard !music.id.isEmpty, !music.name.isEmpty else {
            localError = "MusicInfo 缺少必要字段：id / name"
            return
        }
        localError = nil
        resolvedURL = nil
        parsedSummary = "已解析：\(music.name) - \(music.singer)（\(music.source) / \(music.id)）"
        app.settings.set(SettingKeys.playQuality, .string(selectedQuality))
        isRunning = true
        Task {
            let url = await app.testResolve(musicInfo: music)
            isRunning = false
            if let url {
                resolvedURL = url.absoluteString
            } else {
                localError = app.playbackError ?? "解析失败（请查看源日志 / Toast）"
            }
        }
    }
}

// MARK: - 测试预设

enum TestPresets {
    static let sources = ["kw", "kg", "tx", "wy", "mg"]
    static let fallbackQualityOrder = ["128k", "320k", "flac", "flac24bit"]

    static func json(for source: String) -> String {
        switch source {
        case "kg":
            return kg
        case "tx":
            return tx
        case "wy":
            return wy
        case "mg":
            return mg
        default:
            return kw
        }
    }

    static let kw = """
    {
      "id": "kw_228908",
      "name": "起风了",
      "singer": "买辣椒也用券",
      "source": "kw",
      "interval": "05:11",
      "meta": {
        "songId": "228908",
        "albumName": "起风了",
        "picUrl": "",
        "qualitys": [{ "type": "128k" }, { "type": "320k" }],
        "_qualitys": { "128k": "", "320k": "" }
      }
    }
    """

    static let kg = """
    {
      "id": "kg_9f1a2b3c",
      "name": "示例歌曲",
      "singer": "示例歌手",
      "source": "kg",
      "interval": "04:12",
      "meta": {
        "songId": "9f1a2b3c",
        "albumName": "示例专辑",
        "picUrl": "",
        "qualitys": [{ "type": "128k" }, { "type": "flac" }],
        "_qualitys": { "128k": "", "flac": "" }
      }
    }
    """

    static let tx = """
    {
      "id": "tx_0039MnYb0qxYhV",
      "name": "示例歌曲",
      "singer": "示例歌手",
      "source": "tx",
      "interval": "03:58",
      "meta": {
        "songId": "0039MnYb0qxYhV",
        "albumName": "示例专辑",
        "picUrl": "",
        "qualitys": [{ "type": "128k" }, { "type": "320k" }],
        "_qualitys": { "128k": "", "320k": "" }
      }
    }
    """

    static let wy = """
    {
      "id": "wy_1901371647",
      "name": "示例歌曲",
      "singer": "示例歌手",
      "source": "wy",
      "interval": "04:26",
      "meta": {
        "songId": "1901371647",
        "albumName": "示例专辑",
        "picUrl": "",
        "qualitys": [{ "type": "128k" }, { "type": "320k" }, { "type": "flac" }],
        "_qualitys": { "128k": "", "320k": "", "flac": "" }
      }
    }
    """

    static let mg = """
    {
      "id": "mg_600123456",
      "name": "示例歌曲",
      "singer": "示例歌手",
      "source": "mg",
      "interval": "03:45",
      "meta": {
        "songId": "600123456",
        "albumName": "示例专辑",
        "picUrl": "",
        "qualitys": [{ "type": "128k" }, { "type": "320k" }],
        "_qualitys": { "128k": "", "320k": "" }
      }
    }
    """
}
