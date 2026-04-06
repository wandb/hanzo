import AppKit
import Testing
import SwiftUI
@testable import HanzoCore

@Suite("AppState", .serialized)
struct AppStateTests {

    @Test("stateColor is secondary for idle")
    func stateColorIdle() {
        let state = AppState()
        state.dictationState = .idle
        #expect(state.stateColor == .secondary)
    }

    @Test("stateColor is green for listening")
    func stateColorListening() {
        let state = AppState()
        state.dictationState = .listening
        #expect(state.stateColor == .green)
    }

    @Test("stateColor is orange for forging")
    func stateColorForging() {
        let state = AppState()
        state.dictationState = .forging
        #expect(state.stateColor == .orange)
    }

    @Test("stateColor is red for error")
    func stateColorError() {
        let state = AppState()
        state.dictationState = .error
        #expect(state.stateColor == .red)
    }

    @Test("audioLevels defaults to empty")
    func audioLevelsDefault() {
        let state = AppState()
        #expect(state.audioLevels.isEmpty)
    }

    @Test("asrProvider defaults to configured default")
    func asrProviderDefault() {
        let defaults = UserDefaults.standard
        let prior = defaults.string(forKey: Constants.asrProviderKey)
        defer {
            if let prior {
                defaults.set(prior, forKey: Constants.asrProviderKey)
            } else {
                defaults.removeObject(forKey: Constants.asrProviderKey)
            }
        }
        defaults.removeObject(forKey: Constants.asrProviderKey)

        let state = AppState()
        #expect(state.asrProvider == Constants.defaultASRProvider)
    }

    // MARK: - Appearance Mode

    @Test("preferredColorScheme resolves system appearance for system mode")
    func colorSchemeSystem() {
        let state = AppState()
        state.appearanceMode = .system
        // When NSApp is nil (unit tests), defaults to .light
        guard let app = NSApp else {
            #expect(state.preferredColorScheme == .light)
            return
        }
        let isDark = app.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        #expect(state.preferredColorScheme == (isDark ? .dark : .light))
    }

    @Test("preferredColorScheme is .light for light mode")
    func colorSchemeLight() {
        let state = AppState()
        state.appearanceMode = .light
        #expect(state.preferredColorScheme == .light)
    }

    @Test("preferredColorScheme is .dark for dark mode")
    func colorSchemeDark() {
        let state = AppState()
        state.appearanceMode = .dark
        #expect(state.preferredColorScheme == .dark)
    }

    @Test("hudDisplayMode defaults to configured default")
    func hudDisplayModeDefault() {
        let defaults = UserDefaults.standard
        let prior = defaults.string(forKey: Constants.hudDisplayModeKey)
        defer {
            if let prior {
                defaults.set(prior, forKey: Constants.hudDisplayModeKey)
            } else {
                defaults.removeObject(forKey: Constants.hudDisplayModeKey)
            }
        }
        defaults.removeObject(forKey: Constants.hudDisplayModeKey)

        let state = AppState()
        #expect(state.hudDisplayMode == Constants.defaultHUDDisplayMode)
    }

    @Test("hudDisplayMode loads stored mode")
    func hudDisplayModeStoredValue() {
        let defaults = UserDefaults.standard
        let prior = defaults.string(forKey: Constants.hudDisplayModeKey)
        defer {
            if let prior {
                defaults.set(prior, forKey: Constants.hudDisplayModeKey)
            } else {
                defaults.removeObject(forKey: Constants.hudDisplayModeKey)
            }
        }
        defaults.set(HUDDisplayMode.compact.rawValue, forKey: Constants.hudDisplayModeKey)

        let state = AppState()
        #expect(state.hudDisplayMode == .compact)
    }
}
