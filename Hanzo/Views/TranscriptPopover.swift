import SwiftUI

struct TranscriptPopover: View {
    let appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: appState.menuBarIconName)
                    .foregroundStyle(appState.stateColor)
                Text(stateLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            if !appState.partialTranscript.isEmpty {
                ScrollView {
                    Text(appState.partialTranscript)
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            } else if appState.dictationState == .listening {
                Text("Listening...")
                    .font(.body)
                    .foregroundStyle(.secondary)
            } else if appState.dictationState == .forging {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Forging transcript...")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
            }

            if let error = appState.errorMessage, appState.dictationState == .error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding()
        .frame(width: 320, height: 160)
    }

    private var stateLabel: String {
        switch appState.dictationState {
        case .listening: return "Listening"
        case .forging: return "Forging..."
        case .error: return "Error"
        default: return "Idle"
        }
    }
}
