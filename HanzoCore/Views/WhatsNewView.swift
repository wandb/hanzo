import SwiftUI

struct WhatsNewView: View {
    var appState: AppState
    var onClose: (() -> Void)?

    private let changelog: String?
    private let entries: [ReleaseNotesEntry]

    init(appState: AppState, onClose: (() -> Void)? = nil) {
        self.appState = appState
        self.onClose = onClose
        self.changelog = ReleaseNotesProvider.loadChangelog()
        self.entries = ReleaseNotesProvider.parseEntries(from: self.changelog ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("What's New")
                        .font(.system(.title2, design: .rounded, weight: .semibold))
                    Text("Full release history bundled with this build.")
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button(action: { onClose?() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.primary.opacity(0.3))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close what's new")
            }
            .padding(.bottom, 16)

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if entries.isEmpty {
                        fallbackContent
                    } else {
                        ForEach(entries) { entry in
                            ReleaseNotesEntryView(entry: entry)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 20)
        .frame(width: 720, height: 560)
        .hudBackground(colorScheme: appState.preferredColorScheme)
    }

    @ViewBuilder
    private var fallbackContent: some View {
        if let changelog, !changelog.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text(changelog)
                .font(.system(.body, design: .rounded))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text("Changelog is not available in this build.")
                .font(.system(.body, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct ReleaseNotesEntryView: View {
    let entry: ReleaseNotesEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Version \(entry.version)")
                    .font(.system(.title3, design: .rounded, weight: .semibold))

                if let date = entry.date {
                    Text(date)
                        .font(.system(.caption, design: .rounded, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(entry.body.components(separatedBy: "\n").enumerated()), id: \.offset) { item in
                    ReleaseNotesBodyLineView(line: item.element)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.bottom, 4)
    }
}

private struct ReleaseNotesBodyLineView: View {
    let line: String

    var body: some View {
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        if trimmed.isEmpty {
            Color.clear
                .frame(height: 6)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if trimmed.hasPrefix("### ") {
            Text(String(trimmed.dropFirst(4)))
                .font(.system(.headline, design: .rounded, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if trimmed.hasPrefix("## ") {
            Text(String(trimmed.dropFirst(3)))
                .font(.system(.headline, design: .rounded, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if trimmed.hasPrefix("- ") {
            HStack(alignment: .top, spacing: 8) {
                Text("-")
                    .font(.system(.body, design: .rounded, weight: .medium))
                Text(String(trimmed.dropFirst(2)))
                    .font(.system(.body, design: .rounded))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            Text(trimmed)
                .font(.system(.body, design: .rounded))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
