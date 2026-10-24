import SwiftUI
import AppKit
import MeloCore

// MARK: - 封面

/// 封面图：支持 http(s)（AsyncImage）与本地文件路径（NSImage），带内存缓存与占位图。
/// 固定尺寸用 `init(urlString:size:)`；自适应尺寸（如歌单卡片）用 `init(urlString:width:height:)` 并配合 `aspectRatio`。
struct CoverImage: View {
    let urlString: String?
    let width: CGFloat?
    let height: CGFloat?
    var cornerRadius: CGFloat = MeloMetrics.coverRadius
    private var sizingHint: CGFloat = 26

    init(urlString: String?, size: CGFloat, cornerRadius: CGFloat = MeloMetrics.coverRadius) {
        self.urlString = urlString
        self.width = size
        self.height = size
        self.cornerRadius = cornerRadius
        self.sizingHint = size
    }

    init(urlString: String?, width: CGFloat?, height: CGFloat?, cornerRadius: CGFloat = MeloMetrics.coverRadius, sizingHint: CGFloat = 26) {
        self.urlString = urlString
        self.width = width
        self.height = height
        self.cornerRadius = cornerRadius
        self.sizingHint = sizingHint
    }

    @Environment(\.meloColors) private var colors
    @State private var localImage: NSImage?

    private static let cache = NSCache<NSString, NSImage>()

    private var remoteURL: URL? {
        guard let urlString, let url = URL(string: urlString), MeloUtils.isHTTPURL(urlString) else { return nil }
        return url
    }

    private var localPath: String? {
        guard let urlString, !urlString.isEmpty, !MeloUtils.isHTTPURL(urlString) else { return nil }
        if urlString.hasPrefix("file://") {
            return URL(string: urlString)?.path
        }
        return urlString
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(colors.chipFill)

            if let localImage {
                Image(nsImage: localImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else if let remoteURL {
                AsyncImage(url: remoteURL) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: .fill)
                    case .failure:
                        placeholder
                    default:
                        ProgressView().controlSize(.mini)
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .task(id: localPath) { loadLocalImage() }
    }

    private var placeholder: some View {
        Image(systemName: "music.note")
            .font(.system(size: max(10, sizingHint * 0.34), weight: .regular))
            .foregroundStyle(colors.fontTertiary)
    }

    private func loadLocalImage() {
        guard let path = localPath else {
            localImage = nil
            return
        }
        if let cached = Self.cache.object(forKey: path as NSString) {
            localImage = cached
            return
        }
        guard let image = NSImage(contentsOfFile: path) else {
            localImage = nil
            return
        }
        Self.cache.setObject(image, forKey: path as NSString)
        localImage = image
    }
}

// MARK: - 图标按钮

struct MeloIconButton: View {
    let systemName: String
    var help: String?
    var isActive: Bool = false
    var size: CGFloat = 14
    var frameSize: CGFloat = 28
    var action: () -> Void

    @Environment(\.meloColors) private var colors
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(isActive ? colors.primary : colors.fontSecondary)
                .frame(width: frameSize, height: frameSize)
                .background(hovering ? colors.hover : Color.clear, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help ?? "")
        .onHover { hovering = $0 }
    }
}

// MARK: - 徽标

struct MeloBadge: View {
    let text: String
    var color: Color

    init(_ text: String, color: Color) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .lineLimit(1)
    }
}

/// 歌曲音质 / 来源标签
struct QualityBadges: View {
    let music: MusicInfo

    @Environment(\.meloColors) private var colors

    private var marks: [(String, Color)] {
        var result: [(String, Color)] = []
        let keys = Set(music.qualityBadges)
        if keys.contains("flac24bit") || keys.contains("ape") || keys.contains("wav") {
            if keys.contains("flac24bit") {
                result.append(("24BIT", colors.badgeSecondary))
            } else {
                result.append(("无损", colors.badgeSecondary))
            }
        } else if keys.contains("flac") {
            result.append(("无损", colors.badgeSecondary))
        } else if keys.contains("320k") || keys.contains("192k") {
            result.append((Localizer.tr("tag__high_quality"), colors.badgeSecondary))
        }
        if !music.isLocal, !music.source.isEmpty {
            result.append((music.source.uppercased(), colors.badgeSecondary))
        } else if music.isLocal {
            result.append(("本地", colors.badgeSecondary))
        }
        return result
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(marks.enumerated()), id: \.offset) { _, mark in
                MeloBadge(mark.0, color: mark.1)
            }
        }
    }
}

