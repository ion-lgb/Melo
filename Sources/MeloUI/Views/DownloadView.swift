import SwiftUI
import AppKit
import MeloCore

// MARK: - 下载管理（Phase 2）

struct DownloadView: View {
    let app: AppModel

    @Environment(\.meloColors) private var colors
    @State private var showClearCompletedConfirm = false
    @State private var showClearHistoryConfirm = false
    @State private var historyExpanded: Bool

    /// 仅用于预览/自测：初始收起历史区块
    init(app: AppModel, previewHistoryCollapsed: Bool = false) {
        self.app = app
        _historyExpanded = State(initialValue: !previewHistoryCollapsed)
    }

    private var tasks: [DownloadTaskInfo] { app.downloadTasks }

    private var runningTasks: [DownloadTaskInfo] {
        tasks.filter { $0.status == "run" || $0.status == "pause" }
    }

    private var waitingTasks: [DownloadTaskInfo] {
        tasks.filter { $0.status == "waiting" }
    }

    private var completedTasks: [DownloadTaskInfo] {
        tasks.filter { $0.isCompleted || $0.status == "completed" }
    }

    private var failedTasks: [DownloadTaskInfo] {
        tasks.filter { $0.status == "error" && !$0.isCompleted }
    }

    private var activeCount: Int { runningTasks.count + waitingTasks.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !app.isDownloadEnabled {
                disabledBanner
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if tasks.isEmpty {
                        emptyStateBlock
                    } else {
                        liveSections
                    }
                    historySection
                }
                .padding(.horizontal, MeloMetrics.pageInset)
                .padding(.bottom, 20)
            }
        }
        .alert("清除已完成任务", isPresented: $showClearCompletedConfirm) {
            Button(Localizer.tr("btn_cancel"), role: .cancel) {}
            Button("清除", role: .destructive) {
                app.removeCompletedDownloads()
            }
        } message: {
            Text("将把 \(completedTasks.count) 个已完成任务从当前下载列表移除（已下载文件不会被删除）。此操作只影响本次运行的任务，不影响底部「历史记录」。")
        }
        .alert("清空已完成下载记录", isPresented: $showClearHistoryConfirm) {
            Button(Localizer.tr("btn_cancel"), role: .cancel) {}
            Button("清空", role: .destructive) {
                app.clearDownloadHistory()
            }
        } message: {
            Text("将从原版 download_list 下载历史中删除所有已完成记录（不删除本地文件）。该操作不影响当前下载任务。")
        }
    }

    // MARK: 头部

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            PageTitle("下载管理", subtitle: subtitle)
            Spacer()

            HStack(spacing: 8) {
                Button {
                    app.pauseAllDownloads()
                } label: {
                    Label("全部暂停", systemImage: "pause.fill")
                }
                .buttonStyle(.meloSecondary)
                .disabled(!app.isDownloadEnabled || activeCount == 0)

                Button {
                    app.resumeAllDownloads()
                } label: {
                    Label("全部继续", systemImage: "play.fill")
                }
                .buttonStyle(.meloSecondary)
                .disabled(!app.isDownloadEnabled || (waitingTasks.count + runningTasks.filter { $0.status == "pause" }.count) == 0)

                Button {
                    showClearCompletedConfirm = true
                } label: {
                    Label("清除已完成任务", systemImage: "trash")
                }
                .buttonStyle(.meloSecondary)
                .disabled(completedTasks.isEmpty)

                MeloIconButton(systemName: "folder", help: "打开下载目录") {
                    openDownloadFolder()
                }
                MeloIconButton(systemName: "arrow.clockwise", help: "刷新任务列表") {
                    app.refreshDownloadTasks()
                }
            }
        }
        .padding(.horizontal, MeloMetrics.pageInset)
        .padding(.top, 16)
        .padding(.bottom, 14)
    }

    private var subtitle: String {
        if !app.isDownloadEnabled {
            return "下载功能未开启 · 可在设置中开启"
        }
        if tasks.isEmpty {
            return "保存目录：\(savePath)"
        }
        var parts: [String] = []
        if !runningTasks.isEmpty { parts.append("进行中 \(runningTasks.count)") }
        if !waitingTasks.isEmpty { parts.append("等待 \(waitingTasks.count)") }
        if !completedTasks.isEmpty { parts.append("已完成 \(completedTasks.count)") }
        if !failedTasks.isEmpty { parts.append("失败 \(failedTasks.count)") }
        return parts.joined(separator: " · ")
    }

    private var savePath: String {
        app.settings.string(SettingKeys.downloadSavePath)
            ?? FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first?.path
            ?? NSHomeDirectory()
    }

    // MARK: 未开启下载

    private var disabledBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(colors.badgeTertiary)
            VStack(alignment: .leading, spacing: 3) {
                Text("下载功能未开启")
                    .font(MeloFont.cardTitle)
                    .foregroundStyle(colors.font)
                Text("开启后可保存歌曲到本地，并支持嵌入封面与歌词。")
                    .font(MeloFont.secondary)
                    .foregroundStyle(colors.fontSecondary)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(colors.cardFill, in: RoundedRectangle(cornerRadius: MeloMetrics.cardRadius, style: .continuous))
        .shadow(color: colors.cardShadow, radius: 6, x: 0, y: 2)
        .padding(.horizontal, MeloMetrics.pageInset)
        .padding(.bottom, 12)
    }

    // MARK: 空态

    private var emptyStateBlock: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().fill(colors.chipFill).frame(width: 84, height: 84)
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 34, weight: .ultraLight))
                    .foregroundStyle(colors.fontTertiary)
            }
            Text(app.isDownloadEnabled ? "暂无下载任务" : "下载功能已关闭")
                .font(MeloFont.sectionTitle)
                .foregroundStyle(colors.font)
            Text(
                app.isDownloadEnabled
                    ? "在歌曲右键菜单或搜索结果中点击「下载」即可加入队列；下载目录：\(savePath)"
                    : "前往「设置 → 下载」开启下载功能后再开始下载。"
            )
            .font(MeloFont.secondary)
            .foregroundStyle(colors.fontSecondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 460)

            Button {
                app.route = app.isDownloadEnabled ? .search : .settings
            } label: {
                Label(app.isDownloadEnabled ? "去搜索歌曲" : "去设置开启", systemImage: app.isDownloadEnabled ? "magnifyingglass" : "gearshape")
            }
            .buttonStyle(.meloPrimary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    // MARK: 运行时任务列表

    private var liveSections: some View {
        Group {
            section("进行中", systemImage: "arrow.down.circle.fill", tasks: runningTasks)
            section(Localizer.tr("download___status_waiting"), systemImage: "clock", tasks: waitingTasks)
            section("已完成", systemImage: "checkmark.circle.fill", tasks: completedTasks)
            section("失败", systemImage: "exclamationmark.triangle.fill", tasks: failedTasks)
        }
    }

    @ViewBuilder
    private func section(_ title: String, systemImage: String, tasks: [DownloadTaskInfo]) -> some View {
        if !tasks.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    Image(systemName: systemImage)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(colors.primary)
                    Text(title)
                        .font(MeloFont.cardTitle)
                        .foregroundStyle(colors.font)
                    Text("\(tasks.count)")
                        .font(MeloFont.microCaption.monospacedDigit())
                        .foregroundStyle(colors.fontTertiary)
                    Spacer()
                }
                .padding(.horizontal, 4)

                VStack(spacing: 0) {
                    ForEach(Array(tasks.enumerated()), id: \.element.id) { index, task in
                        DownloadTaskRow(app: app, task: task)
                        if index < tasks.count - 1 {
                            Divider().overlay(colors.border).padding(.leading, 68)
                        }
                    }
                }
                .background(colors.cardFill, in: groupShape)
                .clipShape(groupShape)
                .shadow(color: colors.cardShadow, radius: 6, x: 0, y: 2)
            }
        }
    }

    private var groupShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: MeloMetrics.cardRadius, style: .continuous)
    }

    // MARK: 下载历史（原版 download_list）

    private var history: [DownloadTaskInfo] { app.downloadHistory }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        historyExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: historyExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(colors.fontTertiary)
                            .frame(width: 11)
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(colors.primary)
                        Text("历史记录（原版 download_list）")
                            .font(MeloFont.cardTitle)
                            .foregroundStyle(colors.font)
                        Text("\(history.count)")
                            .font(MeloFont.microCaption.monospacedDigit())
                            .foregroundStyle(colors.fontTertiary)
                    }
                }
                .buttonStyle(.plain)

                if !history.isEmpty {
                    Text("· 已下载记录，仅供查看")
                        .font(MeloFont.caption)
                        .foregroundStyle(colors.fontTertiary)
                }

                Spacer()

                if !history.isEmpty {
                    Button {
                        showClearHistoryConfirm = true
                    } label: {
                        Label("清空已完成记录", systemImage: "trash")
                    }
                    .buttonStyle(.meloSecondary)
                    .help("从 download_list 中清空已完成记录（不删除本地文件）")
                }
            }
            .padding(.horizontal, 4)

            if historyExpanded {
                if history.isEmpty {
                    HStack(spacing: 10) {
                        Image(systemName: "tray")
                            .font(.system(size: 13))
                            .foregroundStyle(colors.fontTertiary)
                        Text("暂无下载历史。完成下载后，记录会显示在这里（来自原版 download_list）。")
                            .font(MeloFont.secondary)
                            .foregroundStyle(colors.fontSecondary)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .background(colors.cardFill, in: groupShape)
                    .clipShape(groupShape)
                    .shadow(color: colors.cardShadow, radius: 6, x: 0, y: 2)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(history.enumerated()), id: \.element.id) { index, record in
                            historyRow(record)
                            if index < history.count - 1 {
                                Divider().overlay(colors.border).padding(.leading, 58)
                            }
                        }
                    }
                    .background(colors.cardFill, in: groupShape)
                    .clipShape(groupShape)
                    .shadow(color: colors.cardShadow, radius: 6, x: 0, y: 2)
                }
            }
        }
    }

    private func historyRow(_ record: DownloadTaskInfo) -> some View {
        HStack(alignment: .center, spacing: 12) {
            CoverImage(urlString: record.musicInfo.picUrl, size: 40)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(record.musicInfo.name)
                        .font(MeloFont.body.weight(.medium))
                        .foregroundStyle(colors.font)
                        .lineLimit(1)
                    Text(record.musicInfo.singer)
                        .font(MeloFont.secondary)
                        .foregroundStyle(colors.fontSecondary)
                        .lineLimit(1)
                    MeloBadge(historyQualityLabel(record.quality), color: colors.badgePrimary)
                    MeloBadge(record.ext.uppercased(), color: colors.badgeSecondary)
                    Spacer(minLength: 0)
                }
                HStack(spacing: 6) {
                    Text(record.fileName)
                        .font(MeloFont.caption.monospacedDigit())
                        .foregroundStyle(colors.fontSecondary)
                        .lineLimit(1)
                    Text("·")
                        .foregroundStyle(colors.fontTertiary)
                    Text(record.isCompleted ? "已完成" : (record.statusText.isEmpty ? record.status : record.statusText))
                        .font(MeloFont.caption)
                        .foregroundStyle(record.isCompleted ? colors.primary : colors.badgeTertiary)
                    Spacer(minLength: 0)
                    Text(record.filePath.isEmpty ? "—" : record.filePath)
                        .font(MeloFont.microCaption)
                        .foregroundStyle(colors.fontTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            HStack(spacing: 2) {
                Button {
                    revealHistoryRecord(record)
                } label: {
                    Image(systemName: "folder")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(colors.fontSecondary)
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("在 Finder 中显示")
                .disabled(record.filePath.isEmpty)

                Button {
                    app.removeDownloadHistory(ids: [record.id])
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(colors.fontSecondary)
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("删除该下载记录（不删除文件）")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .contextMenu {
            Button("在 Finder 中显示") { revealHistoryRecord(record) }
                .disabled(record.filePath.isEmpty)
            Button("复制文件路径") {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(record.filePath, forType: .string)
                app.showToast("已复制文件路径")
            }
            Divider()
            Button("删除记录", role: .destructive) {
                app.removeDownloadHistory(ids: [record.id])
            }
        }
    }

    private func historyQualityLabel(_ quality: String) -> String {
        switch quality {
        case "128k": return "128K"
        case "320k": return "320K"
        case "flac": return "无损"
        case "flac24bit": return "24BIT"
        default: return quality.uppercased()
        }
    }

    private func revealHistoryRecord(_ record: DownloadTaskInfo) {
        guard !record.filePath.isEmpty else { return }
        let url = URL(fileURLWithPath: record.filePath)
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }

    private func openDownloadFolder() {
        let path = savePath
        NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: true))
    }
}

// MARK: - 单个下载任务行

private struct DownloadTaskRow: View {
    let app: AppModel
    let task: DownloadTaskInfo

    @Environment(\.meloColors) private var colors
    @State private var hovering = false

    private var ratio: Double {
        guard task.progressTotal > 0 else { return 0 }
        return min(1, max(0, Double(task.progressDownloaded) / Double(task.progressTotal)))
    }

    private var percentText: String {
        task.isCompleted ? "100%" : "\(Int((ratio * 100).rounded()))%"
    }

    private var byteText: String {
        let downloaded = ByteCountFormatter.string(fromByteCount: task.progressDownloaded, countStyle: .file)
        if task.progressTotal > 0 {
            let total = ByteCountFormatter.string(fromByteCount: task.progressTotal, countStyle: .file)
            return "\(downloaded) / \(total)"
        }
        return downloaded
    }

    private var showsTransferStats: Bool {
        !task.isCompleted && ["run", "waiting", "pause"].contains(task.status)
    }

    private var speedText: String {
        guard showsTransferStats,
              let speed = task.speedBytesPerSecond,
              speed.isFinite, speed > 0 else { return "--" }
        return ByteCountFormatter.string(fromByteCount: Int64(speed.rounded()), countStyle: .file) + "/s"
    }

    private var etaText: String {
        guard showsTransferStats,
              let eta = task.etaSeconds,
              eta.isFinite, eta >= 0, eta < 86400 else { return "--" }
        return "约 " + MeloUtils.formatTime(eta)
    }

    private var qualityLabel: String {
        switch task.quality {
        case "128k": return "128K"
        case "320k": return "320K"
        case "flac": return "无损"
        case "flac24bit": return "24BIT"
        default: return task.quality.uppercased()
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            CoverImage(urlString: task.musicInfo.picUrl, size: 46)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Text(task.musicInfo.name)
                        .font(MeloFont.body.weight(.medium))
                        .foregroundStyle(colors.font)
                        .lineLimit(1)
                    Text(task.musicInfo.singer)
                        .font(MeloFont.secondary)
                        .foregroundStyle(colors.fontSecondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }

                HStack(spacing: 7) {
                    MeloBadge(qualityLabel, color: colors.badgePrimary)
                    MeloBadge(task.ext.uppercased(), color: colors.badgeSecondary)
                    Text(task.statusText.isEmpty ? statusLabel : task.statusText)
                        .font(MeloFont.caption)
                        .foregroundStyle(statusColor)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if task.status == "waiting" {
                        Image(systemName: "clock")
                            .font(.system(size: 10))
                            .foregroundStyle(colors.fontTertiary)
                    }
                }

                progressBar

                HStack(spacing: 7) {
                    Text(percentText)
                        .font(MeloFont.microCaption.monospacedDigit())
                        .foregroundStyle(task.isCompleted ? colors.primary : colors.fontSecondary)
                    Text("· \(byteText)")
                        .font(MeloFont.microCaption.monospacedDigit())
                        .foregroundStyle(colors.fontTertiary)
                    if showsTransferStats {
                        Text("· 速度 \(speedText)")
                            .font(MeloFont.microCaption.monospacedDigit())
                            .foregroundStyle(colors.fontTertiary)
                        Text("· 剩余 \(etaText)")
                            .font(MeloFont.microCaption.monospacedDigit())
                            .foregroundStyle(colors.fontTertiary)
                    }
                    Spacer(minLength: 0)
                    Text(task.fileName)
                        .font(MeloFont.microCaption)
                        .foregroundStyle(colors.fontTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            actions
                .frame(width: 92, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(hovering ? colors.hover : Color.clear)
        .onHover { hovering = $0 }
        .contextMenu { menuContent }
    }

    private var statusLabel: String {
        switch task.status {
        case "waiting": return Localizer.tr("download___status_waiting")
        case "run": return "下载中"
        case "pause": return Localizer.tr("download__paused")
        case "completed": return "已完成"
        case "error": return "下载失败"
        default: return task.status
        }
    }

    private var statusColor: Color {
        switch task.status {
        case "run", "pause", "error": return colors.badgeTertiary
        case "completed": return colors.primary
        case "waiting": return colors.fontTertiary
        default: return colors.fontTertiary
        }
    }

    private var progressBar: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(colors.chipFill)
                Capsule()
                    .fill(statusColor)
                    .frame(width: proxy.size.width * ratio)
            }
        }
        .frame(height: 5)
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 2) {
            switch task.status {
            case "run":
                actionButton("pause.fill", help: Localizer.tr("player__pause")) { app.pauseDownload(id: task.id) }
                actionButton("xmark.circle", help: Localizer.tr("btn_cancel")) { app.cancelDownload(id: task.id) }
            case "waiting":
                actionButton("pause.fill", help: "暂停等待") { app.pauseDownload(id: task.id) }
                actionButton("xmark.circle", help: Localizer.tr("btn_cancel")) { app.cancelDownload(id: task.id) }
            case "pause":
                actionButton("play.fill", help: "继续") { app.resumeDownload(id: task.id) }
                actionButton("trash", help: "删除任务") { app.removeDownload(id: task.id) }
            case "error":
                actionButton("arrow.clockwise", help: "重试") { app.resumeDownload(id: task.id) }
                actionButton("trash", help: "删除任务") { app.removeDownload(id: task.id) }
            case "completed":
                actionButton("folder", help: "在 Finder 中显示") { revealInFinder() }
                actionButton("trash", help: "删除任务") { app.removeDownload(id: task.id) }
            default:
                actionButton("trash", help: "删除任务") { app.removeDownload(id: task.id) }
            }
        }
    }

    private func actionButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(colors.fontSecondary)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    @ViewBuilder
    private var menuContent: some View {
        switch task.status {
        case "run", "waiting":
            Button(Localizer.tr("player__pause")) { app.pauseDownload(id: task.id) }
            Button("取消下载", role: .destructive) { app.cancelDownload(id: task.id) }
        case "pause":
            Button("继续") { app.resumeDownload(id: task.id) }
            Button("删除任务", role: .destructive) { app.removeDownload(id: task.id) }
        case "error":
            Button("重试") { app.resumeDownload(id: task.id) }
            Button("删除任务", role: .destructive) { app.removeDownload(id: task.id) }
        case "completed":
            Button("在 Finder 中显示") { revealInFinder() }
            Button("删除任务", role: .destructive) { app.removeDownload(id: task.id) }
        default:
            Button("删除任务", role: .destructive) { app.removeDownload(id: task.id) }
        }
        Divider()
        Button("复制文件路径") {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(task.filePath, forType: .string)
            app.showToast("已复制文件路径")
        }
    }

    private func revealInFinder() {
        let url = URL(fileURLWithPath: task.filePath)
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }
}
