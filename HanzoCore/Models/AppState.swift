import AppKit
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
    var activeTargetBundleIdentifier: String?
    var isOnboardingComplete: Bool = UserDefaults.standard.bool(forKey: Constants.onboardingCompleteKey)
    var allowsDictationStart: Bool = true
    var isPopoverPresented: Bool = false
    var silenceTimeout: Double = AppBehaviorSettings.globalSilenceTimeout()
    var showsHoldIndicator: Bool = false
    var autoSubmitMode: AutoSubmitMode = AppBehaviorSettings.globalAutoSubmitMode()
    var appearanceMode: AppearanceMode = {
        if let raw = UserDefaults.standard.string(forKey: Constants.appearanceModeKey) {
            return AppearanceMode(rawValue: raw) ?? Constants.defaultAppearanceMode
        }
        return Constants.defaultAppearanceMode
    }()
    var asrProvider: ASRProvider = {
        if let raw = UserDefaults.standard.string(forKey: Constants.asrProviderKey) {
            return ASRProvider(rawValue: raw) ?? Constants.defaultASRProvider
        }
        return Constants.defaultASRProvider
    }()

    var preferredColorScheme: ColorScheme {
        switch appearanceMode {
        case .system:
            let isDark = NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return isDark ? .dark : .light
        case .light: return .light
        case .dark: return .dark
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
