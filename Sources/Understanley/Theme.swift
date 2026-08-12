import SwiftUI

/// The app's visual language.
///
/// Ported from upstream's `dark-gold` preset, which is the default there and
/// the one the product is recognisable by: near-black surfaces, a warm gold
/// accent, and a colour per node type. Values are the exact hexes so a graph
/// looks the same in both tools.
enum Theme {
    // MARK: Surfaces

    static let root = Color(hex: 0x0A0A0A)
    static let surface = Color(hex: 0x111111)
    static let elevated = Color(hex: 0x1A1A1A)
    static let panel = Color(hex: 0x141414)

    // MARK: Accent

    static let accent = Color(hex: 0xD4A574)
    static let accentDim = Color(hex: 0xC9A96E)
    static let accentBright = Color(hex: 0xE8C49A)

    // MARK: Text

    static let textPrimary = Color(hex: 0xF5F0EB)
    static let textSecondary = Color(hex: 0xA39787)
    static let textMuted = Color(hex: 0x6B5F53)

    // MARK: Borders

    static let borderSubtle = Color(hex: 0xD4A574, opacity: 0.12)
    static let borderMedium = Color(hex: 0xD4A574, opacity: 0.25)

    // MARK: Status

    static let diffChanged = Color(hex: 0xE05252)
    static let diffAffected = Color(hex: 0xD4A030)
    static let tested = Color(hex: 0x5A9E6F)

    /// Colour per node type. These carry meaning — a reader learns the palette
    /// within a minute and then reads type at a glance, without labels.
    static func color(for type: NodeType) -> Color {
        switch type {
        case .file: return Color(hex: 0x4A7C9B)
        case .function: return Color(hex: 0x5A9E6F)
        case .class: return Color(hex: 0x8B6FB0)
        case .module: return Color(hex: 0xC9A06C)
        case .concept: return Color(hex: 0xB07A8A)
        case .config: return Color(hex: 0x5EEAD4)
        case .document: return Color(hex: 0x7DD3FC)
        case .service: return Color(hex: 0xA78BFA)
        case .table: return Color(hex: 0x6EE7B7)
        case .endpoint: return Color(hex: 0xFDBA74)
        case .pipeline: return Color(hex: 0xFDA4AF)
        case .schema: return Color(hex: 0xFCD34D)
        case .resource: return Color(hex: 0xA5B4FC)
        // Domain, knowledge and design types reuse the nearest code colour so
        // one palette covers every graph kind.
        case .domain: return Color(hex: 0xB07A8A)
        case .flow: return Color(hex: 0xFDA4AF)
        case .step: return Color(hex: 0x5A9E6F)
        case .article: return Color(hex: 0xD4A574)
        case .entity: return Color(hex: 0x7BA4C9)
        case .topic: return Color(hex: 0xC9B06C)
        case .claim: return Color(hex: 0x6FB07A)
        case .source: return Color(hex: 0x8A8A8A)
        case .page: return Color(hex: 0xB07A8A)
        case .screen: return Color(hex: 0xA78BFA)
        case .component: return Color(hex: 0x8B6FB0)
        case .componentSet: return Color(hex: 0xC9A06C)
        case .instance: return Color(hex: 0x5A9E6F)
        case .token: return Color(hex: 0x5EEAD4)
        }
    }


    static func color(for complexity: Complexity) -> Color {
        switch complexity {
        case .simple: return Color(hex: 0x5A9E6F)
        case .moderate: return accentDim
        case .complex: return Color(hex: 0xC97070)
        }
    }
}

extension Color {
    /// Builds a colour from a packed 0xRRGGBB literal.
    ///
    /// Taking an integer rather than a string keeps the palette checkable at
    /// compile time — a typo in a hex literal is a compiler error, not a
    /// silently black swatch.
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}
