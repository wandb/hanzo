import Testing
import SwiftUI
@testable import HanzoCore

@Suite("AppState")
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
}
