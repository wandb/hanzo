import AppKit
import SwiftUI

struct TranscriptPopover: View {
    let appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if appState.dictationState == .listening || appState.dictationState == .forging {
                AudioWaveformView(appState: appState)
            }

            if !appState.partialTranscript.isEmpty {
                Text(appState.partialTranscript)
                    .font(.system(.title3, design: .rounded, weight: .regular))
                    .lineSpacing(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        .padding()
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxHeight: 400)
        .background(
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                .clipShape(RoundedRectangle(cornerRadius: 22))
        )
        .clipShape(RoundedRectangle(cornerRadius: 22))
    }
}

// MARK: - Visual Effect Background

private struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}
