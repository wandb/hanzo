import Foundation

protocol HotkeySessionControllerDelegate: AnyObject {
    var currentDictationState: DictationState { get }
    func hotkeyControllerStartRecording() -> Bool
    func hotkeyControllerStopRecording()
    func hotkeyControllerResetSilenceWindow()
    func hotkeyControllerQueueRestartAfterForging()
    func hotkeyControllerResetFromError()
    func hotkeyControllerSetShowsHoldIndicator(_ visible: Bool)
}

final class HotkeySessionController {
    enum Mode: Equatable {
        case inactive
        case pendingStartPress
        case tap
        case hold
    }

    weak var delegate: HotkeySessionControllerDelegate?

    private let logger: LoggingServiceProtocol
    private let holdThresholdSeconds: TimeInterval

    private(set) var mode: Mode = .inactive
    private var isPressed = false
    private var generation = 0
    private var holdActivationTask: Task<Void, Never>?

    init(
        logger: LoggingServiceProtocol,
        holdThresholdSeconds: TimeInterval = Constants.hotkeyHoldThresholdSeconds
    ) {
        self.logger = logger
        self.holdThresholdSeconds = holdThresholdSeconds
    }

    func handleKeyDown() {
        guard let delegate else { return }
        guard !isPressed else { return }
        isPressed = true

        switch delegate.currentDictationState {
        case .idle:
            guard delegate.hotkeyControllerStartRecording() else {
                isPressed = false
                return
            }
            generation += 1
            mode = .pendingStartPress
            delegate.hotkeyControllerSetShowsHoldIndicator(true)
            scheduleHoldActivation(for: generation)
        case .listening:
            let control = mode
            clear()
            if control == .tap || control == .inactive {
                delegate.hotkeyControllerStopRecording()
            }
        case .forging:
            logger.info("Toggle received during forging; queued restart")
            delegate.hotkeyControllerQueueRestartAfterForging()
            clear()
        case .error:
            clear()
            delegate.hotkeyControllerResetFromError()
        }
    }

    func handleKeyUp() {
        guard let delegate else { return }
        guard isPressed else { return }
        isPressed = false

        switch mode {
        case .pendingStartPress:
            cancelHoldActivation()
            delegate.hotkeyControllerSetShowsHoldIndicator(false)
            if delegate.currentDictationState == .listening {
                mode = .tap
                delegate.hotkeyControllerResetSilenceWindow()
            } else {
                mode = .inactive
            }
        case .hold:
            cancelHoldActivation()
            mode = .inactive
            if delegate.currentDictationState == .listening {
                delegate.hotkeyControllerStopRecording()
            }
        case .tap, .inactive:
            cancelHoldActivation()
            mode = .inactive
            delegate.hotkeyControllerSetShowsHoldIndicator(false)
        }
    }

    func clear() {
        cancelHoldActivation()
        mode = .inactive
        isPressed = false
        delegate?.hotkeyControllerSetShowsHoldIndicator(false)
    }

    private func scheduleHoldActivation(for targetGeneration: Int) {
        cancelHoldActivation()
        let thresholdNanoseconds = UInt64(holdThresholdSeconds * 1_000_000_000)
        holdActivationTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: thresholdNanoseconds)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                self?.promoteToHoldIfNeeded(generation: targetGeneration)
            }
        }
    }

    private func promoteToHoldIfNeeded(generation: Int) {
        guard let delegate else { return }
        guard self.generation == generation else { return }
        guard isPressed else { return }
        guard mode == .pendingStartPress else { return }
        guard delegate.currentDictationState == .listening else { return }

        mode = .hold
        delegate.hotkeyControllerSetShowsHoldIndicator(true)
    }

    private func cancelHoldActivation() {
        holdActivationTask?.cancel()
        holdActivationTask = nil
    }
}
