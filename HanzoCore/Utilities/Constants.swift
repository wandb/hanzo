import Foundation

enum AutoSubmitMode: String {
    case enter
    case cmdEnter
    case off
}

enum AppearanceMode: String {
    case system
    case light
    case dark
}

enum Constants {
    static let bundleIdentifier = "com.hanzo.app"
    static let defaultHostedServerEndpoint = "https://grunt.zain.aaronbatilo.dev"
    static let defaultHostedServerPassword = ""
    static let hostedServerEndpointInfoKey = "HanzoHostedServerEndpoint"
    static let hostedServerPasswordInfoKey = "HanzoHostedServerPassword"
    static var hostedServerEndpoint: String {
        bundleString(for: hostedServerEndpointInfoKey) ?? defaultHostedServerEndpoint
    }
    static var hostedServerPassword: String {
        bundleString(for: hostedServerPasswordInfoKey) ?? defaultHostedServerPassword
    }
    static let defaultServerEndpoint = ""
    static let defaultLocalServerEndpoint = "http://127.0.0.1:8765"
    static let localRuntimeHealthPath = "healthz"
    static let localRuntimeHelperExecutableName = "HanzoLocalASR"
    static let localRuntimeStartupTimeout: TimeInterval = 12
    static let localRuntimeHealthPollNanoseconds: UInt64 = 250_000_000
    static let localModelStatusPath = "/v1/model/status"
    static let localModelDownloadPath = "/v1/model/download"
    static let localModelPreparePath = "/v1/model/prepare"
    static let localModelsFolderName = "models"
    static let defaultCustomServerPassword = ""
    static let serverEndpointKey = "serverEndpoint"
    static let customServerPasswordKey = "customServerPassword"
    static let localServerEndpointKey = "localServerEndpoint"
    static let asrProviderKey = "asrProvider"
    static let defaultASRProvider: ASRProvider = .hosted
    static let localASRModelPresetKey = "localASRModelPreset"
    static let defaultLocalASRModelPreset: LocalASRModelPreset = .balanced
    static let onboardingCompleteKey = "onboardingComplete"
    static let hotkeyCodeKey = "hotkeyCode"
    static let hotkeyModifiersKey = "hotkeyModifiers"
    static let defaultHotkeyCode: UInt32 = 49    // Space (Carbon virtual key code)
    static let defaultHotkeyModifiers: UInt32 = 4096  // Control (Carbon flag)
    static let logFileName = "hanzo.log"
    static let maxLogFileSizeMB = 10
    static let audioSampleRate: Double = 16000
    static let audioChannels: UInt32 = 1
    // ~250ms of float32 mono audio at 16kHz
    static let chunkAccumulationBytes = 16000

    // Auto-submit (press Return/Cmd+Return after paste)
    static let autoSubmitKey = "autoSubmitMode"
    static let defaultAutoSubmitMode: AutoSubmitMode = .off

    // Launch at login
    static let launchAtLoginDisabledByUserKey = "launchAtLoginDisabledByUser"

    // Appearance
    static let appearanceModeKey = "appearanceMode"
    static let defaultAppearanceMode: AppearanceMode = .system

    // Silence auto-close
    static let silenceTimeoutKey = "silenceTimeout"
    static let defaultSilenceTimeout: Double = 2.0  // seconds; 0 = disabled
    static let silenceRelativeThreshold: Float = 0.15  // fraction of peak speech level
    static let silenceAbsoluteFloor: Float = 0.005  // minimum silence threshold

    private static func bundleString(for key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String else {
            return nil
        }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
