import Testing
import SwiftUI
@testable import HanzoCore

@Suite("AppState")
struct AppStateTests {

    @Test("menuBarIconName returns waveform for idle")
    func menuBarIconNameIdle() {
        let state = AppState()
        state.dictationState = .idle
        #expect(state.menuBarIconName == "waveform")
    }

    @Test("menuBarIconName returns waveform for listening")
    func menuBarIconNameListening() {
        let state = AppState()
        state.dictationState = .listening
        #expect(state.menuBarIconName == "waveform")
    }

    @Test("menuBarIconName returns hammer.fill for forging")
    func menuBarIconNameForging() {
        let state = AppState()
        state.dictationState = .forging
        #expect(state.menuBarIconName == "hammer.fill")
    }

    @Test("menuBarIconName returns exclamationmark.triangle for error")
    func menuBarIconNameError() {
        let state = AppState()
        state.dictationState = .error
        #expect(state.menuBarIconName == "exclamationmark.triangle")
    }

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
}
