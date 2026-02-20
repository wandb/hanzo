import Foundation
import KeychainAccess

final class KeychainService {
    static let shared = KeychainService()

    private let keychain = Keychain(service: Constants.keychainService)

    private init() {}

    func saveAPIKey(_ key: String) throws {
        try keychain.set(key, key: Constants.keychainAPIKeyAccount)
    }

    func loadAPIKey() -> String? {
        try? keychain.get(Constants.keychainAPIKeyAccount)
    }

    func deleteAPIKey() throws {
        try keychain.remove(Constants.keychainAPIKeyAccount)
    }

    /// Ensures a default API key exists in keychain on first launch
    func ensureDefaultAPIKey() {
        if loadAPIKey() == nil {
            try? saveAPIKey(Constants.defaultAPIKey)
        }
    }
}
