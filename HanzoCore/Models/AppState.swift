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
    var autoSubmitMode: AutoSubmitMode = {
        if let raw = UserDefaults.standard.string(forKey: Constants.autoSubmitKey) {
            return AutoSubmitMode(rawValue: raw) ?? Constants.defaultAutoSubmitMode
        }
        return Constants.defaultAutoSubmitMode
    }()

    var stateColor: Color {
        switch dictationState {
        case .idle: return .secondary
        case .listening: return .green
        case .forging: return .orange
        case .error: return .red
        }
    }
}
