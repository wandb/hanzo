import SwiftUI

struct OnboardingContainerView: View {
    @State private var currentStep = Self.initialStep()
    @State private var llmCleanupTask: Task<Void, Never>?
    var appState: AppState
    var settings: AppSettingsProtocol
    var onComplete: () -> Void

    private static func initialStep() -> Int {
        let permissions = PermissionService.shared
        if !permissions.hasMicrophonePermission { return 0 }
        if !permissions.hasAccessibilityPermission { return 1 }
        return 2
    }

    private let totalSteps = 5

    var body: some View {
        VStack(spacing: 0) {
            // Progress indicator
            HStack(spacing: 8) {
                ForEach(0..<totalSteps, id: \.self) { step in
                    Circle()
                        .fill(step <= currentStep ? Color.primary : Color.primary.opacity(0.25))
                        .frame(width: 6, height: 6)
                }
            }
            .padding(.top, 24)

            Spacer()

            switch currentStep {
            case 0:
                MicPermissionStep {
                    withAnimation { currentStep = 1 }
                }
            case 1:
                AccessibilityPermissionStep {
                    withAnimation { currentStep = 2 }
                }
            case 2:
                ModelDownloadStep {
                    withAnimation { currentStep = 3 }
                }
            case 3:
                HotkeyConfirmationStep(appState: appState) {
                    withAnimation { currentStep = 4 }
                }
            case 4:
                AppCustomizationStep {
                    settings.onboardingComplete = true
                    onComplete()
                }
            default:
                EmptyView()
            }

            Spacer()
    }
        .padding(.horizontal, 24)
        .frame(width: 480, height: 380)
        .hudBackground()
        .onAppear {
            if !settings.hasConfiguredASRProvider {
                settings.asrProvider = .local
            }
            if !settings.hasConfiguredTranscriptPostProcessingMode {
                AppBehaviorSettings.setGlobalPostProcessingMode(.llm, settings: settings)
            }
            updateDictationAvailability(for: currentStep)
        }
        .onChange(of: currentStep) { _, newStep in
            updateDictationAvailability(for: newStep)
            scheduleLLMCleanupAfterDemoStepIfNeeded(for: newStep)
        }
        .onDisappear {
            llmCleanupTask?.cancel()
            llmCleanupTask = nil
            appState.allowsDictationStart = true
        }
    }

    private func scheduleLLMCleanupAfterDemoStepIfNeeded(for step: Int) {
        guard step > 3 else { return }

        llmCleanupTask?.cancel()
        llmCleanupTask = Task {
            while !Task.isCancelled {
                let dictationState = await MainActor.run { appState.dictationState }
                switch dictationState {
                case .idle, .error:
                    await LocalLLMRuntimeManager.shared.stop()
                    return
                case .listening, .forging:
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
        }
    }

    private func updateDictationAvailability(for step: Int) {
        appState.allowsDictationStart = step == 3
    }
}
