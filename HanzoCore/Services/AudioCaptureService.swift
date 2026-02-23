import Accelerate
import AVFoundation
import Foundation

final class AudioCaptureService: AudioCaptureProtocol {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var isCapturing = false

    var onAudioChunk: ((Data) -> Void)?
    var onAudioLevels: (([Float]) -> Void)?

    // FFT setup for frequency analysis (pre-allocated, reused per buffer)
    private let fftLog2n: vDSP_Length = 10 // 2^10 = 1024 point FFT
    private let fftSize = 1024
    private lazy var fftSetup = vDSP_create_fftsetup(fftLog2n, FFTRadix(kFFTRadix2))!
    private let fftRealp: UnsafeMutablePointer<Float> = .allocate(capacity: 512)
    private let fftImagp: UnsafeMutablePointer<Float> = .allocate(capacity: 512)
    private var fftWindow = [Float](repeating: 0, count: 1024)
    private var fftWindowReady = false

    deinit {
        fftRealp.deallocate()
        fftImagp.deallocate()
        vDSP_destroy_fftsetup(fftSetup)
    }

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

    private func computeFrequencyBands(_ samples: UnsafePointer<Float>) {
        // Apply Hann window to reduce spectral leakage
        if !fftWindowReady {
            vDSP_hann_window(&fftWindow, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
            fftWindowReady = true
        }

        var windowed = [Float](repeating: 0, count: fftSize)
        vDSP_vmul(samples, 1, fftWindow, 1, &windowed, 1, vDSP_Length(fftSize))

        // Pack into split complex format
        let halfN = fftSize / 2
        windowed.withUnsafeBufferPointer { ptr in
            ptr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfN) { complexPtr in
                var split = DSPSplitComplex(realp: fftRealp, imagp: fftImagp)
                vDSP_ctoz(complexPtr, 2, &split, 1, vDSP_Length(halfN))
            }
        }

        // Forward FFT
        var split = DSPSplitComplex(realp: fftRealp, imagp: fftImagp)
        vDSP_fft_zrip(fftSetup, &split, 1, fftLog2n, FFTDirection(kFFTDirection_Forward))

        // Compute magnitudes (half spectrum = halfN bins)
        var magnitudes = [Float](repeating: 0, count: halfN)
        vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(halfN))

        // Scale
        var scale = Float(1.0 / Float(fftSize))
        vDSP_vsmul(magnitudes, 1, &scale, &magnitudes, 1, vDSP_Length(halfN))

        // Map bins to 7 frequency bands (logarithmic spacing)
        // At 16kHz sample rate, each bin = 16000/1024 ≈ 15.6 Hz
        // Nyquist = 8000 Hz, halfN = 512 bins
        // Bands: ~0-100, 100-250, 250-500, 500-1k, 1k-2k, 2k-4k, 4k-8k Hz
        let binWidth = Float(Constants.audioSampleRate) / Float(fftSize)
        let bandEdges: [Float] = [0, 100, 250, 500, 1000, 2000, 4000, 8000]
        var levels = [Float]()
        levels.reserveCapacity(7)

        for band in 0..<7 {
            let startBin = max(1, Int(bandEdges[band] / binWidth))
            let endBin = min(halfN, Int(bandEdges[band + 1] / binWidth))
            guard endBin > startBin else {
                levels.append(0)
                continue
            }
            var sum: Float = 0
            for i in startBin..<endBin {
                sum += magnitudes[i]
            }
            let avg = sum / Float(endBin - startBin)
            levels.append(sqrtf(avg))
        }

        onAudioLevels?(levels)
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

        let samples = channelData[0]

        // FFT-based frequency band levels for EQ visualization
        if frameCount >= fftSize {
            computeFrequencyBands(samples)
        }

        let data = Data(bytes: samples, count: frameCount * MemoryLayout<Float>.size)
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
