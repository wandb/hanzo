import Foundation

enum Constants {
    static let defaultServerEndpoint = "https://grunt.zain.aaronbatilo.dev"
    static let defaultAPIKey = "aaronissocool"
    static let serverEndpointKey = "serverEndpoint"
    static let apiKeyKey = "apiKey"
    static let onboardingCompleteKey = "onboardingComplete"
    static let logFileName = "hanzo.log"
    static let maxLogFileSizeMB = 10
    static let audioSampleRate: Double = 16000
    static let audioChannels: UInt32 = 1
    // ~640ms of float32 mono audio at 16kHz
    static let chunkAccumulationBytes = 40960
}
