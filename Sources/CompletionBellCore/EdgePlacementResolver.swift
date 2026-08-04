import Foundation

public struct EdgeRect: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var minX: Double { x }
    public var maxX: Double { x + width }
    public var minY: Double { y }
    public var maxY: Double { y + height }
    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }
}

public struct EdgeScreenDescriptor: Equatable, Sendable {
    public let id: String
    public let frame: EdgeRect
    public let visibleFrame: EdgeRect
    public let isMain: Bool
    public let isValid: Bool
    public let safeAreaTop: Double
    public let safeAreaBottom: Double
    /// Widths of the unobstructed menu-bar areas either side of the notch.
    /// Zero on displays without one. The notch width is what's left between
    /// them — measured, not assumed.
    public let auxiliaryLeftWidth: Double
    public let auxiliaryRightWidth: Double

    public init(
        id: String,
        frame: EdgeRect,
        visibleFrame: EdgeRect,
        isMain: Bool,
        isValid: Bool = true,
        safeAreaTop: Double = 0,
        safeAreaBottom: Double = 0,
        auxiliaryLeftWidth: Double = 0,
        auxiliaryRightWidth: Double = 0
    ) {
        self.id = id
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.isMain = isMain
        self.isValid = isValid
        self.safeAreaTop = max(0, safeAreaTop)
        self.safeAreaBottom = max(0, safeAreaBottom)
        self.auxiliaryLeftWidth = max(0, auxiliaryLeftWidth)
        self.auxiliaryRightWidth = max(0, auxiliaryRightWidth)
    }

    /// Real notch width when the display reports auxiliary areas, otherwise nil.
    public var measuredNotchWidth: Double? {
        guard auxiliaryLeftWidth > 0, auxiliaryRightWidth > 0 else { return nil }
        let remainder = frame.width - auxiliaryLeftWidth - auxiliaryRightWidth
        return remainder > 0 ? remainder : nil
    }
}

public struct EdgePlacementPreference: Equatable, Sendable {
    public let screenID: String?
    public let verticalRatio: Double

    public init(screenID: String?, verticalRatio: Double) {
        self.screenID = screenID
        self.verticalRatio = verticalRatio
    }
}

public struct EdgePlacementExclusions: Equatable, Sendable {
    public let top: Double
    public let bottom: Double

    public init(top: Double = 250, bottom: Double = 100) {
        self.top = max(0, top)
        self.bottom = max(0, bottom)
    }
}

public struct EdgePlacement: Equatable, Sendable {
    public let screenID: String
    public let frame: EdgeRect
    public let verticalRatio: Double
    public let fellBackToMainScreen: Bool
    public let dockConflict: Bool
}

/// Resolves a stable screen and a safe edge frame. It also debounces display
/// notifications and ignores invalid ghost displays before AppKit repositions.
public final class EdgePlacementResolver {
    private let displayChangeDebounce: TimeInterval
    private var appliedScreenIDs: Set<String>
    private var pendingScreenIDs: Set<String>?
    private var appliedGeometryFingerprint = ""
    private var hasAppliedGeometryFingerprint = false
    private var pendingGeometryFingerprint: String?
    private var pendingSince: Date?
    private var lastNow: Date

    public var hasPendingScreenChange: Bool { pendingScreenIDs != nil }

    public init(
        initialScreenIDs: Set<String> = [],
        displayChangeDebounce: TimeInterval = 0.35,
        now: Date = Date()
    ) {
        self.appliedScreenIDs = initialScreenIDs
        self.displayChangeDebounce = displayChangeDebounce
        self.lastNow = now
    }

    public func noteScreenChange(_ screens: [EdgeScreenDescriptor], at now: Date) {
        let effectiveNow = max(lastNow, now)
        lastNow = effectiveNow
        let valid = Set(screens.filter { $0.isValid && !$0.id.isEmpty }.map(\.id))
        let fingerprint = geometryFingerprint(screens)
        if valid == appliedScreenIDs && !hasAppliedGeometryFingerprint {
            appliedGeometryFingerprint = fingerprint
            hasAppliedGeometryFingerprint = true
            return
        }
        guard valid != appliedScreenIDs || fingerprint != appliedGeometryFingerprint else {
            pendingScreenIDs = nil
            pendingSince = nil
            pendingGeometryFingerprint = nil
            return
        }
        if pendingScreenIDs != valid || pendingGeometryFingerprint != fingerprint {
            pendingScreenIDs = valid
            pendingGeometryFingerprint = fingerprint
            pendingSince = effectiveNow
        }
    }

