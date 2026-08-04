import Foundation

/// Colour data for the dark surfaces (the notch panel today). Values live in
/// Core rather than the SwiftUI palette so their contrast is a tested product
/// contract instead of something only visible by eye — dark translucent
/// surfaces are exactly where legibility quietly fails.
public enum JianlingDarkScheme {
    public static let background = 0x141311
    public static let surface = 0x1A1917
    public static let raised = 0x232120
    public static let row = 0x201E1C
    public static let rowHover = 0x2A2725

    public static let text = 0xF2EDE3
    public static let secondaryText = 0xC0B8AB
    public static let tertiaryText = 0xADA79C

    public static let accent = 0x8B88EE
    public static let running = 0xE8A055
    public static let unread = 0x7FB4F5
    public static let pending = 0xB79AE0
    public static let handled = 0x5FD199
    public static let seal = 0xE0736A

    /// The notch shell is now opaque pure black to fuse with the physical
    /// cutout, so nothing shows through. Kept at 1.0 so the worst-case pair
    /// below degenerates to the opaque tokens.
    public static let panelTintOpacity = 1.0

    /// The surface as actually rendered: the tint composited over the brightest
    /// plausible backdrop. Text has to clear AA against this, not against the
    /// opaque swatch.
    public static var worstCaseSurface: Int {
        WCAGContrast.composite(tint: surface, opacity: panelTintOpacity, over: 0xFFFFFF)
    }

    /// Every foreground token paired with the surface it is drawn on. The test
    /// walks this table, so adding a token without a pairing is a visible gap.
    public static var contrastPairs: [(name: String, foreground: Int, background: Int)] {
        [
            // Measured against the composited surface, which is what the
            // panel actually renders — the opaque swatch flatters the result.
            ("text/worstCaseSurface", text, worstCaseSurface),
            ("secondaryText/worstCaseSurface", secondaryText, worstCaseSurface),
            ("tertiaryText/worstCaseSurface", tertiaryText, worstCaseSurface),
            ("text/surface", text, surface),
            ("text/row", text, row),
            ("text/raised", text, raised),
            ("secondaryText/surface", secondaryText, surface),
            ("secondaryText/row", secondaryText, row),
            ("tertiaryText/surface", tertiaryText, surface),
            ("tertiaryText/row", tertiaryText, row),
            ("accent/surface", accent, surface),
            ("running/surface", running, surface),
            ("unread/surface", unread, surface),
            ("pending/surface", pending, surface),
            ("handled/surface", handled, surface),
            ("seal/surface", seal, surface),
        ]
    }
}

/// WCAG relative luminance and contrast ratio.
public enum WCAGContrast {
    /// Composite a translucent tint over a backdrop. The dark panel is not the
    /// opaque token — it is that token at some opacity over whatever wallpaper
    /// happens to be behind, so the worst case (a white desktop) is what the
    /// contrast contract has to survive.
    public static func composite(tint: Int, opacity: Double, over backdrop: Int) -> Int {
        let alpha = min(1, max(0, opacity))
        func blend(_ shift: Int) -> Int {
            let top = Double((tint >> shift) & 0xFF)
            let bottom = Double((backdrop >> shift) & 0xFF)
            return Int((top * alpha + bottom * (1 - alpha)).rounded())
        }
        return (blend(16) << 16) | (blend(8) << 8) | blend(0)
    }

    public static func relativeLuminance(_ rgb: Int) -> Double {
        func channel(_ raw: Int) -> Double {
            let value = Double(raw) / 255
            return value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        let r = channel((rgb >> 16) & 0xFF)
        let g = channel((rgb >> 8) & 0xFF)
        let b = channel(rgb & 0xFF)
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    public static func ratio(_ lhs: Int, _ rhs: Int) -> Double {
        let a = relativeLuminance(lhs)
        let b = relativeLuminance(rhs)
        let lighter = max(a, b)
        let darker = min(a, b)
        return (lighter + 0.05) / (darker + 0.05)
    }
}
