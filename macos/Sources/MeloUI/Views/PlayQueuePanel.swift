import SwiftUI
import AppKit
import MeloCore

// MARK: - 播放模式菜单项（PlayerBar 右键 / 队列面板共用）

struct PlayModeMenuItems: View {
    let app: AppModel

    var body: some View {
        ForEach(PlayMode.allCases, id: \.rawValue) { mode in
            Button {
                app.setPlayMode(mode)
            } label: {
                if app.playMode == mode {
                    Label(mode.label, systemImage: "checkmark")
                } else {
                    Text(mode.label)
                }
            }
        }
    }
}

// MARK: - 播放队列面板

struct PlayQueuePanel: View {
    let app: AppModel

    @Environment(\.meloColors) private var colors
    @Environment(\.dismiss) private var dismiss

    @State private var hoveringIndex: Int?
    @State private var showClearConfirm = false

    private var queue: [MusicInfo] { app.playQueue }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(colors.border)
            if queue.isEmpty {
                emptyState
            } else {
                queueList
            }
            Divider().overlay(colors.border)
            footer
        }
        .frame(width: 400, height: 480)
        .background(colors.mainBackground)
        .alert("清空播放队列", isPresented: $showClearConfirm) {
            Button(Localizer.tr("btn_cancel"), role: .cancel) {}
            Button("清空", role: .destructive) {
                app.clearPlayQueue()
            }
        } message: {
            Text("将停止播放并清空队列中的 \(queue.count) 首歌曲（不影响任何列表数据）。")
        }
    }

    // MARK: 头部

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "list.bullet")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(colors.primary)
            Text("播放队列")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(colors.font)
            Text("\(queue.count)")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(colors.fontTertiary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(colors.fontTertiary.opacity(0.08), in: Capsule())
            Spacer()

            Menu {
                PlayModeMenuItems(app: app)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: app.playMode.systemImage)
                        .font(.system(size: 10))
                    Text(app.playMode.label)
                        .font(.system(size: 10))
                }
                .foregroundStyle(colors.fontSecondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(colors.fontTertiary.opacity(0.08), in: Capsule())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("播放模式")

            Button {
                showClearConfirm = true
            } label: {
                Label("清空队列", systemImage: "trash")
                    .font(.system(size: 10))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(queue.isEmpty)
            .help("停止播放并清空队列")

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(colors.fontTertiary)
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: 列表

    private var queueList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(queue.enumerated()), id: \.offset) { index, music in
                        queueRow(index: index, music: music)
                            .id(index)
                        if index < queue.count - 1 {
                            Divider().overlay(colors.border.opacity(0.6))
                        }
                    }
                }
                .padding(.vertical, 3)
            }
            .onAppear {
                proxy.scrollTo(app.playQueueIndex, anchor: .center)
            }
            .onChange(of: app.playQueueIndex) { _, newValue in
                withAnimation(.easeInOut(duration: 0.18)) {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
        }
    }

    private func queueRow(index: Int, music: MusicInfo) -> some View {
        let isCurrent = index == app.playQueueIndex
        return HStack(spacing: 8) {
            Group {
                if isCurrent {
                    Image(systemName: app.isPlaying ? "speaker.wave.2.fill" : "speaker.fill")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(colors.primary)
                } else {
                    Text("\(index + 1)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(colors.fontTertiary)
                }
            }
            .frame(width: 18)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(music.name)
                        .font(.system(size: 11.5, weight: isCurrent ? .semibold : .regular))
                        .foregroundStyle(isCurrent ? colors.primary : colors.font)
                        .lineLimit(1)
                    QualityBadges(music: music)
                }
                Text(music.singer.isEmpty ? "—" : music.singer)
                    .font(.system(size: 9.5))
                    .foregroundStyle(colors.fontSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            HStack(spacing: 1) {
                actionButton("chevron.up", help: Localizer.tr("list__moveup")) {
                    app.movePlayQueueItem(from: index, to: index - 1)
                }
                .disabled(index == 0)

                actionButton("chevron.down", help: Localizer.tr("list__movedown")) {
                    app.movePlayQueueItem(from: index, to: index + 1)
                }
                .disabled(index >= queue.count - 1)

                actionButton("xmark", help: "从队列移除") {
                    app.removePlayQueueItem(at: index)
                }
                .disabled(queue.count <= 1)
            }
            .opacity(hoveringIndex == index ? 1 : 0.55)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(rowBackground(index: index, isCurrent: isCurrent))
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering {
                hoveringIndex = index
            } else if hoveringIndex == index {
                hoveringIndex = nil
            }
        }
        .onTapGesture {
            app.playQueueItem(at: index)
        }
        .contextMenu {
            Button(Localizer.tr("list__play")) { app.playQueueItem(at: index) }
            Divider()
            Button(Localizer.tr("list__moveup")) { app.movePlayQueueItem(from: index, to: index - 1) }
                .disabled(index == 0)
            Button(Localizer.tr("list__movedown")) { app.movePlayQueueItem(from: index, to: index + 1) }
                .disabled(index >= queue.count - 1)
            Button("从队列移除", role: .destructive) { app.removePlayQueueItem(at: index) }
                .disabled(queue.count <= 1)
        }
    }

    private func rowBackground(index: Int, isCurrent: Bool) -> Color {
        if isCurrent { return colors.primary.opacity(0.10) }
        if hoveringIndex == index { return colors.hover }
        return .clear
    }

    private func actionButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(colors.fontSecondary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: 空态 / 底部

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "list.bullet.rectangle")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(colors.fontTertiary.opacity(0.6))
            Text("播放队列为空")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(colors.font)
            Text("从任意列表或搜索结果播放歌曲后，队列会显示在这里。")
                .font(.system(size: 10.5))
                .foregroundStyle(colors.fontSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 260)
            Button {
                app.route = .search
                dismiss()
            } label: {
                Label("去搜索歌曲", systemImage: "magnifyingglass")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderedProminent)
            .tint(colors.primary)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if queue.indices.contains(app.playQueueIndex) {
                Image(systemName: app.isPlaying ? "music.note" : "pause.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(colors.fontTertiary)
                Text("当前：\(queue[app.playQueueIndex].name)")
                    .font(.system(size: 10))
                    .foregroundStyle(colors.fontSecondary)
                    .lineLimit(1)
            } else {
                Text("队列共 \(queue.count) 首")
                    .font(.system(size: 10))
                    .foregroundStyle(colors.fontTertiary)
            }
            Spacer()
            Text("列表循环/随机等模式可在标题栏切换")
                .font(.system(size: 9))
                .foregroundStyle(colors.fontTertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
