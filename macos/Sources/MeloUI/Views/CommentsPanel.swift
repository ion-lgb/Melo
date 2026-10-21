import SwiftUI
import AppKit
import MeloCore

// MARK: - 歌曲评论（播放详情内可折叠区块）

enum CommentsTab: String, CaseIterable, Identifiable {
    case hot
    case latest

    var id: String { rawValue }
    var title: String { self == .hot ? Localizer.tr("comment__hot_title") : Localizer.tr("comment__new_title") }
}

/// 仅用于预览/自测的数据注入（正常运行时为 nil，全部走 AppModel 状态）
struct CommentsPreviewState {
    var hot: [CommentInfo] = []
    var latest: [CommentInfo] = []
    var total: Int = 0
    var page: Int = 0
    var maxPage: Int = 0
    var isLoading: Bool = false
    var error: String?
    var commentsMusicId: String?
}

struct CommentsPanel: View {
    let app: AppModel

    @Environment(\.meloColors) private var colors
    @State private var expanded: Bool
    @State private var tab: CommentsTab
    @State private var expandedCommentIDs: Set<String> = []

    private let preview: CommentsPreviewState?

    init(app: AppModel,
         previewExpanded: Bool = false,
         previewTab: CommentsTab = .hot,
         previewState: CommentsPreviewState? = nil) {
        self.app = app
        self.preview = previewState
        _expanded = State(initialValue: previewExpanded)
        _tab = State(initialValue: previewTab)
    }

    private var currentComments: [CommentInfo] {
        if let preview {
            return tab == .hot ? preview.hot : preview.latest
        }
        return tab == .hot ? app.hotComments : app.comments
    }

    private var commentCount: Int {
        if let preview {
            return tab == .hot ? preview.hot.count : max(preview.total, preview.latest.count)
        }
        return tab == .hot ? app.hotComments.count : max(app.commentsTotal, app.comments.count)
    }

    private var isLoadingComments: Bool {
        preview?.isLoading ?? app.isLoadingComments
    }

    private var commentsError: String? {
        preview?.error ?? app.commentsError
    }

    private var commentsTotal: Int {
        preview?.total ?? app.commentsTotal
    }

    private var commentsPage: Int {
        preview?.page ?? app.commentsPage
    }

    private var commentsMaxPage: Int {
        preview?.maxPage ?? app.commentsMaxPage
    }

