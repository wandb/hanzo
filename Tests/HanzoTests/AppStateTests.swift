import AppKit
import Testing
import SwiftUI
@testable import HanzoCore

@Suite("AppState")
struct AppStateTests {
    private func withSettings<T>(_ body: (AppSettingsProtocol) -> T) -> T {
        let suiteName = "AppStateTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let settings = AppSettings(store: UserDefaultsAppSettingsStore(defaults: defaults))
        return body(settings)
    }

    @Test("stateColor is secondary for idle")
    func stateColorIdle() {
        withSettings { settings in
            let state = AppState(settings: settings)
            state.dictationState = .idle
            #expect(state.stateColor == .secondary)
        }
    }

    @Test("stateColor is green for listening")
    func stateColorListening() {
        withSettings { settings in
            let state = AppState(settings: settings)
            state.dictationState = .listening
            #expect(state.stateColor == .green)
        }
    }

    @Test("stateColor is orange for forging")
    func stateColorForging() {
        withSettings { settings in
            let state = AppState(settings: settings)
            state.dictationState = .forging
            #expect(state.stateColor == .orange)
        }
    }

    @Test("stateColor is red for error")
    func stateColorError() {
        withSettings { settings in
            let state = AppState(settings: settings)
            state.dictationState = .error
            #expect(state.stateColor == .red)
        }
    }

    @Test("audioLevels defaults to empty")
    func audioLevelsDefault() {
        withSettings { settings in
            let state = AppState(settings: settings)
            #expect(state.audioLevels.isEmpty)
        }
    }

    @Test("menuBarToast defaults to nil")
    func menuBarToastDefault() {
        withSettings { settings in
            let state = AppState(settings: settings)
            #expect(state.menuBarToast == nil)
        }
    }

    @Test("asrProvider defaults to configured default")
    func asrProviderDefault() {
        withSettings { settings in
            let state = AppState(settings: settings)
            #expect(state.asrProvider == Constants.defaultASRProvider)
        }
    }

    // MARK: - Appearance Mode

    @Test("preferredColorScheme resolves system appearance for system mode")
    func colorSchemeSystem() {
        withSettings { settings in
            let state = AppState(settings: settings)
            state.appearanceMode = .system
            // When NSApp is nil (unit tests), defaults to .light
            guard let app = NSApp else {
                #expect(state.preferredColorScheme == .light)
                return
            }
            let isDark = app.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            #expect(state.preferredColorScheme == (isDark ? .dark : .light))
        }
    }

    @Test("preferredColorScheme is .light for light mode")
    func colorSchemeLight() {
        withSettings { settings in
            let state = AppState(settings: settings)
            state.appearanceMode = .light
            #expect(state.preferredColorScheme == .light)
        }
    }

    @Test("preferredColorScheme is .dark for dark mode")
    func colorSchemeDark() {
        withSettings { settings in
            let state = AppState(settings: settings)
            state.appearanceMode = .dark
            #expect(state.preferredColorScheme == .dark)
        }
    }

    @Test("hudDisplayMode defaults to configured default")
    func hudDisplayModeDefault() {
        withSettings { settings in
            let state = AppState(settings: settings)
            #expect(state.hudDisplayMode == Constants.defaultHUDDisplayMode)
        }
    }

    @Test("hudDisplayMode loads stored mode")
    func hudDisplayModeStoredValue() {
        withSettings { settings in
            settings.hudDisplayMode = .compact

            let state = AppState(settings: settings)
            #expect(state.hudDisplayMode == .compact)
        }
    }
}
