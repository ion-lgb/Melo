import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MeloCore

// MARK: - 设置页

private enum CachePendingAction: Identifiable {
    case category(CacheCategoryInfo)
    case all

    var id: String {
        switch self {
        case .category(let category): return category.id
        case .all: return "all"
        }
    }
}

private struct PendingBackupImport: Identifiable {
    let kind: BackupKind
    let url: URL
    var id: String { "\(kind.rawValue)-\(url.path)" }
}

struct SettingsView: View {
    let app: AppModel

    @Environment(\.meloColors) private var colors
    @Environment(\.openWindow) private var openWindow

    init(app: AppModel,
         previewImportKind: BackupKind? = nil,
         previewCacheClearID: String? = nil) {
        self.app = app
        _portText = State(initialValue: String(app.openAPIPort))
        _tokenText = State(initialValue: app.openAPIToken)
        if let previewImportKind {
            _pendingImport = State(initialValue: PendingBackupImport(
                kind: previewImportKind,
                url: URL(fileURLWithPath: "/tmp/preview_\(previewImportKind.rawValue).lxmc")
            ))
        }
        let proxy = app.proxySettings
        _proxyEnabled = State(initialValue: proxy.enabled)
        _proxyHost = State(initialValue: proxy.host)
        _proxyPortText = State(initialValue: proxy.port > 0 ? String(proxy.port) : "")
        _proxyUsername = State(initialValue: proxy.username)
        _proxyPassword = State(initialValue: proxy.password)
        if let previewCacheClearID {
            if previewCacheClearID == "all" {
                _pendingCacheClear = State(initialValue: .all)
            } else if let category = app.cacheCategories.first(where: { $0.id == previewCacheClearID }) {
                _pendingCacheClear = State(initialValue: .category(category))
            }
        }
    }

    @State private var importingSource = false
    @State private var showURLImport = false
    @State private var pendingDeleteSource: UserSourceInfo?
    @State private var sourceImportError: String?

    // 备份与恢复 / 开放 API
    @State private var pendingImport: PendingBackupImport?
    @State private var pendingCacheClear: CachePendingAction?
    @State private var showSleepTimerSheet = false
    @State private var showDislikeRulesSheet = false

    // 网络代理
    @State private var proxyEnabled: Bool
    @State private var proxyHost: String
    @State private var proxyPortText: String
    @State private var proxyUsername: String
    @State private var proxyPassword: String
    @State private var showProxyPassword = false
    @State private var backupStatusText: String?
    @State private var portText: String
    @State private var tokenText: String
    @State private var maskToken = true

