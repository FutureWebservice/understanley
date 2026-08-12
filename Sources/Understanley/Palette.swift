import SwiftUI

/// Layout constants shared by both renderers. Values match upstream's ELK
/// configuration so a graph reads at the same scale in either tool.
enum GraphLayout {
    static let nodeWidth: Double = 280
    /// Shorter than upstream's 120. A card shows a type line, a name and at
    /// most two lines of summary; the rest was empty gutter, and vertical
    /// gutter is what pushes a whole-project fit past the zoom where the text
    /// becomes legible.
    static let nodeHeight: Double = 104
    static let interLayerSpacing: Double = 80
    /// Tightened from 60. Gutter was 44% of the Blueprint's total area on a
    /// typical project, which is area not spent on the cards themselves.
    static let nodeSpacing: Double = 42
}

/// Derives every colour in the Universe view.
///
/// The rule is that no hue is ever hand-picked — each one is computed from
/// something true about the node. That is what keeps "colour variety" from
/// becoming noise: a reader learns the mapping in about a minute and then reads
/// structure directly off the picture.
///
///   layer      → hue family (golden-angle spaced, so any number of layers
///                stays maximally separated and adding one never recolours the
///                others)
///   node type  → ±12° shift inside that family
///   complexity → brightness and radius
///   edges      → gradient from source hue to target hue, so a cross-layer
///                dependency literally shows as one colour bleeding into
///                another
enum Palette {
    /// The golden angle. Successive multiples land as far from every previous
    /// value as possible, which is exactly the property a categorical palette
    /// needs — and unlike an evenly-divided wheel, it does not need to know how
    /// many categories there will be.
    static let goldenAngle: Float = 137.507_764

    static func layerHue(_ ordinal: Int) -> Float {
        // Offset so the first layer lands on the product's warm gold rather
        // than on red.
        (38 + Float(ordinal) * goldenAngle).truncatingRemainder(dividingBy: 360)
    }

    /// Per-type offset within a layer's family. Small enough that a layer still
    /// reads as one constellation, large enough to separate a file from a
    /// function inside it.
    static func nodeHue(layerHue: Float, type: NodeType) -> Float {
        let shift: Float
        switch type {
        case .file, .document, .config: shift = 0
        case .function, .step: shift = 12
        case .class, .component, .schema: shift = -12
        case .service, .resource, .pipeline: shift = 24
        case .table, .endpoint: shift = -24
        default: shift = 6
        }
        var hue = layerHue + shift
        if hue < 0 { hue += 360 }
        return hue.truncatingRemainder(dividingBy: 360)
    }

    static func brightness(for complexity: Complexity) -> Float {
        switch complexity {
        case .simple: return 0.62
        case .moderate: return 0.80
        case .complex: return 1.0
        }
    }

    /// Body radius from connection degree. Square-rooted so a node with 100
    /// connections is visibly a hub without being 100× the area of a leaf.
    static func radius(degree: Int) -> Float {
        min(28, 4 + sqrt(Float(degree)) * 3)
    }

    /// Universe body colour.
    static func color(hue: Float, brightness: Float, saturation: Float = 0.62,
                      opacity: Double = 1) -> Color {
        Color(hue: Double(hue) / 360, saturation: Double(saturation),
              brightness: Double(brightness), opacity: opacity)
    }

    /// Deep-space background. Not flat black: a very slight vertical gradient
    /// gives the field depth before a single star is drawn.
    static let spaceTop = Color(hex: 0x0A0A12)
    static let spaceBottom = Color(hex: 0x050508)
}

// MARK: - Level of detail

/// What to draw at the current zoom.
///
/// The ladder is what makes 10 000 nodes viable: at low zoom the frame cost is
/// a few thousand cached sprites and nothing else, and detail arrives only when
/// there is room on screen to read it.
/// What fits on a Blueprint card at a given on-screen size.
///
/// Split out from the renderer so the thresholds can be asserted rather than
/// eyeballed. The bug this replaces was invisible in code review and obvious on
/// screen: every card on a small project rendered as an empty rectangle,
/// because the gate was the camera zoom rather than how big the card actually
/// ended up. A card is legible when *it* is big enough — the zoom number that
/// produced it is beside the point.
struct CardLayout: Sendable, Equatable {
    /// Point size for the node name, already clamped to a readable range.
    var nameSize: CGFloat
    var showsName: Bool
    var showsType: Bool
    var showsSummary: Bool
    var showsComplexityChip: Bool
    var showsTestedDot: Bool
    /// Characters of the name that fit across the card.
    var nameBudget: Int

    static func forCard(width: CGFloat, height: CGFloat, hasSummary: Bool,
                        isComplex: Bool, isTested: Bool) -> CardLayout {
        var out = CardLayout(nameSize: 0, showsName: false, showsType: false,
                             showsSummary: false, showsComplexityChip: false,
                             showsTestedDot: false, nameBudget: 0)
        guard width > 34, height > 14 else { return out }

        // Clamped UP to 9pt. Sizing purely in proportion to the card is what
        // blanked everything: at a whole-project fit a card is ~73x31pt, and
        // 0.155 of that height is 4.8pt.
        let nameSize = min(15, max(9, height * 0.155))
        guard height >= nameSize * 1.35 else { return out }

        let inset = max(3, width * 0.035)
        let available = width - (inset + width * 0.02) - inset

        out.nameSize = nameSize
        out.showsName = true
        // 0.55em is a fair average advance for the system font here. Erring
        // narrow is right: an overflowing name paints over its neighbour.
        out.nameBudget = max(3, Int(available / (nameSize * 0.55)))
        // Stated as heights, because that is what they actually reduce to. The
        // type line is drawn at 0.68 of the name, so demanding it be legible
        // (>= 7.5pt) already implies a card taller than 70 — an extra
        // `height > 46` test read like a second, looser gate and was dead.
        out.showsType = height > 70
        // Spaced away from the type threshold so detail arrives one line at a
        // time rather than two lines appearing together.
        out.showsSummary = height > 92 && hasSummary
        out.showsComplexityChip = out.showsType && width > 96 && isComplex
        out.showsTestedDot = isTested && width > 60
        return out
    }
}

struct LODLevel: Sendable {
    var drawEdges: Bool
    var drawEdgeGradients: Bool
    var drawCores: Bool
    var drawLabels: Bool
    var labelOpacity: Double

    static func forZoom(_ zoom: Double) -> LODLevel {
        LODLevel(
            drawEdges: zoom > 0.06,
            // Gradient strokes are the single most expensive per-edge cost;
            // below this zoom the two endpoint hues are a pixel apart anyway.
            drawEdgeGradients: zoom > 0.3,
            drawCores: zoom > 0.22,
            // Universe labels only — Blueprint draws its names inside the card,
            // gated on the card's on-screen size instead of this number.
            drawLabels: zoom > 0.35,
            labelOpacity: min(1, max(0, (zoom - 0.35) / 0.3))
        )
    }
}
