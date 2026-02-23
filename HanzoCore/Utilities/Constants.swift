import Foundation

enum Constants {
    static let defaultServerEndpoint = "https://grunt.zain.aaronbatilo.dev"
    static let defaultAPIKey = ""
    static let serverEndpointKey = "serverEndpoint"
    static let apiKeyKey = "apiKey"
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

    // Auto-submit (press Return after paste)
    static let autoSubmitKey = "autoSubmit"
    static let defaultAutoSubmit = false

    // Launch at login
    static let launchAtLoginRegisteredKey = "launchAtLoginRegistered"

    // Silence auto-close
    static let silenceTimeoutKey = "silenceTimeout"
    static let defaultSilenceTimeout: Double = 2.0  // seconds; 0 = disabled
    static let silenceRelativeThreshold: Float = 0.15  // fraction of peak speech level
    static let silenceAbsoluteFloor: Float = 0.005  // minimum silence threshold
}
