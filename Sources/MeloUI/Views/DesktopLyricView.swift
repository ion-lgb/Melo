import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MeloCore

// MARK: - 桌面歌词窗口

/// 桌面歌词视图。窗口本身（透明、置顶、尺寸、拖动）由 `MeloApp` 的 `Window("desktop-lyric")` 配置；
/// 本视图负责绘制歌词、悬停控制条与窗口拖动，并应用桌面歌词样式/行为/显示开关。
public struct DesktopLyricView: View {
    private let app: AppModel

    public init(app: AppModel) {
        self.app = app
    }

    @State private var hovering = false
    @State private var displayCenterIndex: Int?

    public var body: some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.black.opacity(0.22))

            VStack(spacing: 6) {
                if hovering {
                    musicHeader
                }
                if app.isDesktopLyricAudioVisualizationEnabled {
                    DesktopLyricSpectrumView(app: app)
                        .padding(.horizontal, 30)
                }
                lyricBody
                    .opacity(contentOpacity)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .contextMenu { contextMenuItems }
            .windowDraggable()

            if hovering {
                controlBar
                    .padding(6)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.white.opacity(hovering ? 0.18 : 0.06), lineWidth: 1)
        )
        .frame(minWidth: 240, minHeight: 100)
        .onHover { hovering = $0 }
        .onAppear {
            displayCenterIndex = app.currentLyricIndex
        }
        .onChange(of: app.currentLyricIndex) { _, newValue in
            guard let newValue else { return }
            if app.desktopLyricDelayScroll {
                Task {
                    try? await Task.sleep(nanoseconds: 1_600_000_000)
                    await MainActor.run {
                        displayCenterIndex = app.currentLyricIndex
                        _ = newValue
                    }
                }
            } else {
                displayCenterIndex = newValue
            }
        }
    }

    // MARK: 歌词

    private var lyrics: [(index: Int, line: LyricLine)] {
        let lines = app.lyricDocument.lines
        guard !lines.isEmpty else { return [] }
        let center = displayCenterIndex ?? app.currentLyricIndex ?? 0
        let lower = max(0, center - 2)
        let upper = min(lines.count - 1, center + 2)
        guard lower <= upper else { return [] }
        return (lower...upper).map { ($0, lines[$0]) }
    }

    @ViewBuilder
    private var lyricBody: some View {
        if let music = app.currentMusic {
            if lyrics.isEmpty {
                Text(app.isLoadingLyric ? "歌词加载中…" : "暂无歌词 · \(music.name)")
                    .font(.system(size: baseFontSize * 0.8))
                    .foregroundStyle(unplayColor.opacity(0.6))
                    .multilineTextAlignment(textAlignment)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: frameAlignment)
            } else {
                VStack(alignment: stackAlignment, spacing: lyricSpacing) {
                    ForEach(lyrics, id: \.index) { item in
                        lyricLine(item.line, index: item.index)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: frameAlignment)
            }
        } else {
            VStack(spacing: 6) {
                Image(systemName: "music.note")
                    .font(.system(size: 18, weight: .light))
                    .foregroundStyle(Color.white.opacity(0.5))
                Text("Melo 桌面歌词")
                    .font(.system(size: baseFontSize * 0.7, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.55))
                Text("播放歌曲后在此显示歌词 · 拖动可移动窗口 · 右键可调整歌词")
                    .font(.system(size: baseFontSize * 0.5))
                    .foregroundStyle(Color.white.opacity(0.35))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        return VStack(alignment: stackAlignment, spacing: 1) {
            Group {
                if isCurrent, app.playWordByWordLyric, !line.words.isEmpty {
                    KaraokeLyricLine(
                        line: line,
                        currentTime: app.currentTime,
                        isPlaying: app.isPlaying,
                        fontSize: baseFontSize * 1.12,
                        fontWeight: .semibold,
                        playedColor: playedColor,
                        unplayedColor: unplayColor,
                        alignment: karaokeAlignment,
                        shadowColor: shadowColor
                    )
                    .frame(maxWidth: .infinity, alignment: frameAlignment)
                } else {
                    Text(text)
                        .font(.system(size: baseFontSize * (isCurrent ? 1.12 : 0.88),
                                      weight: isCurrent ? .semibold : .regular))
                        .foregroundStyle(isCurrent ? playedColor : unplayColor)
                        .multilineTextAlignment(textAlignment)
                        .lineLimit(app.desktopLyricEllipsis ? 1 : 2)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: frameAlignment)
                        .shadow(color: shadowColor, radius: 2, x: 0, y: 1)
                }
            }
            ForEach(Array(extended.enumerated()), id: \.offset) { _, item in
                Text(item)
                    .font(.system(size: baseFontSize * 0.58))
                    .foregroundStyle(unplayColor.opacity(isCurrent ? 0.85 : 0.5))
                    .multilineTextAlignment(textAlignment)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: frameAlignment)
                    .shadow(color: shadowColor, radius: 2, x: 0, y: 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: frameAlignment)
        .contentShape(Rectangle())
        .onTapGesture {
            app.seek(to: line.time)
        }
        .help("点击跳转到该句")
    }

    // MARK: 右键菜单

    @ViewBuilder
    private var contextMenuItems: some View {
        Text("歌词偏移：\(offsetText)")
        Button("偏移 +10ms") { app.adjustLyricOffset(by: 10) }
        Button("偏移 +100ms") { app.adjustLyricOffset(by: 100) }
        Button("偏移 -10ms") { app.adjustLyricOffset(by: -10) }
        Button("偏移 -100ms") { app.adjustLyricOffset(by: -100) }
        Button("重置偏移") { app.resetLyricOffset() }
            .disabled(app.lyricOffsetMs == 0)

        Divider()

        Text("字号：\(Int(app.desktopLyricFontSize.rounded()))pt")
        Button("字号 +5") { app.setDesktopLyricFontSize(app.desktopLyricFontSize + 5) }
        Button("字号 -5") { app.setDesktopLyricFontSize(app.desktopLyricFontSize - 5) }
        Button("字号重置（20pt）") { app.setDesktopLyricFontSize(20) }

        Divider()

        ForEach([("left", "左对齐"), ("center", Localizer.tr("lyric_menu__align_center")), ("right", "右对齐")], id: \.0) { item in
            Button {
                app.setDesktopLyricAlign(item.0)
            } label: {
                if app.desktopLyricAlign == item.0 {
                    Label(item.1, systemImage: "checkmark")
                } else {
                    Text(item.1)
                }
            }
        }

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

    // MARK: 顶部歌曲信息（悬停时显示）

    private var musicHeader: some View {
        HStack(spacing: 6) {
            if let music = app.currentMusic {
                Text(music.name)
                    .font(MeloFont.caption.weight(.medium))
                    .foregroundStyle(Color.white.opacity(0.75))
                    .lineLimit(1)
                Text("·")
                    .foregroundStyle(Color.white.opacity(0.35))
                Text(music.singer)
                    .font(MeloFont.caption)
                    .foregroundStyle(Color.white.opacity(0.55))
                    .lineLimit(1)
            } else {
                Text("未在播放")
                    .font(MeloFont.caption)
                    .foregroundStyle(Color.white.opacity(0.5))
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: 控制条

    private var controlBar: some View {
        HStack(spacing: 2) {
            lyricIconButton(
                app.settings.bool(SettingKeys.desktopLyricAlwaysOnTop) ? "pin.fill" : "pin",
                help: "置顶"
            ) {
                let newValue = !app.settings.bool(SettingKeys.desktopLyricAlwaysOnTop)
                app.settings.set(SettingKeys.desktopLyricAlwaysOnTop, .bool(newValue))
                app.showToast(newValue ? "桌面歌词已置顶（窗口属性由应用层应用）" : "桌面歌词已取消置顶")
            }
            lyricIconButton("backward.fill", help: Localizer.tr("player__prev")) { app.previous() }
            lyricIconButton(app.isPlaying ? "pause.fill" : "play.fill", help: app.isPlaying ? Localizer.tr("player__pause") : Localizer.tr("list__play")) {
                app.togglePlayPause()
            }
            lyricIconButton("forward.fill", help: Localizer.tr("player__next")) { app.next() }
            Divider()
                .frame(height: 14)
                .overlay(Color.white.opacity(0.28))
                .padding(.horizontal, 3)
            lyricIconButton("macwindow", help: "打开主窗口并进入播放详情") {
                app.openPlayDetail()
                MeloUIWindow.activateMainWindow()
            }
            lyricIconButton("xmark", help: Localizer.tr("player__desktop_lyric_off")) {
                app.settings.set(SettingKeys.desktopLyricEnable, .bool(false))
                MeloUIWindow.closeDesktopLyric()
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(Color.black.opacity(0.42), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
    }

    private func lyricIconButton(_ systemName: String, help: String, action: @escaping () -> Void) -> some View {
        DesktopLyricControlButton(systemName: systemName, help: help, action: action)
    }

    private struct DesktopLyricControlButton: View {
        let systemName: String
        let help: String
        let action: () -> Void

        @State private var hovering = false

        var body: some View {
            Button(action: action) {
                Image(systemName: systemName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.88))
                    .frame(width: 24, height: 24)
                    .background(Color.white.opacity(hovering ? 0.18 : 0), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(help)
            .onHover { hovering = $0 }
        }
    }

    // MARK: 设置派生

    private var baseFontSize: CGFloat {
        CGFloat(min(max(app.desktopLyricFontSize, 10), 60))
    }

    private var lyricSpacing: CGFloat {
        max(2, CGFloat(min(max(app.desktopLyricLineGap, 0), 60)))
    }

    private var playedColor: Color {
        LyricDisplaySupport.color(fromCSS: app.desktopLyricPlayedColor) ?? app.appColors.primary
    }

    private var unplayColor: Color {
        LyricDisplaySupport.color(fromCSS: app.desktopLyricUnplayColor) ?? Color.white.opacity(0.92)
    }

    private var shadowColor: Color {
        LyricDisplaySupport.color(fromCSS: app.desktopLyricShadowColor) ?? Color.black.opacity(0.18)
    }

    private var stackAlignment: HorizontalAlignment {
        switch app.desktopLyricAlign {
        case "left": return .leading
        case "right": return .trailing
        default: return .center
        }
    }

    private var textAlignment: TextAlignment {
        switch app.desktopLyricAlign {
        case "left": return .leading
        case "right": return .trailing
        default: return .center
        }
    }

    private var frameAlignment: Alignment {
        switch app.desktopLyricAlign {
        case "left": return .leading
        case "right": return .trailing
        default: return .center
        }
    }

    private var karaokeAlignment: HorizontalAlignment { stackAlignment }

    private var offsetText: String {
        let value = app.lyricOffsetMs
        return value == 0 ? "0 ms" : String(format: "%+d ms", value)
    }

    /// 不透明度 + 暂停/悬停/全屏隐藏行为
    private var contentOpacity: Double {
        let base = min(max(app.desktopLyricOpacity / 100, 0.1), 1.0)
        if app.desktopLyricPauseHide, !app.isPlaying, app.currentMusic != nil { return 0 }
        if app.desktopLyricHoverHide, hovering { return 0 }
        if app.desktopLyricFullscreenHide, isOtherWindowFullscreen { return 0 }
        return base
    }

    private var isOtherWindowFullscreen: Bool {
        NSApp.windows.contains { window in
            window.isVisible
                && window.styleMask.contains(.fullScreen)
                && window.title != "桌面歌词"
        }
    }
}
