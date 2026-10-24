import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MeloCore

// MARK: - 播放详情（覆盖主窗口的沉浸式面板）

struct PlayDetailView: View {
    let app: AppModel

    @Environment(\.meloColors) private var colors
    @State private var scrubTime: Double?
    @State private var backgroundImage: NSImage?

    /// 仅用于预览/自测：默认展开评论面板 / 注入评论预览数据
    private let previewShowComments: Bool
    private let previewCommentsState: CommentsPreviewState?

    init(app: AppModel,
         previewShowComments: Bool = false,
         previewCommentsState: CommentsPreviewState? = nil) {
        self.app = app
        self.previewShowComments = previewShowComments
        self.previewCommentsState = previewCommentsState
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                background
                VStack(spacing: 0) {
                    topBar
                    HStack(alignment: .top, spacing: 44) {
                        leftPanel(size: min(400, max(200, geo.size.height * 0.46)))
                        VStack(alignment: .leading, spacing: 10) {
                            lyricPanel
                            CommentsPanel(app: app,
                                          previewExpanded: previewShowComments,
                                          previewState: previewCommentsState)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                    .padding(.horizontal, 40)
                    .padding(.top, 10)
                    Spacer(minLength: 12)
                    bottomControls
                        .padding(.horizontal, 44)
                        .padding(.bottom, 26)
                }
            }
        }
        // 沉浸式深色面板：底图来自正在播放的封面
        .background(Color.black)
        // 播放详情恒为深色，子视图（评论、音质徽标等）按暗色令牌取色
        .environment(\.meloColors, AppColors.appleMusic(isDark: true))
        .onExitCommand { app.closePlayDetail() }
        .task(id: app.currentMusic?.picUrl) { loadBackgroundImage() }
    }

    // MARK: 背景

    private var background: some View {
        ArtworkBackdrop(image: backgroundImage, blurRadius: 70, dimOpacity: 0.5)
    }

    private func loadBackgroundImage() {
        guard let urlString = app.currentMusic?.picUrl, !urlString.isEmpty else {
            backgroundImage = nil
            return
        }
        if MeloUtils.isHTTPURL(urlString) {
            backgroundImage = nil
            guard let url = URL(string: urlString) else { return }
            Task {
                if let data = try? await URLSession.shared.data(from: url).0,
                   let image = NSImage(data: data) {
                    backgroundImage = image
                }
            }
        } else {
            let path = urlString.hasPrefix("file://") ? (URL(string: urlString)?.path ?? urlString) : urlString
            backgroundImage = NSImage(contentsOfFile: path)
        }
    }

    // MARK: 顶栏

