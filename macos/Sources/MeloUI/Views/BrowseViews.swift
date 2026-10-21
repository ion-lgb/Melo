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
                .font(.system(size: 11))
                .foregroundStyle(colors.primary)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(colors.fontSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(colors.primaryOpacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(colors.primaryOpacity(0.18), lineWidth: 1)
        )
    }
}
