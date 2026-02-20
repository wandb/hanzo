import SwiftUI

struct SettingsView: View {
    var onSave: (() -> Void)?

    @State private var serverEndpoint: String = UserDefaults.standard.string(forKey: Constants.serverEndpointKey) ?? Constants.defaultServerEndpoint
    @State private var apiKey: String = UserDefaults.standard.string(forKey: Constants.apiKeyKey) ?? ""
    @State private var showSaved = false

    var body: some View {
        Form {
            Section("Server") {
                TextField("ASR Server Endpoint", text: $serverEndpoint)
                    .textFieldStyle(.roundedBorder)
                SecureField("API Key", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
            }

            Section("Hotkey") {
                HStack {
                    Text("Global Hotkey:")
                    Text("Ctrl + Option + H")
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.quaternary)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                Text("Press this combination anywhere to start/stop dictation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Button("Save") {
                        save()
                    }
                    .keyboardShortcut(.return, modifiers: .command)

                    if showSaved {
                        Text("Saved")
                            .font(.caption)
                            .foregroundStyle(.green)
                            .transition(.opacity)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 280)
    }

    private func save() {
        UserDefaults.standard.set(serverEndpoint, forKey: Constants.serverEndpointKey)
        UserDefaults.standard.set(apiKey, forKey: Constants.apiKeyKey)
        onSave?()

        withAnimation {
            showSaved = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation { showSaved = false }
        }
    }
}
