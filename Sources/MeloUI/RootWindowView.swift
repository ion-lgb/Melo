import SwiftUI
import AppKit
import MeloCore

// MARK: - 主窗口根视图

/// 应用主窗口：Apple Music 式布局 —— 毛玻璃侧边栏 + 统一工具栏 + 内容区 + 底部播放条，
/// 播放详情以沉浸式覆盖层铺满整个窗口。
public struct RootWindowView: View {
    private let app: AppModel
    @State private var searchText: String = ""
    @State private var searchDebounce: Task<Void, Never>?

    public init(app: AppModel) {
        self.app = app
    }

    public var body: some View {
        // 用 GeometryReader 把内容尺寸严格约束为宿主窗口尺寸：
        // NavigationSplitView 在手工 NSHostingView 宿主下会让列按子树理想高度撑开
        // （特别是包含 GeometryReader/空态的页面），导致上下被裁切。
        GeometryReader { proxy in
            Group {
                if app.isBootstrapped {
                    mainWindow
                } else {
                    MeloLoadingView(app: app)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .environment(\.meloColors, app.appColors)
        .tint(app.appColors.primary)
        .preferredColorScheme(app.appColors.isDark ? .dark : .light)
        .frame(minWidth: 980, minHeight: 640)
        .overlay(alignment: .top) { toastOverlay }
        .animation(.easeInOut(duration: 0.2), value: app.toastMessage)
    }

    // MARK: 主窗口

    private var mainWindow: some View {
        NavigationSplitView {
            SidebarView(app: app)
                .navigationSplitViewColumnWidth(min: 200, ideal: MeloMetrics.sidebarWidth, max: 320)
        } detail: {
            detailContent
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                toolbarSearchField
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    app.route = .settings
                } label: {
                    Image(systemName: "gearshape")
                }
                .help(Localizer.tr("setting"))

                Button {
                    app.refreshLibrary()
                    app.reloadSources()
                    app.showToast("已刷新曲库与自定义源")
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("刷新")
            }
        }
        .overlay {
            if app.isShowingPlayDetail {
                PlayDetailView(app: app)
                    .transition(.opacity)
                    .zIndex(2)
            }
        }
        .animation(.easeInOut(duration: 0.22), value: app.isShowingPlayDetail)
        .onChange(of: searchText) { _, newValue in
            searchDebounce?.cancel()
            searchDebounce = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard !Task.isCancelled else { return }
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    if app.route == .search { await app.performSearch("") }
                } else {
                    app.route = .search
                    await app.performSearch(trimmed)
                }
            }
        }
    }

    private var detailContent: some View {
        VStack(spacing: 0) {
            // 页面统一放进 GeometryReader，给 ScrollView 类页面一个确定的高度上下文。
            // 否则（手工 NSHostingView 宿主时）NavigationSplitView 会把 detail 列
            // 按页面内容的理想高度（例如设置页 2500pt）撑开，导致上下裁切。
            GeometryReader { proxy in
                pageContent
                    .frame(width: proxy.size.width, height: proxy.size.height)
            }
            PlayerBar(app: app)
        }
        .background(app.appColors.mainBackground)
        // 固定窗口标题：页面大标题已在内容区呈现，避免工具栏与页面标题重复。
        .navigationTitle("Melo")
        .overlay(alignment: .top) {
            if let error = app.libraryError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(colors.badgeTertiary)
                    Text("曲库加载异常：\(error)")
                        .font(MeloFont.secondary)
                        .foregroundStyle(colors.font)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Button("重试") { app.refreshLibrary() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(colors.cardFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(colors.badgeTertiary.opacity(0.4), lineWidth: 1)
                )
                .shadow(color: colors.cardShadow, radius: 8, y: 3)
                .padding(.horizontal, MeloMetrics.pageInset)
                .padding(.top, 10)
            }
        }
    }

    @ViewBuilder
    private var pageContent: some View {
        switch app.route {
        case .search:
            SearchView(app: app, keyword: $searchText)
        case .leaderboard:
            LeaderboardView(app: app)
        case .songList:
            SongListView(app: app)
        case .songListDetail(let id, let source):
            SongListDetailView(app: app, id: id, source: source)
        case .myList(let listId):
            MyListView(app: app, listId: listId)
        case .download:
            DownloadView(app: app)
        case .settings:
            SettingsView(app: app)
        case .test:
            TestView(app: app)
        }
    }

    // MARK: 工具栏搜索

    private var toolbarSearchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(colors.fontTertiary)
            TextField("搜索音乐、歌手…", text: $searchText)
                .textFieldStyle(.plain)
                .font(MeloFont.body)
                .frame(width: 200)
                .onSubmit(submitSearch)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(colors.fontTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            colors.chipFill,
            in: RoundedRectangle(cornerRadius: MeloMetrics.controlRadius, style: .continuous)
        )
    }

    private func submitSearch() {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        app.route = .search
        Task { await app.performSearch(trimmed) }
    }

    // MARK: Toast

    @ViewBuilder
    private var toastOverlay: some View {
        if let message = app.toastMessage {
            ToastView(message: message)
                .padding(.top, 12)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private var colors: AppColors { app.appColors }
}
