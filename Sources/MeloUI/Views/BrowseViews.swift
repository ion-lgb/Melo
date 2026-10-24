import SwiftUI
import AppKit
import MeloCore

// MARK: - Phase 占位说明条

struct PhaseBanner: View {
    let text: String

    @Environment(\.meloColors) private var colors

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "hammer.fill")
                .font(.system(size: 12))
                .foregroundStyle(colors.primary)
            Text(text)
                .font(MeloFont.secondary)
                .foregroundStyle(colors.fontSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(colors.primaryOpacity(0.08), in: RoundedRectangle(cornerRadius: MeloMetrics.controlRadius, style: .continuous))
    }
}
