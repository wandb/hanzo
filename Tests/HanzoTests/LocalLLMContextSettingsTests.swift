import Foundation
import Testing
@testable import HanzoCore

@Suite("Local LLM Context Settings")
struct LocalLLMContextSettingsTests {
    private func withDefaults<T>(_ body: (UserDefaults) -> T) -> T {
        let suiteName = "LocalLLMContextSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return body(defaults)
    }

    @Test("defaults to 2048 when unset")
    func defaultsTo2048WhenUnset() {
        withDefaults { defaults in
            #expect(Constants.localLLMContextSize(defaults: defaults) == 2048)
        }
    }

    @Test("returns configured value when supported")
    func returnsConfiguredValueWhenSupported() {
        withDefaults { defaults in
            defaults.set(2048, forKey: Constants.localLLMContextSizeKey)
            #expect(Constants.localLLMContextSize(defaults: defaults) == 2048)
        }
    }

    @Test("falls back to default when unsupported")
    func fallsBackToDefaultWhenUnsupported() {
        withDefaults { defaults in
            defaults.set(4096, forKey: Constants.localLLMContextSizeKey)
            #expect(Constants.localLLMContextSize(defaults: defaults) == 2048)
        }
    }
}
