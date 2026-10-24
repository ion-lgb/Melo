import SwiftUI
import AppKit
import MeloCore

// MARK: - 度量

/// Apple Music 风格的几何尺度：留白更大、圆角更软、行高更高。
enum MeloMetrics {
    static let pageInset: CGFloat = 20
    static let sectionSpacing: CGFloat = 30
    static let gridSpacing: CGFloat = 18

    static let cardRadius: CGFloat = 14
    static let controlRadius: CGFloat = 8
    static let coverRadius: CGFloat = 8
    static let heroCoverRadius: CGFloat = 12

    static let rowHeight: CGFloat = 40
    static let sidebarRowHeight: CGFloat = 28
    static let playerBarHeight: CGFloat = 78

    static let sidebarWidth: CGFloat = 236
}

// MARK: - 排版

/// 标题层级对齐 Apple Music：页面大标题 28、章节标题 17、正文 13、辅助 11。
enum MeloFont {
    static let heroTitle = Font.system(size: 34, weight: .bold)
    static let pageTitle = Font.system(size: 28, weight: .bold)
    static let sectionTitle = Font.system(size: 17, weight: .bold)
    static let cardTitle = Font.system(size: 13, weight: .semibold)
    static let body = Font.system(size: 13)
    static let controlLabel = Font.system(size: 12, weight: .medium)
    static let secondary = Font.system(size: 12)
    static let caption = Font.system(size: 11)
    static let microCaption = Font.system(size: 10)
    static let timecode = Font.system(size: 11, weight: .regular, design: .default).monospacedDigit()
}

// MARK: - 材质

struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar
    var blending: NSVisualEffectView.BlendingMode = .behindWindow
    var state: NSVisualEffectView.State = .followsWindowActiveState

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blending
        view.state = state
        view.isEmphasized = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blending
        nsView.state = state
    }
}

enum MeloMaterial {
    /// 侧边栏毛玻璃（透出桌面）
    static var sidebar: some View { VisualEffectBackground(material: .sidebar) }
    /// 播放条 / 工具栏毛玻璃
    static var bar: some View { VisualEffectBackground(material: .headerView, blending: .withinWindow, state: .active) }
    /// 卡片内的轻量模糊（不透明窗口内）
    static var card: some View { VisualEffectBackground(material: .contentBackground, blending: .withinWindow, state: .active) }
}

// MARK: - 卡片

/// Apple Music 式分组卡片：无边框、纯色填充、大圆角、极轻投影。
struct MeloSurface<Content: View>: View {
    var padding: CGFloat = 18
    var fill: Color? = nil
    var cornerRadius: CGFloat = MeloMetrics.cardRadius
    @ViewBuilder var content: () -> Content

    @Environment(\.meloColors) private var colors

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(fill ?? colors.cardFill)
            )
            .shadow(color: colors.cardShadow, radius: 6, x: 0, y: 2)
    }
}

// MARK: - 章节标题

struct MeloSectionHeader: View {
    let title: String
    var subtitle: String?
    var actionTitle: String?
    var action: (() -> Void)?

    @Environment(\.meloColors) private var colors

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(MeloFont.sectionTitle)
                    .foregroundStyle(colors.font)
                if let subtitle {
                    Text(subtitle)
                        .font(MeloFont.caption)
                        .foregroundStyle(colors.fontTertiary)
                }
            }
            Spacer(minLength: 8)
            if let actionTitle, let action {
                Button(action: action) {
                    HStack(spacing: 3) {
                        Text(actionTitle)
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                    }
                    .font(MeloFont.controlLabel)
                    .foregroundStyle(colors.primary)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - 按钮样式

/// Apple Music 主行动按钮：胶囊 + 强调色（播放、收藏等）。
struct MeloCapsuleButtonStyle: ButtonStyle {
    var prominent = true

    func makeBody(configuration: Configuration) -> some View {
        CapsuleButtonBody(configuration: configuration, prominent: prominent)
    }

    private struct CapsuleButtonBody: View {
        let configuration: Configuration
        let prominent: Bool
        @Environment(\.meloColors) private var colors
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(prominent ? Color.white : colors.font)
                .padding(.horizontal, 18)
                .padding(.vertical, 7)
                .background(
                    Capsule(style: .continuous)
                        .fill(prominent
                              ? colors.primary.opacity(configuration.isPressed ? 0.75 : 1)
                              : colors.chipFill.opacity(configuration.isPressed ? 0.7 : 1))
                )
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(prominent ? Color.clear : colors.border, lineWidth: 1)
                )
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
                .opacity(isEnabled ? 1 : 0.45)
        }
    }
}

/// 次级胶囊按钮（灰底）
extension ButtonStyle where Self == MeloCapsuleButtonStyle {
    static var meloPrimary: MeloCapsuleButtonStyle { MeloCapsuleButtonStyle() }
    static var meloSecondary: MeloCapsuleButtonStyle { MeloCapsuleButtonStyle(prominent: false) }
}

/// 图标按钮的圆形 hover 底（Apple Music 播放条上的按钮）
struct MeloCircleIconButton: View {
    let systemName: String
    var help: String?
    var size: CGFloat = 15
    var frameSize: CGFloat = 30
    var isActive: Bool = false
    var action: () -> Void

    @Environment(\.meloColors) private var colors
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(isActive ? colors.primary : colors.fontSecondary)
                .frame(width: frameSize, height: frameSize)
                .background(colors.hover.opacity(hovering ? 1 : 0), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help ?? "")
        .onHover { hovering = $0 }
    }
}

// MARK: - 筛选药丸

struct MeloChip: View {
    let text: String
    var isSelected: Bool
    var action: () -> Void

