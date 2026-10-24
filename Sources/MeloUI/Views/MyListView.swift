import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MeloCore

// MARK: - 我的列表 / 歌曲列表页（多选、批量操作、拖拽排序）

struct MyListView: View {
    let app: AppModel
    let listId: String
    /// 仅用于预览/自测：强制显示「拖拽导入」高亮覆盖层
    var previewDropHighlighted: Bool = false

    @Environment(\.meloColors) private var colors

    @State private var filterText: String = ""
    @State private var selectedIDs: Set<String> = []
    @State private var anchorID: String?
    @State private var showListPicker = false
    @State private var showRemoveConfirm = false
    @State private var isDropTargeted = false
    @State private var showExportSheet = false
    @State private var keyMonitor: Any?

    private var allMusics: [MusicInfo] { app.currentMusics }

    private var filteredMusics: [MusicInfo] {
        let keyword = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return allMusics }
        return allMusics.filter {
            $0.name.localizedCaseInsensitiveContains(keyword)
                || $0.singer.localizedCaseInsensitiveContains(keyword)
                || $0.albumName.localizedCaseInsensitiveContains(keyword)
        }
    }

    private var selectedMusics: [MusicInfo] {
        filteredMusics.filter { selectedIDs.contains($0.id) }
    }

    private var listTitle: String { app.listName(listId) }

    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 0) {
                header
                if !selectedIDs.isEmpty {
                    batchBar
                }
                SongTableHeader()
                content
            }

            if isDropTargeted || previewDropHighlighted {
                dropOverlay
            }
        }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTargeted) { providers in
            handleDropProviders(providers)
        }
        .onChange(of: listId) { _, _ in
            filterText = ""
            clearSelection()
        }
        .onChange(of: filterText) { _, _ in
            let visible = Set(filteredMusics.map(\.id))
            selectedIDs.formIntersection(visible)
            if let anchorID, !visible.contains(anchorID) { self.anchorID = nil }
        }
        .onAppear { installKeyMonitor() }
        .onDisappear { removeKeyMonitor() }
        .sheet(isPresented: $showListPicker) {
            ListPickerSheet(app: app, musics: selectedMusics)
        }
        .sheet(isPresented: $showExportSheet) {
            ListExportSheet(app: app)
        }
        .alert("从「\(listTitle)」移除歌曲", isPresented: $showRemoveConfirm) {
            Button(Localizer.tr("btn_cancel"), role: .cancel) {}
            Button("移除 \(selectedMusics.count) 首", role: .destructive) {
                removeSelected()
            }
        } message: {
            Text("将从当前列表移除选中的 \(selectedMusics.count) 首歌曲，不会删除本地文件，操作不可撤销。")
        }
    }

    // MARK: 头部

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            PageTitle(listTitle, subtitle: subtitle)

            Spacer(minLength: 8)

            HStack(spacing: 7) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .font(.system(size: 13))
                    .foregroundStyle(colors.fontTertiary)
                TextField("过滤歌曲…", text: $filterText)
                    .textFieldStyle(.plain)
                    .font(MeloFont.body)
                    .frame(width: 150)
                if !filterText.isEmpty {
                    Button {
                        filterText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(colors.fontTertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(colors.chipFill, in: RoundedRectangle(cornerRadius: MeloMetrics.controlRadius, style: .continuous))

            Menu {
                Button {
                    importLocalFiles()
                } label: {
                    Label("导入本地文件…", systemImage: "doc.badge.plus")
                }
                Button {
                    importLocalFolder()
                } label: {
                    Label("导入文件夹…", systemImage: "folder.badge.plus")
                }
                Divider()
                Text("支持 mp3 / flac / m4a / wav / aac / ape 等音频格式；文件夹会递归扫描并自动去重")
            } label: {
                HStack(spacing: 5) {
                    if app.isImportingLocalMusic {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: 12))
                    }
                    Text(app.isImportingLocalMusic ? "导入中…" : Localizer.tr("import"))
                        .font(MeloFont.controlLabel)
                }
                .foregroundStyle(colors.font)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(colors.chipFill, in: Capsule())
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(app.isImportingLocalMusic)
            .help("导入本地音乐文件或文件夹（也可直接拖入列表）")

            Menu {
                Button {
                    showExportSheet = true
                } label: {
                    Label("导出列表…", systemImage: "square.and.arrow.up")
                }
                Button {
                    copyCurrentListAsText()
                } label: {
                    Label("复制为文本", systemImage: "doc.on.doc")
                }
                Divider()
                Text("导出支持文本 / CSV，可合并单文件或按列表拆分；复制为「歌名  歌手  专辑」纯文本")
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(colors.fontSecondary)
                    .frame(width: 24, height: 22)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("更多：导出 / 复制列表")

            Button {
                guard !filteredMusics.isEmpty else { return }
                app.playList(filteredMusics, startAt: 0)
            } label: {
                Label("播放全部", systemImage: "play.fill")
            }
            .buttonStyle(.meloPrimary)
            .disabled(filteredMusics.isEmpty)
            .help("从第一首开始播放当前列表（含过滤结果）")

            MeloIconButton(systemName: "arrow.clockwise", help: "重新加载当前列表") {
                app.loadMusicsForSelectedList()
                app.refreshLibrary()
            }
        }
        .padding(.horizontal, MeloMetrics.pageInset)
        .padding(.top, 16)
        .padding(.bottom, 10)
    }

    private var subtitle: String {
        let total = allMusics.count
        let showing = filteredMusics.count
        var text = "\(total) 首歌曲"
        if ListIDs.isBuiltin(listId) {
            text += " · 内置列表"
        } else {
            text += " · 用户列表"
        }
        if !filterText.isEmpty {
            text += " · 过滤后 \(showing) 首"
        }
        text += " · ⌘/Shift 多选 · ⌘A 全选 · Esc 取消 · 可拖入文件导入"
        if let error = app.libraryError {
            text += " · ⚠️ \(error)"
        }
        return text
    }

    // MARK: 批量操作栏

    private var batchBar: some View {
        HStack(spacing: 10) {
            Text("已选择 \(selectedMusics.count) 首")
                .font(MeloFont.controlLabel)
                .foregroundStyle(colors.primary)

            batchButton(Localizer.tr("list__play"), systemImage: "play.fill") {
                guard !selectedMusics.isEmpty else { return }
                app.playList(selectedMusics, startAt: 0)
            }
            batchButton(Localizer.tr("player__next"), systemImage: "text.insert") { playNextSelected() }
            batchButton(Localizer.tr("love_list"), systemImage: "heart") { favoriteSelected() }
            batchButton("添加到列表…", systemImage: "text.badge.plus") { showListPicker = true }
            batchButton(Localizer.tr("download"), systemImage: "arrow.down.circle") {
                let musics = selectedMusics.filter { !$0.isLocal }
                guard !musics.isEmpty else {
                    app.showToast("本地音乐无需下载")
                    return
                }
                Task { await app.startDownloads(musics) }
            }
            batchButton(Localizer.tr("list__remove"), systemImage: "trash", destructive: true) {
                guard !selectedMusics.isEmpty else { return }
                showRemoveConfirm = true
            }

            Spacer()
            Button("取消选择") { clearSelection() }
                .buttonStyle(.plain)
                .font(MeloFont.secondary)
                .foregroundStyle(colors.fontTertiary)
        }
        .padding(.horizontal, MeloMetrics.pageInset)
        .padding(.vertical, 9)
        .background(colors.primaryOpacity(0.07))
    }

    private func batchButton(_ title: String, systemImage: String, destructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 11))
                Text(title)
            }
            .font(MeloFont.controlLabel)
            .foregroundStyle(destructive ? colors.primary : colors.font)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(colors.chipFill, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: 内容

    @ViewBuilder
    private var content: some View {
        if allMusics.isEmpty {
            emptyListState
        } else if filteredMusics.isEmpty {
            EmptyStateView(
                systemImage: "magnifyingglass",
                title: "没有匹配「\(filterText)」的歌曲",
                message: "试试更短的关键词，或清空过滤条件。",
                actionTitle: "清空过滤",
                action: { filterText = "" }
            )
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(filteredMusics.enumerated()), id: \.element.id) { index, music in
                        SongRow(
                            app: app,
                            music: music,
                            index: index,
                            isSelected: selectedIDs.contains(music.id),
                            removeFromListId: listId,
                            batchActions: batchActions,
                            onCommandSelect: { handleCommandSelect(music) },
                            onShiftSelect: { handleShiftSelect(music) },
                            onSelect: { handlePlainSelect(music) },
                            onPlay: { playRow(music, index: index) }
                        )
                        .onDrag {
                            NSItemProvider(object: music.id as NSString)
                        }
                        .dropDestination(for: String.self) { items, _ in
                            handleDrop(items, target: music)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: 空列表 / 拖拽导入

    private var emptyListState: some View {
        VStack(spacing: 14) {
            Image(systemName: "music.note.list")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(colors.fontTertiary.opacity(0.55))
            Text("「\(listTitle)」还没有歌曲")
                .font(MeloFont.sectionTitle)
                .foregroundStyle(colors.font)
            Text("导入本地音乐，或到搜索页找歌、进入歌单详情播放，再通过右键菜单添加到该列表。")
                .font(MeloFont.secondary)
                .foregroundStyle(colors.fontSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420)

            HStack(spacing: 12) {
                Button {
                    importLocalFiles()
                } label: {
                    Label("导入本地音乐", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.meloPrimary)
                .disabled(app.isImportingLocalMusic)

                Button("导入文件夹") { importLocalFolder() }
                    .buttonStyle(.meloSecondary)
                    .disabled(app.isImportingLocalMusic)

                Button("去搜索") { app.route = .search }
                    .buttonStyle(.meloSecondary)
            }

            if app.isImportingLocalMusic {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在扫描并导入本地音乐…")
                        .font(MeloFont.caption)
                        .foregroundStyle(colors.fontSecondary)
                }
            } else {
                Text("也可以直接把音频文件或文件夹拖到列表区域")
                    .font(MeloFont.caption)
                    .foregroundStyle(colors.fontTertiary)
            }
        }
        .padding(36)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var dropOverlay: some View {
        ZStack {
            RoundedRectangle(cornerRadius: MeloMetrics.cardRadius, style: .continuous)
                .fill(colors.mainBackground.opacity(colors.isDark ? 0.94 : 0.96))
            RoundedRectangle(cornerRadius: MeloMetrics.cardRadius, style: .continuous)
                .fill(colors.primary.opacity(0.07))
            RoundedRectangle(cornerRadius: MeloMetrics.cardRadius, style: .continuous)
                .strokeBorder(
                    colors.primary,
                    style: StrokeStyle(lineWidth: 2, dash: [8, 5])
                )
            VStack(spacing: 10) {
                Image(systemName: "square.and.arrow.down.on.square")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(colors.primary)
                Text("松开导入本地音乐")
                    .font(MeloFont.sectionTitle)
                    .foregroundStyle(colors.font)
                Text("音频文件或文件夹将加入「\(listTitle)」（自动递归扫描并去重）")
                    .font(MeloFont.secondary)
                    .foregroundStyle(colors.fontSecondary)
            }
        }
        .padding(10)
        .allowsHitTesting(false)
        .transition(.opacity)
    }

    private var audioContentTypes: [UTType] {
        var types: [UTType] = [.audio]
        for ext in ["mp3", "flac", "m4a", "wav", "aac", "ogg", "ape", "wma", "opus", "aiff", "aif"] {
            if let type = UTType(filenameExtension: ext), !types.contains(type) {
                types.append(type)
            }
        }
        return types
    }

    private func copyCurrentListAsText() {
        let musics = app.currentMusics
        guard !musics.isEmpty else {
            app.showToast("当前列表为空，无法复制")
            return
        }
        let text = musics
            .map { "\($0.name)  \($0.singer)  \($0.albumName)" }
            .joined(separator: "\n")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        app.showToast("已复制 \(musics.count) 首歌曲为文本")
    }

    private func importLocalFiles() {
        let panel = NSOpenPanel()
        panel.title = "导入本地音乐文件"
        panel.message = "选择要导入「\(listTitle)」的音频文件（可多选，自动去重）"
        panel.prompt = Localizer.tr("import")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = audioContentTypes
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let urls = panel.urls
        Task { await app.importLocalMusic(urls: urls) }
    }

    private func importLocalFolder() {
        let panel = NSOpenPanel()
        panel.title = "导入本地音乐文件夹"
        panel.message = "选择要导入「\(listTitle)」的文件夹（递归扫描音频文件，自动去重）"
        panel.prompt = Localizer.tr("import")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let urls = panel.urls
        Task { await app.importLocalMusic(urls: urls) }
    }

    private func handleDropProviders(_ providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty else { return false }
        Task {
            var urls: [URL] = []
            for provider in providers {
                if let url = await loadFileURL(from: provider) {
                    urls.append(url)
                }
            }
            guard !urls.isEmpty else {
                app.showToast("未识别到文件或文件夹")
                return
            }
            await app.importLocalMusic(urls: urls)
        }
        return true
    }

    private func loadFileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                var url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let nsURL = item as? NSURL {
                    url = nsURL as URL
                } else if let directURL = item as? URL {
                    url = directURL
                }
                continuation.resume(returning: url)
            }
        }
    }

    // MARK: 多选逻辑

    private var batchActions: SongRowBatchActions? {
        guard selectedIDs.count > 1 else { return nil }
        return SongRowBatchActions(
            count: selectedMusics.count,
            play: { if !selectedMusics.isEmpty { app.playList(selectedMusics, startAt: 0) } },
            playNext: playNextSelected,
            favorite: favoriteSelected,
            addToList: { showListPicker = true },
            download: {
                let musics = selectedMusics.filter { !$0.isLocal }
                Task { await app.startDownloads(musics) }
            },
            remove: { showRemoveConfirm = true }
        )
    }

    private func handlePlainSelect(_ music: MusicInfo) {
        clearTextFocus()
        selectedIDs = [music.id]
        anchorID = music.id
    }

    private func handleCommandSelect(_ music: MusicInfo) {
        clearTextFocus()
        if selectedIDs.contains(music.id) {
            selectedIDs.remove(music.id)
        } else {
            selectedIDs.insert(music.id)
        }
        anchorID = music.id
    }

    private func handleShiftSelect(_ music: MusicInfo) {
        clearTextFocus()
        let visible = filteredMusics
        guard let anchorID,
              let anchorIndex = visible.firstIndex(where: { $0.id == anchorID }),
              let currentIndex = visible.firstIndex(where: { $0.id == music.id }) else {
            handlePlainSelect(music)
            return
        }
        let range = anchorIndex <= currentIndex ? anchorIndex...currentIndex : currentIndex...anchorIndex
        selectedIDs = Set(visible[range].map(\.id))
    }

    private func playRow(_ music: MusicInfo, index: Int) {
        selectedIDs = [music.id]
        anchorID = music.id
        app.playList(filteredMusics, startAt: index)
    }

    /// 点击歌曲行时释放搜索/过滤框焦点，保证 ⌘A / Esc 等列表快捷键可用
    private func clearTextFocus() {
        if let window = NSApp.keyWindow, window.firstResponder is NSTextView {
            window.makeFirstResponder(nil)
        }
    }

    private func selectAllVisible() {
        selectedIDs = Set(filteredMusics.map(\.id))
        anchorID = filteredMusics.first?.id
    }

    private func clearSelection() {
        selectedIDs.removeAll()
        anchorID = nil
    }

    // MARK: 批量动作

    private func playNextSelected() {
        let musics = selectedMusics
        guard !musics.isEmpty else { return }
        // playNext 每次插到当前「下一首」之前，倒序插入可保持选区顺序
        for music in musics.reversed() {
            app.playNext(music)
        }
        app.showToast("已将 \(musics.count) 首加入下一首播放")
    }

    private func favoriteSelected() {
        let musics = selectedMusics
        guard !musics.isEmpty else { return }
        var added = 0
        for music in musics where !app.isFavorite(music) {
            app.toggleFavorite(music)
            added += 1
        }
        app.showToast(added > 0 ? "已收藏 \(added) 首" : "选中的歌曲已全部收藏")
    }

    private func removeSelected() {
        let ids = selectedMusics.map(\.id)
        guard !ids.isEmpty else { return }
        app.removeMusics(ids: ids, from: listId)
        clearSelection()
    }

    // MARK: 拖拽排序

    private func handleDrop(_ ids: [String], target: MusicInfo) -> Bool {
        guard filterText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard let draggedID = ids.first,
              draggedID != target.id,
              let sourceIndex = app.currentMusics.firstIndex(where: { $0.id == draggedID }),
              let targetIndex = app.currentMusics.firstIndex(where: { $0.id == target.id }) else {
            return false
        }
        let destination = targetIndex > sourceIndex ? targetIndex + 1 : targetIndex
        app.moveMusics(in: app.selectedListId, fromOffsets: IndexSet(integer: sourceIndex), toOffset: destination)
        return true
    }

    // MARK: 键盘（⌘A / Esc）

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // 只把值类型（非 NSEvent 本身）跨到 MainActor，避免 Swift 6 的 Sendable 警告
            let keyCode = event.keyCode
            let characters = event.charactersIgnoringModifiers?.lowercased()
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let consumed = MainActor.assumeIsolated {
                handleLocalKey(keyCode: keyCode, characters: characters, flags: flags)
            }
            return consumed ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    @MainActor
    private func handleLocalKey(keyCode: UInt16, characters: String?, flags: NSEvent.ModifierFlags) -> Bool {
        // 文本输入（过滤框等）中不拦截
        if NSApp.keyWindow?.firstResponder is NSTextView { return false }
        if flags == .command, characters == "a" {
            guard !filteredMusics.isEmpty else { return false }
            selectAllVisible()
            return true
        }
        if keyCode == 53 {
            if !selectedIDs.isEmpty {
                clearSelection()
                return true
            }
        }
        return false
    }
}