// MARK: - 空态

struct EmptyStateView: View {
    let systemImage: String
    let title: String
    var message: String?
    var actionTitle: String?
    var action: (() -> Void)?

    @Environment(\.meloColors) private var colors

    var body: some View {
        // 用 GeometryReader 填充可用空间而不是 `.frame(maxHeight: .infinity)`：
        // 后者会让 NavigationSplitView 的 detail 列在测量理想尺寸时报告无限大，
        // 导致 macOS 上侧边栏/页面头部被挤到不可见区域。
        GeometryReader { proxy in
            VStack(spacing: 14) {
                ZStack {
                    Circle().fill(colors.chipFill).frame(width: 84, height: 84)
                    Image(systemName: systemImage)
                        .font(.system(size: 32, weight: .ultraLight))
                        .foregroundStyle(colors.fontTertiary)
                }
                Text(title)
                    .font(MeloFont.sectionTitle)
                    .foregroundStyle(colors.font)
                if let message {
                    Text(message)
                        .font(MeloFont.secondary)
                        .foregroundStyle(colors.fontTertiary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 380)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let actionTitle, let action {
                    Button(actionTitle, action: action)
                        .buttonStyle(MeloCapsuleButtonStyle())
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .padding(32)
        }
    }
}

// MARK: - Toast

struct ToastView: View {
    let message: String

    @Environment(\.meloColors) private var colors

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.9))
            Text(message)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(2)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            Color(.sRGB, red: 0.16, green: 0.16, blue: 0.18, opacity: 0.94),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .shadow(color: .black.opacity(0.28), radius: 16, y: 6)
    }
}

// MARK: - 加载态

struct MeloLoadingView: View {
    let app: AppModel

    @Environment(\.meloColors) private var colors

    var body: some View {
        ZStack {
            ThemeBackground(colors: app.appColors)
            VStack(spacing: 18) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 88, height: 88)
                    .meloCoverShadow(intensity: 0.8)
                Text("Melo")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(colors.font)
                if let error = app.bootstrapError {
                    Text("启动失败：\(error)")
                        .font(MeloFont.secondary)
                        .foregroundStyle(colors.primary)
                        .frame(maxWidth: 420)
                        .multilineTextAlignment(.center)
                    Button("重试") { app.bootstrap() }
                        .buttonStyle(MeloCapsuleButtonStyle())
                } else {
                    ProgressView()
                        .controlSize(.small)
                    Text(app.libraryError ?? "正在加载曲库与设置…")
                        .font(MeloFont.caption)
                        .foregroundStyle(colors.fontSecondary)
                }
            }
            .padding(40)
        }
    }
}

// MARK: - 窗口访问 / 拖动

final class WindowProbeView: NSView {
    var onWindow: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindow?(window)
    }
}

/// 读取当前 SwiftUI 视图所在 NSWindow 的桥接视图
struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> WindowProbeView {
        let view = WindowProbeView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ nsView: WindowProbeView, context: Context) {
        nsView.onWindow = onWindow
    }
}

/// 通过鼠标拖动移动窗口（桌面歌词窗口的背景拖动使用）。
struct WindowDragModifier: ViewModifier {
    @State private var window: NSWindow?
    @State private var initialOrigin: NSPoint?

    func body(content: Content) -> some View {
        content
            .background(
                WindowAccessor { newWindow in
                    if window !== newWindow { window = newWindow }
                }
                .frame(width: 0, height: 0)
            )
            .gesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { value in
                        guard let window else { return }
                        if initialOrigin == nil {
                            initialOrigin = window.frame.origin
                        }
                        guard let base = initialOrigin else { return }
                        window.setFrameOrigin(
                            NSPoint(x: base.x + value.translation.width,
                                    y: base.y - value.translation.height)
                        )
                    }
                    .onEnded { _ in
                        initialOrigin = nil
                    }
            )
    }
}

extension View {
    func windowDraggable() -> some View {
        modifier(WindowDragModifier())
    }
}
