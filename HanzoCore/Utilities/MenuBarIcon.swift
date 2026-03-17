import AppKit

enum MenuBarIcon {
    /// Creates a radial waveform icon matching the app's visualization style.
    static func radialWaveform(
        size: CGFloat = 18,
        strokeColor: NSColor = .black,
        isTemplate: Bool = true
    ) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }

            let center = CGPoint(x: rect.midX, y: rect.midY)
            let totalBars = 24
            let innerRadius: CGFloat = size * 0.23
            let minBarLength: CGFloat = size * 0.08
            let maxBarLength: CGFloat = size * 0.24
            let barWidth: CGFloat = size * 0.085

            context.setStrokeColor(strokeColor.cgColor)
            context.setLineCap(.round)
            context.setLineWidth(barWidth)

            // Same harmonic frequencies as AudioWaveformView for a matching organic pattern
            let harmonics: [(freq: Double, amp: Double, phase: Double)] = [
                (2, 0.35, 0.0),
                (3, 0.25, 0.5),
                (5, 0.10, 1.2),
            ]

            for i in 0..<totalBars {
                let angle = (CGFloat(i) / CGFloat(totalBars)) * 2 * .pi - .pi / 2
                let normalizedAngle = Double(i) / Double(totalBars) * 2 * .pi

                var noise = 0.0
                for h in harmonics {
                    noise += sin(h.freq * normalizedAngle + h.phase) * h.amp
                }
                let extension_ = CGFloat(noise + 1) * 0.5
                let barLength = minBarLength + extension_ * (maxBarLength - minBarLength)

                let start = CGPoint(
                    x: center.x + innerRadius * cos(angle),
                    y: center.y + innerRadius * sin(angle)
                )
                let end = CGPoint(
                    x: center.x + (innerRadius + barLength) * cos(angle),
                    y: center.y + (innerRadius + barLength) * sin(angle)
                )

                context.move(to: start)
                context.addLine(to: end)
            }

            context.strokePath()
            return true
        }

        image.isTemplate = isTemplate
        return image
    }
}
