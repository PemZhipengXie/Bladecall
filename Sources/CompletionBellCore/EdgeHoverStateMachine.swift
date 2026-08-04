import Foundation

public enum EdgeHoverEvent: Equatable, Sendable {
    case entryEntered
    case entryExited
    case pointerValidation(isInsideHotRegion: Bool)
    case entryClicked
    case contentActivated
    case menuOpened
    case menuClosed
    case pinChanged(Bool)
}

public struct EdgeHoverSnapshot: Equatable, Sendable {
    public let isExpanded: Bool
    public let isPinned: Bool
    public let isHoverArmed: Bool
    public let isInsideHotRegion: Bool
    public let isMenuOpen: Bool
    public let isMoving: Bool
    public var shouldPoll: Bool {
        !isPinned && (isExpanded || isInsideHotRegion)
    }
}

/// Pure hover timing and arbitration. AppKit supplies tracking events and a
/// periodic pointer validation; this type owns every expand/collapse decision.
public final class EdgeHoverStateMachine {
    /// Exposed so callers and tests reason about the contract (a pass shorter
    /// than this must not expand) rather than a hard-coded millisecond value.
    public private(set) var expandDelay: TimeInterval
    public private(set) var collapseDelay: TimeInterval
    /// Longer window granted after the user opens a session from the panel.
    public private(set) var activationGrace: TimeInterval
    private var pendingActivationGrace = false
    private var entryInside = false
    private var menuOpen = false
    private var pinned = false
    private var expanded = false
    private var hoverArmed = true
    private var expandAt: Date?
    private var collapseAt: Date?
    private var lastNow: Date

    public init(
        // Short enough to feel immediate, long enough to reject a cursor that
        // is merely travelling along the screen edge. The fluid bulge already
        // gives feedback before this fires, so intent is visible earlier.
        expandDelay: TimeInterval = 0.13,
        collapseDelay: TimeInterval = 0.62,
        activationGrace: TimeInterval = 1.8,
        now: Date = Date()
    ) {
        self.expandDelay = expandDelay
        self.collapseDelay = collapseDelay
        self.activationGrace = max(collapseDelay, activationGrace)
        self.lastNow = now
    }

    @discardableResult
    public func send(_ event: EdgeHoverEvent, at now: Date) -> EdgeHoverSnapshot {
        advance(to: now)
        switch event {
        case .entryEntered:
            entryInside = true
            enteredHotRegion(at: now)
        case .entryExited:
            entryInside = false
            validationInside = false
            leftPartOfHotRegion(at: now)
        case .pointerValidation(let isInside):
            if isInside {
                validationInside = true
                enteredHotRegion(at: now)
            } else {
                entryInside = false
                validationInside = false
                leftHotRegionCompletely(at: now)
            }
        case .entryClicked:
            expandAt = nil
            collapseAt = nil
            if pinned {
                expanded = true
                break
            }
            if expanded {
                expanded = false
                hoverArmed = false
            } else {
                expanded = true
            }
        case .contentActivated:
            guard !pinned else { break }
            // Opening a session hands focus to the other app, but the pointer
            // is still on the panel — the user is mid-triage and very likely
            // to act on the next row. Collapsing here yanked the panel out
            // from under them. Stay open while they are still on it; leaving
            // is what means "I'm done", and that path already collapses.
            if isInsideHotRegion {
                collapseAt = nil
                pendingActivationGrace = true
            } else {
                expanded = false
                expandAt = nil
                collapseAt = nil
                hoverArmed = false
            }
        case .menuOpened:
            menuOpen = true
            collapseAt = nil
        case .menuClosed:
            menuOpen = false
            if !isInsideHotRegion && expanded && !pinned {
                collapseAt = now.addingTimeInterval(collapseDelay)
            }
        case .pinChanged(let value):
            pinned = value
            if value {
                expanded = true
                expandAt = nil
                collapseAt = nil
            } else if expanded && !isInsideHotRegion {
                collapseAt = now.addingTimeInterval(collapseDelay)
            }
        }
        return snapshot
    }

    @discardableResult
    public func advance(to now: Date) -> EdgeHoverSnapshot {
        let effectiveNow = max(lastNow, now)
        lastNow = effectiveNow
        if let due = expandAt, due <= effectiveNow, hoverArmed, isInsideHotRegion {
            expanded = true
            expandAt = nil
        }
        if let due = collapseAt, due <= effectiveNow, !pinned, !menuOpen, !isInsideHotRegion {
            expanded = false
            collapseAt = nil
        }
        return snapshot
    }

    public var snapshot: EdgeHoverSnapshot {
        EdgeHoverSnapshot(
            isExpanded: expanded,
            isPinned: pinned,
            isHoverArmed: hoverArmed,
            isInsideHotRegion: isInsideHotRegion,
            isMenuOpen: menuOpen,
            isMoving: expandAt != nil || collapseAt != nil
        )
    }

    private var validationInside = false
    private var isInsideHotRegion: Bool { entryInside || validationInside }

    private func enteredHotRegion(at now: Date) {
        collapseAt = nil
        if !expanded && hoverArmed && expandAt == nil {
            expandAt = now.addingTimeInterval(expandDelay)
        }
    }

    private func leftPartOfHotRegion(at now: Date) {
        guard !isInsideHotRegion else { return }
        leftHotRegionCompletely(at: now)
    }

    private func leftHotRegionCompletely(at now: Date) {
        expandAt = nil
        if !hoverArmed { hoverArmed = true }
        if expanded && !pinned && !menuOpen && collapseAt == nil {
            // Right after opening a session the pointer often crosses out to
            // the app that just took focus and comes straight back for the
            // next row. Give that round trip room before collapsing.
            let grace = pendingActivationGrace ? activationGrace : collapseDelay
            pendingActivationGrace = false
            collapseAt = now.addingTimeInterval(grace)
        }
    }
}
