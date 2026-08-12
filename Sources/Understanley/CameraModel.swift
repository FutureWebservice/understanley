import CoreGraphics
import Foundation

/// The viewport transform: where the camera is looking and how far in.
///
/// A value type with no dependencies on SwiftUI, so it can be reasoned about
/// and tested on its own. `centre` is in world coordinates; `zoom` is a scale
/// factor where 1 means one world unit per point.
struct Camera: Sendable, Equatable {
    var centre: SIMD2<Float> = .zero
    var zoom: Double = 1

    /// Bounds chosen so the whole graph fits at the low end and a single node
    /// card fills the view at the high end.
    static let minZoom: Double = 0.02
    static let maxZoom: Double = 3

    // MARK: Transforms

    func worldToScreen(_ world: SIMD2<Float>, viewport: CGSize) -> CGPoint {
        CGPoint(
            x: (CGFloat(world.x - centre.x)) * zoom + viewport.width / 2,
            y: (CGFloat(world.y - centre.y)) * zoom + viewport.height / 2
        )
    }

    func screenToWorld(_ screen: CGPoint, viewport: CGSize) -> SIMD2<Float> {
        SIMD2(
            Float((screen.x - viewport.width / 2) / zoom) + centre.x,
            Float((screen.y - viewport.height / 2) / zoom) + centre.y
        )
    }

    /// The world rectangle currently on screen, expanded by `margin` so culling
    /// keeps partially-visible nodes and their glow halos.
    func visibleWorldRect(viewport: CGSize, margin: CGFloat = 200) -> CGRect {
        let halfWidth = viewport.width / 2 / zoom + margin
        let halfHeight = viewport.height / 2 / zoom + margin
        return CGRect(
            x: CGFloat(centre.x) - halfWidth, y: CGFloat(centre.y) - halfHeight,
            width: halfWidth * 2, height: halfHeight * 2
        )
    }

    // MARK: Movement

    /// Zooms while keeping the world point under `anchor` pinned there.
    ///
    /// Anchoring on the cursor rather than the view centre is what makes a
    /// trackpad pinch feel like manipulating the graph instead of driving a
    /// camera — you zoom into what you are pointing at.
    mutating func zoom(by factor: Double, anchor: CGPoint, viewport: CGSize) {
        let before = screenToWorld(anchor, viewport: viewport)
        zoom = min(Camera.maxZoom, max(Camera.minZoom, zoom * factor))
        let after = screenToWorld(anchor, viewport: viewport)
        centre += before - after
    }

    mutating func pan(by delta: CGSize) {
        centre -= SIMD2(Float(delta.width / zoom), Float(delta.height / zoom))
    }

    /// Frames `rect`, leaving `padding` as a fraction of the viewport.
    static func fitting(_ rect: CGRect, viewport: CGSize, padding: Double = 0.12) -> Camera {
        guard rect.width > 0, rect.height > 0, viewport.width > 0, viewport.height > 0 else {
            return Camera()
        }
        let scaleX = viewport.width / rect.width
        let scaleY = viewport.height / rect.height
        let scale = min(scaleX, scaleY) * (1 - padding)
        return Camera(
            centre: SIMD2(Float(rect.midX), Float(rect.midY)),
            zoom: min(Camera.maxZoom, max(Camera.minZoom, scale))
        )
    }

    /// Eased interpolation toward `target`.
    ///
    /// Zoom is interpolated geometrically rather than linearly: zoom is
    /// perceptually multiplicative, and a linear blend from 0.05 to 2 spends
    /// almost the whole animation looking like it has already arrived.
    func interpolated(toward target: Camera, t: Double) -> Camera {
        let eased = Camera.easeInOut(min(1, max(0, t)))
        return Camera(
            centre: centre + (target.centre - centre) * Float(eased),
            zoom: zoom * pow(target.zoom / zoom, eased)
        )
    }

    /// Smootherstep — zero first *and* second derivative at both ends, so a
    /// camera move has no visible start or stop.
    static func easeInOut(_ t: Double) -> Double {
        t * t * t * (t * (t * 6 - 15) + 10)
    }
}

/// Pan momentum, so a flick keeps gliding and settles instead of stopping dead.
struct PanMomentum: Sendable {
    private var velocity: SIMD2<Float> = .zero
    /// Per-frame retention at 60 fps. Tuned to coast for roughly half a second.
    private let friction: Float = 0.92
    private let minimumSpeed: Float = 0.5

    var isMoving: Bool {
        velocity.x * velocity.x + velocity.y * velocity.y > minimumSpeed * minimumSpeed
    }

    mutating func begin() { velocity = .zero }

    mutating func record(delta: CGSize, zoom: Double) {
        let sample = SIMD2(Float(delta.width / zoom), Float(delta.height / zoom))
        // Blended rather than replaced, so one jittery frame at the end of a
        // drag cannot fling the view.
        velocity = velocity * 0.6 + sample * 0.4
    }

    /// Advances one frame, returning the pan to apply, or nil once settled.
    mutating func step() -> SIMD2<Float>? {
        guard isMoving else {
            velocity = .zero
            return nil
        }
        let applied = velocity
        velocity *= friction
        return -applied
    }

    mutating func stop() { velocity = .zero }
}
