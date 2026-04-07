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
    var isOnboardingComplete: Bool
    var allowsDictationStart: Bool = true
    var isPopoverPresented: Bool = false
    var silenceTimeout: Double
    var showsHoldIndicator: Bool = false
    var autoSubmitMode: AutoSubmitMode
    var recentDictations: [RecentDictationEntry] = []
    var appearanceMode: AppearanceMode
    var hudDisplayMode: HUDDisplayMode
    var asrProvider: ASRProvider

    init(settings: AppSettingsProtocol = AppSettings.live) {
        self.isOnboardingComplete = settings.onboardingComplete
        self.silenceTimeout = settings.globalSilenceTimeout
        self.autoSubmitMode = settings.globalAutoSubmitMode
        self.appearanceMode = settings.appearanceMode
        self.hudDisplayMode = settings.hudDisplayMode
        self.asrProvider = settings.asrProvider
    }

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
