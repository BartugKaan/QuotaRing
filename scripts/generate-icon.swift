// generate-icon.swift: draws the QuotaRing app icon and writes it as a macOS AppIcon set.
//
// What it draws (one vector drawing on a 1024 x 1024 canvas, following Apple's macOS icon grid):
//   - an 824 x 824 "squircle" body (a superellipse, which matches the corner shape of macOS icons) on a deep
//     navy/indigo vertical gradient, with a soft drop shadow, a faint sheen and a thin top highlight;
//   - a thick progress ring in the centre: a dim full track plus a bright arc that covers 72 % of the circle,
//     starting at 12 o'clock and running clockwise, with round caps. The arc fades from teal to electric blue
//     along its length and carries a soft glow and a small bright dot at its end.
// Renderings of 32 px or less (icon_16x16, icon_16x16@2x and icon_32x32) use a simplified variant of the same
// drawing: no shadow, sheen, glow or dot, a larger body and a thicker ring, so the icon stays legible in lists.
//
// Output: icon_16x16.png ... icon_512x512@2x.png (the ten files macOS expects) plus a matching Contents.json.
// The drawing uses only CoreGraphics and ImageIO and is deterministic: the same toolchain produces the same
// bytes on every run.
//
// Regenerate the committed icon from the repository root with:
//
//     swift scripts/generate-icon.swift App/Resources/Assets.xcassets/AppIcon.appiconset
//
// The 512 px README preview (docs/images/app-icon.png) is a copy of icon_512x512.png.

import CoreGraphics
import Foundation
import ImageIO

// MARK: - Colors

struct RGB {
    var red: Double
    var green: Double
    var blue: Double

    init(_ hex: UInt32) {
        red = Double((hex >> 16) & 0xFF) / 255
        green = Double((hex >> 8) & 0xFF) / 255
        blue = Double(hex & 0xFF) / 255
    }

    init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// Linear interpolation in sRGB; `t` is clamped to 0...1.
    func mixed(with other: RGB, _ t: Double) -> RGB {
        let u = min(max(t, 0), 1)
        return RGB(
            red: red + (other.red - red) * u,
            green: green + (other.green - green) * u,
            blue: blue + (other.blue - blue) * u)
    }
}

enum Palette {
    static let bodyTop = RGB(0x202D52)
    static let bodyBottom = RGB(0x121829)
    static let arcStart = RGB(0x2EE6C5)  // teal, at 12 o'clock
    static let arcEnd = RGB(0x3D7BFF)  // electric blue, at the end of the arc
    static let glow = RGB(0x2F8CFF)
    static let track = RGB(0xA9BCFF)  // pale blue, drawn translucent
    static let white = RGB(0xFFFFFF)
    static let black = RGB(0x000000)
}

// MARK: - Style

/// Everything that differs between the detailed and the compact rendering. All values are in canvas units (1024).
struct Style {
    var inset: Double  // distance between the canvas edge and the body
    var ringRadius: Double  // radius of the ring's centre line
    var ringWidth: Double
    var trackAlpha: Double
    var detailed: Bool  // drop shadow, sheen, top highlight, glow and end dot

    static let canvas = 1024.0
    static let progress = 0.72  // share of the ring that is filled
    static let squircleExponent = 5.0  // 5 approximates the macOS icon shape (corner radius of about 185)

    static func forPixelSize(_ pixels: Int) -> Style {
        if pixels <= 32 {
            return Style(inset: 52, ringRadius: 276, ringWidth: 158, trackAlpha: 0.22, detailed: false)
        }
        return Style(inset: 100, ringRadius: 258, ringWidth: 112, trackAlpha: 0.11, detailed: true)
    }
}

// MARK: - Renderer

struct IconRenderer {
    let space: CGColorSpace
    let style: Style
    let scale: Double  // pixels per canvas unit

    private var center: CGPoint { CGPoint(x: Style.canvas / 2, y: Style.canvas / 2) }
    private var bodyRect: CGRect {
        CGRect(
            x: style.inset, y: style.inset, width: Style.canvas - 2 * style.inset,
            height: Style.canvas - 2 * style.inset)
    }
    // Angles are mathematical (y up): 12 o'clock is pi/2 and the arc runs clockwise, i.e. towards smaller angles.
    private var startAngle: Double { .pi / 2 }
    private var sweep: Double { 2 * .pi * Style.progress }
    private var endAngle: Double { startAngle - sweep }

    func cgColor(_ color: RGB, _ alpha: Double = 1) -> CGColor {
        CGColor(colorSpace: space, components: [color.red, color.green, color.blue, alpha].map { CGFloat($0) })
            ?? CGColor(gray: 0, alpha: alpha)
    }

    func gradient(_ stops: [(RGB, Double)]) -> CGGradient? {
        CGGradient(
            colorsSpace: space,
            colors: stops.map { cgColor($0.0, $0.1) } as CFArray,
            locations: nil)
    }

