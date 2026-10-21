import SwiftUI
import AppKit
import Combine
import MeloCore

// MARK: - 底部播放条

struct PlayerBar: View {
    let app: AppModel

    @Environment(\.meloColors) private var colors
    @Environment(\.openWindow) private var openWindow

    @State private var showVolume = false
    @State private var showQueue = false
    @State private var scrubTime: Double?
    @State private var showSoundEffect = false

    private let rateOptions: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0]
    private let qualityOptions = ["128k", "320k", "flac", "flac24bit"]

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(colors.border).frame(height: 1)
            HStack(spacing: 14) {
                nowPlaying
                transport
                progress
                utilities
            }
            .padding(.horizontal, 16)
            .frame(height: 72)
            .background(colors.mainBackground.opacity(colors.isDark ? 0.80 : 0.90))
        }
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
            CoverImage(urlString: app.currentMusic?.picUrl, size: 48, cornerRadius: 7)
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

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(app.currentMusic?.name ?? "未在播放")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(colors.font)
                        .lineLimit(1)
                    if let music = app.currentMusic {
                        Button {
                            app.toggleFavorite(music)
                        } label: {
                            Image(systemName: app.isFavorite(music) ? "heart.fill" : "heart")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(app.isFavorite(music) ? colors.primary : colors.fontTertiary)
                        }
                        .buttonStyle(.plain)
                        .help(app.isFavorite(music) ? Localizer.tr("setting__hot_key_player_music_unlove") : "收藏到「我的收藏」")
                    }
                }
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(colors.fontSecondary)
                    .lineLimit(1)
            }
            .frame(minWidth: 150, alignment: .leading)
        }
        .frame(minWidth: 220, idealWidth: 260, maxWidth: 300, alignment: .leading)
    }

    private var subtitle: String {
        guard let music = app.currentMusic else {
            return app.isBootstrapped ? "从列表中选择一首歌开始播放" : "正在启动…"
        }
        var parts: [String] = []
        if !music.singer.isEmpty { parts.append(music.singer) }
        if !music.albumName.isEmpty { parts.append(music.albumName) }
        if app.playbackError != nil {
            parts.append("⚠️ 播放错误")
        } else if playerStatusText != nil {
            parts.append(playerStatusText!)
        }
        return parts.joined(separator: " · ")
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

    // MARK: 传输控制

    private var transport: some View {
        HStack(spacing: 8) {
            MeloIconButton(systemName: "backward.fill", help: Localizer.tr("player__prev"), size: 13, frameSize: 28) {
                app.previous()
            }
            .disabled(app.playQueue.isEmpty)

            Button {
                app.togglePlayPause()
            } label: {
                ZStack {
                    Circle().fill(colors.primary.opacity(app.currentMusic == nil ? 0.35 : 1))
                    Image(systemName: app.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .offset(x: app.isPlaying ? 0 : 1)
                }
                .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .disabled(app.currentMusic == nil)
            .help(app.isPlaying ? Localizer.tr("player__pause") : Localizer.tr("list__play"))

            MeloIconButton(systemName: "forward.fill", help: Localizer.tr("player__next"), size: 13, frameSize: 28) {
                app.next()
            }
            .disabled(app.playQueue.isEmpty)
        }
    }

    // MARK: 进度

    private var progress: some View {
        HStack(spacing: 8) {
            Text(MeloUtils.formatTime(scrubTime ?? app.currentTime))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(colors.fontSecondary)
                .frame(width: 42, alignment: .trailing)

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
            .controlSize(.small)
            .tint(colors.primary)
            .disabled(app.duration <= 0)

            Text(MeloUtils.formatTime(app.duration))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(colors.fontTertiary)
                .frame(width: 42, alignment: .leading)
        }
        .frame(maxWidth: .infinity, minHeight: 26)
    }

    // MARK: 工具区

    private var utilities: some View {
        HStack(spacing: 4) {
            playModeButton
            queueButton
            volumeButton
            rateMenu
            qualityMenu
            MeloIconButton(
                systemName: "slider.horizontal.3",
                help: "音效（10 段 EQ / 变速变调）",
                isActive: hasSoundEffects
            ) {
                showSoundEffect = true
            }
            MeloIconButton(
                systemName: app.settings.bool(SettingKeys.desktopLyricEnable) ? "text.bubble.fill" : "text.bubble",
                help: "桌面歌词",
                isActive: app.settings.bool(SettingKeys.desktopLyricEnable)
            ) {
                toggleDesktopLyric()
            }
            MeloIconButton(systemName: "chevron.up", help: "播放详情", size: 12) {
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
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(app.playMode == .none ? colors.fontTertiary : colors.fontSecondary)
                .frame(width: 26, height: 26)
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
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(colors.fontSecondary)
                .frame(width: 26, height: 26)
                .overlay(alignment: .topTrailing) {
                    if !app.playQueue.isEmpty {
                        Text("\(app.playQueue.count)")
                            .font(.system(size: 7.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(colors.primary)
                            .padding(.horizontal, 3)
                            .padding(.vertical, 0.5)
                            .background(colors.primary.opacity(0.12), in: Capsule())
                            .offset(x: 4, y: -2)
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

    private var volumeButton: some View {
        Button {
            showVolume.toggle()
        } label: {
            Image(systemName: volumeIcon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(colors.fontSecondary)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("音量")
        .popover(isPresented: $showVolume, arrowEdge: .bottom) {
            HStack(spacing: 10) {
                Button {
                    app.toggleMute()
                } label: {
                    Image(systemName: app.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(colors.fontSecondary)
                        .frame(width: 20)
                }
                .buttonStyle(.plain)

                Slider(
                    value: Binding(
                        get: { app.volume },
                        set: { app.setVolume($0) }
                    ),
                    in: 0...1
                )
                .controlSize(.small)
                .tint(colors.primary)
                .frame(width: 140)

                Text("\(Int((app.volume * 100).rounded()))%")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(colors.fontSecondary)
                    .frame(width: 34, alignment: .trailing)
            }
            .padding(14)
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
            Text(rateLabel(app.playbackRate))
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(colors.fontSecondary)
                .frame(width: 38)
        }
        .menuStyle(.borderlessButton)
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
            Text(isCurrentMusicLocal ? "本地" : qualityLabel(currentQuality))
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(isCurrentMusicLocal ? colors.badgeTertiary : colors.fontSecondary)
                .frame(width: 40)
        }
        .menuStyle(.borderlessButton)
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
