import AppKit
import Testing

@MainActor
@Suite struct RingStyleTests {
    @Test func theTintFollowsWhatIsLeft() {
        #expect(RingStyle.tint(forRemaining: 100) == .standard)
        #expect(RingStyle.tint(forRemaining: 50) == .standard)
        #expect(RingStyle.tint(forRemaining: 20.5) == .standard)
        #expect(RingStyle.tint(forRemaining: 20) == .warning)
        #expect(RingStyle.tint(forRemaining: 10) == .warning)
        #expect(RingStyle.tint(forRemaining: 5.5) == .warning)
        #expect(RingStyle.tint(forRemaining: 5) == .critical)
        #expect(RingStyle.tint(forRemaining: 0) == .critical)
        #expect(RingStyle.tint(forRemaining: -3) == .critical)
    }

    @Test func aPlainStyleIsFreshStandardAndNeedsNothing() {
        let style = RingStyle()
        #expect(style.tint == .standard)
        #expect(!style.isStale)
        #expect(!style.needsAttention)
    }
}

/// Draws the ring into a bitmap of its own (2 pixels per point) so that tests can look at pixels.
@MainActor
private struct Raster {
    static let scale = 2

    let bitmap: NSBitmapImageRep

    init(_ image: NSImage) throws {
        let side = Int(RingImageRenderer.imageSize.width) * Self.scale
        let bitmap = try #require(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        // The size in points makes the context draw at 2 pixels per point.
        bitmap.size = RingImageRenderer.imageSize
        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(
            in: NSRect(origin: .zero, size: RingImageRenderer.imageSize), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        self.bitmap = bitmap
    }

    /// The pixel `(x, y)` in points from the top left corner of the image.
    func color(x: Double, y: Double) -> NSColor {
        let pixelX = Int(x * Double(Self.scale))
        let pixelY = Int(y * Double(Self.scale))
        return bitmap.colorAt(x: pixelX, y: pixelY) ?? .clear
    }

    func alpha(x: Double, y: Double) -> Double {
        Double(color(x: x, y: y).alphaComponent)
    }

    /// The sum of every pixel's opacity: how much ink there is.
    var ink: Double {
        var total = 0.0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                total += Double(bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0)
            }
        }
        return total
    }

    var bytes: Data {
        bitmap.representation(using: .tiff, properties: [:]) ?? Data()
    }

    // Points of the ring, from the top left of the 18 x 18 image: it is centred, 6 points from the centre.
    static let top = (x: 9.0, y: 3.0)
    static let right = (x: 15.0, y: 9.0)
    static let bottom = (x: 9.0, y: 15.0)
    static let left = (x: 3.0, y: 9.0)
    /// The middle of the dot that marks "needs attention", at the top right.
    static let dot = (x: 15.0, y: 3.0)
    static let center = (x: 9.0, y: 9.0)
}

/// Values a bug upstream could hand to the renderer: none of them may crash it or draw outside the image.
private let hardFractions: [Double?] = [
    nil, 0, 0.0001, 0.25, 0.5, 0.9999, 1, Double.nan, -1, -0.0001, 1.0001, 2, 100, Double.infinity,
    -Double.infinity, Double.greatestFiniteMagnitude, -Double.greatestFiniteMagnitude,
    Double.leastNonzeroMagnitude,
]

@MainActor
@Suite struct RingImageRendererTests {
    private static let styles: [RingStyle] = [.standard, .warning, .critical].flatMap { tint in
        [false, true].flatMap { stale in
            [false, true].map { attention in
                RingStyle(tint: tint, isStale: stale, needsAttention: attention)
            }
        }
    }

    // MARK: - Size and template flag

    @Test func theImageIsEighteenPointsSquare() {
        let image = RingImageRenderer.image(fraction: 0.5, style: RingStyle())
        #expect(image.size == NSSize(width: 18, height: 18))
        #expect(RingImageRenderer.imageSize == NSSize(width: 18, height: 18))
        #expect(RingImageRenderer.ringDiameter == 14)
        #expect(RingImageRenderer.lineWidth == 2)
    }

    @Test func onlyTheStandardTintIsATemplateImage() {
        for stale in [false, true] {
            for attention in [false, true] {
                for fraction: Double? in [nil, 0, 0.5, 1] {
                    func image(_ tint: RingStyle.Tint) -> NSImage {
                        RingImageRenderer.image(
                            fraction: fraction, style: RingStyle(tint: tint, isStale: stale, needsAttention: attention))
                    }
                    #expect(image(.standard).isTemplate)
                    #expect(!image(.warning).isTemplate)
                    #expect(!image(.critical).isTemplate)
                }
            }
        }
    }

    // MARK: - Odd fractions

    @Test(arguments: hardFractions)
    func noFractionCrashesOrDrawsOutsideTheImage(fraction: Double?) throws {
        for style in Self.styles {
            let image = RingImageRenderer.image(fraction: fraction, style: style)
            #expect(image.size == RingImageRenderer.imageSize)
            let raster = try Raster(image)
            // It drew something, and the middle of the ring stays empty.
            #expect(raster.ink > 0)
            #expect(raster.alpha(x: Raster.center.x, y: Raster.center.y) == 0)
        }
    }

    @Test func notANumberDrawsLikeNothingUsed() throws {
        let style = RingStyle()
        let empty = try Raster(RingImageRenderer.image(fraction: 0, style: style)).bytes
        #expect(try Raster(RingImageRenderer.image(fraction: .nan, style: style)).bytes == empty)
    }