    func render(pixels: Int) -> CGImage? {
        guard
            let ctx = CGContext(
                data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.setAllowsAntialiasing(true)
        ctx.setShouldAntialias(true)
        ctx.interpolationQuality = .high
        ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale))

        let body = squircle(in: bodyRect)
        if style.detailed {
            drawDropShadow(ctx, body: body)
        }
        drawBody(ctx, body: body)
        drawRing(ctx)
        return ctx.makeImage()
    }

    // MARK: Body

    /// A superellipse |x/a|^n + |y/b|^n = 1 sampled in polar form, which keeps the sampling dense enough everywhere.
    func squircle(in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        let a = Double(rect.width) / 2
        let b = Double(rect.height) / 2
        let n = Style.squircleExponent
        let segments = 2880
        for i in 0..<segments {
            let theta = 2 * Double.pi * Double(i) / Double(segments)
            let c = abs(cos(theta)) / a
            let s = abs(sin(theta)) / b
            let r = pow(pow(c, n) + pow(s, n), -1 / n)
            let point = CGPoint(x: Double(rect.midX) + r * cos(theta), y: Double(rect.midY) + r * sin(theta))
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }

    private func drawDropShadow(_ ctx: CGContext, body: CGPath) {
        let s = scale
        // A wide, soft shadow plus a tight contact shadow, as on system icons.
        for (offset, blur, alpha) in [(-16.0, 34.0, 0.40), (-4.0, 9.0, 0.30)] {
            ctx.saveGState()
            ctx.setShadow(
                offset: CGSize(width: 0, height: offset * s), blur: CGFloat(blur * s),
                color: cgColor(Palette.black, alpha))
            ctx.setFillColor(cgColor(Palette.bodyBottom))
            ctx.addPath(body)
            ctx.fillPath()
            ctx.restoreGState()
        }
    }

    private func drawBody(_ ctx: CGContext, body: CGPath) {
        let rect = bodyRect
        ctx.saveGState()
        ctx.addPath(body)
        ctx.clip()

        if let fill = gradient([(Palette.bodyTop, 1), (Palette.bodyBottom, 1)]) {
            ctx.drawLinearGradient(
                fill, start: CGPoint(x: 0, y: rect.maxY), end: CGPoint(x: 0, y: rect.minY), options: [])
        }

        if style.detailed {
            // Cool glow behind the ring.
            if let glow = gradient([(Palette.glow, 0.20), (Palette.glow, 0)]) {
                ctx.drawRadialGradient(
                    glow, startCenter: CGPoint(x: center.x, y: center.y + 30), startRadius: 0,
                    endCenter: CGPoint(x: center.x, y: center.y + 30), endRadius: 400, options: [])
            }
            // Faint sheen over the upper half.
            if let sheen = gradient([(Palette.white, 0.075), (Palette.white, 0)]) {
                ctx.drawLinearGradient(
                    sheen, start: CGPoint(x: 0, y: rect.maxY), end: CGPoint(x: 0, y: rect.midY + 40), options: [])
            }
            // Thin highlight along the top edge, fading out towards the sides and the bottom.
            ctx.saveGState()
            ctx.addPath(body)
            ctx.setLineWidth(5)
            ctx.replacePathWithStrokedPath()
            ctx.clip()
            if let edge = gradient([(Palette.white, 0.38), (Palette.white, 0.04), (Palette.white, 0)]) {
                ctx.drawLinearGradient(
                    edge, start: CGPoint(x: 0, y: rect.maxY), end: CGPoint(x: 0, y: rect.minY), options: [])
            }
            ctx.restoreGState()
        }
        ctx.restoreGState()
    }

    // MARK: Ring

    private func arcPath() -> CGPath {
        let path = CGMutablePath()
        path.addArc(
            center: center, radius: CGFloat(style.ringRadius), startAngle: CGFloat(startAngle),
            endAngle: CGFloat(endAngle), clockwise: true)
        return path
    }

    private func arcColor(at t: Double) -> RGB {
        Palette.arcStart.mixed(with: Palette.arcEnd, t)
    }

    private func drawRing(_ ctx: CGContext) {
        let radius = style.ringRadius
        let width = style.ringWidth

        // Track.
        ctx.saveGState()
        ctx.setStrokeColor(cgColor(Palette.track, style.trackAlpha))
        ctx.setLineWidth(CGFloat(width))
        ctx.strokeEllipse(
            in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        ctx.restoreGState()

        // Glow under the arc.
        if style.detailed {
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: CGFloat(44 * scale), color: cgColor(Palette.glow, 0.55))
            ctx.addPath(arcPath())
            ctx.setStrokeColor(cgColor(arcColor(at: 0.7)))
            ctx.setLineWidth(CGFloat(width))
            ctx.setLineCap(.round)
            ctx.strokePath()
            ctx.restoreGState()
        }

        // The arc itself: clip to the stroked arc, then paint an angular gradient as thin wedges.
        ctx.saveGState()
        ctx.addPath(arcPath())
        ctx.setLineWidth(CGFloat(width))
        ctx.setLineCap(.round)
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        paintAngularGradient(ctx)

        if style.detailed {
            // Tube shading across the stroke: a soft light on the outer edge, a slight shade on the inner edge.
            if let shade = gradient([
                (Palette.black, 0.14), (Palette.black, 0), (Palette.white, 0), (Palette.white, 0.22),
            ]) {
                ctx.drawRadialGradient(
                    shade, startCenter: center, startRadius: CGFloat(radius - width / 2), endCenter: center,
                    endRadius: CGFloat(radius + width / 2), options: [])
            }
        }
        ctx.restoreGState()

        // Bright dot at the end of the arc.
        if style.detailed {
            let dot = CGPoint(
                x: Double(center.x) + radius * cos(endAngle), y: Double(center.y) + radius * sin(endAngle))
            let dotRadius = width * 0.19
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: CGFloat(16 * scale), color: cgColor(Palette.white, 0.85))
            ctx.setFillColor(cgColor(Palette.white, 0.96))
            ctx.fillEllipse(
                in: CGRect(x: dot.x - dotRadius, y: dot.y - dotRadius, width: dotRadius * 2, height: dotRadius * 2))
            ctx.restoreGState()
        }
    }

    /// Fills the current clip with a teal-to-blue gradient that follows the arc. CoreGraphics only offers axial and
    /// radial gradients on the macOS versions this script supports, so the sweep is painted as half-degree wedges
    /// that overlap their successors; later wedges cover the anti-aliased edge of earlier ones, so no seams show.
    private func paintAngularGradient(_ ctx: CGContext) {
        let capAngle = style.ringWidth / 2 / style.ringRadius + 0.05  // the round caps reach past the arc ends
        let from = startAngle + capAngle
        let to = endAngle - capAngle
        let total = from - to
        let steps = Int((total * 180 / .pi) * 2)
        let reach = Style.canvas  // far enough to cover the whole ring
        let overlap = 0.004

        for i in 0..<steps {
            let a0 = from - total * Double(i) / Double(steps)
            let a1 = from - total * Double(i + 1) / Double(steps) - overlap
            let angleMid = (a0 + a1) / 2
            let t = (startAngle - angleMid) / sweep  // 0 at the start of the arc, 1 at its end
            ctx.setFillColor(cgColor(arcColor(at: t)))
            ctx.move(to: center)
            ctx.addLine(to: CGPoint(x: Double(center.x) + reach * cos(a0), y: Double(center.y) + reach * sin(a0)))
            ctx.addLine(to: CGPoint(x: Double(center.x) + reach * cos(a1), y: Double(center.y) + reach * sin(a1)))
            ctx.closePath()
            ctx.fillPath()
        }
    }
}

