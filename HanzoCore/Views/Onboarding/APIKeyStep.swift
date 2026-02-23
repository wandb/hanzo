import SwiftUI

struct APIKeyStep: View {
    var onNext: () -> Void
    @State private var apiKey: String = UserDefaults.standard.string(forKey: Constants.apiKeyKey) ?? Constants.defaultAPIKey

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "key.fill")
                .font(.system(size: 48))
                .foregroundStyle(.primary)

            Text("API key")
                .font(.system(.title2, design: .rounded, weight: .bold))

            Text("Enter your ASR server API key. You can change this later in Settings.")
                .font(.system(.body, design: .rounded))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)

            TextField("API key", text: $apiKey)
                .textFieldStyle(.plain)
                .font(.system(.body, design: .rounded))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.primary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .frame(maxWidth: 300)

            Button("Continue") {
                let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    UserDefaults.standard.set(trimmed, forKey: Constants.apiKeyKey)
                }
                onNext()
            }
            .buttonStyle(HUDButtonStyle())
            .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
}
