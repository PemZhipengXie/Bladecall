import AppKit
import JianlingShared
import CompletionBellCore
import SwiftUI

enum JianlingAppearance: String, CaseIterable, Identifiable {
    case modern
    case pixel

    var id: String { rawValue }
    func label(language: JianlingLanguage) -> String {
        self == .modern ? language.text("现代", "Modern") : language.text("像素", "Pixel")
    }
}

enum CompletionNoticeStyle: String, CaseIterable, Identifiable {
    case quiet
    case chime

    var id: String { rawValue }
    func label(language: JianlingLanguage) -> String {
        self == .quiet ? language.text("静默", "Quiet") : language.text("剑鸣", "Sword sounds")
    }
}

struct JianlingPalette {
    let background: Color
    let surface: Color
    let raised: Color
    let row: Color
    let rowHover: Color
    let text: Color
    let secondaryText: Color
    let tertiaryText: Color
    let line: Color
    let accent: Color
    let running: Color
    let unread: Color
    let pending: Color
    let handled: Color
    let seal: Color
    /// Quota gem bands. Orange/vermilion reuse the existing running/seal
    /// tokens; jade comes from the handled green. Only 「秋金」 is new.
    let quotaFull: Color
    let quotaGood: Color
    let quotaLow: Color
    let quotaCritical: Color
    let edgeSurface: Color
    let edgeText: Color
    let cornerLarge: CGFloat
    let cornerMedium: CGFloat
    let cornerSmall: CGFloat

    init(_ appearance: JianlingAppearance, colorScheme: ColorScheme = .light) {
        if colorScheme == .dark {
            background = Color(rgb: UInt(JianlingDarkScheme.background))
            surface = Color(rgb: UInt(JianlingDarkScheme.surface))
            raised = Color(rgb: UInt(JianlingDarkScheme.raised))
            row = Color(rgb: UInt(JianlingDarkScheme.row))
            rowHover = Color(rgb: UInt(JianlingDarkScheme.rowHover))
            text = Color(rgb: UInt(JianlingDarkScheme.text))
            secondaryText = Color(rgb: UInt(JianlingDarkScheme.secondaryText))
            tertiaryText = Color(rgb: UInt(JianlingDarkScheme.tertiaryText))
            line = Color(rgb: UInt(JianlingDarkScheme.secondaryText)).opacity(0.18)
            accent = Color(rgb: UInt(JianlingDarkScheme.accent))
            running = Color(rgb: UInt(JianlingDarkScheme.running))
            unread = Color(rgb: UInt(JianlingDarkScheme.unread))
            pending = Color(rgb: UInt(JianlingDarkScheme.pending))
            handled = Color(rgb: UInt(JianlingDarkScheme.handled))
            seal = Color(rgb: UInt(JianlingDarkScheme.seal))
            quotaFull = Color(rgb: 0x54B87E)
            quotaGood = Color(rgb: 0xD6A93F)
            quotaLow = Color(rgb: 0xE08B3E)
            quotaCritical = Color(rgb: 0xD65F52)
            edgeSurface = Color(rgb: UInt(JianlingDarkScheme.background))
            edgeText = Color(rgb: UInt(JianlingDarkScheme.text))
            cornerLarge = appearance == .pixel ? 0 : 20
            cornerMedium = appearance == .pixel ? 0 : 11
            cornerSmall = appearance == .pixel ? 0 : 8
            return
        }
        switch appearance {
        case .modern:
            background = Color(rgb: 0xE9EBF0)
            surface = Color(rgb: 0xFBFBFD)
            raised = .white
            row = Color(rgb: 0xF1F2F6)
            rowHover = Color(rgb: 0xE9EAF0)
            text = Color(rgb: 0x1F2026)
            secondaryText = Color(rgb: 0x63656F)
            tertiaryText = Color(rgb: 0x92949D)
            line = Color.black.opacity(0.11)
            accent = Color(rgb: 0x5B58D7)
            running = Color(rgb: 0xDF8A26)
            unread = Color(rgb: 0x3979DA)
            pending = Color(rgb: 0x8A63BD)
            handled = Color(rgb: 0x299963)
            seal = Color(rgb: 0xA43135)
            // Tuned toward macOS semantic hues rather than poster colours:
            // less chroma, closer value, so four gems can sit together without
            // one of them shouting. 「秋金」 loses the muddy green cast.
            quotaFull = Color(rgb: 0x54B87E)
            quotaGood = Color(rgb: 0xD6A93F)
            quotaLow = Color(rgb: 0xE08B3E)
            quotaCritical = Color(rgb: 0xD65F52)
            edgeSurface = Color(rgb: 0x222126)
            edgeText = .white
            cornerLarge = 20
            cornerMedium = 11
            cornerSmall = 8
        case .pixel:
            background = Color(rgb: 0xEFE4C8)
            surface = Color(rgb: 0xF7EBCF)
            raised = Color(rgb: 0xFFF8EA)
            row = Color(rgb: 0xF1E4C5)
            rowHover = Color(rgb: 0xE8D8B4)
            text = Color(rgb: 0x211813)
            secondaryText = Color(rgb: 0x655345)
            tertiaryText = Color(rgb: 0x95816C)
            line = Color(rgb: 0x463629).opacity(0.25)
            accent = Color(rgb: 0x7C1F24)
            running = Color(rgb: 0xD27B1F)
            unread = Color(rgb: 0x2E70C8)
            pending = Color(rgb: 0x6A4A9A)
            handled = Color(rgb: 0x238A55)
            seal = Color(rgb: 0xA72E2F)
            quotaFull = Color(rgb: 0x66C48C)
            quotaGood = Color(rgb: 0xD8BE55)
            quotaLow = Color(rgb: 0xE59A4A)
            quotaCritical = Color(rgb: 0xD9584C)
            edgeSurface = Color(rgb: 0x211813)
            edgeText = Color(rgb: 0xFFF3D9)
            cornerLarge = 0
            cornerMedium = 0
            cornerSmall = 0
        }
    }
}

