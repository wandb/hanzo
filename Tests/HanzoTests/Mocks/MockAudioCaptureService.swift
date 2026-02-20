import Foundation
@testable import HanzoCore

final class MockAudioCaptureService: AudioCaptureProtocol {
    var onAudioChunk: ((Data) -> Void)?
    var startCaptureCalled = false
    var stopCaptureCalled = false
    var throwOnStart: Error?

    func startCapture() throws {
        if let error = throwOnStart { throw error }
        startCaptureCalled = true
    }

    func stopCapture() {
        stopCaptureCalled = true
    }

    func simulateChunk(_ data: Data) {
        onAudioChunk?(data)
    }
}