    @Test func fractionsOutsideZeroToOneAreClamped() throws {
        let style = RingStyle()
        let empty = try Raster(RingImageRenderer.image(fraction: 0, style: style)).bytes
        let full = try Raster(RingImageRenderer.image(fraction: 1, style: style)).bytes
        let belowZero: [Double] = [-0.0001, -1, -Double.infinity, -Double.greatestFiniteMagnitude]
        let aboveOne: [Double] = [1.0001, 2, 100, Double.infinity, Double.greatestFiniteMagnitude]
        for below in belowZero {
            #expect(try Raster(RingImageRenderer.image(fraction: below, style: style)).bytes == empty)
        }
        for above in aboveOne {
            #expect(try Raster(RingImageRenderer.image(fraction: above, style: style)).bytes == full)
        }
        #expect(empty != full)
    }

    // MARK: - What the picture shows

    @Test func theArcStartsAtTwelveOClockAndRunsClockwise() throws {
        let style = RingStyle()
        let track = try Raster(RingImageRenderer.image(fraction: 0, style: style))
        // Nothing used: only the faint track.
        for point in [Raster.top, Raster.right, Raster.bottom, Raster.left] {
            let alpha = track.alpha(x: point.x, y: point.y)
            #expect(alpha > 0.1 && alpha < 0.5, "track at \(point) has opacity \(alpha)")
        }

        // 40 percent: past twelve and three o'clock, not yet at six or nine.
        let some = try Raster(RingImageRenderer.image(fraction: 0.4, style: style))
        #expect(some.alpha(x: Raster.top.x, y: Raster.top.y) > 0.9)
        #expect(some.alpha(x: Raster.right.x, y: Raster.right.y) > 0.9)
        #expect(some.alpha(x: Raster.bottom.x, y: Raster.bottom.y) < 0.5)
        #expect(some.alpha(x: Raster.left.x, y: Raster.left.y) < 0.5)

        // 90 percent: all the way round to just before twelve.
        let most = try Raster(RingImageRenderer.image(fraction: 0.9, style: style))
        for point in [Raster.top, Raster.right, Raster.bottom, Raster.left] {
            #expect(most.alpha(x: point.x, y: point.y) > 0.9, "arc missing at \(point)")
        }
    }

    @Test func aFullRingIsClosed() throws {
        let full = try Raster(RingImageRenderer.image(fraction: 1, style: RingStyle()))
        for point in [Raster.top, Raster.right, Raster.bottom, Raster.left] {
            #expect(full.alpha(x: point.x, y: point.y) > 0.9, "gap at \(point)")
        }
    }

    @Test func moreUsedMeansMoreInk() throws {
        let style = RingStyle()
        let inks = try [0.0, 0.1, 0.3, 0.6, 1.0].map {
            try Raster(RingImageRenderer.image(fraction: $0, style: style)).ink
        }
        for (smaller, larger) in zip(inks, inks.dropFirst()) {
            #expect(smaller < larger)
        }
    }

    @Test func noDataIsNotTheSamePictureAsNothingUsed() throws {
        let style = RingStyle()
        let noData = try Raster(RingImageRenderer.image(fraction: nil, style: style))
        let empty = try Raster(RingImageRenderer.image(fraction: 0, style: style))
        #expect(noData.bytes != empty.bytes)
        // A dashed track drawn stronger: gaps between dashes, but darker dashes than the faint solid track.
        #expect(noData.ink > 0)
    }

    @Test func staleDataIsDrawnDashed() throws {
        for fraction: Double in [0, 0.5, 1] {
            let fresh = try Raster(RingImageRenderer.image(fraction: fraction, style: RingStyle()))
            let stale = try Raster(RingImageRenderer.image(fraction: fraction, style: RingStyle(isStale: true)))
            #expect(fresh.bytes != stale.bytes, "stale looks like fresh at \(fraction)")
            #expect(stale.ink < fresh.ink)
        }
    }

    @Test func theAttentionDotAppearsAtTheTopRightOnly() throws {
        for fraction: Double? in [nil, 0, 0.5, 1] {
            let plain = try Raster(RingImageRenderer.image(fraction: fraction, style: RingStyle()))
            let flagged = try Raster(
                RingImageRenderer.image(fraction: fraction, style: RingStyle(needsAttention: true)))
            #expect(plain.alpha(x: Raster.dot.x, y: Raster.dot.y) == 0)
            #expect(flagged.alpha(x: Raster.dot.x, y: Raster.dot.y) > 0.9)
            #expect(plain.bytes != flagged.bytes)
            // The bottom of the ring is left alone.
            #expect(
                plain.alpha(x: Raster.bottom.x, y: Raster.bottom.y)
                    == flagged.alpha(x: Raster.bottom.x, y: Raster.bottom.y))
        }
    }

    @Test func theTintDecidesTheColor() throws {
        func topColor(_ tint: RingStyle.Tint) throws -> NSColor {
            let raster = try Raster(RingImageRenderer.image(fraction: 1, style: RingStyle(tint: tint)))
            return raster.color(x: Raster.top.x, y: Raster.top.y).usingColorSpace(.deviceRGB) ?? .clear
        }
        let standard = try topColor(.standard)
        #expect(standard.redComponent < 0.1 && standard.greenComponent < 0.1 && standard.blueComponent < 0.1)

        let warning = try topColor(.warning)
        #expect(warning.redComponent > 0.8 && warning.greenComponent > 0.3 && warning.blueComponent < 0.3)

        let critical = try topColor(.critical)
        #expect(critical.redComponent > 0.8 && critical.greenComponent < 0.4 && critical.blueComponent < 0.4)
    }
}
