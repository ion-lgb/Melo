import SwiftUI
import AppKit
import Combine
import MeloCore

// MARK: - 底部播放条

/// Apple Music 式播放条：材质底 + 顶部发丝线，三栏布局
/// （左：封面与曲目信息；中：纯字形传输控件 + 细进度条；右：功能与音量）。
struct PlayerBar: View {
    let app: AppModel

    @Environment(\.meloColors) private var colors
    @Environment(\.openWindow) private var openWindow

    @State private var showQueue = false
    @State private var scrubTime: Double?
    @State private var showSoundEffect = false

    private let rateOptions: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0]
    private let qualityOptions = ["128k", "320k", "flac", "flac24bit"]

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(colors.border).frame(height: 1)
            HStack(spacing: 12) {
                nowPlaying
                transport
                utilities
            }
            .padding(.horizontal, 14)
            .frame(height: MeloMetrics.playerBarHeight)
        }
        .background(MeloMaterial.bar.ignoresSafeArea(edges: .bottom))
        .sheet(isPresented: $showSoundEffect) {
            SoundEffectPanel(app: app)
        }
        .onReceive(NotificationCenter.default.publisher(for: .meloShowSoundEffectPanel)) { _ in
            showSoundEffect = true
        }
    }

    // MARK: 当前歌曲

    private var nowPlaying: some View {
        HStack(spacing: 10) {
            CoverImage(urlString: app.currentMusic?.picUrl, size: 48, cornerRadius: MeloMetrics.coverRadius)
                .meloCoverShadow(intensity: 0.7)
                .overlay(alignment: .bottomTrailing) {
                    if app.isResolvingMusic {
                        ProgressView()
                            .controlSize(.mini)
                            .padding(3)
                            .background(.thinMaterial, in: Circle())
                            .padding(2)
                    }
                }
                .onTapGesture {
                    if app.currentMusic != nil { app.openPlayDetail() }
                }
                .help("打开播放详情")

            VStack(alignment: .leading, spacing: 1) {
                Text(app.currentMusic?.name ?? "未在播放")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(app.currentMusic == nil ? colors.fontTertiary : colors.font)
                    .lineLimit(1)
                Text(subtitle)
                    .font(MeloFont.caption)
                    .foregroundStyle(colors.fontSecondary)
                    .lineLimit(1)
            }

            if app.currentMusic != nil {
                Button {
                    app.toggleFavorite(app.currentMusic!)
                } label: {
                    Image(systemName: isFavorite ? "heart.fill" : "heart")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(isFavorite ? colors.primary : colors.fontTertiary)
                }
                .buttonStyle(.plain)
                .help(isFavorite ? Localizer.tr("setting__hot_key_player_music_unlove") : "收藏到「我的收藏」")
            }

            Spacer(minLength: 0)
        }
        .frame(minWidth: 240, idealWidth: 280, maxWidth: 340, alignment: .leading)
    }

    private var isFavorite: Bool {
        guard let music = app.currentMusic else { return false }
        return app.isFavorite(music)
    }

    private var subtitle: String {
        guard let music = app.currentMusic else {
            return app.isBootstrapped ? "从列表中选择一首歌开始播放" : "正在启动…"
        }
        var parts: [String] = []
        if !music.singer.isEmpty { parts.append(music.singer) }
        if app.playbackError != nil {
            parts.append("播放错误")
        } else if playerStatusText != nil {
            parts.append(playerStatusText!)
        }
        return parts.isEmpty ? " " : parts.joined(separator: " – ")
    }

    private var playerStatusText: String? {
        switch app.playerStatus {
        case .loading: return "缓冲中…"
        case .error: return "错误"
        case .paused: return Localizer.tr("download__paused")
        case .stopped: return nil
        case .playing: return nil
        }
    }

    // MARK: 传输控制（居中）

    private var transport: some View {
        VStack(spacing: 1) {
            HStack(spacing: 26) {
                Button {
                    app.previous()
                } label: {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(app.playQueue.isEmpty ? colors.fontTertiary : colors.font)
                        .frame(width: 30, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(app.playQueue.isEmpty)
                .help(Localizer.tr("player__prev"))

                Button {
                    app.togglePlayPause()
                } label: {
                    Image(systemName: app.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 19))
                        .foregroundStyle(app.currentMusic == nil ? colors.fontTertiary : colors.font)
                        .frame(width: 34, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(app.currentMusic == nil)
                .help(app.isPlaying ? Localizer.tr("player__pause") : Localizer.tr("list__play"))

                Button {
                    app.next()
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(app.playQueue.isEmpty ? colors.fontTertiary : colors.font)
                        .frame(width: 30, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(app.playQueue.isEmpty)
                .help(Localizer.tr("player__next"))
            }

            scrubber
        }
        .frame(maxWidth: .infinity)
    }

    private var scrubber: some View {
        HStack(spacing: 10) {
            Text(MeloUtils.formatTime(scrubTime ?? app.currentTime))
                .font(MeloFont.timecode)
                .foregroundStyle(colors.fontTertiary)
                .frame(width: 40, alignment: .trailing)

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
            .tint(colors.primary)
            .disabled(app.duration <= 0)

            Text(MeloUtils.formatTime(app.duration))
                .font(MeloFont.timecode)
                .foregroundStyle(colors.fontTertiary)
                .frame(width: 40, alignment: .leading)
        }
    }

    // MARK: 工具区

    private var utilities: some View {
        HStack(spacing: 2) {
            playModeButton
            queueButton
            rateMenu
            qualityMenu
            volumeControl
            MeloIconButton(
                systemName: "slider.horizontal.3",
                help: "音效（10 段 EQ / 变速变调）",
                isActive: hasSoundEffects,
                frameSize: 28
            ) {
                showSoundEffect = true
            }
            MeloIconButton(
                systemName: app.settings.bool(SettingKeys.desktopLyricEnable) ? "text.bubble.fill" : "text.bubble",
                help: "桌面歌词",
                isActive: app.settings.bool(SettingKeys.desktopLyricEnable),
                frameSize: 28
            ) {
                toggleDesktopLyric()
            }
            MeloIconButton(systemName: "chevron.up", help: "播放详情", size: 12, frameSize: 26) {
                if app.currentMusic != nil { app.openPlayDetail() }
            }
            .disabled(app.currentMusic == nil)
        }
    }

    private var playModeButton: some View {
        Button {
            app.cyclePlayMode()
        } label: {
            Image(systemName: app.playMode.systemImage)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(app.playMode == .none ? colors.fontTertiary : colors.fontSecondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("播放模式：\(app.playMode.label)（单击切换，右键选择）")
        .contextMenu {
            PlayModeMenuItems(app: app)
        }
    }

    private var queueButton: some View {
        Button {
            showQueue.toggle()
        } label: {
            Image(systemName: "list.bullet")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(colors.fontSecondary)
                .frame(width: 28, height: 28)
                .overlay(alignment: .topTrailing) {
                    if !app.playQueue.isEmpty {
                        Text("\(app.playQueue.count)")
                            .font(.system(size: 8))
                            .monospacedDigit()
                            .foregroundStyle(colors.primary)
                            .offset(x: 2, y: -3)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("播放队列（\(app.playQueue.count) 首）")
        .popover(isPresented: $showQueue, arrowEdge: .bottom) {
            PlayQueuePanel(app: app)
        }
    }

    private var volumeIcon: String {
        if app.isMuted || app.volume <= 0.001 { return "speaker.slash.fill" }
        if app.volume < 0.34 { return "speaker.fill" }
        if app.volume < 0.67 { return "speaker.wave.1.fill" }
        return "speaker.wave.2.fill"
    }

    /// Apple Music 式内联音量条：点击图标静音，拖动滑块调音量
    private var volumeControl: some View {
        HStack(spacing: 4) {
            Button {
                app.toggleMute()
            } label: {
                Image(systemName: volumeIcon)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(colors.fontSecondary)
                    .frame(width: 26, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(app.isMuted ? "取消静音" : "静音")

            Slider(
                value: Binding(
                    get: { app.volume },
                    set: { app.setVolume($0) }
                ),
                in: 0...1
            )
            .controlSize(.mini)
            .tint(colors.fontSecondary)
            .frame(width: 62)
        }
    }

    private var rateMenu: some View {
        Menu {
            ForEach(rateOptions, id: \.self) { rate in
                Button {
                    app.setPlaybackRate(rate)
                } label: {
                    if abs(app.playbackRate - rate) < 0.001 {
                        Label(rateLabel(rate), systemImage: "checkmark")
                    } else {
                        Text(rateLabel(rate))
                    }
                }
            }
        } label: {
            HStack(spacing: 2) {
                Text(rateLabel(app.playbackRate))
                    .font(.system(size: 11))
                    .monospacedDigit()
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .semibold))
            }
            .foregroundStyle(colors.fontSecondary)
            .frame(width: 40)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("播放速度")
    }

    private var qualityMenu: some View {
        Menu {
            ForEach(qualityOptions, id: \.self) { quality in
                Button {
                    app.settings.set(SettingKeys.playQuality, .string(quality))
                    app.showToast("默认音质已切换为 \(qualityLabel(quality))（下次取链生效）")
                } label: {
                    if currentQuality == quality {
                        Label(qualityLabel(quality), systemImage: "checkmark")
                    } else {
                        Text(qualityLabel(quality))
                    }
                }
            }
        } label: {
            HStack(spacing: 2) {
                Text(isCurrentMusicLocal ? "本地" : qualityLabel(currentQuality))
                    .font(.system(size: 11))
                if !isCurrentMusicLocal {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7, weight: .semibold))
                }
            }
            .foregroundStyle(isCurrentMusicLocal ? colors.badgeSecondary : colors.fontSecondary)
            .frame(width: 44)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(isCurrentMusicLocal)
        .help(isCurrentMusicLocal ? "本地音乐无需选择音质" : "默认播放音质")
    }

    private var isCurrentMusicLocal: Bool {
        app.currentMusic?.isLocal == true
    }

    private var currentQuality: String {
        app.settings.string(SettingKeys.playQuality) ?? "128k"
    }

    private func rateLabel(_ rate: Double) -> String {
        if abs(rate - rate.rounded()) < 0.001 {
            return String(format: "%.1fx", rate)
        }
        return String(format: "%.2fx", rate)
    }

    private func qualityLabel(_ quality: String) -> String {
        switch quality {
        case "128k": return "128K"
        case "192k": return "192K"
        case "320k": return "320K"
        case "flac": return "无损"
        case "flac24bit": return "24BIT"
        default: return quality.uppercased()
        }
    }

    /// 音效层是否启用（EQ 增益或变速变调；播放条倍速不算音效）
    private var hasSoundEffects: Bool {
        let effects = app.audioEffects
        return effects.isEQActive || abs(app.pitchShifterRate - 1) > 0.005
    }

    private func toggleDesktopLyric() {
        let enabled = app.settings.bool(SettingKeys.desktopLyricEnable)
        if enabled {
            app.settings.set(SettingKeys.desktopLyricEnable, .bool(false))
            MeloUIWindow.closeDesktopLyric()
            app.showToast("已关闭桌面歌词")
        } else {
            app.settings.set(SettingKeys.desktopLyricEnable, .bool(true))
            openWindow(id: MeloUIWindow.desktopLyricID)
            app.showToast("已打开桌面歌词")
        }
    }
}
