import SwiftUI

struct APIKeyStep: View {
    var onNext: () -> Void
    @State private var serverPassword: String = UserDefaults.standard.string(forKey: Constants.customServerPasswordKey) ?? Constants.defaultCustomServerPassword

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "key.fill")
                .font(.system(size: 48))
                .foregroundStyle(.primary)

            Text("Server password")
                .font(.system(.title2, design: .rounded, weight: .bold))

            Text("Enter your custom ASR server password. You can change this later in Settings.")
                .font(.system(.body, design: .rounded))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)

            SecureField("Server password", text: $serverPassword)
                .textFieldStyle(.plain)
                .font(.system(.body, design: .rounded))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.primary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .frame(maxWidth: 300)

            Button("Continue") {
                let trimmed = serverPassword.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    UserDefaults.standard.set(trimmed, forKey: Constants.customServerPasswordKey)
                }
                onNext()
            }
            .buttonStyle(HUDButtonStyle())
            .disabled(serverPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
}