    @Environment(\.meloColors) private var colors

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(MeloFont.controlLabel)
                .foregroundStyle(isSelected ? Color.white : colors.font)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(
                    Capsule(style: .continuous)
                        .fill(isSelected ? colors.primary : colors.chipFill)
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 流式布局

/// 按内容宽度自动换行的流式布局（热搜词、标签等不定宽 chips）。
struct MeloFlow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var totalWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth > 0, rowWidth + spacing + size.width > maxWidth {
                totalHeight += rowHeight + spacing
                totalWidth = max(totalWidth, rowWidth)
                rowWidth = 0
                rowHeight = 0
            }
            rowWidth += (rowWidth > 0 ? spacing : 0) + size.width
            rowHeight = max(rowHeight, size.height)
        }
        totalHeight += rowHeight
        totalWidth = max(totalWidth, rowWidth)
        return CGSize(width: totalWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - 封面

extension View {
    /// 封面投影：Apple Music 的封面始终浮在背景之上
    func meloCoverShadow(intensity: Double = 1) -> some View {
        shadow(color: Color.black.opacity(0.16 * intensity), radius: 8 * intensity, x: 0, y: 4 * intensity)
    }

    /// 圆角裁切 + 细描边，统一封面/卡片形状
    func meloRounded(_ radius: CGFloat, border: Color = .clear) -> some View {
        clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(border, lineWidth: border == .clear ? 0 : 1)
            )
    }
}

// MARK: - 封面取色背景

/// 从封面图取色，用于 hero 头图与沉浸式播放详情的渐变底。
@MainActor
enum ArtworkPalette {
    struct Palette: Hashable {
        var average: Color
        var top: Color
        var bottom: Color
    }

    private static let cache = NSCache<NSString, PaletteBox>()

    private final class PaletteBox {
        let value: Palette
        init(_ value: Palette) { self.value = value }
    }

    static func palette(for image: NSImage) -> Palette {
        let key = "\(ObjectIdentifier(image))"
        if let hit = cache.object(forKey: key as NSString) { return hit.value }
        let palette = compute(image)
        cache.setObject(PaletteBox(palette), forKey: key as NSString)
        return palette
    }

    private static func compute(_ image: NSImage) -> Palette {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return Palette(average: .gray, top: .gray, bottom: .gray)
        }
        let side = 12
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: &pixels, width: side, height: side,
                                  bitsPerComponent: 8, bytesPerRow: side * 4,
                                  space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return Palette(average: .gray, top: .gray, bottom: .gray)
        }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))

        func color(row: Range<Int>, column: Int) -> Color {
            var r = 0, g = 0, b = 0, n = 0
            for y in row {
                let base = (y * side + column) * 4
                r += Int(pixels[base]); g += Int(pixels[base + 1]); b += Int(pixels[base + 2]); n += 1
            }
            return Color(.sRGB, red: Double(r) / Double(n) / 255,
                         green: Double(g) / Double(n) / 255, blue: Double(b) / Double(n) / 255)
        }
        // CG 原点在左上：前几行是图片顶部
        let top = color(row: 0..<3, column: side / 2)
        let bottom = color(row: (side - 3)..<side, column: side / 2)
        let average = color(row: 0..<side, column: side / 2)
        return Palette(average: average, top: top, bottom: bottom)
    }
}

/// 沉浸式封面底：模糊封面 + 取色渐变 + 压暗层。
struct ArtworkBackdrop: View {
    let image: NSImage?
    var blurRadius: CGFloat = 60
    var dimOpacity: Double = 0.55
    var saturate: Double = 1.4

    var body: some View {
        ZStack {
            Color.black
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .saturation(saturate)
                    .blur(radius: blurRadius, opaque: false)
                    .opacity(0.85)
                LinearGradient(
                    colors: [
                        ArtworkPalette.palette(for: image).top.opacity(0.55),
                        ArtworkPalette.palette(for: image).bottom.opacity(0.75),
                    ],
                    startPoint: .top, endPoint: .bottom
                )
            }
            Color.black.opacity(dimOpacity)
        }
        .ignoresSafeArea()
        .clipped()
    }
}

/// 浅色 hero 头图：封面取色渐变 + 顶部透明，用于歌单/榜单详情页头部。
struct ArtworkTintHeader: View {
    let image: NSImage?
    @Environment(\.meloColors) private var colors

    var body: some View {
        ZStack {
            colors.mainBackground
            if let image {
                LinearGradient(
                    colors: [
                        ArtworkPalette.palette(for: image).top.opacity(colors.isDark ? 0.5 : 0.35),
                        ArtworkPalette.palette(for: image).bottom.opacity(colors.isDark ? 0.28 : 0.18),
                        colors.mainBackground.opacity(0),
                    ],
                    startPoint: .top, endPoint: .bottom
                )
            }
        }
    }
}

// MARK: - 加载封面图

/// 异步读取封面 URL（本地路径或 http），用于取色背景。
@MainActor
final class ArtworkImageLoader {
    static let shared = ArtworkImageLoader()
    private static let cache = NSCache<NSString, NSImage>()

    func image(for urlString: String?) async -> NSImage? {
        guard let urlString, !urlString.isEmpty else { return nil }
        if MeloUtils.isHTTPURL(urlString) {
            if let cached = Self.cache.object(forKey: urlString as NSString) { return cached }
            guard let url = URL(string: urlString),
                  let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = NSImage(data: data) else { return nil }
            Self.cache.setObject(image, forKey: urlString as NSString)
            return image
        }
        let path = urlString.hasPrefix("file://") ? (URL(string: urlString)?.path ?? urlString) : urlString
        return NSImage(contentsOfFile: path)
    }
}
