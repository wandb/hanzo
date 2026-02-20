import SwiftUI

struct APIKeyStep: View {
    var onNext: () -> Void
    @State private var apiKey: String = UserDefaults.standard.string(forKey: Constants.apiKeyKey) ?? Constants.defaultAPIKey

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "key.fill")
                .font(.system(size: 48))
                .foregroundStyle(Color.accentColor)

            Text("API key")
                .font(.title2.bold())

            Text("Enter your ASR server API key. You can change this later in Settings.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)

            TextField("API key", text: $apiKey)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 300)

            Button("Continue") {
                let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    UserDefaults.standard.set(trimmed, forKey: Constants.apiKeyKey)
                }
                onNext()
            }
            .buttonStyle(.borderedProminent)
            .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding()
    }
}
