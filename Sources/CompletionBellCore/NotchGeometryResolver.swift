import Foundation

/// What the top-of-screen host should render on a given display.
public enum NotchPresentation: Equatable, Sendable {
    /// A physical notch is present: content flanks it and expands beneath.
    case notch
    /// No notch: a floating capsule hangs just below the menu bar instead.
    case capsule
}

public struct NotchGeometry: Equatable, Sendable {
    public let screenID: String
    public let presentation: NotchPresentation
    /// The physical notch rect, empty when presenting as a capsule.
    public let notchRect: EdgeRect
    /// Fixed window frame. The host window never resizes — the shape inside it
    /// animates instead, because moving an NSWindow every frame goes through the
    /// window server and stutters, while animating content is GPU-composited.
    public let hostFrame: EdgeRect
    /// Collapsed footprint: the capsule itself, or the notch plus its flanks.
    public let collapsedRect: EdgeRect
    /// Panel that drops below the collapsed footprint.
    public let expandedRect: EdgeRect
    public let fellBackToMainScreen: Bool
}

/// Resolves the top-of-screen host's geometry from screen metrics. Pure, so the
/// notch/no-notch split, the flank budget and the multi-display fallback are all
/// testable without a Mac attached.
public struct NotchGeometryResolver: Sendable {
    /// Fallback only — the real width comes from the display's auxiliary areas.
    public static let assumedNotchWidth = 200.0
    /// Matches the physical notch's own curvature so the expanded panel reads as
    /// a continuation of it rather than a card parked underneath.
    public static let expandedTopCornerRadius = 15.0
    public static let expandedBottomCornerRadius = 20.0
    /// Bottom radius of the compact strip when it carries content — the same
    /// profile the system's volume HUD uses beside the notch.
    public static let compactCornerRadius = 11.0
    /// Concave radius where the strip's outer corners meet the screen top — the
    /// flare the volume HUD has, so the strip reads as flowing out of the menu
    /// bar instead of being stamped onto it.
    public static let compactTopFlareRadius = 8.0
    /// Width of each content slot flanking the notch in the compact state.
    public static let compactSlotWidth = 44.0
    /// Slot width sized to its content: the base slot carries the unread
    /// signal; quota pairs (runtime mark + percent) need more room. Both slots
    /// share the wider figure so the strip stays centred on the notch.
    public static func compactSlotWidth(quotaPairs: Int) -> Double {
        guard quotaPairs > 0 else { return compactSlotWidth }
        let pairs = Double(quotaPairs)
        return max(compactSlotWidth, 20 + pairs * 27 + (pairs - 1) * 7)
    }
    /// Sized to its content, not a fixed slab — a wide capsule with the items
    /// pushed to both ends reads as an unfinished layout.
    public static func capsuleWidth(quotaCount: Int, countDigits: Int) -> Double {
        let chrome = 11.0 * 2          // horizontal padding
        let seal = 17.0 + 7            // logo + gap
        let count = Double(max(1, countDigits)) * 9 + 1
        let gems = quotaCount > 0
            ? 1 + 2 + 2 + Double(quotaCount) * 31 + Double(max(0, quotaCount - 1)) * 8
            : 0
        return chrome + seal + count + gems
    }
    public static let capsuleHeight = 34.0
    public static let capsuleTopInset = 6.0

    public init() {}

