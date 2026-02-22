import SwiftUI

struct AudioWaveformView: View {
    let appState: AppState

    private let totalBars = 28
    private let innerRadius: CGFloat = 8
    private let minBarLength: CGFloat = 1.0
    private let maxBarExtension: CGFloat = 2.3
    private let volumeBoost: CGFloat = 1.5
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
    private let size: CGFloat = 44

    private let harmonics: [(freq: Double, speed: Double, amp: Double)] = [
        (2, 0.8, 0.35),
        (3, -1.0, 0.25),
        (5, 0.55, 0.10),
    ]

    @State private var smoothedVolume: CGFloat = 0
    @State private var smoothedRadiusVolume: CGFloat = 0
    @State private var lastTime: TimeInterval = 0

    var body: some View {
        TimelineView(.animation) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            let speed: Double = appState.dictationState == .forging ? 1.8 : 1.0

            Canvas { ctx, canvasSize in
                let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
                let vol = smoothedVolume
                let amp = maxBarExtension + vol * volumeBoost
                let radius = innerRadius * (1 + smoothedRadiusVolume * radiusGrow)
                // Cycle through hues + white; desaturate in blue/purple range
                let cycle = (time * colorSpeed).truncatingRemainder(dividingBy: 1.0)
                let whitePortion = 0.12
                let saturation: Double
                let hue: Double
                if cycle < whitePortion {
                    // Fade from color into white and back
                    let whiteT = (0.5 - abs(cycle / whitePortion - 0.5)) * 2
                    hue = 0.0
                    saturation = 0.85 * (1 - whiteT)
                } else {
                    hue = (cycle - whitePortion) / (1 - whitePortion)
                    let blueDist = min(abs(hue - 0.67), abs(hue - 0.67 + 1), abs(hue - 0.67 - 1))
                    let brightBoost = max(0, 1 - blueDist / 0.15)
                    saturation = 0.85 - brightBoost * 0.45
                }
                let color = Color(hue: hue, saturation: saturation, brightness: 1.0)

                for i in 0..<totalBars {
                    let angle = (CGFloat(i) / CGFloat(totalBars)) * 2 * .pi - .pi / 2
                    let noise = harmonicNoise(
                        angle: Double(i) / Double(totalBars) * 2 * .pi,
                        time: time * speed
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
            .frame(width: size, height: size)
            .onChange(of: time) {
                updateSmoothedVolume(time: time)
            }
        }
        .frame(height: size)
        .frame(maxWidth: .infinity)
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
}
