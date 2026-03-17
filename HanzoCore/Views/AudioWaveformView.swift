import SwiftUI

struct AudioWaveformView: View {
    let appState: AppState

    private let totalBars = 72
    private let innerRadius: CGFloat = 10
    private let minBarLength: CGFloat = 1.5
    private let maxBarExtension: CGFloat = 3.45
    private let volumeBoost: CGFloat = 2.25
    private let barWidth: CGFloat = 1.5
    private let baseOpacity = 0.3
    private let radiusGrow: CGFloat = 0.25
    private let colorSpeed: Double = 0.04
    private let decayRate: CGFloat = 1.0
    private let glowThreshold: CGFloat = 0.35
    private let volExpand: CGFloat = 0.30
    private let glowExpand: CGFloat = 0.35
    private let glowPow: CGFloat = 0.6
    private let normalizeThreshold: Float = 0.08
    private let size: CGFloat = 66
    private let forgingRetractDuration: Double = 0.9
    private let forgingPulseSpeed: Double = 0.78
    private let forgingTargetRadius: CGFloat = 6.2

    private let harmonics: [(freq: Double, speed: Double, amp: Double)] = [
        (2, 0.8, 0.35),
        (3, -1.0, 0.25),
        (5, 0.55, 0.10),
    ]

    @State private var smoothedVolume: CGFloat = 0
    @State private var smoothedRadiusVolume: CGFloat = 0
    @State private var lastTime: TimeInterval = 0
    @State private var forgingStartTime: TimeInterval?
    @State private var forgingProgress: CGFloat = 0
    @State private var frozenForgingVolume: CGFloat = 0
    @State private var frozenForgingRadiusVolume: CGFloat = 0
    @State private var frozenForgingColorPhase: Double = 0

    var body: some View {
        TimelineView(.animation) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            let isForging = appState.dictationState == .forging

            Canvas { ctx, canvasSize in
                let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
                if isForging {
                    drawForgingState(context: ctx, center: center, time: time)
                } else {
                    drawListeningState(context: ctx, center: center, time: time)
                }
            }
            .frame(width: size, height: size)
            .onChange(of: time) {
                updateSmoothedVolume(time: time)
                updateForgingTransition(time: time)
            }
        }
        .onChange(of: appState.dictationState) { _, newState in
            if newState == .forging {
                beginForgingTransition()
            } else {
                resetForgingTransition()
            }
        }
        .frame(height: size)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Drawing

    private func drawListeningState(context ctx: GraphicsContext, center: CGPoint, time: TimeInterval) {
        let vol = smoothedVolume
        let amp = maxBarExtension + vol * volumeBoost
        let radius = innerRadius * (1 + smoothedRadiusVolume * radiusGrow)

        let colorPhase = (time * colorSpeed).truncatingRemainder(dividingBy: 1.0)
        let color = listeningColor(atPhase: colorPhase)

        for i in 0..<totalBars {
            let angle = (CGFloat(i) / CGFloat(totalBars)) * 2 * .pi - .pi / 2
            let noise = harmonicNoise(
                angle: Double(i) / Double(totalBars) * 2 * .pi,
                time: time
            )
            let extension_ = CGFloat(noise + 1) * 0.5
            let glow = max(0, (extension_ - glowThreshold) / (1 - glowThreshold))
            let barLength = (minBarLength + extension_ * amp) * (1 + vol * volExpand + glow * vol * glowExpand)

            let intensity = pow(glow * vol, glowPow)
            let opacity = baseOpacity + (1.0 - baseOpacity) * intensity

            let start = CGPoint(
                x: center.x + radius * cos(angle),
                y: center.y + radius * sin(angle)
            )
            let end = CGPoint(
                x: center.x + (radius + barLength) * cos(angle),
                y: center.y + (radius + barLength) * sin(angle)
            )

            var path = Path()
            path.move(to: start)
            path.addLine(to: end)

            ctx.stroke(
                path,
                with: .color(color.opacity(opacity)),
                style: StrokeStyle(lineWidth: barWidth, lineCap: .round)
            )
        }
    }