extension JianlingPalette {
    func quotaColor(_ tier: QuotaTier) -> Color {
        switch tier {
        case .full: return quotaFull
        case .good: return quotaGood
        case .low: return quotaLow
        case .critical: return quotaCritical
        }
    }
}

/// Faceted gem silhouette. The upper facet is lit and the lower one shaded so
/// the shape reads as cut stone rather than a flat polygon at 18pt.
struct GemShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width, h = rect.height
        path.move(to: CGPoint(x: w * 0.5, y: 0))
        path.addLine(to: CGPoint(x: w * 0.9, y: h * 0.26))
        path.addLine(to: CGPoint(x: w * 0.9, y: h * 0.74))
        path.addLine(to: CGPoint(x: w * 0.5, y: h))
        path.addLine(to: CGPoint(x: w * 0.1, y: h * 0.74))
        path.addLine(to: CGPoint(x: w * 0.1, y: h * 0.26))
        path.closeSubpath()
        return path
    }
}

struct GemTopFacet: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width, h = rect.height
        path.move(to: CGPoint(x: w * 0.5, y: 0))
        path.addLine(to: CGPoint(x: w * 0.9, y: h * 0.26))
        path.addLine(to: CGPoint(x: w * 0.5, y: h * 0.46))
        path.addLine(to: CGPoint(x: w * 0.1, y: h * 0.26))
        path.closeSubpath()
        return path
    }
}

struct GemBottomFacet: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width, h = rect.height
        path.move(to: CGPoint(x: w * 0.1, y: h * 0.74))
        path.addLine(to: CGPoint(x: w * 0.5, y: h * 0.46))
        path.addLine(to: CGPoint(x: w * 0.9, y: h * 0.74))
        path.addLine(to: CGPoint(x: w * 0.5, y: h))
        path.closeSubpath()
        return path
    }
}

enum AppAssets {
    static func resourceURL(relativePath: String) -> URL? {
        var bundles = [Bundle.main]
#if SWIFT_PACKAGE
        bundles.append(Bundle.module)
#endif
        for bundle in bundles {
            guard let root = bundle.resourceURL else { continue }
            let url = root.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    static func image(relativePath: String) -> NSImage? {
        guard let url = resourceURL(relativePath: relativePath) else { return nil }
        return NSImage(contentsOf: url)
    }

    static var productLogo: NSImage? {
        image(relativePath: "logo-huashu.svg")
    }

    /// Menu-bar icon rasterized from the SVG logo via a drawing-handler
    /// image: NSStatusBarButton renders it through a plain bitmap path at
    /// the right backing scale, avoiding the SVG-rep edge cases that can
    /// leave the status item blank.
    static var statusBarIcon: NSImage? {
        guard let base = productLogo else { return nil }
        let icon = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            base.draw(in: rect)
            return true
        }
        icon.isTemplate = false
        return icon
    }

    static func runtimeLogo(_ assetName: String) -> NSImage? {
        image(relativePath: "Runtimes/\(assetName)")
    }
}

struct JianlingSeal: View {
    let size: CGFloat

    var body: some View {
        Group {
            if let image = AppAssets.productLogo {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
            } else {
                ZStack {
                    Rectangle().fill(Color(rgb: 0xA6282A))
                    Text("令")
                        .font(.custom("STKaiti", size: size * 0.58))
                        .foregroundStyle(Color(rgb: 0xFFF3D9))
                }
            }
        }
        .frame(width: size, height: size)
    }
}

struct RuntimeLogo: View {
    let assetName: String
    let size: CGFloat
    let appearance: JianlingAppearance
    @Environment(\.colorScheme) private var colorScheme

    private var palette: JianlingPalette { JianlingPalette(appearance, colorScheme: colorScheme) }

    var body: some View {
        Group {
            if let image = AppAssets.runtimeLogo(assetName) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Image(systemName: "terminal.fill")
                    .resizable()
                    .scaledToFit()
                    .padding(size * 0.2)
                    .foregroundStyle(palette.secondaryText)
                    .background(palette.row)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: appearance == .pixel ? 0 : size * 0.2))
    }
}

extension Color {
    init(rgb: UInt, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255,
            opacity: alpha
        )
    }
}

private struct JianlingFontScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

extension EnvironmentValues {
    var jianlingFontScale: CGFloat {
        get { self[JianlingFontScaleKey.self] }
        set { self[JianlingFontScaleKey.self] = newValue }
    }
}

private struct JianlingFontModifier: ViewModifier {
    let appearance: JianlingAppearance
    let size: CGFloat
    let weight: Font.Weight
    @Environment(\.jianlingFontScale) private var fontScale

    @ViewBuilder
    func body(content: Content) -> some View {
        let scaledSize = size * fontScale
        if appearance == .pixel {
            content.font(.system(size: scaledSize, weight: weight, design: .monospaced))
        } else {
            content.font(.system(size: scaledSize, weight: weight, design: .default))
        }
    }
}

extension View {
    func jianlingFont(_ appearance: JianlingAppearance, size: CGFloat, weight: Font.Weight = .regular) -> some View {
        modifier(JianlingFontModifier(appearance: appearance, size: size, weight: weight))
    }

    func jianlingFontScale(_ scale: Double) -> some View {
        environment(\.jianlingFontScale, CGFloat(min(1.25, max(0.85, scale))))
    }
}
