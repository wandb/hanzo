import Foundation

protocol AudioCaptureProtocol {
    var onAudioChunk: ((Data) -> Void)? { get set }
    var onAudioLevels: (([Float]) -> Void)? { get set }
    func startCapture() throws
    func stopCapture()
}
