import AppKit

/// How the menu bar ring is drawn apart from its fill.
struct RingStyle: Equatable {
    enum Tint: Equatable {
        /// Template image: the menu bar picks the color.
        case standard
        /// Little left (≤ 20 % remaining): orange.
        case warning
        /// Almost nothing left (≤ 5 % remaining): red.
        case critical
    }

    var tint: Tint = .standard
    /// The data is old: the ring is drawn dashed, so it never looks like a current reading.
    var isStale = false
    /// Something needs the user's attention (for example the Live mode login expired): a small dot at the top right.
    var needsAttention = false

    /// The tint for a session with `percentRemaining` (`0...100`) left.
    static func tint(forRemaining percentRemaining: Double) -> Tint {
        if percentRemaining <= 5 { return .critical }
        if percentRemaining <= 20 { return .warning }
        return .standard
    }
}

/// Draws the menu bar ring: an 18 × 18 pt image with a 14 pt ring, 2 pt stroke and round caps. A faint full track
/// sits under an arc that starts at 12 o'clock and runs clockwise.
///
/// - Fresh data: a solid arc on the faint track.
/// - Stale data: a dashed arc on the faint track.
/// - No (current) data: a dashed track alone.
///
/// The standard tint stays a template image, so every variant follows a light or dark menu bar.
enum RingImageRenderer {
    static let imageSize = NSSize(width: 18, height: 18)
    static let ringDiameter: CGFloat = 14
    static let lineWidth: CGFloat = 2
    /// Dash and gap lengths of the dashed ring: 24 even segments around the track.
    private static let dashes: [CGFloat] = [2, 2.4]

    /// - Parameter fraction: The arc length in `0...1`, or `nil` when there is no data yet (a dashed track only).
    static func image(fraction: Double?, style: RingStyle) -> NSImage {
        let clamped = fraction.map { min(1, max(0, $0.isNaN ? 0 : $0)) }
        let image = NSImage(size: imageSize, flipped: false) { rect in
            draw(in: rect, fraction: clamped, style: style)
            return true
        }
        image.isTemplate = style.tint == .standard
        return image
    }

    private static func draw(in rect: NSRect, fraction: Double?, style: RingStyle) {
        let color: NSColor =
            switch style.tint {
            case .standard: .black
            case .warning: .systemOrange
            case .critical: .systemRed
            }
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let radius = (ringDiameter - lineWidth) / 2
        let circle = NSRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius)

        let track = NSBezierPath(ovalIn: circle)
        track.lineWidth = lineWidth
        if let fraction {
            color.withAlphaComponent(0.25).setStroke()
            track.stroke()

            if fraction > 0 {
                let arc: NSBezierPath
                if fraction >= 1 {
                    arc = NSBezierPath(ovalIn: circle)
                } else {
                    arc = NSBezierPath()
                    arc.appendArc(
                        withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - 360 * fraction,
                        clockwise: true)
                }
                arc.lineWidth = lineWidth
                if style.isStale {
                    // Butt caps keep the short dashes crisp.
                    arc.setLineDash(dashes, count: dashes.count, phase: 0)
                } else {
                    arc.lineCapStyle = .round
                }
                color.setStroke()
                arc.stroke()
            }
        } else {
            track.setLineDash(dashes, count: dashes.count, phase: 0)
            color.withAlphaComponent(0.6).setStroke()
            track.stroke()
        }

        if style.needsAttention {
            let dotCenter = NSPoint(x: rect.maxX - 3, y: rect.maxY - 3)
            // Knock out a gap around the dot so it reads as separate from the ring.
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: NSRect(x: dotCenter.x - 3.5, y: dotCenter.y - 3.5, width: 7, height: 7)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: dotCenter.x - 2.5, y: dotCenter.y - 2.5, width: 5, height: 5)).fill()
        }
    }
}