    private var canLoadMore: Bool {
        !isLoadingComments && commentsPage < commentsMaxPage
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if expanded {
                Divider().overlay(Color.white.opacity(0.10))
                content
                    .frame(height: 232)
            }
        }
        .background(Color.white.opacity(expanded ? 0.055 : 0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
        .task(id: app.currentMusic?.id) {
            guard preview == nil else { return }
            guard expanded, let _ = app.currentMusic else { return }
            await loadCurrentTab(reset: true)
        }
        .onChange(of: expanded) { _, newValue in
            guard preview == nil else { return }
            guard newValue, let _ = app.currentMusic else { return }
            if app.commentsMusicId != app.currentMusic?.id || currentComments.isEmpty {
                Task { await loadCurrentTab(reset: true) }
            }
        }
    }

    // MARK: 头部

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    expanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.4))
                        .frame(width: 10)
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                    Text("评论")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.75))
                    if commentCount > 0 {
                        Text("\(commentCount)")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.45))
                    }
                }
            }
            .buttonStyle(.plain)

            if expanded {
                HStack(spacing: 2) {
                    ForEach(CommentsTab.allCases) { item in
                        Button {
                            selectTab(item)
                        } label: {
                            Text(item.title)
                                .font(.system(size: 10, weight: tab == item ? .semibold : .regular))
                                .foregroundStyle(tab == item ? Color.white : .white.opacity(0.45))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2.5)
                                .background(tab == item ? Color.white.opacity(0.14) : Color.clear, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.leading, 4)
            }

            Spacer()

            if expanded, isLoadingComments {
                ProgressView().controlSize(.mini)
            }
            if expanded, commentCount > 0 {
                Text("共 \(commentCount) 条")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    // MARK: 内容

    @ViewBuilder
    private var content: some View {
        if let error = app.commentsError, currentComments.isEmpty, !app.isLoadingComments {
            errorState(error)
        } else if app.isLoadingComments && currentComments.isEmpty {
            loadingState
        } else if currentComments.isEmpty {
            emptyState
        } else {
            commentsList
        }
    }

    private var loadingState: some View {
        VStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("正在加载评论…")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.45))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 7) {
            Image(systemName: "bubble.left")
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(.white.opacity(0.28))
            Text(tab == .hot ? "暂无热门评论" : Localizer.tr("comment__no_content"))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
            Text("歌曲评论来自内置音源（网易云等支持评论的源可见）")
                .font(.system(size: 9.5))
                .foregroundStyle(.white.opacity(0.35))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(10)
    }

    private func errorState(_ message: String) -> some View {
        let unsupported = message.contains("不支持") || message.contains("尚未就绪")
        return VStack(spacing: 8) {
            Image(systemName: unsupported ? "hand.raised" : "exclamationmark.triangle")
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(.white.opacity(0.35))
            Text(unsupported ? "当前音源暂不支持评论" : "评论加载失败")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.75))
            Text(unsupported
                 ? "内置网易云等支持评论的音源才能显示评论；不影响播放、歌词与其它功能。"
                 : message)
                .font(.system(size: 9.5))
                .foregroundStyle(.white.opacity(0.4))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 280)
            Button {
                Task { await loadCurrentTab(reset: true) }
            } label: {
                Label("重试", systemImage: "arrow.clockwise")
                    .font(.system(size: 10))
            }
            .buttonStyle(.bordered)
            .tint(.white)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(10)
    }

    private var commentsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(currentComments) { comment in
                    commentRow(comment)
                    Divider().overlay(Color.white.opacity(0.07))
                }

                if tab == .latest {
                    loadMoreFooter
                }

                Text("共 \(commentsTotal > 0 ? commentsTotal : currentComments.count) 条评论 · 已加载 \(currentComments.count) 条")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.3))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            }
            .padding(.horizontal, 10)
        }
    }

    private var loadMoreFooter: some View {
        HStack(spacing: 8) {
            if isLoadingComments {
                ProgressView().controlSize(.mini)
                Text("加载中…")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.white.opacity(0.4))
            } else if canLoadMore {
                Button {
                    Task { await app.loadMoreComments() }
                } label: {
                    Label("加载更多", systemImage: "arrow.down.circle")
                        .font(.system(size: 10))
                }
                .buttonStyle(.bordered)
                .tint(.white)
                .controlSize(.small)
            } else {
                Text("已加载全部评论")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.3))
            }
            Spacer()
            if commentsMaxPage > 0 {
                Text("第 \(commentsPage)/\(commentsMaxPage) 页")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.3))
            }
        }
        .padding(.vertical, 8)
    }

    private func commentRow(_ comment: CommentInfo) -> some View {
        HStack(alignment: .top, spacing: 9) {
            CommentAvatar(urlString: comment.avatar)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(comment.userName.isEmpty ? "匿名用户" : comment.userName)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.8))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(timeText(comment))
                        .font(.system(size: 8.5))
                        .foregroundStyle(.white.opacity(0.35))
                }

                if let location = comment.location, !location.isEmpty {
                    HStack(spacing: 3) {
                        Image(systemName: "mappin.and.ellipse")
                            .font(.system(size: 7.5))
                        Text(location)
                            .font(.system(size: 8.5))
                    }
                    .foregroundStyle(.white.opacity(0.3))
                }

                Text(comment.text)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.78))
                    .lineLimit(isExpanded(comment) ? nil : 3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)

                if shouldOfferExpand(comment) {
                    Button {
                        toggleExpanded(comment)
                    } label: {
                        Text(isExpanded(comment) ? "收起" : "展开")
                            .font(.system(size: 9))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                }

                if let reply = comment.reply {
                    replyBlock(reply)
                }

                HStack(spacing: 4) {
                    Spacer()
                    Image(systemName: "heart")
                        .font(.system(size: 8.5))
                    Text("\(comment.likedCount)")
                        .font(.system(size: 8.5, design: .monospaced))
                }
                .foregroundStyle(.white.opacity(0.35))
            }
        }
        .padding(.vertical, 7)
    }

    private func replyBlock(_ reply: CommentReply) -> some View {
        HStack(alignment: .top, spacing: 5) {
            Image(systemName: "arrowshape.turn.up.left")
                .font(.system(size: 8))
                .foregroundStyle(.white.opacity(0.35))
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text("@\(reply.userName.isEmpty ? "回复" : reply.userName)")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                Text(reply.text)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(6)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    // MARK: 动作

    private func loadCurrentTab(reset: Bool) async {
        switch tab {
        case .hot:
            await app.loadComments(hot: true, reset: reset)
        case .latest:
            await app.loadComments(hot: false, reset: reset)
        }
    }

    private func selectTab(_ newTab: CommentsTab) {
        tab = newTab
        if newTab == .hot && !app.hotComments.isEmpty { return }
        Task { await loadCurrentTab(reset: true) }
    }

    private func shouldOfferExpand(_ comment: CommentInfo) -> Bool {
        comment.text.count > 90 || comment.text.contains("\n")
    }

    private func isExpanded(_ comment: CommentInfo) -> Bool {
        expandedCommentIDs.contains(comment.id)
    }

    private func toggleExpanded(_ comment: CommentInfo) {
        if expandedCommentIDs.contains(comment.id) {
            expandedCommentIDs.remove(comment.id)
        } else {
            expandedCommentIDs.insert(comment.id)
        }
    }

    private func timeText(_ comment: CommentInfo) -> String {
        if let timeStr = comment.timeStr, !timeStr.isEmpty { return timeStr }
        guard let time = comment.time else { return "" }
        let date = Date(timeIntervalSince1970: time)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

// MARK: - 评论头像

private struct CommentAvatar: View {
    let urlString: String?

    private var remoteURL: URL? {
        guard let urlString, !urlString.isEmpty, let url = URL(string: urlString), MeloUtils.isHTTPURL(urlString) else {
            return nil
        }
        return url
    }

    var body: some View {
        Group {
            if let remoteURL {
                AsyncImage(url: remoteURL) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: .fill)
                    default:
                        placeholder
                    }
                }
            } else if let urlString, !urlString.isEmpty, !MeloUtils.isHTTPURL(urlString),
                      let image = NSImage(contentsOfFile: urlString) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                placeholder
            }
        }
        .frame(width: 26, height: 26)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
    }

    private var placeholder: some View {
        ZStack {
            Circle().fill(Color.white.opacity(0.10))
            Image(systemName: "person.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.45))
        }
    }
}
