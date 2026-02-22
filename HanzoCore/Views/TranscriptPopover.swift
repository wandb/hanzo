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
                AnimatedTranscriptView(text: appState.partialTranscript)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.top, 16)
        .padding(.horizontal, 24)
        .padding(.bottom, appState.partialTranscript.isEmpty ? 16 : 24)
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

// MARK: - Animated Transcript

private struct AnimatedTranscriptView: View {
    let text: String
    @State private var revealedCount: Int = 0

    private var words: [String] {
        text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
    }

    var body: some View {
        WordFlowLayout(spacing: 5, lineSpacing: 6) {
            ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                Text(word)
                    .font(.system(.title3, design: .rounded, weight: .regular))
                    .contentTransition(.interpolate)
                    .animation(.easeOut(duration: 0.2), value: word)
                    .opacity(index < revealedCount ? 1.0 : 0.0)
                    .offset(y: index < revealedCount ? 0 : 4)
                    .animation(.easeOut(duration: 0.25), value: index < revealedCount)
            }
        }
        .onChange(of: words.count) { _, newCount in
            revealedCount = newCount
        }
        .onAppear {
            revealedCount = words.count
        }
    }
}

// MARK: - Word Flow Layout

private struct WordFlowLayout: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() where index < subviews.count {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                proposal: .unspecified
            )
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x - spacing)
        }

        let totalHeight = positions.isEmpty ? 0 : y + rowHeight
        return (CGSize(width: maxX, height: totalHeight), positions)
    }
}