    public func resolve(
        screens: [EdgeScreenDescriptor],
        preferredScreenID: String?,
        expandedSize: (width: Double, height: Double),
        notchWidthOverride: Double? = nil,
        capsuleWidth: Double = NotchGeometryResolver.capsuleWidth(quotaCount: 2, countDigits: 2),
        compactSlotWidth: Double = 0
    ) -> NotchGeometry? {
        let usable = screens.filter { !$0.id.isEmpty && $0.frame.width > 0 && $0.frame.height > 0 }
        // Mirrors the edge resolver: a mistaken validity flag must never leave
        // the host with nowhere to go.
        let valid = usable.contains(where: \.isValid) ? usable.filter(\.isValid) : usable
        guard !valid.isEmpty else { return nil }
        let preferred = preferredScreenID.flatMap { id in valid.first { $0.id == id } }
        let screen = preferred ?? valid.first(where: \.isMain) ?? valid[0]
        let fellBack = preferredScreenID != nil && preferred == nil

        // A notch shows up as a non-zero safe-area inset at the top.
        let hasNotch = screen.safeAreaTop > 0
        let frame = screen.frame
        let menuBarHeight = hasNotch ? screen.safeAreaTop : max(24, frame.maxY - screen.visibleFrame.maxY)

        guard hasNotch else {
            let width = min(capsuleWidth, frame.width - 24)
            let capsule = EdgeRect(
                x: frame.minX + (frame.width - width) / 2,
                y: frame.maxY - menuBarHeight - Self.capsuleTopInset - Self.capsuleHeight,
                width: width,
                height: Self.capsuleHeight
            )
            let panel = expanded(under: capsule, screen: screen, size: expandedSize)
            return NotchGeometry(
                screenID: screen.id,
                presentation: .capsule,
                notchRect: EdgeRect(x: 0, y: 0, width: 0, height: 0),
                hostFrame: hostFrame(for: screen, covering: [capsule, panel]),
                collapsedRect: capsule,
                expandedRect: panel,
                fellBackToMainScreen: fellBack
            )
        }

        let notchWidth = min(
            notchWidthOverride ?? screen.measuredNotchWidth ?? Self.assumedNotchWidth,
            frame.width * 0.5
        )
        let notch = EdgeRect(
            x: frame.minX + (frame.width - notchWidth) / 2,
            y: frame.maxY - menuBarHeight,
            width: notchWidth,
            height: menuBarHeight
        )
        // With nothing to report the collapsed shape IS the notch — invisible.
        // When there is something worth a glance, the same black extends one
        // small slot either side, exactly the system volume-HUD grammar.
        let slot = max(0, compactSlotWidth)
        let collapsed = EdgeRect(
            x: notch.minX - slot,
            y: notch.minY,
            width: notch.width + slot * 2,
            height: notch.height
        )
        let expandedWidth = min(expandedSize.width, frame.width - 24)
        let expandedHeight = min(expandedSize.height, max(1, notch.maxY - screen.visibleFrame.minY))
        // Top edge flush with the screen top so the shape continues the notch
        // with no seam.
        let expandedRect = EdgeRect(
            x: frame.minX + (frame.width - expandedWidth) / 2,
            y: frame.maxY - expandedHeight,
            width: expandedWidth,
            height: expandedHeight
        )
        return NotchGeometry(
            screenID: screen.id,
            presentation: .notch,
            notchRect: notch,
            hostFrame: hostFrame(for: screen, covering: [collapsed, expandedRect]),
            collapsedRect: collapsed,
            expandedRect: expandedRect,
            fellBackToMainScreen: fellBack
        )
    }

    /// One frame large enough for every state, pinned to the top of the screen.
    private func hostFrame(for screen: EdgeScreenDescriptor, covering rects: [EdgeRect]) -> EdgeRect {
        let width = min(screen.frame.width, max(rects.map(\.width).max() ?? 0, 1) + 80)
        let height = max(rects.map { screen.frame.maxY - $0.minY }.max() ?? 0, 1) + 40
        return EdgeRect(
            x: screen.frame.minX + (screen.frame.width - width) / 2,
            y: screen.frame.maxY - height,
            width: width,
            height: min(height, screen.frame.height)
        )
    }

    private func expanded(
        under collapsed: EdgeRect,
        screen: EdgeScreenDescriptor,
        size: (width: Double, height: Double)
    ) -> EdgeRect {
        let width = min(size.width, screen.frame.width - 24)
        let available = collapsed.minY - screen.visibleFrame.minY
        let height = min(size.height, max(1, available))
        return EdgeRect(
            x: screen.frame.minX + (screen.frame.width - width) / 2,
            y: collapsed.minY - height,
            width: width,
            height: height
        )
    }
}
