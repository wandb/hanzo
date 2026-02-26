import AppKit
import SwiftUI

struct TranscriptPopover: View {
    let appState: AppState
    var onSettingsChanged: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if appState.dictationState == .error, let message = appState.errorMessage {
                Text(message)
                    .font(.system(.caption, design: .rounded, weight: .medium))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if !appState.partialTranscript.isEmpty {
                AnimatedTranscriptView(text: appState.partialTranscript)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if appState.dictationState == .listening || appState.dictationState == .forging {
                ZStack {
                    AudioWaveformView(appState: appState)
                        .frame(maxWidth: .infinity, alignment: .center)

                    StatusFooterView(appState: appState, onSettingsChanged: onSettingsChanged)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
        .padding(.top, appState.partialTranscript.isEmpty ? 16 : 24)
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxHeight: 400)
        .background(
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                .clipShape(RoundedRectangle(cornerRadius: 22))
        )
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .preferredColorScheme(appState.preferredColorScheme)
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

// MARK: - Status Footer

private struct StatusFooterView: View {
    let appState: AppState
    var onSettingsChanged: (() -> Void)?

    private let silenceSteps: [Double] = [0, 1, 2, 3, 5]

    var body: some View {
        HStack(spacing: 0) {
            // Silence timeout control
            Button {
                cycleSilenceTimeout()
            } label: {
                Text(silenceLabel)
                    .font(.system(.caption2, design: .rounded))
                    .foregroundStyle(.primary.opacity(appState.silenceTimeout > 0 ? 0.5 : 0.25))
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .pillTooltip("Silence timer")
            .accessibilityLabel("Silence timer")

            Text(" · ")
                .font(.system(.caption2, design: .rounded))
                .foregroundStyle(.primary.opacity(0.2))

            // Auto-submit control
            Button {
                cycleAutoSubmit()
            } label: {
                Text(autoSubmitLabel)
                    .font(.system(.caption2, design: .rounded))
                    .foregroundStyle(.primary.opacity(appState.autoSubmitMode != .off ? 0.5 : 0.25))
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .pillTooltip("Auto submit")
            .accessibilityLabel("Auto submit")
        }
    }

    private var silenceLabel: String {
        if appState.silenceTimeout > 0 {
            let s = appState.silenceTimeout.truncatingRemainder(dividingBy: 1) == 0
                ? "\(Int(appState.silenceTimeout))s"
                : "\(appState.silenceTimeout)s"
            return "⏱ \(s)"
        }
        return "⏱ off"
    }

    private var autoSubmitLabel: String {
        switch appState.autoSubmitMode {
        case .enter: return "↩ enter"
        case .cmdEnter: return "↩ ⌘enter"
        case .off: return "↩ off"
        }
    }

    private func cycleSilenceTimeout() {
        let currentIndex = silenceSteps.firstIndex(of: appState.silenceTimeout) ?? 0
        let nextIndex = (currentIndex + 1) % silenceSteps.count
        let newValue = silenceSteps[nextIndex]
        appState.silenceTimeout = newValue
        UserDefaults.standard.set(newValue, forKey: Constants.silenceTimeoutKey)
        onSettingsChanged?()
    }

    private func cycleAutoSubmit() {
        let modes: [AutoSubmitMode] = [.off, .enter, .cmdEnter]
        let currentIndex = modes.firstIndex(of: appState.autoSubmitMode) ?? 0
        let nextIndex = (currentIndex + 1) % modes.count
        let newMode = modes[nextIndex]
        appState.autoSubmitMode = newMode
        UserDefaults.standard.set(newMode.rawValue, forKey: Constants.autoSubmitKey)
        onSettingsChanged?()
    }
}

// MARK: - Pill Tooltip

private struct PillTooltipModifier: ViewModifier {
    let text: String
    @State private var isHovering = false
    @State private var showTooltip = false

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                isHovering = hovering
                if hovering {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        if isHovering { showTooltip = true }
                    }
                } else {
                    showTooltip = false
                }
            }
            .overlay(alignment: .top) {
                if showTooltip {
                    Text(text)
                        .font(.system(.caption2, design: .rounded))
                        .foregroundStyle(.primary.opacity(0.7))
                        .fixedSize()
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.primary.opacity(0.1))
                        .clipShape(Capsule())
                        .allowsHitTesting(false)
                        .offset(y: -22)
                        .transition(.opacity)
                        .animation(.easeInOut(duration: 0.15), value: showTooltip)
                }
            }
    }
}

private extension View {
    func pillTooltip(_ text: String) -> some View {
        modifier(PillTooltipModifier(text: text))
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