// MARK: - Output

struct IconFile {
    let points: Int
    let scale: Int

    var pixels: Int { points * scale }
    var name: String { "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png" }
}

let iconFiles: [IconFile] = [16, 32, 128, 256, 512].flatMap { points in
    [IconFile(points: points, scale: 1), IconFile(points: points, scale: 2)]
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("generate-icon: \(message)\n".utf8))
    exit(1)
}

func writePNG(_ image: CGImage, to url: URL) {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        fail("cannot create \(url.path)")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fail("cannot write \(url.path)") }
}

func contentsJSON() throws -> Data {
    let images: [[String: String]] = iconFiles.map {
        [
            "filename": $0.name,
            "idiom": "mac",
            "scale": "\($0.scale)x",
            "size": "\($0.points)x\($0.points)",
        ]
    }
    let root: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
    var data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    data.append(Data("\n".utf8))
    return data
}

func main() {
    let arguments = CommandLine.arguments
    guard arguments.count == 2 else {
        fail("usage: swift scripts/generate-icon.swift <output .appiconset directory>")
    }
    let outputDirectory = URL(fileURLWithPath: arguments[1], isDirectory: true)
    guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { fail("sRGB color space is unavailable") }

    do {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    } catch {
        fail("cannot create \(outputDirectory.path): \(error.localizedDescription)")
    }

    var rendered: [Int: CGImage] = [:]  // 16@2x and 32@1x share one 32 px rendering
    for file in iconFiles {
        if rendered[file.pixels] == nil {
            let renderer = IconRenderer(
                space: space, style: Style.forPixelSize(file.pixels), scale: Double(file.pixels) / Style.canvas)
            guard let image = renderer.render(pixels: file.pixels) else { fail("cannot render \(file.pixels) px") }
            rendered[file.pixels] = image
        }
        if let image = rendered[file.pixels] {
            writePNG(image, to: outputDirectory.appendingPathComponent(file.name))
        }
    }

    do {
        try contentsJSON().write(to: outputDirectory.appendingPathComponent("Contents.json"), options: .atomic)
    } catch {
        fail("cannot write Contents.json: \(error.localizedDescription)")
    }
}

main()
