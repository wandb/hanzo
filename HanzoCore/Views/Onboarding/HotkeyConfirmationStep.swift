import SwiftUI

struct HotkeyConfirmationStep: View {
    var onDone: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "keyboard.fill")
                .font(.system(size: 48))
                .foregroundStyle(.white)

            Text("Your dictation hotkey")
                .font(.system(.title2, design: .rounded, weight: .bold))

            HStack(spacing: 4) {
                KeyCapView(label: "Ctrl")
                Text("+")
                    .font(.system(.body, design: .rounded))
                    .foregroundStyle(.secondary)
                KeyCapView(label: "Space")
            }
            .padding(.vertical, 8)

            Text("Press this combination anywhere to start dictation.\nPress again to stop and insert the transcript.")
                .font(.system(.body, design: .rounded))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)

            Button("Done") {
                onDone()
            }
            .buttonStyle(HUDButtonStyle())
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
            .background(.white.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
