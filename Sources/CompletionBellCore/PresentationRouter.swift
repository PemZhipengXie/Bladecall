import Foundation

public enum PresentationHost: String, CaseIterable, Sendable {
    case floating
    case notch
    case rightEdge
}

public enum PresentationTrigger: Equatable, Sendable {
    case launch
    case dockReopen
    case statusMenuShow
    case modeChanged(from: PresentationMode, to: PresentationMode)
    case hostCreationFailed(PresentationHost)
}

public struct PresentationRoute: Equatable, Sendable {
    public let present: PresentationHost
    public let destroy: Set<PresentationHost>
    public let persistedMode: PresentationMode
    public let didFallback: Bool

    public init(
        present: PresentationHost,
        destroy: Set<PresentationHost>,
        persistedMode: PresentationMode,
        didFallback: Bool = false
    ) {
        self.present = present
        self.destroy = destroy
        self.persistedMode = persistedMode
        self.didFallback = didFallback
    }
}

/// Decides host lifecycle only. Window creation, presentation, and teardown
/// remain AppKit side effects performed by AppDelegate.
public struct PresentationRouter: Sendable {
    public init() {}

    public func route(mode: PresentationMode, trigger: PresentationTrigger) -> PresentationRoute {
        switch trigger {
        case .launch, .dockReopen, .statusMenuShow:
            return routeForMode(mode)
        case .modeChanged(_, let new):
            let next = host(for: new)
            return PresentationRoute(
                present: next,
                destroy: Set(PresentationHost.allCases).subtracting([next]),
                persistedMode: supportedMode(for: new),
                didFallback: false
            )
        case .hostCreationFailed(let failed):
            return PresentationRoute(
                present: .floating,
                destroy: [failed],
                persistedMode: .floating,
                didFallback: true
            )
        }
    }

    private func routeForMode(_ mode: PresentationMode) -> PresentationRoute {
        let selected = host(for: mode)
        return PresentationRoute(
            present: selected,
            destroy: Set(PresentationHost.allCases).subtracting([selected]),
            persistedMode: supportedMode(for: mode),
            didFallback: false
        )
    }

    private func host(for mode: PresentationMode) -> PresentationHost {
        switch mode {
        case .floating: return .floating
        case .notch: return .notch
        case .rightEdge: return .rightEdge
        }
    }

    private func supportedMode(for mode: PresentationMode) -> PresentationMode {
        mode
    }
}
