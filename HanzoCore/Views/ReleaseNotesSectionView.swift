import SwiftUI

struct ReleaseNotesSectionView: View {
    let title: String
    let subtitle: String
    let changelog: String?
    let entries: [ReleaseNotesEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(.title3, design: .rounded, weight: .semibold))
                Text(subtitle)
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundStyle(.secondary)
            }

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