    private let qualityOptions = ["128k", "320k", "flac", "flac24bit"]
    private let rateOptions: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0]

    @State private var category: SettingsCategory = .appearance

    private enum SettingsCategory: String, CaseIterable, Identifiable {
        case appearance = "外观"
        case playback = "播放"
        case desktopLyric = "桌面歌词"
        case hotKey = "快捷键"
        case download = "下载"
        case source = "源"
        case data = "数据"
        case network = "网络"
        case system = "系统"

        var id: String { rawValue }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MeloMetrics.gridSpacing) {
                header
                categoryBar
                categoryCards
            }
            .padding(.horizontal, MeloMetrics.pageInset)
            .padding(.vertical, 20)
            .frame(maxWidth: 920, alignment: .leading)
        }
        .background(colors.groupedBackground)
        .fileImporter(
            isPresented: $importingSource,
            allowedContentTypes: [UTType(filenameExtension: "js") ?? .sourceCode, .sourceCode],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                sourceImportError = nil
                Task { await app.importSource(url: url) }
            case .failure(let error):
                sourceImportError = error.localizedDescription
            }
        }
        .sheet(isPresented: $showURLImport) {
            ImportSourceSheet(app: app)
        }
        .sheet(isPresented: $showSleepTimerSheet) {
            SleepTimerSheet(app: app)
        }
        .sheet(isPresented: $showDislikeRulesSheet) {
            DislikeRulesSheet(app: app)
        }
        .alert(importAlertTitle, isPresented: importAlertBinding, presenting: pendingImport) { item in
            Button(Localizer.tr("btn_cancel"), role: .cancel) { pendingImport = nil }
            Button("覆盖导入", role: .destructive) {
                app.importBackup(from: item.url)
                backupStatusText = "已导入：\(item.url.lastPathComponent)"
                pendingImport = nil
            }
        } message: { item in
            Text("将导入「\(item.url.lastPathComponent)」（\(backupKindName(item.kind))）。此操作会覆盖当前对应的数据，建议先导出备份后再继续。")
        }
        .onChange(of: app.openAPIPort) { _, newValue in
            portText = String(newValue)
        }
        .onChange(of: app.openAPIToken) { _, newValue in
            tokenText = newValue
        }
        .alert("删除自定义源", isPresented: Binding(
            get: { pendingDeleteSource != nil },
            set: { if !$0 { pendingDeleteSource = nil } }
        )) {
            Button(Localizer.tr("btn_cancel"), role: .cancel) { pendingDeleteSource = nil }
            Button("删除", role: .destructive) {
                if let source = pendingDeleteSource {
                    app.removeSource(id: source.id)
                }
                pendingDeleteSource = nil
            }
        } message: {
            Text("将删除「\(pendingDeleteSource?.name ?? "")」及其脚本数据，此操作不可撤销。")
        }
    }

    // MARK: 头部

    private var header: some View {
        HStack(alignment: .top) {
            PageTitle(Localizer.tr("setting"), subtitle: "外观 / 播放 / 自定义源 / 数据 / 关于 · 设置写入原版兼容的 config_v2.json")
            Spacer()
            Button {
                app.route = .test
            } label: {
                Label("自定义源测试", systemImage: "testtube.2")
            }
            .buttonStyle(.meloSecondary)
        }
    }

    // MARK: 分类导航

    private var categoryBar: some View {
        HStack(spacing: 8) {
            ForEach(SettingsCategory.allCases) { item in
                MeloChip(text: item.rawValue, isSelected: category == item) {
                    category = item
                }
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var categoryCards: some View {
        switch category {
        case .appearance:
            appearanceCard
        case .playback:
            playbackCard
        case .desktopLyric:
            desktopLyricCard
        case .hotKey:
            HotKeySettingsCard(app: app)
        case .download:
            downloadCard
        case .source:
            sourcesCard
        case .data:
            dataCard
            onlineListUpdateCard
            backupCard
        case .network:
            openAPICard
            proxyCard
        case .system:
            miscCard
            aboutCard
        }
    }

    // MARK: 外观

    private var appearanceCard: some View {
        MeloCard(title: "外观与语言", subtitle: "外观已固定为 Apple Music 风格，支持跟随系统自动切换亮/暗", systemImage: "paintpalette") {
            VStack(alignment: .leading, spacing: 14) {
                Toggle("跟随系统自动切换亮/暗", isOn: autoThemeBinding)
                    .toggleStyle(.switch)
                    .font(MeloFont.body)
                    .frame(minHeight: 28)

                Text("原版主题文件（themes.json 与自定义主题）仍会读写以保持数据兼容，但不再影响界面外观。")
                    .font(MeloFont.caption)
                    .foregroundStyle(colors.fontTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider().overlay(colors.border)

                HStack(spacing: 14) {
                    Text(Localizer.tr("setting__basic_lang"))
                        .font(MeloFont.body)
                        .foregroundStyle(colors.font)
                    Picker(Localizer.tr("setting__basic_lang"), selection: languageBinding) {
                        ForEach(app.localizer.languageOptions, id: \.locale) { option in
                            Text(option.name).tag(option.locale)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .menuIndicator(.visible)
                    .buttonStyle(.plain)
                    .tint(colors.font)
                    .fixedSize()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(colors.chipFill, in: Capsule())
                    Text("运行时立即切换（复用原版 src/lang/*.json）")
                        .font(MeloFont.caption)
                        .foregroundStyle(colors.fontTertiary)
                    Spacer()
                }
                .frame(minHeight: 28)
            }
        }
    }

    // MARK: 在线列表更新

    private var onlineListUpdateCard: some View {
        MeloCard(
            title: "在线列表更新",
            subtitle: "从在线歌单/排行榜保存的列表可在此管理同步；勾选自动更新的列表会在每次启动时自动同步一次",
            systemImage: "arrow.triangle.2.circlepath"
        ) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "globe")
                        .font(.system(size: 12))
                        .foregroundStyle(colors.fontTertiary)
                    Text("在线列表：\(app.onlineUserLists.count) 个")
                        .font(MeloFont.secondary)
                        .foregroundStyle(colors.fontSecondary)
                    Spacer()
                    Button {
                        app.loadListUpdateInfo()
                        app.showToast("已刷新列表更新状态")
                    } label: {
                        Label("刷新状态", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.meloSecondary)
                }

                if app.onlineUserLists.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "tray")
                            .font(.system(size: 12))
                            .foregroundStyle(colors.fontTertiary)
                        Text("暂无在线列表。从在线歌单/排行榜保存为列表后，可在此查看与更新。")
                            .font(MeloFont.secondary)
                            .foregroundStyle(colors.fontTertiary)
                        Spacer()
                    }
                    .frame(minHeight: 28)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(app.onlineUserLists.enumerated()), id: \.element.id) { index, list in
                            onlineListRow(list)
                            if index < app.onlineUserLists.count - 1 {
                                Divider().overlay(colors.border)
                            }
                        }
                    }
                    .background(
                        colors.chipFill,
                        in: RoundedRectangle(cornerRadius: MeloMetrics.controlRadius, style: .continuous)
                    )
                }

                Text("说明：更新会按源歌单/排行榜的最新内容覆盖该列表内歌曲（保留列表本身）；自动更新仅在应用启动时触发一次，更新失败会 toast 提示。")
                    .font(MeloFont.caption)
                    .foregroundStyle(colors.fontTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func onlineListRow(_ list: ListInfo) -> some View {
        let info = app.listUpdateInfo[list.id]
        let isUpdating = app.updatingListIds.contains(list.id)
        return HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(colors.fontSecondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(list.name)
                        .font(MeloFont.cardTitle)
                        .foregroundStyle(colors.font)
                        .lineLimit(1)
                    if let source = list.source, !source.isEmpty {
                        MeloBadge(source.uppercased(), color: colors.badgeTertiary)
                    }
                }
                Text("最后更新：\(formatUpdateTime(info?.updateTime ?? 0))")
                    .font(MeloFont.caption)
                    .foregroundStyle(colors.fontTertiary)
            }
            Spacer()
            Toggle(Localizer.tr("list_update_modal__auto_update"), isOn: Binding(
                get: { app.listUpdateInfo[list.id]?.isAutoUpdate ?? false },
                set: { app.setListAutoUpdate(listId: list.id, enabled: $0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .font(MeloFont.secondary)

            if isUpdating {
                ProgressView().controlSize(.mini)
                Text("更新中…")
                    .font(MeloFont.caption)
                    .foregroundStyle(colors.fontTertiary)
            } else {
                Button(Localizer.tr("list_update_modal__update")) {
                    Task { await app.updateSourceList(id: list.id) }
                }
                .buttonStyle(.meloSecondary)
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 32)
    }

    private func formatUpdateTime(_ milliseconds: Int64) -> String {
        guard milliseconds > 0 else { return "从未更新" }
        let date = Date(timeIntervalSince1970: Double(milliseconds) / 1000)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    private func formatTimeout(_ remaining: TimeInterval) -> String {
        let total = max(0, Int(remaining.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    // MARK: 播放

    private var playbackCard: some View {
        MeloCard(title: Localizer.tr("list__play"), subtitle: "音量 / 默认音质 / 播放速度等会写入原版 config_v2.json", systemImage: "play.circle") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Text("默认音量")
                        .font(MeloFont.body)
                        .frame(width: 84, alignment: .leading)
                    Slider(
                        value: Binding(get: { app.volume }, set: { app.setVolume($0) }),
                        in: 0...1
                    )
                    .tint(colors.primary)
                    .frame(width: 220)
                    Text("\(Int((app.volume * 100).rounded()))%")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(colors.fontSecondary)
                        .frame(width: 44, alignment: .trailing)
                    Toggle(Localizer.tr("player__volume_mute_label"), isOn: Binding(get: { app.isMuted }, set: { _ in app.toggleMute() }))
                        .toggleStyle(.checkbox)
                        .font(MeloFont.body)
                    Spacer()
                }
                .frame(minHeight: 28)

                HStack(spacing: 12) {
                    Text("默认音质")
                        .font(MeloFont.body)
                        .frame(width: 84, alignment: .leading)
                    Picker("默认音质", selection: stringBinding(SettingKeys.playQuality, default: "128k")) {
                        ForEach(qualityOptions, id: \.self) { quality in
                            Text(qualityLabel(quality)).tag(quality)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 140)
                    Text("实际取链时会按自定义源能力自动降级")
                        .font(MeloFont.caption)
                        .foregroundStyle(colors.fontTertiary)
                    Spacer()
                }
                .frame(minHeight: 28)

                HStack(spacing: 12) {
                    Text("播放速度")
                        .font(MeloFont.body)
                        .frame(width: 84, alignment: .leading)
                    Picker("播放速度", selection: Binding(
                        get: { app.playbackRate },
                        set: { app.setPlaybackRate($0) }
                    )) {
                        ForEach(rateOptions, id: \.self) { rate in
                            Text(String(format: "%.2fx", rate)).tag(rate)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 120)
                    Toggle("保持音调", isOn: boolBinding(SettingKeys.preservesPitch, default: true))
                        .toggleStyle(.checkbox)
                        .font(MeloFont.body)
                    Spacer()
                }
                .frame(minHeight: 28)

                HStack(spacing: 12) {
                    Text("输出设备")
                        .font(MeloFont.body)
                        .frame(width: 84, alignment: .leading)
                    if app.availableOutputDevices.isEmpty {
                        Text("未发现音频输出设备")
                            .font(MeloFont.secondary)
                            .foregroundStyle(colors.fontTertiary)
                    } else {
                        Picker("输出设备", selection: outputDeviceBinding) {
                            Text("系统默认").tag("default")
                            ForEach(app.availableOutputDevices) { device in
                                Text(device.isDefault ? "\(device.name)（系统默认）" : device.name)
                                    .tag(device.id)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 220)
                    }
                    Text(app.currentOutputDeviceName)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(colors.fontTertiary)
                    Spacer()
                }
                .frame(minHeight: 28)

                HStack(alignment: .top, spacing: 12) {
                    Text("")
                        .frame(width: 84, alignment: .leading)
                    Text("选择非默认设备后，播放会切换到音效引擎（远程音频需先缓存，属 AVPlayer 无法直接指定输出设备的限制）；切换设备会保留当前播放位置。")
                        .font(MeloFont.caption)
                        .foregroundStyle(colors.fontTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }

                HStack(spacing: 12) {
                    Text(Localizer.tr("setting__other"))
                        .font(MeloFont.body)
                        .frame(width: 84, alignment: .leading)
                    Toggle("界面动画", isOn: boolBinding(SettingKeys.showAnimation, default: true))
                        .toggleStyle(.checkbox)
                        .font(MeloFont.body)
                    Text("（动画设置会写入原版 config_v2.json）")
                        .font(MeloFont.caption)
                        .foregroundStyle(colors.fontTertiary)
                    Spacer()
                }
                .frame(minHeight: 28)

                HStack(spacing: 12) {
                    Text("播放增强")
                        .font(MeloFont.body)
                        .frame(width: 84, alignment: .leading)
                    Toggle("播放错误时自动切歌", isOn: boolBinding(SettingKeys.autoSkipOnError, default: true))
                        .toggleStyle(.checkbox)
                        .font(MeloFont.body)
                    Toggle("启动后自动播放", isOn: boolBinding(SettingKeys.startupAutoPlay, default: false))
                        .toggleStyle(.checkbox)
                        .font(MeloFont.body)
                    Toggle("记住上次播放进度", isOn: boolBinding(SettingKeys.savePlayTime, default: false))
                        .toggleStyle(.checkbox)
                        .font(MeloFont.body)
                    Spacer()
                }
                .frame(minHeight: 28)

                HStack(alignment: .top, spacing: 12) {
                    Text("")
                        .frame(width: 84, alignment: .leading)
                    Text("自动切歌：播放地址失效/解码失败时跳过当前歌曲（连续 3 次失败后停止）；启动自动播放会在下次启动时恢复上次歌曲；记住进度会保存播放位置。")
                        .font(MeloFont.caption)
                        .foregroundStyle(colors.fontTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }

                HStack(spacing: 12) {
                    Text(Localizer.tr("play_timeout"))
                        .font(MeloFont.body)
                        .frame(width: 84, alignment: .leading)
                    if let remaining = app.playTimeoutRemaining {
                        Text(remaining <= 0 ? "等待本曲结束" : "剩余 \(formatTimeout(remaining))")
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(colors.primary)
                        Button(Localizer.tr("play_timeout_stop")) {
                            app.cancelPlayTimeout()
                        }
                        .buttonStyle(.meloSecondary)
                    } else {
                        Text(Localizer.tr("setting__hot_key_unset_input"))
                            .font(MeloFont.secondary)
                            .foregroundStyle(colors.fontTertiary)
                    }
                    Button("设置定时暂停…") {
                        showSleepTimerSheet = true
                    }
                    .buttonStyle(.meloSecondary)
                    Text("到时间自动暂停播放；可选等待当前歌曲结束")
                        .font(MeloFont.caption)
                        .foregroundStyle(colors.fontTertiary)
                    Spacer()
                }
                .frame(minHeight: 28)

                HStack(spacing: 12) {
                    Text("窗口")
                        .font(MeloFont.body)
                        .frame(width: 84, alignment: .leading)
                    Toggle("关闭窗口时最小化到菜单栏", isOn: boolBinding(SettingKeys.trayEnable, default: false))
                        .toggleStyle(.checkbox)
                        .font(MeloFont.body)
                    Text("菜单栏图标常驻，点击可重新打开主窗口；窗口大小/位置已自动记忆（NSWindow autosave）")
                        .font(MeloFont.caption)
                        .foregroundStyle(colors.fontTertiary)
                    Spacer()
                }
                .frame(minHeight: 28)

                HStack(spacing: 12) {
                    Text("歌词显示")
                        .font(MeloFont.body)
                        .frame(width: 84, alignment: .leading)
                    Toggle("翻译", isOn: lyricOptionBinding(SettingKeys.showLyricTranslation))
                        .toggleStyle(.checkbox)
                        .font(MeloFont.body)
                    Toggle("罗马音", isOn: lyricOptionBinding(SettingKeys.showLyricRoma))
                        .toggleStyle(.checkbox)
                        .font(MeloFont.body)
                    Toggle("逐字", isOn: lyricOptionBinding(SettingKeys.playWordByWordLyric))
                        .toggleStyle(.checkbox)
                        .font(MeloFont.body)
                    Toggle("繁简", isOn: lyricOptionBinding(SettingKeys.convertLyricS2T))
                        .toggleStyle(.checkbox)
                        .font(MeloFont.body)
                    Text("（播放详情 / 桌面歌词生效）")
                        .font(MeloFont.caption)
                        .foregroundStyle(colors.fontTertiary)
                    Spacer()
                }
                .frame(minHeight: 28)

                HStack(spacing: 12) {
                    Text("视觉")
                        .font(MeloFont.body)
                        .frame(width: 84, alignment: .leading)
                    Toggle(Localizer.tr("audio_visualization"), isOn: Binding(
                        get: { app.isAudioVisualizationEnabled },
                        set: { app.setAudioVisualizationEnabled($0) }
                    ))
                        .toggleStyle(.checkbox)
                        .font(MeloFont.body)
                    Text("仅音效引擎播放时可用；开启后播放会强制走音效引擎（远程歌曲首次需缓存，AVPlayer 路径无频谱）")
                        .font(MeloFont.caption)
                        .foregroundStyle(colors.fontTertiary)
                    Spacer()
                }
                .frame(minHeight: 28)

                Divider().overlay(colors.border)

                HStack(spacing: 12) {
                    Text("音效")
                        .font(MeloFont.body)
                        .frame(width: 84, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(hasSoundEffects ? colors.primary : colors.fontTertiary)
                                .frame(width: 7, height: 7)
                            Text(audioEffectSummary)
                                .font(MeloFont.body)
                                .foregroundStyle(hasSoundEffects ? colors.font : colors.fontSecondary)
                        }
                        Text("10 段均衡器 / 变速变调会写入原版 player.soundEffect.*；启用后播放会切换到音效引擎")
                            .font(MeloFont.caption)
                            .foregroundStyle(colors.fontTertiary)
                    }
                    Spacer()
                    Button("打开音效面板") {
                        NotificationCenter.default.post(name: .meloShowSoundEffectPanel, object: nil)
                    }
                    .buttonStyle(.meloSecondary)
                }
                .frame(minHeight: 28)
            }
        }
    }

    // MARK: 桌面歌词

    private var desktopLyricCard: some View {
        MeloCard(
            title: "桌面歌词",
            subtitle: "样式与行为写入原版 desktopLyric.* 设置，桌面歌词窗口实时生效；窗口位置/尺寸由原版设置保存",
            systemImage: "text.bubble"
        ) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Text(Localizer.tr("setting__is_enable"))
                        .font(MeloFont.body)
                        .frame(width: 84, alignment: .leading)
                    Toggle("桌面歌词", isOn: boolBinding(SettingKeys.desktopLyricEnable, default: false))
                        .toggleStyle(.switch)
                        .font(MeloFont.body)
                    Button(app.settings.bool(SettingKeys.desktopLyricEnable) ? Localizer.tr("player__desktop_lyric_off") : "打开桌面歌词") {
                        toggleDesktopLyricWindow()
                    }
                    .buttonStyle(.meloSecondary)
                    Spacer()
                }
                .frame(minHeight: 28)

                desktopLyricSlider("字号", value: app.desktopLyricFontSize, range: 10...60, step: 1, suffix: "pt") {
                    app.setDesktopLyricFontSize($0)
                }
                desktopLyricSlider("不透明度", value: app.desktopLyricOpacity, range: 10...100, step: 1, suffix: "%") {
                    app.setDesktopLyricOpacity($0)
                }
                desktopLyricSlider("行间距", value: app.desktopLyricLineGap, range: 0...60, step: 1, suffix: "pt") {
                    app.setDesktopLyricLineGap($0)
                }

                HStack(spacing: 12) {
                    Text("对齐")
                        .font(MeloFont.body)
                        .frame(width: 84, alignment: .leading)
                    Picker("对齐", selection: Binding(
                        get: { app.desktopLyricAlign },
                        set: { app.setDesktopLyricAlign($0) }
                    )) {
                        Text("左对齐").tag("left")
                        Text(Localizer.tr("lyric_menu__align_center")).tag("center")
                        Text("右对齐").tag("right")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .font(MeloFont.body)
                    .frame(width: 220)
                    Spacer()
                }
                .frame(minHeight: 28)

                HStack(spacing: 14) {
                    Text("颜色")
                        .font(MeloFont.body)
                        .frame(width: 84, alignment: .leading)
                    ColorPicker(Localizer.tr("list__play"), selection: desktopLyricColorBinding(.played), supportsOpacity: true)
                        .font(MeloFont.body)
                    ColorPicker("未播放", selection: desktopLyricColorBinding(.unplay), supportsOpacity: true)
                        .font(MeloFont.body)
                    ColorPicker("阴影", selection: desktopLyricColorBinding(.shadow), supportsOpacity: true)
                        .font(MeloFont.body)
                    Button("恢复默认配色") {
                        app.setDesktopLyricColors(
                            played: "rgba(7, 197, 86, 1)",
                            unplay: "rgba(255, 255, 255, 1)",
                            shadow: "rgba(0, 0, 0, 0.18)"
                        )
                    }
                    .buttonStyle(.meloSecondary)
                    Spacer()
                }
                .frame(minHeight: 28)

                Divider().overlay(colors.border)

                HStack(spacing: 18) {
                    Text("行为")
                        .font(MeloFont.body)
                        .frame(width: 84, alignment: .leading)
                    desktopLyricBehaviorToggle("暂停时隐藏", key: SettingKeys.desktopLyricPauseHide)
                    desktopLyricBehaviorToggle("鼠标悬停隐藏", key: SettingKeys.desktopLyricHoverHide)
                    desktopLyricBehaviorToggle("全屏时隐藏", key: SettingKeys.desktopLyricFullscreenHide)
                    Spacer()
                }
                .frame(minHeight: 28)

                HStack(spacing: 18) {
                    Text("")
                        .frame(width: 84, alignment: .leading)
                    desktopLyricBehaviorToggle("延迟滚动", key: SettingKeys.desktopLyricDelayScroll)
                    desktopLyricBehaviorToggle("超长省略", key: SettingKeys.desktopLyricEllipsis)
                    Text("桌面歌词区域右键可快速调整歌词偏移/字号/对齐")
                        .font(MeloFont.caption)
                        .foregroundStyle(colors.fontTertiary)
                    Spacer()
                }
                .frame(minHeight: 28)

                HStack(spacing: 18) {
                    Text("视觉")
                        .font(MeloFont.body)
                        .frame(width: 84, alignment: .leading)
                    Toggle(Localizer.tr("setting__desktop_lyric_audio_visualization"), isOn: Binding(
                        get: { app.isDesktopLyricAudioVisualizationEnabled },
                        set: { app.setAudioVisualizationEnabled($0, desktopLyric: true) }
                    ))
                        .toggleStyle(.checkbox)
                        .font(MeloFont.body)
                    Text("在歌词上方显示细频谱；仅音效引擎播放时可用，远程歌曲首次需缓存")
                        .font(MeloFont.caption)
                        .foregroundStyle(colors.fontTertiary)
                    Spacer()
                }
                .frame(minHeight: 28)
            }
        }
    }

    private func desktopLyricSlider(_ label: String,
                                    value: Double,
                                    range: ClosedRange<Double>,
                                    step: Double,
                                    suffix: String,
                                    onChange: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(MeloFont.body)
                .frame(width: 84, alignment: .leading)
            Slider(
                value: Binding(get: { min(max(value, range.lowerBound), range.upperBound) }, set: onChange),
                in: range,
                step: step
            )
            .tint(colors.primary)
            .frame(width: 220)
            Text("\(Int(value.rounded()))\(suffix)")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(colors.fontSecondary)
                .frame(width: 56, alignment: .leading)
            Spacer()
        }
        .frame(minHeight: 28)
    }

    private enum DesktopLyricColorSlot {
        case played
        case unplay
        case shadow
    }

    private func desktopLyricColorBinding(_ slot: DesktopLyricColorSlot) -> Binding<Color> {
        Binding(
            get: {
                switch slot {
                case .played: return LyricDisplaySupport.color(fromCSS: app.desktopLyricPlayedColor) ?? colors.primary
                case .unplay: return LyricDisplaySupport.color(fromCSS: app.desktopLyricUnplayColor) ?? .white
                case .shadow: return LyricDisplaySupport.color(fromCSS: app.desktopLyricShadowColor) ?? .black.opacity(0.18)
                }
            },
            set: { newColor in
                let css = LyricDisplaySupport.cssString(from: newColor)
                switch slot {
                case .played: app.setDesktopLyricColors(played: css, unplay: nil, shadow: nil)
                case .unplay: app.setDesktopLyricColors(played: nil, unplay: css, shadow: nil)
                case .shadow: app.setDesktopLyricColors(played: nil, unplay: nil, shadow: css)
                }
            }
        )
    }

    private func desktopLyricBehaviorToggle(_ title: String, key: String) -> some View {
        Toggle(title, isOn: Binding(
            get: { app.settings.bool(key) },
            set: { app.setDesktopLyricBehavior(key, enabled: $0) }
        ))
        .toggleStyle(.checkbox)
        .font(MeloFont.body)
    }

    private func lyricOptionBinding(_ key: String) -> Binding<Bool> {
        Binding(
            get: { app.settings.bool(key) },
            set: { app.setLyricDisplayOption(key, enabled: $0) }
        )
    }

    private func toggleDesktopLyricWindow() {
        let enabled = app.settings.bool(SettingKeys.desktopLyricEnable)
        if enabled {
            app.settings.set(SettingKeys.desktopLyricEnable, .bool(false))
            MeloUIWindow.closeDesktopLyric()
        } else {
            app.settings.set(SettingKeys.desktopLyricEnable, .bool(true))
            openWindow(id: MeloUIWindow.desktopLyricID)
        }
    }

    private var outputDeviceBinding: Binding<String> {
        Binding(
            get: {
                let current = app.mediaDeviceId
                if current == "default" || current.isEmpty { return "default" }
                return app.availableOutputDevices.contains(where: { $0.id == current }) ? current : "default"
            },
            set: { newValue in
                app.setMediaDeviceId(newValue == "default" ? nil : newValue)
            }
        )
    }

    private var hasSoundEffects: Bool {
        let effects = app.audioEffects
        return effects.isEQActive
            || abs(app.pitchShifterRate - 1) > 0.005
            || effects.isConvolutionActive
            || effects.pannerEnabled
    }

    private var audioEffectSummary: String {
        let effects = app.audioEffects
        var parts: [String] = []
        if effects.isEQActive {
            let presetName = EQPreset.matching(effects.eqBands)?.name ?? "自定义"
            parts.append("均衡器：\(presetName)")
        }
        let rate = app.pitchShifterRate
        if abs(rate - 1) > 0.005 {
            let semitones = rate > 0 ? 12 * log2(rate) : 0
            parts.append(String(format: "变速变调：%.2fx（%+.1f 半音）", rate, semitones))
        }
        if effects.isConvolutionActive {
            let name = app.convolutionPresets.first { $0.fileName == effects.convolutionFileName }?.name
                ?? effects.convolutionFileName
                ?? "自定义"
            parts.append("混响：\(name)")
        }
        if effects.pannerEnabled {
            parts.append("环绕：开")
        }
        return parts.isEmpty ? "未启用（普通播放引擎）" : parts.joined(separator: " · ")
    }

    // MARK: 下载

    private var downloadCard: some View {
        MeloCard(
            title: Localizer.tr("download"),
            subtitle: "原生下载引擎；保存目录 / 文件名 / 并发数与标签写入设置与原版 config_v2.json 兼容",
            systemImage: "arrow.down.circle"
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("开启下载功能", isOn: boolBinding(SettingKeys.downloadEnable, default: false))
                    .toggleStyle(.switch)
                    .font(MeloFont.body)
                    .frame(minHeight: 28)

                HStack(spacing: 12) {
                    Text("保存目录")
                        .font(MeloFont.body)
                        .frame(width: 84, alignment: .leading)
                    Text(currentDownloadPath)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(colors.fontSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer(minLength: 8)
                    Button("选择目录…") { chooseDownloadFolder() }
                        .buttonStyle(.meloSecondary)
                    Button(Localizer.tr("songlist__import_input_btn_confirm")) {
                        NSWorkspace.shared.open(URL(fileURLWithPath: currentDownloadPath, isDirectory: true))
                    }
                    .buttonStyle(.meloSecondary)
                }
                .frame(minHeight: 28)

                HStack(spacing: 12) {
                    Text("文件名模板")
                        .font(MeloFont.body)
                        .frame(width: 84, alignment: .leading)
                    Picker("文件名模板", selection: stringBinding(SettingKeys.downloadFileName, default: "歌名 - 歌手")) {
                        Text("歌名 - 歌手").tag("歌名 - 歌手")
                        Text("歌手 - 歌名").tag("歌手 - 歌名")
                        Text("歌名").tag("歌名")
                    }
                    .labelsHidden()
                    .frame(width: 180)
                    Text("示例：\(downloadTemplatePreview)")
                        .font(MeloFont.caption)
                        .foregroundStyle(colors.fontTertiary)
                    Spacer()
                }
                .frame(minHeight: 28)

                HStack(spacing: 12) {
                    Text("同时下载")
                        .font(MeloFont.body)
                        .frame(width: 84, alignment: .leading)
                    Picker("同时下载", selection: intBinding(SettingKeys.downloadMaxNumber, default: 3)) {
                        ForEach(1...10, id: \.self) { count in
                            Text("\(count)").tag(count)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 80)
                    Text("修改后需重启应用生效（下载服务在启动时创建并发队列）")
                        .font(MeloFont.caption)
                        .foregroundStyle(colors.fontTertiary)
                    Spacer()
                }
                .frame(minHeight: 28)

                HStack(spacing: 12) {
                    Text("写入标签")
                        .font(MeloFont.body)
                        .frame(width: 84, alignment: .leading)
                    Toggle(Localizer.tr("setting__download_embed_pic"), isOn: boolBinding(SettingKeys.downloadEmbedPic, default: true))
                        .toggleStyle(.checkbox)
                        .font(MeloFont.body)
                    Toggle(Localizer.tr("setting__download_embed_lyric"), isOn: boolBinding(SettingKeys.downloadEmbedLyric, default: false))
                        .toggleStyle(.checkbox)
                        .font(MeloFont.body)
                    Text("MP3 / FLAC 下载完成后写入标题、歌手、专辑等元数据")
                        .font(MeloFont.caption)
                        .foregroundStyle(colors.fontTertiary)
                    Spacer()
                }
                .frame(minHeight: 28)

                if app.settings.bool(SettingKeys.downloadEmbedLyric) {
                    HStack(spacing: 12) {
                        Text("")
                            .frame(width: 84, alignment: .leading)
                        Toggle("逐字", isOn: boolBinding(SettingKeys.downloadEmbedLyricLx, default: true))
                            .toggleStyle(.checkbox)
                            .font(MeloFont.body)
                        Toggle("翻译", isOn: boolBinding(SettingKeys.downloadEmbedLyricT, default: false))
                            .toggleStyle(.checkbox)
                            .font(MeloFont.body)
                        Toggle("罗马音", isOn: boolBinding(SettingKeys.downloadEmbedLyricR, default: false))
                            .toggleStyle(.checkbox)
                            .font(MeloFont.body)
                        Text("逐字/翻译/罗马音会合并进歌词标签（逐字默认开启）")
                            .font(MeloFont.caption)
                            .foregroundStyle(colors.fontTertiary)
                        Spacer()
                    }
                    .frame(minHeight: 28)
                }

                HStack(spacing: 12) {
                    Text("歌词文件")
                        .font(MeloFont.body)
                        .frame(width: 84, alignment: .leading)
                    Toggle("保存歌词文件", isOn: boolBinding(SettingKeys.downloadSaveLrc, default: false))
                        .toggleStyle(.checkbox)
                        .font(MeloFont.body)
                    Text("下载歌曲时同时保存 .lrc 歌词文件")
                        .font(MeloFont.caption)
                        .foregroundStyle(colors.fontTertiary)
                    Spacer()
                }
                .frame(minHeight: 28)

                if app.settings.bool(SettingKeys.downloadSaveLrc) {
                    HStack(spacing: 12) {
                        Text("")
                            .frame(width: 84, alignment: .leading)
                        Toggle("合并逐字", isOn: boolBinding(SettingKeys.downloadSaveLxLrc, default: true))
                            .toggleStyle(.checkbox)
                            .font(MeloFont.body)
                        Toggle("翻译", isOn: boolBinding(SettingKeys.downloadSaveTLrc, default: false))
                            .toggleStyle(.checkbox)
                            .font(MeloFont.body)
                        Toggle("罗马音", isOn: boolBinding(SettingKeys.downloadSaveRLrc, default: false))
                            .toggleStyle(.checkbox)
                            .font(MeloFont.body)
                        Text("编码")
                            .font(MeloFont.secondary)
                            .foregroundStyle(colors.fontSecondary)
                        Picker("编码", selection: stringBinding(SettingKeys.downloadLrcFormat, default: "utf8")) {
                            Text(Localizer.tr("setting__download_lyric_format_utf8")).tag("utf8")
                            Text(Localizer.tr("setting__download_lyric_format_gbk")).tag("gbk")
                        }
                        .labelsHidden()
                        .frame(width: 96)
                        Spacer()
                    }
                    .frame(minHeight: 28)
                }

                Divider().overlay(colors.border)

                HStack(spacing: 10) {
                    Text("当前队列：\(app.downloadTasks.count) 个任务 · 进行中 \(activeDownloadCount)")
                        .font(MeloFont.secondary)
                        .foregroundStyle(colors.fontSecondary)
                    Spacer()
                    if !app.isDownloadEnabled {
                        Text("下载功能已关闭")
                            .font(MeloFont.caption)
                            .foregroundStyle(colors.badgeTertiary)
                    }
                    Button("打开下载页") { app.route = .download }
                        .buttonStyle(.meloSecondary)
                }
                .frame(minHeight: 28)
            }
        }
    }

    private var currentDownloadPath: String {
        app.settings.string(SettingKeys.downloadSavePath)
            ?? FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first?.path
            ?? NSHomeDirectory()
    }

    private var downloadTemplatePreview: String {
        let template = app.settings.string(SettingKeys.downloadFileName) ?? "歌名 - 歌手"
        return template
            .replacingOccurrences(of: "歌名", with: "起风了")
            .replacingOccurrences(of: "歌手", with: "买辣椒也用券") + ".mp3"
    }

    private var activeDownloadCount: Int {
        app.downloadTasks.filter { $0.status == "run" || $0.status == "pause" || $0.status == "waiting" }.count
    }

    private func chooseDownloadFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "选择下载目录"
        panel.message = "选择歌曲下载保存目录"
        panel.directoryURL = URL(fileURLWithPath: currentDownloadPath, isDirectory: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        app.settings.set(SettingKeys.downloadSavePath, .string(url.path))
        app.showToast("下载目录已更新：\(url.path)")
    }

    // MARK: 备份与恢复

    private var backupCard: some View {
        MeloCard(
            title: Localizer.tr("setting__backup"),
            subtitle: "兼容原版 LX Music 备份格式（.lxmc = gzip 压缩的 JSON；type=allData_v2 / playList_v2 / setting_v2）",
            systemImage: "archivebox"
        ) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Text(Localizer.tr("export"))
                        .font(MeloFont.body)
                        .frame(width: 64, alignment: .leading)
                    backupButton("全部数据（.lxmc）", systemImage: "square.and.arrow.up", kind: .allData)
                    backupButton("列表（.lxmc）", systemImage: "square.and.arrow.up", kind: .playlists)
                    backupButton("设置（.lxmc）", systemImage: "square.and.arrow.up", kind: .settings)
                    Spacer()
                }
                .frame(minHeight: 28)

                HStack(spacing: 8) {
                    Text(Localizer.tr("import"))
                        .font(MeloFont.body)
                        .frame(width: 64, alignment: .leading)
                    importButton("全部数据", kind: .allData)
                    importButton("列表", kind: .playlists)
                    importButton(Localizer.tr("setting"), kind: .settings)
                    Spacer()
                }
                .frame(minHeight: 28)

                if let backupStatusText {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(colors.primary)
                        Text(backupStatusText)
                            .font(MeloFont.secondary)
                            .foregroundStyle(colors.fontSecondary)
                    }
                }

                Divider().overlay(colors.border)

                Text("说明：导出为原版 .lxmc（gzip JSON），可直接与 LX Music Desktop 互通；导入会覆盖对应的当前数据（列表按原版规则合并/覆盖），建议先导出一份备份。设置导入后部分项可能需要重启应用生效。")
                    .font(MeloFont.caption)
                    .foregroundStyle(colors.fontTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func backupButton(_ title: String, systemImage: String, kind: BackupKind) -> some View {
        Button {
            exportBackup(kind)
        } label: {
            Label(title, systemImage: systemImage)
        }
        .buttonStyle(.meloSecondary)
        .help("导出为 \(kind.defaultFileName)")
    }

    private func importButton(_ title: String, kind: BackupKind) -> some View {
        Button {
            beginImportBackup(kind)
        } label: {
            Label("导入\(title)", systemImage: "square.and.arrow.down")
        }
        .buttonStyle(.meloSecondary)
    }

    private var importAlertBinding: Binding<Bool> {
        Binding(
            get: { pendingImport != nil },
            set: { if !$0 { pendingImport = nil } }
        )
    }

    private var importAlertTitle: String {
        pendingImport.map { "导入\(backupKindName($0.kind))备份" } ?? "导入备份"
    }

    private func backupKindName(_ kind: BackupKind) -> String {
        switch kind {
        case .allData: return "全部数据"
        case .playlists: return "列表"
        case .settings: return Localizer.tr("setting")
        }
    }

    private func exportBackup(_ kind: BackupKind) {
        let panel = NSSavePanel()
        panel.title = "导出\(backupKindName(kind))备份"
        panel.prompt = Localizer.tr("export")
        panel.nameFieldStringValue = kind.defaultFileName
        var types: [UTType] = []
        if let lxmc = UTType(filenameExtension: kind.fileExtension) {
            types.append(lxmc)
        }
        types.append(contentsOf: [.json, .data])
        panel.allowedContentTypes = types
        guard panel.runModal() == .OK, let url = panel.url else { return }
        app.exportBackup(kind: kind, to: url)
        backupStatusText = "已导出：\(url.lastPathComponent)"
    }

    private func beginImportBackup(_ kind: BackupKind) {
        let panel = NSOpenPanel()
        panel.title = "导入\(backupKindName(kind))备份"
        panel.message = "选择原版 LX Music 备份文件（.lxmc / .json）"
        panel.prompt = "选择"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        var types: [UTType] = []
        if let lxmc = UTType(filenameExtension: kind.fileExtension) {
            types.append(lxmc)
        }
        types.append(contentsOf: [.json, .data])
        panel.allowedContentTypes = types
        guard panel.runModal() == .OK, let url = panel.url else { return }
        pendingImport = PendingBackupImport(kind: kind, url: url)
    }

    // MARK: 开放 API

    private var openAPICard: some View {
        MeloCard(
            title: Localizer.tr("setting__open_api"),
            subtitle: openAPICardSubtitle,
            systemImage: "network"
        ) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Toggle("启用本地开放 API", isOn: openAPIEnabledBinding)
                        .toggleStyle(.switch)
                        .font(MeloFont.body)
                    Spacer()
                    openAPIStatusRow
                }
                .frame(minHeight: 28)

                HStack(spacing: 10) {
                    Toggle("允许局域网访问", isOn: openAPIBindLanBinding)
                        .toggleStyle(.switch)
                        .font(MeloFont.body)
                    Text(app.openAPIBindLan ? "绑定 0.0.0.0（局域网可访问）" : "绑定 127.0.0.1（仅本机）")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(app.openAPIBindLan ? colors.badgeTertiary : colors.fontTertiary)
                    Spacer()
                }
                .frame(minHeight: 28)

                if app.openAPIBindLan {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(colors.badgeTertiary)
                            .padding(.top, 1)
                        Text("已允许局域网访问：同一网络内的任意设备都可调用该 API（端点无 TLS）；如仅本机使用请关闭。建议同时设置 Token（请求头 Authorization: Bearer <token>）。")
                            .font(MeloFont.caption)
                            .foregroundStyle(colors.fontSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(colors.badgeTertiary.opacity(0.10), in: RoundedRectangle(cornerRadius: MeloMetrics.controlRadius, style: .continuous))
                }

                HStack(spacing: 8) {
                    Text(Localizer.tr("setting__network_proxy_port"))
                        .font(MeloFont.body)
                        .frame(width: 64, alignment: .leading)
                    TextField("23330", text: $portText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(width: 96)
                        .onSubmit { applyOpenAPISettings() }
                    Text("1–65535")
                        .font(MeloFont.caption)
                        .foregroundStyle(colors.fontTertiary)
                    Spacer()
                }
                .frame(minHeight: 28)

                HStack(spacing: 8) {
                    Text("Token")
                        .font(MeloFont.body)
                        .frame(width: 64, alignment: .leading)
                    Group {
                        if maskToken {
                            SecureField("留空 = 不鉴权", text: $tokenText)
                        } else {
                            TextField("留空 = 不鉴权", text: $tokenText)
                        }
                    }
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(width: 240)
                    .onSubmit { applyOpenAPISettings() }

                    Button {
                        maskToken.toggle()
                    } label: {
                        Image(systemName: maskToken ? "eye" : "eye.slash")
                            .font(.system(size: 12))
                            .foregroundStyle(colors.fontSecondary)
                    }
                    .buttonStyle(.plain)
                    .help(maskToken ? "显示 Token" : "隐藏 Token")

                    Button("应用端口 / Token") { applyOpenAPISettings() }
                        .buttonStyle(.meloSecondary)

                    Spacer()
                }
                .frame(minHeight: 28)

                if app.openAPIEnabled && app.openAPIToken.isEmpty {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(colors.badgeTertiary)
                            .padding(.top, 1)
                        Text("Token 为空：本机任意程序都可以调用接口控制播放。建议设置一个随机 Token（请求头 Authorization: Bearer <token>）。")
                            .font(MeloFont.caption)
                            .foregroundStyle(colors.fontSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(colors.badgeTertiary.opacity(0.10), in: RoundedRectangle(cornerRadius: MeloMetrics.controlRadius, style: .continuous))
                }

                Divider().overlay(colors.border)

                HStack {
                    Text("端点示例")
                        .font(MeloFont.secondary)
                        .foregroundStyle(colors.fontTertiary)
                    Spacer()
                    Button {
                        copyToPasteboard(openAPIEndpointsText)
                        app.showToast("已复制 API 端点示例")
                    } label: {
                        Label("复制端点", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.meloSecondary)
                }
                .frame(minHeight: 28)

                Text(openAPIEndpointsText)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(colors.fontSecondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(colors.chipFill, in: RoundedRectangle(cornerRadius: MeloMetrics.controlRadius, style: .continuous))

                Text(app.openAPIBindLan
                     ? "安全提示：当前监听 0.0.0.0（局域网可访问，不对外网开放）；如仅本机使用请关闭「允许局域网访问」，并建议设置 Token。"
                     : "安全提示：服务仅监听 127.0.0.1（不对外网开放）；如需局域网访问请开启「允许局域网访问」并设置 Token。")
                    .font(MeloFont.caption)
                    .foregroundStyle(app.openAPIBindLan ? colors.badgeTertiary : colors.fontTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var openAPICardSubtitle: String {
        app.openAPIBindLan
            ? "本机 HTTP 控制接口，当前允许局域网访问（监听 0.0.0.0）；默认关闭，开启后可用脚本/快捷指令控制播放"
            : "本机 HTTP 控制接口，仅绑定 127.0.0.1；默认关闭，开启后可用脚本/快捷指令控制播放"
    }

    private var openAPIBindLanBinding: Binding<Bool> {
        Binding(
            get: { app.openAPIBindLan },
            set: { newValue in
                app.setOpenAPI(enabled: app.openAPIEnabled,
                               port: app.openAPIPort,
                               token: app.openAPIToken,
                               bindLan: newValue)
            }
        )
    }

    private var openAPIEnabledBinding: Binding<Bool> {
        Binding(
            get: { app.openAPIEnabled },
            set: { app.setOpenAPI(enabled: $0) }
        )
    }

    private var openAPIStatusRow: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(app.openAPIRunning ? colors.primary : (app.openAPIError != nil ? colors.badgeTertiary : colors.fontTertiary))
                .frame(width: 7, height: 7)

            if app.openAPIRunning {
                Text("运行中 · http://\(openAPIHost):\(app.openAPIPort)\(app.openAPIBindLan ? "（局域网）" : "")")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(app.openAPIBindLan ? colors.badgeTertiary : colors.fontSecondary)
                    .textSelection(.enabled)
                Button {
                    copyToPasteboard("http://\(openAPIHost):\(app.openAPIPort)")
                    app.showToast("已复制 API 地址")
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 11))
                        .foregroundStyle(colors.fontSecondary)
                }
                .buttonStyle(.plain)
                .help("复制 API 地址")
            } else if let error = app.openAPIError {
                Text("启动失败：\(error)")
                    .font(MeloFont.secondary)
                    .foregroundStyle(colors.primary)
                    .lineLimit(2)
            } else if app.openAPIEnabled {
                Text("未运行（等待启动）")
                    .font(MeloFont.caption)
                    .foregroundStyle(colors.fontTertiary)
            } else {
                Text("已关闭")
                    .font(MeloFont.caption)
                    .foregroundStyle(colors.fontTertiary)
            }

            Button("重新启动") {
                app.restartOpenAPI()
            }
            .buttonStyle(.meloSecondary)
            .disabled(!app.openAPIEnabled)
            .opacity(app.openAPIEnabled ? 1 : 0.5)
            .help("按当前端口 / Token 重新启动服务")
        }
    }

    private var openAPIHost: String {
        app.openAPIBindLan ? "0.0.0.0" : "127.0.0.1"
    }

    private var openAPIEndpointsText: String {
        let lanNote = app.openAPIBindLan ? "\n局域网访问请把 0.0.0.0 换成本机局域网 IP（如 192.168.x.x）" : ""
        return """
        GET  http://\(openAPIHost):\(app.openAPIPort)/api/status
        GET|POST /api/command/play
        GET|POST /api/command/pause
        GET|POST /api/command/toggle
        GET|POST /api/command/next
        GET|POST /api/command/previous
        GET|POST /api/command/seek?position=<秒> | ?percent=<0-100>
        GET|POST /api/command/volume?volume=<0-1>
        GET|POST /api/command/collect
        GET|POST /api/command/uncollect
        鉴权：Authorization: Bearer <token>（Token 为空时不校验）\(lanNote)
        """
    }

    private func applyOpenAPISettings() {
        let trimmed = portText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let port = Int(trimmed), (1...65535).contains(port) else {
            app.showToast("端口需为 1–65535 的数字")
            portText = String(app.openAPIPort)
            return
        }
        app.setOpenAPI(enabled: app.openAPIEnabled, port: port, token: tokenText)
    }

    private func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    // MARK: 自定义源

    private var sourcesCard: some View {
        MeloCard(
            title: Localizer.tr("setting__basic_source"),
            subtitle: "复用原版 LX 自定义源脚本（不内置、不重写）；导入后按原版 user_api.json 格式保存",
            systemImage: "puzzlepiece.extension"
        ) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    statusBadge
                    Spacer()
                    Button {
                        app.reloadSources()
                        app.showToast("已刷新自定义源列表")
                    } label: {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.meloSecondary)

                    Button {
                        importingSource = true
                    } label: {
                        Label("导入源文件…", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.meloPrimary)

                    Button {
                        showURLImport = true
                    } label: {
                        Label("从链接导入…", systemImage: "link")
                    }
                    .buttonStyle(.meloSecondary)
                    .help("从 http(s) 链接在线导入自定义源脚本")

                    Button {
                        app.route = .test
                    } label: {
                        Label("测试面板", systemImage: "testtube.2")
                    }
                    .buttonStyle(.meloSecondary)
                }

                if let sourceImportError {
                    Text("导入失败：\(sourceImportError)")
                        .font(MeloFont.secondary)
                        .foregroundStyle(colors.primary)
                }

                if app.sources.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 13))
                            .foregroundStyle(colors.fontTertiary)
                        Text("尚未导入自定义源。可点击「导入源文件…」选择本地 .js 脚本，或点击「从链接导入…」从 http(s) 链接在线导入（如原版 community 源）。")
                            .font(MeloFont.secondary)
                            .foregroundStyle(colors.fontSecondary)
                    }
                    .frame(minHeight: 28)
                } else {
                    VStack(spacing: 0) {
                        ForEach(app.sources) { source in
                            sourceRow(source)
                            if source.id != app.sources.last?.id {
                                Divider().overlay(colors.border)
                            }
                        }
                    }
                    .background(
                        colors.chipFill,
                        in: RoundedRectangle(cornerRadius: MeloMetrics.controlRadius, style: .continuous)
                    )
                }

                if !app.activeCapabilities.isEmpty {
                    HStack(alignment: .top, spacing: 8) {
                        Text("能力")
                            .font(MeloFont.caption)
                            .foregroundStyle(colors.fontTertiary)
                            .padding(.top, 2)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(app.activeCapabilities, id: \.source) { cap in
                                    capabilityChip(cap)
                                }
                            }
                        }
                    }
                }

                if !app.sourceLogs.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("源日志")
                                .font(MeloFont.caption)
                                .foregroundStyle(colors.fontTertiary)
                            Spacer()
                            Text("最新 \(min(app.sourceLogs.count, 120)) 条")
                                .font(MeloFont.microCaption)
                                .foregroundStyle(colors.fontTertiary)
                        }
                        ScrollView {
                            Text(app.sourceLogs.suffix(120).joined(separator: "\n"))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(colors.fontSecondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                        }
                        .frame(height: 110)
                        .background(
                            colors.chipFill,
                            in: RoundedRectangle(cornerRadius: MeloMetrics.controlRadius, style: .continuous)
                        )
                    }
                }
            }
        }
    }

    private var statusBadge: some View {
        let (text, color): (String, Color) = {
            switch app.sourceStatus {
            case .idle:
                return ("未加载", colors.fontTertiary)
            case .loading:
                return ("源加载中…", colors.badgeTertiary)
            case .ready(let caps):
                return ("已就绪 · \(caps.count) 个能力", colors.badgePrimary)
            case .error(let message):
                return ("源错误：\(message)", .red)
            }
        }()
        return HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text)
                .font(MeloFont.controlLabel)
                .foregroundStyle(colors.fontSecondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(color.opacity(0.10), in: Capsule())
    }

    private func sourceRow(_ source: UserSourceInfo) -> some View {
        HStack(spacing: 10) {
            Image(systemName: source.id == app.activeSourceId ? "checkmark.seal.fill" : "doc.text")
                .font(.system(size: 15))
                .foregroundStyle(source.id == app.activeSourceId ? colors.primary : colors.fontTertiary)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(source.name)
                        .font(MeloFont.cardTitle)
                        .foregroundStyle(colors.font)
                    if let version = source.version, !version.isEmpty {
                        MeloBadge("v\(version)", color: colors.badgeSecondary)
                    }
                    if let author = source.author, !author.isEmpty {
                        Text(author)
                            .font(MeloFont.caption)
                            .foregroundStyle(colors.fontTertiary)
                    }
                }
                Text(source.description?.isEmpty == false ? (source.description ?? "") : source.id)
                    .font(MeloFont.secondary)
                    .foregroundStyle(colors.fontSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if source.id == app.activeSourceId {
                Text("使用中")
                    .font(MeloFont.controlLabel)
                    .foregroundStyle(colors.primary)
            } else {
                Button("激活") {
                    Task { await app.activateSource(id: source.id) }
                }
                .buttonStyle(.meloSecondary)
                .disabled(app.isSwitchingSource)
                .opacity(app.isSwitchingSource ? 0.5 : 1)
            }

            MeloIconButton(systemName: "trash", help: "删除源") {
                pendingDeleteSource = source
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 40)
    }

    private func capabilityChip(_ cap: SourceCapability) -> some View {
        HStack(spacing: 5) {
            Text(cap.source)
                .font(MeloFont.controlLabel)
                .foregroundStyle(colors.badgePrimary)
            Text(cap.qualitys.joined(separator: " / "))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(colors.fontSecondary)
            Text(cap.actions.joined(separator: ","))
                .font(MeloFont.microCaption)
                .foregroundStyle(colors.fontTertiary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(colors.badgePrimary.opacity(0.10), in: Capsule())
    }

    // MARK: 数据

    private var dataCard: some View {
        MeloCard(title: "数据与缓存", subtitle: "数据目录沿用原版路径，可直接读取已有 lx.data.db / config_v2.json / user_api.json", systemImage: "internaldrive") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "folder")
                        .font(.system(size: 12))
                        .foregroundStyle(colors.fontTertiary)
                    Text(app.data.dataDirectory.path)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(colors.fontSecondary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                }

                HStack(spacing: 8) {
                    Button {
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: app.data.dataDirectory.path)
                    } label: {
                        Label("在 Finder 中打开", systemImage: "finder")
                    }
                    .buttonStyle(.meloSecondary)

                    Button {
                        app.refreshLibrary()
                        app.showToast("已重新加载曲库")
                    } label: {
                        Label("重新加载曲库", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.meloSecondary)

                    Spacer()
                }
                .frame(minHeight: 28)

                if let libraryError = app.libraryError {
                    Text("曲库错误：\(libraryError)")
                        .font(MeloFont.secondary)
                        .foregroundStyle(colors.primary)
                }

                Divider().overlay(colors.border)

                cacheManagementBlock
            }
        }
    }

    // MARK: 缓存管理

    private var cacheManagementBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "archivebox")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(colors.primary)
                Text("缓存管理")
                    .font(MeloFont.cardTitle)
                    .foregroundStyle(colors.font)
                Spacer()
                Text("总占用：\(formattedTotalCacheSize)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(colors.fontSecondary)
                Button {
                    app.refreshCacheInfo()
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.meloSecondary)
            }
            .frame(minHeight: 28)

            if app.cacheCategories.isEmpty || app.totalCacheSize == 0 {
                HStack(spacing: 8) {
                    Image(systemName: "tray")
                        .font(.system(size: 12))
                        .foregroundStyle(colors.fontTertiary)
                    Text("暂无缓存文件（本地封面 / 音效渲染 / 下载临时目录均无缓存）")
                        .font(MeloFont.secondary)
                        .foregroundStyle(colors.fontTertiary)
                    Spacer()
                }
                .frame(minHeight: 28)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(app.cacheCategories.enumerated()), id: \.element.id) { index, category in
                        cacheCategoryRow(category)
                        if index < app.cacheCategories.count - 1 {
                            Divider().overlay(colors.border)
                        }
                    }
                }
                .background(
                    colors.chipFill,
                    in: RoundedRectangle(cornerRadius: MeloMetrics.controlRadius, style: .continuous)
                )
            }

            HStack(spacing: 8) {
                Spacer()
                Button {
                    pendingCacheClear = .all
                } label: {
                    Label("清理全部缓存", systemImage: "trash")
                        .foregroundStyle(colors.primary)
                }
                .buttonStyle(.meloSecondary)
                .disabled(app.cacheCategories.allSatisfy { $0.sizeBytes == 0 || $0.fileCount == 0 })
                .opacity(app.cacheCategories.allSatisfy { $0.sizeBytes == 0 || $0.fileCount == 0 } ? 0.5 : 1)
                .help("依次清理全部分类的缓存文件")
            }

            Text("说明：清理「本地音乐封面」后下次显示会重新从音频中提取；清理「音效/混响渲染缓存」后下次启用音效会重新处理；下载临时目录仅清理未完成的临时文件。不会影响歌单、歌曲、设置、自定义源等核心数据。")
                .font(MeloFont.caption)
                .foregroundStyle(colors.fontTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .alert("清理缓存", isPresented: cacheAlertBinding, presenting: pendingCacheClear) { item in
            Button(Localizer.tr("btn_cancel"), role: .cancel) { pendingCacheClear = nil }
            Button("清理", role: .destructive) {
                performCacheClear(item)
            }
        } message: { item in
            switch item {
            case .category(let category):
                Text("将清理「\(category.name)」共 \(category.fileCount) 个文件（\(category.displaySize)）。\(cacheClearHint(for: category.id))")
            case .all:
                Text("将清理全部 \(app.cacheCategories.count) 个缓存类别，共 \(formattedTotalCacheSize)。\(cacheClearHint(for: "all"))")
            }
        }
    }

    private var cacheAlertBinding: Binding<Bool> {
        Binding(
            get: { pendingCacheClear != nil },
            set: { if !$0 { pendingCacheClear = nil } }
        )
    }

    private var formattedTotalCacheSize: String {
        ByteCountFormatter.string(fromByteCount: app.totalCacheSize, countStyle: .file)
    }

    private func cacheCategoryRow(_ category: CacheCategoryInfo) -> some View {
        HStack(spacing: 10) {
            Image(systemName: cacheIcon(for: category.id))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(colors.fontSecondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(category.name)
                    .font(MeloFont.body)
                    .foregroundStyle(colors.font)
                Text("\(category.fileCount) 个文件")
                    .font(MeloFont.caption)
                    .foregroundStyle(colors.fontTertiary)
            }
            Spacer()
            Text(category.displaySize)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(colors.fontSecondary)
            Button("清理") {
                pendingCacheClear = .category(category)
            }
            .buttonStyle(.meloSecondary)
            .disabled(category.fileCount == 0 || category.sizeBytes == 0)
            .opacity(category.fileCount == 0 || category.sizeBytes == 0 ? 0.5 : 1)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 32)
    }

    private func cacheIcon(for categoryID: String) -> String {
        switch categoryID {
        case "covers": return "photo.on.rectangle"
        case "effectAudio": return "waveform"
        case "downloadTemp": return "arrow.down.circle"
        default: return "archivebox"
        }
    }

    private func cacheClearHint(for categoryID: String) -> String {
        switch categoryID {
        case "covers": return "清理后本地音乐封面会在下次显示时重新提取。"
        case "effectAudio": return "清理后下次启用音效/混响会重新渲染处理。"
        case "downloadTemp": return "仅清理未完成的下载临时文件，不影响已完成下载。"
        case "all": return "核心数据（歌单/设置/自定义源/主题/快捷键）不会被清理。"
        default: return ""
        }
    }

    private func performCacheClear(_ action: CachePendingAction) {
        switch action {
        case .category(let category):
            _ = app.clearCache(categoryID: category.id)
        case .all:
            for category in app.cacheCategories where category.fileCount > 0 && category.sizeBytes > 0 {
                _ = app.clearCache(categoryID: category.id)
            }
        }
        pendingCacheClear = nil
    }

    // MARK: 网络代理

    private var proxyCard: some View {
        MeloCard(
            title: "网络代理",
            subtitle: "仅 App 内 HTTP(S) 网络请求（自定义源脚本 / 内置元数据接口）走代理；AVPlayer 媒体流不受代理影响",
            systemImage: "network"
        ) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Toggle("启用 HTTP(S) 代理", isOn: $proxyEnabled)
                        .toggleStyle(.switch)
                        .font(MeloFont.body)
                    Spacer()
                    if app.proxySettings.isValid {
                        HStack(spacing: 5) {
                            Circle().fill(colors.primary).frame(width: 7, height: 7)
                            Text("当前生效：\(app.proxySettings.host):\(app.proxySettings.port)")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(colors.primary)
                        }
                    } else {
                        Text(proxyEnabled ? "配置不完整" : "未启用")
                            .font(MeloFont.caption)
                            .foregroundStyle(proxyEnabled ? colors.badgeTertiary : colors.fontTertiary)
                    }
                }
                .frame(minHeight: 28)

                HStack(spacing: 10) {
                    Text(Localizer.tr("setting__network_proxy_host"))
                        .font(MeloFont.body)
                        .frame(width: 64, alignment: .leading)
                    TextField("127.0.0.1 或 proxy.example.com", text: $proxyHost)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(width: 240)
                    Text(Localizer.tr("setting__network_proxy_port"))
                        .font(MeloFont.body)
                        .frame(width: 40, alignment: .leading)
                    TextField("7890", text: $proxyPortText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(width: 80)
                    Text("1–65535")
                        .font(MeloFont.caption)
                        .foregroundStyle(colors.fontTertiary)
                    Spacer()
                }
                .frame(minHeight: 28)

                HStack(spacing: 10) {
                    Text(Localizer.tr("setting__network_proxy_username"))
                        .font(MeloFont.body)
                        .frame(width: 64, alignment: .leading)
                    TextField("可选", text: $proxyUsername)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(width: 200)
                    Text(Localizer.tr("setting__network_proxy_password"))
                        .font(MeloFont.body)
                        .frame(width: 40, alignment: .leading)
                    Group {
                        if showProxyPassword {
                            TextField("可选", text: $proxyPassword)
                        } else {
                            SecureField("可选", text: $proxyPassword)
                        }
                    }
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(width: 200)
                    Button {
                        showProxyPassword.toggle()
                    } label: {
                        Image(systemName: showProxyPassword ? "eye.slash" : "eye")
                            .font(.system(size: 12))
                            .foregroundStyle(colors.fontSecondary)
                    }
                    .buttonStyle(.plain)
                    .help(showProxyPassword ? "隐藏密码" : "显示密码")
                    Spacer()
                }
                .frame(minHeight: 28)

                HStack(spacing: 8) {
                    Spacer()
                    Button("应用代理设置") {
                        applyProxySettings()
                    }
                    .buttonStyle(.meloPrimary)
                }

                Text("说明：代理只作用于 App 内发起的 HTTP(S) 请求（自定义源脚本的取链/搜索、内置元数据接口、歌词等）；音频播放由 AVPlayer 直连媒体地址，不经过此代理。修改后需点击「应用代理设置」生效。")
                    .font(MeloFont.caption)
                    .foregroundStyle(colors.fontTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func applyProxySettings() {
        let host = proxyHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let port = Int(proxyPortText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        if proxyEnabled {
            guard !host.isEmpty else {
                app.showToast("代理主机不能为空")
                return
            }
            guard (1...65535).contains(port) else {
                app.showToast("代理端口需为 1–65535 的数字")
                proxyPortText = String(app.proxySettings.port)
                return
            }
        }
        app.setProxy(enabled: proxyEnabled,
                     host: host,
                     port: port,
                     username: proxyUsername,
                     password: proxyPassword)
    }

    // MARK: 不喜欢规则 / 开机自启

    private var miscCard: some View {
        MeloCard(
            title: "不喜欢与系统",
            subtitle: "不喜欢规则会在播放时自动跳过匹配歌曲；开机自启需要 App 位于「应用程序」文件夹",
            systemImage: "hand.raised.slash"
        ) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Text("不喜欢规则")
                        .font(MeloFont.body)
                        .frame(width: 84, alignment: .leading)
                    Text("已保存 \(app.dislikeRules.count) 条规则")
                        .font(MeloFont.body)
                        .foregroundStyle(app.dislikeRules.isEmpty ? colors.fontTertiary : colors.font)
                    Button("编辑规则…") {
                        showDislikeRulesSheet = true
                    }
                    .buttonStyle(.meloSecondary)
                    Spacer()
                }
                .frame(minHeight: 28)

                HStack(alignment: .top, spacing: 10) {
                    Text("")
                        .frame(width: 84, alignment: .leading)
                    Text("支持「歌曲名@艺术家 / 歌曲名 / @艺术家」，歌曲右键「不喜欢这首歌曲」会自动追加规则；播放时自动跳过的逻辑由 AppModel 处理。")
                        .font(MeloFont.caption)
                        .foregroundStyle(colors.fontTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }

                Divider().overlay(colors.border)

                HStack(spacing: 10) {
                    Text("开机自启")
                        .font(MeloFont.body)
                        .frame(width: 84, alignment: .leading)
                    Toggle("开机时自动启动 Melo", isOn: Binding(
                        get: { app.openAtLogin },
                        set: { app.setOpenAtLogin($0) }
                    ))
                    .toggleStyle(.switch)
                    .font(MeloFont.body)
                    Text("通过系统登录项注册；需将 Melo 放入「应用程序」文件夹，ad-hoc 签名可能无法注册成功。")
                        .font(MeloFont.caption)
                        .foregroundStyle(colors.fontTertiary)
                    Spacer()
                }
                .frame(minHeight: 28)
            }
        }
    }

    // MARK: 关于

    private var aboutCard: some View {
        MeloCard(title: "关于 Melo", subtitle: "LX Music Desktop 的 macOS 原生移植", systemImage: "info.circle") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: MeloMetrics.controlRadius, style: .continuous)
                            .fill(LinearGradient(
                                colors: [colors.primary, colors.primary.opacity(0.7)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ))
                        Text("M")
                            .font(.system(size: 18, weight: .heavy, design: .rounded))
                            .foregroundStyle(.white)
                    }
                    .frame(width: 40, height: 40)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Melo for macOS")
                            .font(MeloFont.cardTitle)
                        Text("版本 \(appVersion) · 原生 SwiftUI（无 Electron / 无第三方依赖）")
                            .font(MeloFont.secondary)
                            .foregroundStyle(colors.fontSecondary)
                    }
                    Spacer()
                }

                Text("本项目是开源项目 LX Music Desktop（Apache-2.0）的 macOS 原生重写版本，复用其数据格式、主题、语言包与自定义源脚本生态。自定义源脚本由各自作者提供，本项目不内置任何第三方音源。")
                    .font(MeloFont.secondary)
                    .foregroundStyle(colors.fontSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    Button {
                        if let url = URL(string: "https://github.com/lyswhut/lx-music-desktop") {
                            NSWorkspace.shared.open(url)
                        }
                    } label: {
                        Label("原项目 LX Music Desktop", systemImage: "link")
                    }
                    .buttonStyle(.meloSecondary)

                    Button {
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: app.data.dataDirectory.path)
                    } label: {
                        Label("数据目录", systemImage: "folder")
                    }
                    .buttonStyle(.meloSecondary)

                    Spacer()
                }
                .frame(minHeight: 28)
            }
        }
    }

    private var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.1.0"
    }

    // MARK: 绑定

    private var autoThemeBinding: Binding<Bool> {
        Binding(
            get: { app.theme.isAutoMode },
            set: { enabled in
                if enabled {
                    let light = app.settings.string(SettingKeys.lightThemeId) ?? "green"
                    let dark = app.settings.string(SettingKeys.darkThemeId) ?? "black"
                    app.theme.setAutoTheme(lightId: light, darkId: dark)
                } else {
                    app.setTheme(id: app.theme.current.id)
                }
            }
        )
    }

    private var languageBinding: Binding<String> {
        Binding(
            get: { app.localizer.languageID },
            set: { app.setLanguage(id: $0) }
        )
    }

    private func boolBinding(_ key: String, default def: Bool) -> Binding<Bool> {
        Binding(
            get: { app.settings.bool(key, default: def) },
            set: { app.settings.set(key, .bool($0)) }
        )
    }

    private func intBinding(_ key: String, default def: Int) -> Binding<Int> {
        Binding(
            get: { app.settings.int(key, default: def) },
            set: { app.settings.set(key, .int(Int64($0))) }
        )
    }

    private func stringBinding(_ key: String, default def: String) -> Binding<String> {
        Binding(
            get: { app.settings.string(key) ?? def },
            set: { app.settings.set(key, .string($0)) }
        )
    }

    private func qualityLabel(_ quality: String) -> String {
        switch quality {
        case "128k": return "128K"
        case "320k": return "320K"
        case "flac": return "无损 FLAC"
        case "flac24bit": return "无损 24BIT"
        default: return quality.uppercased()
        }
    }
}
