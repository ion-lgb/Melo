import SwiftUI
import AppKit
import MeloCore

// MARK: - 主窗口根视图

/// 应用主窗口：NavigationSplitView（侧边栏 + 内容区）+ 工具栏 + 底部播放条 + 播放详情覆盖层。
public struct RootWindowView: View {
    private let app: AppModel
    @State private var searchText: String = ""

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
                .navigationSplitViewColumnWidth(min: 210, ideal: 236, max: 300)
        } detail: {
            detailContent
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                toolbarSearchField
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    themeMenuContent
                } label: {
                    Image(systemName: "paintpalette")
                }
                .help("切换主题")

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
    }

    private var detailContent: some View {
        ZStack {
            ThemeBackground(colors: app.appColors, imageURL: app.theme.backgroundImageURL)
            // 内容区半透明主背景：与原版 #right 一致（背景图主要在侧栏透出）
            app.appColors.mainBackground
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
        }
        .navigationTitle(windowTitle)
        .overlay(alignment: .top) {
            if let error = app.libraryError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(colors.badgeTertiary)
                    Text("曲库加载异常：\(error)")
                        .font(.system(size: 11))
                        .foregroundStyle(colors.font)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Button("重试") { app.refreshLibrary() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(colors.mainBackground.opacity(0.96), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(colors.badgeTertiary.opacity(0.4), lineWidth: 1))
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
        }
    }

    private var windowTitle: String {
        switch app.route {
        case .myList(let listId):
            return app.listName(listId)
        case .test:
            return "自定义源测试"
        case .search:
            return app.localizer.t("search")
        case .leaderboard:
            return app.localizer.t("leaderboard")
        case .songList:
            return app.localizer.t("song_list")
        case .songListDetail:
            return app.songListDetail?.info.name ?? "歌单详情"
        case .download:
            return app.localizer.t("download")
        case .settings:
            return app.localizer.t("setting")
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
                .font(.system(size: 11))
                .foregroundStyle(colors.fontTertiary)
            TextField("搜索音乐、歌手…", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .frame(width: 190)
                .onSubmit(submitSearch)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(colors.fontTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            colors.fontTertiary.opacity(0.10),
            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(colors.border, lineWidth: 1)
        )
    }

    private func submitSearch() {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        app.route = .search
        Task { await app.performSearch(trimmed) }
    }

    // MARK: 主题菜单

    @ViewBuilder
    private var themeMenuContent: some View {
        Button {
            let light = app.settings.string(SettingKeys.lightThemeId) ?? "green"
            let dark = app.settings.string(SettingKeys.darkThemeId) ?? "black"
            app.theme.setAutoTheme(lightId: light, darkId: dark)
        } label: {
            if app.theme.isAutoMode {
                Label("跟随系统（自动）", systemImage: "checkmark")
            } else {
                Text("跟随系统（自动）")
            }
        }

        Divider()

        ForEach(app.theme.builtinThemes) { theme in
            Button {
                app.setTheme(id: theme.id)
            } label: {
                if theme.id == app.theme.current.id {
                    Label(theme.name, systemImage: "checkmark")
                } else {
                    Text(theme.name)
                }
            }
        }

        if !app.theme.userThemes.isEmpty {
            Divider()
            ForEach(app.theme.userThemes) { theme in
                Button {
                    app.setTheme(id: theme.id)
                } label: {
                    if theme.id == app.theme.current.id {
                        Label(theme.name, systemImage: "checkmark")
                    } else {
                        Text(theme.name)
                    }
                }
            }
        }
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
