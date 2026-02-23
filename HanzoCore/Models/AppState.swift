import Foundation
import SwiftUI

enum DictationState: String {
    case idle
    case listening
    case forging
    case error
}

@Observable
final class AppState {
    var dictationState: DictationState = .idle
    var partialTranscript: String = ""
    var errorMessage: String?
    var audioLevels: [Float] = []
    var isOnboardingComplete: Bool = UserDefaults.standard.bool(forKey: Constants.onboardingCompleteKey)
    var isPopoverPresented: Bool = false
    var silenceTimeout: Double = UserDefaults.standard.object(forKey: Constants.silenceTimeoutKey) != nil
        ? UserDefaults.standard.double(forKey: Constants.silenceTimeoutKey)
        : Constants.defaultSilenceTimeout
    var autoSubmit: Bool = UserDefaults.standard.object(forKey: Constants.autoSubmitKey) != nil
        ? UserDefaults.standard.bool(forKey: Constants.autoSubmitKey)
        : Constants.defaultAutoSubmit

    var menuBarIconName: String {
        switch dictationState {
        case .idle: return "waveform"
        case .listening: return "waveform"
        case .forging: return "hammer.fill"
        case .error: return "exclamationmark.triangle"
        }
    }

    var stateColor: Color {
        switch dictationState {
        case .idle: return .secondary
        case .listening: return .green
        case .forging: return .orange
        case .error: return .red
        }
    }
}
