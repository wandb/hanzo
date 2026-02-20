import SwiftUI

struct OnboardingContainerView: View {
    @State private var currentStep = Self.initialStep()
    var onComplete: () -> Void

    private static let totalSteps = 4

    private static func initialStep() -> Int {
        let permissions = PermissionService.shared
        if !permissions.hasMicrophonePermission { return 0 }
        if !permissions.hasAccessibilityPermission { return 1 }
        return 2
    }

    var body: some View {
        VStack(spacing: 0) {
            // Progress indicator
            HStack(spacing: 8) {
                ForEach(0..<Self.totalSteps, id: \.self) { step in
                    Circle()
                        .fill(step <= currentStep ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 8, height: 8)
                }
            }
            .padding(.top, 20)

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
                APIKeyStep {
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
        .frame(width: 480, height: 340)
    }
}
