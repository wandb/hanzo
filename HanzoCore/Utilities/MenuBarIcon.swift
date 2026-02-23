import AppKit

enum MenuBarIcon {
    /// Creates a radial waveform icon matching the app's visualization style.
    /// Returns a template NSImage suitable for the menu bar.
    static func radialWaveform(size: CGFloat = 18) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }

            let center = CGPoint(x: rect.midX, y: rect.midY)
            let totalBars = 24
            let innerRadius: CGFloat = 4.5
            let minBarLength: CGFloat = 1.0
            let maxBarLength: CGFloat = 3.5
            let barWidth: CGFloat = 1.2

            context.setStrokeColor(NSColor.black.cgColor)
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

        image.isTemplate = true
        return image
    }
}