    private var topBar: some View {
        HStack(spacing: 10) {
            Button {
                app.closePlayDetail()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 30, height: 30)
                    .background(.white.opacity(0.12), in: Circle())
            }
            .buttonStyle(.plain)
            .help("收起播放详情（Esc）")

            Text("正在播放")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))

            Spacer()

            if let music = app.currentMusic {
                QualityBadges(music: music)
                    .opacity(0.9)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 18)
    }

    // MARK: 左侧信息

    private func leftPanel(size: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            CoverImage(urlString: app.currentMusic?.picUrl, size: size, cornerRadius: MeloMetrics.heroCoverRadius)
                .meloCoverShadow(intensity: 2.4)

            if app.isAudioVisualizationEnabled {
                VStack(alignment: .leading, spacing: 4) {
                    Text("音频可视化")
                        .font(MeloFont.microCaption)
                        .foregroundStyle(.white.opacity(0.35))
                    PlayDetailSpectrumView(app: app)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(app.currentMusic?.name ?? "未在播放")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                Text(app.currentMusic?.singer ?? "—")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(1)
                if let album = app.currentMusic?.albumName, !album.isEmpty {
                    Text(album)
                        .font(MeloFont.secondary)
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(1)
                }
            }

            HStack(spacing: 14) {
                if let music = app.currentMusic {
                    Button {
                        app.toggleFavorite(music)
                    } label: {
                        Image(systemName: app.isFavorite(music) ? "heart.fill" : "heart")
                            .font(.system(size: 16, weight: .regular))
                            .foregroundStyle(app.isFavorite(music) ? .white : .white.opacity(0.65))
                            .frame(width: 34, height: 34)
                            .background(.white.opacity(0.14), in: Circle())
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help(app.isFavorite(music) ? "取消收藏" : "收藏到「我的收藏」")
                }
                if app.isResolvingMusic {
                    ProgressView().controlSize(.small)
                    Text("正在获取播放地址…")
                        .font(MeloFont.caption)
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
        }
        .frame(width: size, alignment: .leading)
    }

    // MARK: 歌词

    private var lyricPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("歌词")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.75))
                if app.isLoadingLyric {
                    ProgressView().controlSize(.mini)
                }
                Spacer()
                if !app.lyricDocument.lines.isEmpty {
                    Text("点击歌词可跳转播放进度 · 右键可调整歌词")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.white.opacity(0.4))
                }
                Menu {
                    lyricSettingsMenuItems
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("歌词设置")
            }
            .padding(.top, 4)

            if app.lyricDocument.lines.isEmpty {
                VStack(spacing: 10) {
                    Spacer(minLength: 40)
                    Image(systemName: "text.alignleft")
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(.white.opacity(0.35))
                    Text(app.isLoadingLyric ? "正在加载歌词…" : "暂无歌词")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.55))
                    Text("歌词来源：原版数据库缓存 / 自定义源 lyric 能力")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.35))
                    Spacer(minLength: 40)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                lyricsScroll
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .contextMenu { lyricContextMenuItems }
    }

    private var lyricsScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: lyricStackAlignment, spacing: 14) {
                    ForEach(Array(app.lyricDocument.lines.enumerated()), id: \.offset) { index, line in
                        lyricLine(line, index: index)
                            .id(index)
                    }
                }
                .frame(maxWidth: .infinity, alignment: lyricFrameAlignment)
                .padding(.vertical, 90)
                .padding(.trailing, 12)
            }
            .onAppear {
                if let index = app.currentLyricIndex {
                    proxy.scrollTo(index, anchor: .center)
                }
            }
            .onChange(of: app.currentLyricIndex) { _, newValue in
                guard let index = newValue else { return }
                withAnimation(.easeInOut(duration: 0.35)) {
                    proxy.scrollTo(index, anchor: .center)
                }
            }
        }
    }

    private func lyricLine(_ line: LyricLine, index: Int) -> some View {
        let isCurrent = index == app.currentLyricIndex
        let text = LyricDisplaySupport.displayText(line.text, convertS2T: app.convertLyricS2T)
        let extended = LyricDisplaySupport.displayExtended(
            LyricDisplaySupport.extendedLines(
                for: line,
                lyric: app.lyric,
                showTranslation: app.showLyricTranslation,
                showRoma: app.showLyricRoma,
                swapTranslationAndRoma: app.swapLyricTranslationAndRoma
            ),
            convertS2T: app.convertLyricS2T
        )
        let currentSize = lyricBaseFont
        let lineSize = currentSize * (isCurrent ? 1.0 : 0.84)
        return Button {
            app.seek(to: line.time)
        } label: {
            VStack(alignment: lyricStackAlignment, spacing: 3) {
                Group {
                    if isCurrent, app.playWordByWordLyric, !line.words.isEmpty {
                        KaraokeLyricLine(
                            line: line,
                            currentTime: app.currentTime,
                            isPlaying: app.isPlaying,
                            fontSize: currentSize,
                            fontWeight: .bold,
                            playedColor: .white,
                            unplayedColor: .white.opacity(0.32),
                            alignment: lyricStackAlignment
                        )
                        .frame(maxWidth: .infinity, alignment: lyricFrameAlignment)
                    } else {
                        Text(text)
                            .font(.system(size: lineSize, weight: isCurrent ? .bold : .regular))
                            .foregroundStyle(isCurrent ? Color.white : .white.opacity(0.32))
                            .multilineTextAlignment(lyricTextAlignment)
                            .frame(maxWidth: .infinity, alignment: lyricFrameAlignment)
                    }
                }
                ForEach(Array(extended.enumerated()), id: \.offset) { _, item in
                    Text(item)
                        .font(.system(size: currentSize * (isCurrent ? 0.7 : 0.61)))
                        .foregroundStyle(isCurrent ? .white.opacity(0.8) : .white.opacity(0.35))
                        .multilineTextAlignment(lyricTextAlignment)
                        .frame(maxWidth: .infinity, alignment: lyricFrameAlignment)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(nil, value: isCurrent)
    }

    // MARK: 歌词样式 / 菜单

    private var lyricBaseFont: CGFloat {
        CGFloat(min(max(app.settings.double(SettingKeys.playDetailFontSize, default: 140), 70), 200)) / 8
    }

    private var lyricAlignRaw: String {
        app.settings.string(SettingKeys.playDetailAlign) ?? "left"
    }

    private var lyricStackAlignment: HorizontalAlignment {
        switch lyricAlignRaw {
        case "center": return .center
        case "right": return .trailing
        default: return .leading
        }
    }

    private var lyricTextAlignment: TextAlignment {
        switch lyricAlignRaw {
        case "center": return .center
        case "right": return .trailing
        default: return .leading
        }
    }

    private var lyricFrameAlignment: Alignment {
        switch lyricAlignRaw {
        case "center": return .center
        case "right": return .trailing
        default: return .leading
        }
    }

    private func setPlayDetailFontSize(_ value: Double) {
        app.settings.set(SettingKeys.playDetailFontSize, .double(min(max(value, 70), 200)))
    }

    private func setPlayDetailAlign(_ value: String) {
        guard ["left", "center", "right"].contains(value) else { return }
        app.settings.set(SettingKeys.playDetailAlign, .string(value))
    }

    private func lyricToggleBinding(_ key: String) -> Binding<Bool> {
        Binding(
            get: { app.settings.bool(key) },
            set: { app.setLyricDisplayOption(key, enabled: $0) }
        )
    }

    @ViewBuilder
    private var lyricSettingsMenuItems: some View {
        Toggle("显示翻译", isOn: lyricToggleBinding(SettingKeys.showLyricTranslation))
        Toggle("显示罗马音", isOn: lyricToggleBinding(SettingKeys.showLyricRoma))
        Toggle(Localizer.tr("setting__desktop_lyric_font_weight_font"), isOn: lyricToggleBinding(SettingKeys.playWordByWordLyric))
        Toggle("繁简转换", isOn: lyricToggleBinding(SettingKeys.convertLyricS2T))
        Divider()
        Button("关联本地歌词文件…") { pickLocalLyricFile() }
        Button("取消本地歌词关联") { app.removeLocalLyricAssociation() }
        Text("关联后优先于在线歌词（存原版 lyric 表 edited），可随时取消恢复在线")
        Divider()
        Menu("歌词偏移（当前 \(lyricOffsetText)）") {
            Button("+100ms") { app.adjustLyricOffset(by: 100) }
            Button("+10ms") { app.adjustLyricOffset(by: 10) }
            Button("-10ms") { app.adjustLyricOffset(by: -10) }
            Button("-100ms") { app.adjustLyricOffset(by: -100) }
            Divider()
            Button("重置偏移") { app.resetLyricOffset() }
        }
        Menu("歌词字号（\(Int(lyricBaseFont * 8))）") {
            Button("增大 +5") { setPlayDetailFontSize(app.settings.double(SettingKeys.playDetailFontSize, default: 140) + 5) }
            Button("减小 -5") { setPlayDetailFontSize(app.settings.double(SettingKeys.playDetailFontSize, default: 140) - 5) }
            Divider()
            Button("重置（140）") { setPlayDetailFontSize(140) }
        }
        Menu("歌词对齐") {
            Button { setPlayDetailAlign("left") } label: {
                if lyricAlignRaw == "left" {
                    Label("左对齐", systemImage: "checkmark")
                } else {
                    Text("左对齐")
                }
            }
            Button { setPlayDetailAlign("center") } label: {
                if lyricAlignRaw == "center" {
                    Label(Localizer.tr("lyric_menu__align_center"), systemImage: "checkmark")
                } else {
                    Text(Localizer.tr("lyric_menu__align_center"))
                }
            }
            Button { setPlayDetailAlign("right") } label: {
                if lyricAlignRaw == "right" {
                    Label("右对齐", systemImage: "checkmark")
                } else {
                    Text("右对齐")
                }
            }
        }
    }

    @ViewBuilder
    private var lyricContextMenuItems: some View {
        Text("歌词偏移：\(lyricOffsetText)")
        Button("偏移 +100ms") { app.adjustLyricOffset(by: 100) }
        Button("偏移 +10ms") { app.adjustLyricOffset(by: 10) }
        Button("偏移 -10ms") { app.adjustLyricOffset(by: -10) }
        Button("偏移 -100ms") { app.adjustLyricOffset(by: -100) }
        Button("重置偏移") { app.resetLyricOffset() }
            .disabled(app.lyricOffsetMs == 0)
        Divider()
        Text("字号：\(Int(app.settings.double(SettingKeys.playDetailFontSize, default: 140)))")
        Button("字号 +5") { setPlayDetailFontSize(app.settings.double(SettingKeys.playDetailFontSize, default: 140) + 5) }
        Button("字号 -5") { setPlayDetailFontSize(app.settings.double(SettingKeys.playDetailFontSize, default: 140) - 5) }
        Button("字号重置（140）") { setPlayDetailFontSize(140) }
        Divider()
        ForEach([("left", "左对齐"), ("center", Localizer.tr("lyric_menu__align_center")), ("right", "右对齐")], id: \.0) { item in
            Button {
                setPlayDetailAlign(item.0)
            } label: {
                if lyricAlignRaw == item.0 {
                    Label(item.1, systemImage: "checkmark")
                } else {
                    Text(item.1)
                }
            }
        }
        Divider()
        Toggle("显示翻译", isOn: lyricToggleBinding(SettingKeys.showLyricTranslation))
        Toggle("显示罗马音", isOn: lyricToggleBinding(SettingKeys.showLyricRoma))
        Toggle(Localizer.tr("setting__desktop_lyric_font_weight_font"), isOn: lyricToggleBinding(SettingKeys.playWordByWordLyric))
        Toggle("繁简转换", isOn: lyricToggleBinding(SettingKeys.convertLyricS2T))
        Divider()
        Button("关联本地歌词文件…") { pickLocalLyricFile() }
        Button("取消本地歌词关联") { app.removeLocalLyricAssociation() }
        Text("关联后优先于在线歌词（存原版 lyric 表 edited），可随时取消恢复在线")
        Divider()
        Button("复制当前歌词") {
            guard let index = app.currentLyricIndex,
                  app.lyricDocument.lines.indices.contains(index) else { return }
            let text = app.lyricDocument.lines[index].text
            guard !text.isEmpty else { return }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            app.showToast("已复制当前歌词")
        }
        .disabled(app.currentLyricIndex == nil)
    }

    private func pickLocalLyricFile() {
        let panel = NSOpenPanel()
        panel.title = "关联本地歌词文件"
        panel.message = "选择 .lrc / .txt 歌词文件；关联后优先于在线歌词（保存到原版 lyric 表 edited），可随时取消"
        panel.prompt = "关联"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        var types: [UTType] = [.plainText]
        if let lrc = UTType(filenameExtension: "lrc") { types.insert(lrc, at: 0) }
        panel.allowedContentTypes = types
        guard panel.runModal() == .OK, let url = panel.url else { return }
        _ = app.associateLocalLyricFile(url)
    }

    private var lyricOffsetText: String {
        let value = app.lyricOffsetMs
        return value == 0 ? "0 ms" : String(format: "%+d ms", value)
    }

    // MARK: 底部控制

    private var bottomControls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Text(MeloUtils.formatTime(scrubTime ?? app.currentTime))
                    .font(MeloFont.timecode)
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(width: 44, alignment: .trailing)

                Slider(
                    value: Binding(
                        get: { scrubTime ?? app.currentTime },
                        set: { scrubTime = $0 }
                    ),
                    in: 0...max(app.duration, 1),
                    onEditingChanged: { editing in
                        if !editing {
                            if let time = scrubTime { app.seek(to: time) }
                            scrubTime = nil
                        }
                    }
                )
                .controlSize(.mini)
                .tint(.white)
                .disabled(app.duration <= 0)

                Text(MeloUtils.formatTime(app.duration))
                    .font(MeloFont.timecode)
                    .foregroundStyle(.white.opacity(0.45))
                    .frame(width: 44, alignment: .leading)
            }

            HStack(spacing: 34) {
                Button {
                    app.previous()
                } label: {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(app.playQueue.isEmpty ? .white.opacity(0.35) : .white)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(app.playQueue.isEmpty)
                .help(Localizer.tr("player__prev"))

                Button {
                    app.togglePlayPause()
                } label: {
                    Image(systemName: app.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(app.currentMusic == nil ? .white.opacity(0.35) : .white)
                        .frame(width: 44, height: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(app.currentMusic == nil)
                .help(app.isPlaying ? Localizer.tr("player__pause") : Localizer.tr("list__play"))

                Button {
                    app.next()
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(app.playQueue.isEmpty ? .white.opacity(0.35) : .white)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(app.playQueue.isEmpty)
                .help(Localizer.tr("player__next"))
            }
        }
    }
}