    private func drawForgingState(context ctx: GraphicsContext, center: CGPoint, time: TimeInterval) {
        let retract = smoothstep(forgingProgress)
        let sessionElapsed = max(0, time - (forgingStartTime ?? time))
        let pulse = 0.5 + 0.5 * sin(sessionElapsed * forgingPulseSpeed * 2 * .pi)
        let vol = frozenForgingVolume
        let amp = maxBarExtension + vol * volumeBoost
        let baseRadius = innerRadius * (1 + frozenForgingRadiusVolume * radiusGrow)
        let barColor = listeningColor(atPhase: frozenForgingColorPhase)

        for i in 0..<totalBars {
            let angle = (CGFloat(i) / CGFloat(totalBars)) * 2 * .pi - .pi / 2
            let noise = harmonicNoise(
                angle: Double(i) / Double(totalBars) * 2 * .pi,
                time: forgingStartTime ?? time
            )
            let extension_ = CGFloat(noise + 1) * 0.5
            let glow = max(0, (extension_ - glowThreshold) / (1 - glowThreshold))
            let originalLength = (minBarLength + extension_ * amp) * (1 + vol * volExpand + glow * vol * glowExpand)

            let startRadius = lerp(baseRadius, forgingTargetRadius, retract)
            let endRadius = lerp(baseRadius + originalLength, forgingTargetRadius, retract)
            guard endRadius - startRadius > 0.08 else { continue }

            let intensity = pow(glow * max(vol, 0.18), glowPow)
            let opacity = (baseOpacity + (1.0 - baseOpacity) * intensity) * (1 - retract * 0.5)

            let start = CGPoint(
                x: center.x + startRadius * cos(angle),
                y: center.y + startRadius * sin(angle)
            )
            let end = CGPoint(
                x: center.x + endRadius * cos(angle),
                y: center.y + endRadius * sin(angle)
            )
            var path = Path()
            path.move(to: start)
            path.addLine(to: end)
            ctx.stroke(
                path,
                with: .color(barColor.opacity(opacity)),
                style: StrokeStyle(lineWidth: barWidth, lineCap: .round)
            )
        }

        let sphereReveal = smoothstep(max(0, (forgingProgress - 0.35) / 0.45))
        let whitening = smoothstep(max(0, (forgingProgress - 0.72) / 0.28))
        let pulseScale = 1 + 0.05 * whitening * CGFloat(pulse)
        let sphereDiameter = forgingTargetRadius * 2 * pulseScale
        let sphereRect = CGRect(
            x: center.x - sphereDiameter / 2,
            y: center.y - sphereDiameter / 2,
            width: sphereDiameter,
            height: sphereDiameter
        )
        let spherePath = Path(ellipseIn: sphereRect)

        // Keep the collapsed bar color visible first, then bias toward white.
        ctx.fill(
            spherePath,
            with: .color(barColor.opacity(0.34 * sphereReveal * (1 - whitening * 0.35)))
        )
        ctx.fill(
            spherePath,
            with: .color(
                Color.white.opacity((0.08 + 0.42 * whitening) * sphereReveal * (0.88 + 0.12 * pulse))
            )
        )
        ctx.stroke(
            spherePath,
            with: .color(Color.white.opacity(0.05 + 0.12 * whitening)),
            style: StrokeStyle(lineWidth: 0.8)
        )
    }

    // MARK: - Smoothed Volume

    private func updateSmoothedVolume(time: TimeInterval) {
        let dt = lastTime > 0 ? min(time - lastTime, 0.1) : 0
        lastTime = time

        let currentVolume = overallVolume
        if currentVolume > smoothedVolume {
            smoothedVolume = smoothedVolume + (currentVolume - smoothedVolume) * min(CGFloat(dt) * 8, 1)
        } else {
            smoothedVolume = max(0, smoothedVolume - CGFloat(dt) * decayRate)
        }

        // Slow average for radius — gentle rise and fall
        let radiusRate = CGFloat(dt) * 1.2
        smoothedRadiusVolume += (currentVolume - smoothedRadiusVolume) * min(radiusRate, 1)
    }

    private var overallVolume: CGFloat {
        let levels = appState.audioLevels
        guard !levels.isEmpty else { return 0 }
        let avg = levels.reduce(0, +) / Float(levels.count)
        let normalized = min(avg / normalizeThreshold, 1.0)
        return CGFloat(sqrt(normalized))
    }

    // MARK: - Noise

    private func harmonicNoise(angle: Double, time: Double) -> Double {
        var value = 0.0
        for h in harmonics {
            value += sin(h.freq * angle + h.speed * time) * h.amp
        }
        return value
    }

    private func beginForgingTransition() {
        forgingStartTime = lastTime > 0 ? lastTime : nil
        forgingProgress = 0
        frozenForgingVolume = smoothedVolume
        frozenForgingRadiusVolume = smoothedRadiusVolume
        frozenForgingColorPhase = lastTime > 0 ? (lastTime * colorSpeed).truncatingRemainder(dividingBy: 1.0) : 0
    }

    private func resetForgingTransition() {
        forgingStartTime = nil
        forgingProgress = 0
    }

    private func updateForgingTransition(time: TimeInterval) {
        guard appState.dictationState == .forging else { return }
        if forgingStartTime == nil {
            forgingStartTime = time
        }
        guard let start = forgingStartTime else { return }
        let elapsed = max(0, time - start)
        forgingProgress = min(CGFloat(elapsed / forgingRetractDuration), 1)
    }

    private func listeningColor(atPhase phase: Double) -> Color {
        let cycle = phase.truncatingRemainder(dividingBy: 1.0)
        let whitePortion = 0.12
        let saturation: Double
        let hue: Double
        if cycle < whitePortion {
            let whiteT = (0.5 - abs(cycle / whitePortion - 0.5)) * 2
            hue = 0.0
            saturation = 0.85 * (1 - whiteT)
        } else {
            hue = (cycle - whitePortion) / (1 - whitePortion)
            let blueDist = min(abs(hue - 0.67), abs(hue - 0.67 + 1), abs(hue - 0.67 - 1))
            let brightBoost = max(0, 1 - blueDist / 0.15)
            saturation = 0.85 - brightBoost * 0.45
        }
        return Color(hue: hue, saturation: saturation, brightness: 1.0)
    }

    private func lerp(_ start: CGFloat, _ end: CGFloat, _ t: CGFloat) -> CGFloat {
        start + (end - start) * t
    }

    private func smoothstep(_ value: CGFloat) -> CGFloat {
        let t = min(max(value, 0), 1)
        return t * t * (3 - 2 * t)
    }

}
