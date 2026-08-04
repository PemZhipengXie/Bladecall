import Foundation

/// The user's persisted primary host choice. Rendering surfaces are modeled
/// separately because the menu popover is not a primary host.
public enum PresentationMode: String, Codable, CaseIterable, Sendable {
    case floating
    case notch
    case rightEdge
}

public enum InboxSurface: String, CaseIterable, Sendable {
    case menu
    case floating
    case notchExpanded
    case edgeExpanded
}

public struct SurfaceChromePolicy: Equatable, Sendable {
    public let showsHeader: Bool
    public let showsSummary: Bool
    public let showsEnergy: Bool
    public let showsFooter: Bool

    public init(surface: InboxSurface) {
        showsHeader = true
        showsSummary = true
        showsEnergy = surface != .notchExpanded
        showsFooter = true
    }
}

/// One source for sizes shared by SwiftUI and AppKit hosts.
public enum PresentationLayout {
    public static let menuWidth = 432.0
    public static let menuHeight = 630.0
    public static let floatingDefaultWidth = 432.0
    public static let floatingDefaultHeight = 630.0
    public static let floatingMinimumWidth = 320.0
    public static let floatingMinimumHeight = 380.0
    public static let floatingMaximumWidth = 760.0
    public static let floatingMaximumHeight = 900.0
    public static let edgeTagVisualWidth = 30.0
    public static let edgeTagHitWidth = 52.0
    public static let edgeTagHeight = 88.0
    public static func edgeTagHeight(quotaRowCount: Int) -> Double {
        edgeTagHeight + Double(min(2, max(0, quotaRowCount))) * 18.0
    }
    public static let edgeFluidProximityThreshold = 80.0
    public static let edgeExpandedWidth = 372.0
    public static let edgeExpandedHeight = 630.0
    public static let notchExpandedWidth = 420.0
    public static let notchExpandedHeight = 630.0

    public static let energyBeltHeight = 37.0

    public static func edgePanelHeight(
        itemCount: Int,
        groupCount: Int,
        isEmpty: Bool,
        showsEnergy: Bool = false
    ) -> Double {
        let chrome = 159.0 + (showsEnergy ? energyBeltHeight : 0)
        let content = isEmpty ? 110.0 : Double(max(1, itemCount)) * 56.0 + Double(groupCount) * 44.0 + 18.0
        return min(edgeExpandedHeight, max(floatingMinimumHeight, chrome + content))
    }
}

/// User-selectable footprint for the right-edge tag. Every inner metric scales
/// with the tier so the composition keeps its proportions instead of stretching
/// one dimension — and so the engraved gem figure grows legible at the top end.
public enum EdgeTagSize: String, Codable, CaseIterable, Sendable {
    case small
    case medium
    case large

    public var visualWidth: Double {
        switch self {
        case .small: return 24
        case .medium: return 30
        case .large: return 38
        }
    }

    public var hitWidth: Double {
        // Always at least the 44pt comfortable target, plus room to grow.
        max(44, visualWidth + 22)
    }

    public var baseHeight: Double {
        switch self {
        case .small: return 72
        case .medium: return 88
        case .large: return 108
        }
    }

    public var sealSize: Double {
        switch self {
        case .small: return 13
        case .medium: return 16
        case .large: return 21
        }
    }

    public var countFontSize: Double {
        switch self {
        case .small: return 13
        case .medium: return 15
        case .large: return 19
        }
    }

    public var gemSize: Double {
        switch self {
        case .small: return 15
        case .medium: return 18
        case .large: return 23
        }
    }

    public var gemFontSize: Double {
        switch self {
        case .small: return 6
        case .medium: return 7
        case .large: return 9
        }
    }

    public var labelFontSize: Double {
        switch self {
        case .small: return 5.5
        case .medium: return 6
        case .large: return 7.5
        }
    }

    public var statusDotSize: Double {
        switch self {
        case .small: return 6
        case .medium: return 7
        case .large: return 9
        }
    }

    /// Height grows by the full gem row (gem + label + spacing) per quota row.
    public func height(quotaRowCount: Int) -> Double {
        let rows = Double(min(2, max(0, quotaRowCount)))
        guard rows > 0 else { return baseHeight }
        let row = gemSize + labelFontSize + 7
        return baseHeight + rows * row
    }
}
