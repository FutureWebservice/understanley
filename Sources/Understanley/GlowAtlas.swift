import AppKit
import SwiftUI

/// Pre-rendered radial glow sprites.
///
/// A node in Universe is a halo plus a core. Resolving a `RadialGradient` per
/// node per frame is the single most expensive thing the renderer could do —
/// thousands of gradient evaluations every frame, all of them identical. So
/// each glow is rasterised once into a small bitmap and thereafter drawn as an
/// image, which is a blit.
///
/// Sprites are keyed by hue bucket and size bucket rather than exact values:
/// 24 hues × 4 sizes is 96 bitmaps, a rounding nobody can see, and it turns an
/// unbounded cache into a fixed one.
@MainActor
final class GlowAtlas {
    static let shared = GlowAtlas()

    /// 15° per bucket. Fine enough that adjacent layers stay distinguishable,
    /// coarse enough to keep the atlas small — and to let the edge renderer
    /// batch every edge into one path per bucket.
    static let hueBucketCount = 24
    private static let sizeBuckets: [CGFloat] = [16, 32, 64, 128]

    private var cache: [Int: Image] = [:]

    private init() {}

    /// A glow sprite for the given hue and radius.
    ///
    /// The returned image is `sizeBucket` points square with the glow centred;
    /// callers scale it to the radius they actually want.
    func glow(hue: Float, bucket: Int) -> Image {
        let hueBucket = Self.hueBucket(hue)
        let key = hueBucket * 100 + bucket
        if let cached = cache[key] { return cached }

        let side = Self.sizeBuckets[min(bucket, Self.sizeBuckets.count - 1)]
        let image = Self.render(hueBucket: hueBucket, side: side)
        cache[key] = image
        return image
    }

    /// Which size bucket a radius belongs to. Larger bodies get more pixels so
    /// their halo does not look soft when scaled up.
    static func bucket(forRadius radius: CGFloat) -> Int {
        switch radius {
        case ..<10: return 0
        case ..<22: return 1
        case ..<48: return 2
        default: return 3
        }
    }

    static func hueBucket(_ hue: Float) -> Int {
        let normalised = ((hue.truncatingRemainder(dividingBy: 360)) + 360)
            .truncatingRemainder(dividingBy: 360)
        return Int(normalised / Float(360 / hueBucketCount)) % hueBucketCount
    }

    static func hue(forBucket bucket: Int) -> Double {
        Double(bucket) * (360 / Double(hueBucketCount))
    }

    private static func render(hueBucket: Int, side: CGFloat) -> Image {
        let hue = hue(forBucket: hueBucket) / 360
        let pixels = Int(side)
        let nsImage = NSImage(size: CGSize(width: side, height: side))
        nsImage.lockFocus()

        if let context = NSGraphicsContext.current?.cgContext {
            context.clear(CGRect(x: 0, y: 0, width: side, height: side))

            // A four-stop falloff rather than a linear one. A plain
            // centre-to-edge ramp reads as a flat disc; concentrating opacity
            // near the middle and letting the tail run long is what makes it
            // read as emitted light.
            let colours = [
                NSColor(hue: hue, saturation: 0.35, brightness: 1.0, alpha: 0.95).cgColor,
                NSColor(hue: hue, saturation: 0.70, brightness: 0.95, alpha: 0.45).cgColor,
                NSColor(hue: hue, saturation: 0.85, brightness: 0.75, alpha: 0.14).cgColor,
                NSColor(hue: hue, saturation: 0.90, brightness: 0.60, alpha: 0.0).cgColor,
            ] as CFArray

            if let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: colours,
                locations: [0.0, 0.22, 0.55, 1.0]
            ) {
                let centre = CGPoint(x: side / 2, y: side / 2)
                context.drawRadialGradient(
                    gradient,
                    startCenter: centre, startRadius: 0,
                    endCenter: centre, endRadius: side / 2,
                    options: []
                )
            }
        }
        nsImage.unlockFocus()
        _ = pixels
        return Image(nsImage: nsImage)
    }
}

// MARK: - Starfield

/// The parallax backdrop.
///
/// Procedural and seeded, so it is identical every frame and every launch —
/// a starfield that resampled would shimmer, which is far more distracting
/// than no starfield at all. Stars live in their own coordinate space and are
/// drawn with a fraction of the camera's translation, which is what produces
/// depth when you pan.
struct Starfield: Sendable {
    struct Star: Sendable {
        var position: SIMD2<Float>
        var radius: Float
        var opacity: Double
    }

    /// One entry per depth plane, far to near.
    struct Plane: Sendable {
        var parallax: Float
        var stars: [Star]
    }

    let planes: [Plane]
    /// Side length of the tile that repeats as you pan.
    let tileSize: Float

    static let shared = Starfield()

    init(tileSize: Float = 2600) {
        self.tileSize = tileSize
        // Two planes is enough to sell depth; a third costs frames for an
        // effect nobody consciously notices.
        planes = [
            Plane(parallax: 0.10, stars: Self.generate(count: 260, seed: 0x5EED_1, tile: tileSize,
                                                       radius: 0.6...1.1, opacity: 0.18...0.42)),
            Plane(parallax: 0.35, stars: Self.generate(count: 130, seed: 0x5EED_2, tile: tileSize,
                                                       radius: 0.9...1.8, opacity: 0.25...0.60)),
        ]
    }

    /// Deterministic star placement from a linear congruential generator.
    /// Seeded rather than `Double.random` so the field never changes.
    private static func generate(
        count: Int, seed: UInt64, tile: Float,
        radius: ClosedRange<Float>, opacity: ClosedRange<Double>
    ) -> [Star] {
        var state = seed
        func next() -> Float {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float((state >> 33) % 1_000_000) / 1_000_000
        }
        return (0..<count).map { _ in
            Star(
                position: SIMD2(next() * tile, next() * tile),
                radius: radius.lowerBound + next() * (radius.upperBound - radius.lowerBound),
                opacity: opacity.lowerBound
                    + Double(next()) * (opacity.upperBound - opacity.lowerBound)
            )
        }
    }
}
