import SwiftUI

struct SettingsSectionHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(.title3, design: .rounded, weight: .semibold))
            Text(subtitle)
                .font(.system(.subheadline, design: .rounded))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct SettingLabel: View {
    let title: String
    let helpText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(.body, design: .rounded))
            if let helpText {
                Text(helpText)
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
