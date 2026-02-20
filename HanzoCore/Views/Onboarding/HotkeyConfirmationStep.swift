import SwiftUI

struct HotkeyConfirmationStep: View {
    var onDone: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "keyboard.fill")
                .font(.system(size: 48))
                .foregroundStyle(Color.accentColor)

            Text("Your dictation hotkey")
                .font(.title2.bold())

            HStack(spacing: 4) {
                KeyCapView(label: "Ctrl")
                Text("+")
                    .foregroundStyle(.secondary)
                KeyCapView(label: "Space")
            }
            .padding(.vertical, 8)

            Text("Press this combination anywhere to start dictation.\nPress again to stop and insert the transcript.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)

            Button("Done") {
                onDone()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }
}

private struct KeyCapView: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.system(.body, design: .rounded, weight: .medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.quaternary)
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
