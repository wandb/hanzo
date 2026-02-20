import AVFoundation
import Foundation

final class AudioCaptureService {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var isCapturing = false

    var onAudioChunk: ((Data) -> Void)?

    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: Constants.audioSampleRate,
        channels: Constants.audioChannels,
        interleaved: false
    )!

    func startCapture() throws {
        guard !isCapturing else { return }

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        // Check if we need format conversion
        let needsConversion = inputFormat.sampleRate != targetFormat.sampleRate
            || inputFormat.channelCount != targetFormat.channelCount

        if needsConversion {
            converter = AVAudioConverter(from: inputFormat, to: targetFormat)
            guard converter != nil else {
                throw AudioCaptureError.converterCreationFailed
            }

            inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
                self?.convertAndDeliver(buffer)
            }
        } else {
            inputNode.installTap(onBus: 0, bufferSize: 4096, format: targetFormat) { [weak self] buffer, _ in
                self?.deliverBuffer(buffer)
            }
        }

        engine.prepare()
        try engine.start()
        isCapturing = true
        LoggingService.shared.info("Audio capture started (input: \(inputFormat.sampleRate)Hz \(inputFormat.channelCount)ch, target: \(targetFormat.sampleRate)Hz \(targetFormat.channelCount)ch)")
    }

    func stopCapture() {
        guard isCapturing else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil
        isCapturing = false
        LoggingService.shared.info("Audio capture stopped")
    }

    private func convertAndDeliver(_ inputBuffer: AVAudioPCMBuffer) {
        guard let converter = converter else { return }

        let ratio = targetFormat.sampleRate / inputBuffer.format.sampleRate
        let outputFrameCount = AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio)
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCount) else {
            return
        }

        var error: NSError?
        var allConsumed = false
        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if allConsumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            allConsumed = true
            outStatus.pointee = .haveData
            return inputBuffer
        }

        if let error = error {
            LoggingService.shared.warn("Audio conversion error: \(error)")
            return
        }

        deliverBuffer(outputBuffer)
    }

    private func deliverBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return }
        let data = Data(bytes: channelData[0], count: frameCount * MemoryLayout<Float>.size)
        onAudioChunk?(data)
    }
}

enum AudioCaptureError: Error, LocalizedError {
    case converterCreationFailed

    var errorDescription: String? {
        switch self {
        case .converterCreationFailed:
            return "Failed to create audio format converter"
        }
    }
}
