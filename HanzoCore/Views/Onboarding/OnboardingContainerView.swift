import SwiftUI

struct OnboardingContainerView: View {
    @State private var currentStep = Self.initialStep()
    var onComplete: () -> Void

    private static func initialStep() -> Int {
        let permissions = PermissionService.shared
        if !permissions.hasMicrophonePermission { return 0 }
        if !permissions.hasAccessibilityPermission { return 1 }
        return 2
    }

    private let totalSteps = 4

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
                HotkeyConfirmationStep {
                    UserDefaults.standard.set(true, forKey: Constants.onboardingCompleteKey)
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
            UserDefaults.standard.set(ASRProvider.hosted.rawValue, forKey: Constants.asrProviderKey)
            if UserDefaults.standard.string(forKey: Constants.localServerEndpointKey) == nil {
                UserDefaults.standard.set(
                    Constants.defaultLocalServerEndpoint,
                    forKey: Constants.localServerEndpointKey
                )
            }
            if UserDefaults.standard.string(forKey: Constants.localASRModelPresetKey) == nil {
                UserDefaults.standard.set(
                    Constants.defaultLocalASRModelPreset.rawValue,
                    forKey: Constants.localASRModelPresetKey
                )
            }
        }
    }
}
