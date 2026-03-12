import SwiftUI

struct HotkeyConfirmationStep: View {
    var appState: AppState
    var onDone: () -> Void

    @State private var demoText = ""
    @State private var demoCompleted = false
    @FocusState private var isTextFieldFocused: Bool

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: demoCompleted ? "checkmark.circle.fill" : "keyboard.fill")
                .font(.system(size: 48))
                .foregroundStyle(demoCompleted ? .green : .primary)
                .contentTransition(.symbolEffect(.replace))

            Text(demoCompleted ? "You're all set!" : "Try it out")
                .font(.system(.title2, design: .rounded, weight: .bold))

            Text(instructionText)
                .font(.system(.body, design: .rounded))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)

            // Demo text field — mimics a real input the user would dictate into
            TextField("Transcription appears here…", text: $demoText)
                .textFieldStyle(.plain)
                .font(.system(.body, design: .rounded))
                .padding(12)
                .background(.primary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .focused($isTextFieldFocused)
                .frame(maxWidth: 360)

            if !demoCompleted {
                HStack(spacing: 4) {
                    KeyCapView(label: "Ctrl")
                    Text("+")
                        .font(.system(.body, design: .rounded))
                        .foregroundStyle(.secondary)
                    KeyCapView(label: "Space")
                }
            }

            if demoCompleted {
                Button("Done") {
                    onDone()
                }
                .buttonStyle(HUDButtonStyle())
            } else {
                Button("Skip") {
                    onDone()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .font(.system(.body, design: .rounded))
            }
        }
        .onAppear {
            isTextFieldFocused = true
        }
        .onChange(of: demoText) { _, newText in
            if !newText.isEmpty && !demoCompleted {
                withAnimation { demoCompleted = true }
            }
        }
    }

    private var instructionText: String {
        switch appState.dictationState {
        case .listening:
            return "Listening… speak and it'll stop automatically when you pause."
        case .forging:
            return "Processing your speech…"
        default:
            if demoCompleted {
                return "That's how it works — dictate into any text field, anywhere."
            }
            return "Click the field, then press your hotkey to start dictating."
        }
    }
}

private struct KeyCapView: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.system(.body, design: .rounded, weight: .medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.primary.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
