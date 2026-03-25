import SwiftUI

struct AppCustomizationStep: View {
    var onDone: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 48))
                .foregroundStyle(.primary)

            Text("Tailor Hanzo for every app")
                .font(.system(.title2, design: .rounded, weight: .bold))
                .multilineTextAlignment(.center)

            Text("Write custom rewrite instructions for each app so dictation matches where you're working. In Settings, use one style for chat and another for interacting with agents.")
                .font(.system(.body, design: .rounded))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            Button("Done") {
                onDone()
            }
            .buttonStyle(HUDButtonStyle())
            .padding(.top, 4)
        }
    }
}
