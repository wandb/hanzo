import SwiftUI

struct MenuBarToastView: View {
    let message: String
    let colorScheme: ColorScheme

    var body: some View {
        Text(message)
            .font(.system(.caption, design: .rounded, weight: .medium))
            .foregroundStyle(.primary)
            .lineLimit(1)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            VisualEffectView(material: .menu, blendingMode: .behindWindow)
                .clipShape(RoundedRectangle(cornerRadius: 14))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(.white.opacity(colorScheme == .dark ? 0.10 : 0.16), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .preferredColorScheme(colorScheme)
        .fixedSize()
    }
}
