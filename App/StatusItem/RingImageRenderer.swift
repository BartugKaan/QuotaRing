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
/// - Fresh data: a solid arc on a solid faint track.
/// - Stale data: a dashed arc on a dashed faint track, so even an empty or nearly empty stale ring differs from a fresh
///   one.
/// - No (current) data: a dashed track alone, drawn stronger.
///
/// The standard tint stays a template image, so every variant follows a light or dark menu bar.
enum RingImageRenderer {
    static let imageSize = NSSize(width: 18, height: 18)
    static let ringDiameter: CGFloat = 14
    static let lineWidth: CGFloat = 2
    /// The number of dashes around a dashed ring. Track and arc start at 12 o'clock with the same pattern, so their
    /// dashes line up.
    private static let dashCount = 9

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
        let period = 2 * .pi * radius / CGFloat(dashCount)
        let dashes = [period * 0.45, period * 0.55]

        let track = ring(center: center, radius: radius, fraction: 1)
        track.lineWidth = lineWidth
        guard let fraction else {
            track.setLineDash(dashes, count: dashes.count, phase: 0)
            color.withAlphaComponent(0.6).setStroke()
            track.stroke()
            drawAttentionDot(in: rect, color: color, style: style)
            return
        }

        if style.isStale {
            track.setLineDash(dashes, count: dashes.count, phase: 0)
        }
        color.withAlphaComponent(style.isStale ? 0.3 : 0.25).setStroke()
        track.stroke()

        if fraction > 0 {
            let arc = ring(center: center, radius: radius, fraction: fraction)
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
        drawAttentionDot(in: rect, color: color, style: style)
    }

    /// `fraction` of a circle, from 12 o'clock clockwise.
    private static func ring(center: NSPoint, radius: CGFloat, fraction: Double) -> NSBezierPath {
        let path = NSBezierPath()
        if fraction >= 1 {
            // Two halves: a single 360° arc can collapse to nothing.
            path.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: -90, clockwise: true)
            path.appendArc(withCenter: center, radius: radius, startAngle: -90, endAngle: -270, clockwise: true)
        } else {
            path.appendArc(
                withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - 360 * CGFloat(fraction),
                clockwise: true)
        }
        return path
    }

    private static func drawAttentionDot(in rect: NSRect, color: NSColor, style: RingStyle) {
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