    public func takeScreenChangeDue(at now: Date) -> Bool {
        let effectiveNow = max(lastNow, now)
        lastNow = effectiveNow
        guard let pendingScreenIDs, let pendingSince,
              effectiveNow.timeIntervalSince(pendingSince) >= displayChangeDebounce else { return false }
        appliedScreenIDs = pendingScreenIDs
        appliedGeometryFingerprint = pendingGeometryFingerprint ?? ""
        hasAppliedGeometryFingerprint = true
        self.pendingScreenIDs = nil
        self.pendingGeometryFingerprint = nil
        self.pendingSince = nil
        return true
    }

    public func resolve(
        screens: [EdgeScreenDescriptor],
        preference: EdgePlacementPreference,
        size: (width: Double, height: Double),
        exclusions: EdgePlacementExclusions = EdgePlacementExclusions(),
        tagHeight: Double = PresentationLayout.edgeTagHeight
    ) -> EdgePlacement? {
        let usable = screens.filter { !$0.id.isEmpty && $0.visibleFrame.width > 0 && $0.visibleFrame.height > 0 }
        // The isValid flag is computed AppKit-side to drop ghost displays, so
        // a misjudgement there must never leave the edge entry with nowhere to
        // go — placing it on a suspect-but-drawable screen beats vanishing.
        let valid = usable.contains(where: \.isValid) ? usable.filter(\.isValid) : usable
        guard !valid.isEmpty else { return nil }
        let preferred = preference.screenID.flatMap { id in valid.first { $0.id == id } }
        let screen = preferred ?? valid.first(where: \.isMain) ?? valid[0]
        let fallback = preference.screenID != nil && preferred == nil
        let ratio = min(1, max(0, preference.verticalRatio))
        let available = screen.visibleFrame
        let bounds = safeBounds(for: screen, exclusions: exclusions, tagHeight: tagHeight)
        let effectiveHeight = min(size.height, max(1, bounds.upper - bounds.lower))
        let effectiveWidth = min(size.width, available.width)
        let compactY = bounds.compactLower + (bounds.compactUpper - bounds.compactLower) * ratio
        let anchorCenter = compactY + tagHeight / 2
        let y = min(bounds.upper - effectiveHeight, max(bounds.lower, anchorCenter - effectiveHeight / 2))
        let rightEdge = min(screen.frame.maxX, available.maxX)
        let dockConflict = available.maxX < screen.frame.maxX - 1
        let x = min(available.maxX - effectiveWidth, max(available.minX, rightEdge - effectiveWidth))
        return EdgePlacement(
            screenID: screen.id,
            frame: EdgeRect(x: x, y: y, width: effectiveWidth, height: effectiveHeight),
            verticalRatio: ratio,
            fellBackToMainScreen: fallback,
            dockConflict: dockConflict
        )
    }

    public func verticalRatio(
        forY y: Double,
        screen: EdgeScreenDescriptor,
        height: Double,
        exclusions: EdgePlacementExclusions = EdgePlacementExclusions(),
        tagHeight: Double = PresentationLayout.edgeTagHeight
    ) -> Double {
        let bounds = safeBounds(for: screen, exclusions: exclusions, tagHeight: tagHeight)
        guard bounds.compactUpper > bounds.compactLower else { return 0.5 }
        let anchorCenter = y + height / 2
        let compactY = anchorCenter - tagHeight / 2
        return min(1, max(0, (compactY - bounds.compactLower) / (bounds.compactUpper - bounds.compactLower)))
    }

    private struct SafeBounds {
        let lower: Double
        let upper: Double
        let compactLower: Double
        let compactUpper: Double
    }

    private func safeBounds(for screen: EdgeScreenDescriptor, exclusions: EdgePlacementExclusions, tagHeight: Double) -> SafeBounds {
        let available = screen.visibleFrame
        var top = max(exclusions.top, screen.safeAreaTop)
        var bottom = max(exclusions.bottom, screen.safeAreaBottom)
        let minimumHeight = min(PresentationLayout.floatingMinimumHeight, available.height)
        var deficit = max(0, minimumHeight - (available.height - top - bottom))
        let topReduction = min(deficit, top)
        top -= topReduction
        deficit -= topReduction
        bottom = max(0, bottom - deficit)
        let lower = available.minY + bottom
        let upper = max(lower, available.maxY - top)
        return SafeBounds(
            lower: lower,
            upper: upper,
            compactLower: lower,
            compactUpper: max(lower, upper - tagHeight)
        )
    }

    private func geometryFingerprint(_ screens: [EdgeScreenDescriptor]) -> String {
        screens.filter { $0.isValid && !$0.id.isEmpty }.sorted { $0.id < $1.id }.map {
            "\($0.id):\($0.frame.x),\($0.frame.y),\($0.frame.width),\($0.frame.height):\($0.visibleFrame.x),\($0.visibleFrame.y),\($0.visibleFrame.width),\($0.visibleFrame.height):\($0.safeAreaTop),\($0.safeAreaBottom)"
        }.joined(separator: "|")
    }
}
