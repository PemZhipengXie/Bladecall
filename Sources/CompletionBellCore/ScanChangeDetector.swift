import Foundation

/// Round-over-round comparison of adapter output so idle ticks can skip the
/// full main-thread update chain. The comparison deliberately covers every
/// SessionSnapshot field: settle flips, title refreshes, and status changes
/// all surface in the output, so they defeat the short-circuit on exactly
/// the rounds that must go through.
public enum ScanChangeDetector {
    /// Sessions sorted by id, so display ordering and adapter enumeration
    /// order can't make two identical scans compare as different.
    public static func canonical(_ sessions: [SessionSnapshot]) -> [SessionSnapshot] {
        sessions.sorted { $0.id < $1.id }
    }

    public static func isUnchanged(
        canonicalSessions: [SessionSnapshot],
        errors: [String],
        previousCanonicalSessions: [SessionSnapshot]?,
        previousErrors: [String]
    ) -> Bool {
        guard let previousCanonicalSessions else { return false }
        return errors == previousErrors && canonicalSessions == previousCanonicalSessions
    }
}

/// A UI-facing comparison that intentionally coalesces raw filesystem
/// activity. Tool events may update a transcript several times per second,
/// but the inbox only needs a new render when user-visible state changes or
/// the minute-level relative-time label advances.
public struct SessionPresentationFingerprint: Equatable, Sendable {
    private let value: Int

    private init(value: Int) {
        self.value = value
    }

    public static func compute(sessions: [SessionSnapshot], now: Date) -> SessionPresentationFingerprint {
        var hasher = Hasher()
        hasher.combine(Int(now.timeIntervalSince1970 / 60))
        for session in sessions.sorted(by: { $0.id < $1.id }) {
            hasher.combine(session.id)
            hasher.combine(session.title)
            hasher.combine(session.status)
            hasher.combine(session.completionFingerprint)
            hasher.combine(session.projectPath)
            hasher.combine(session.hasUnread)
            hasher.combine(session.origin)
            hasher.combine(session.isHostVisible)
            hasher.combine(session.turnStartedAt)
            hasher.combine(session.turnCompletedAt)
            hasher.combine(Int(session.lastActivity.timeIntervalSince1970 / 60))
        }
        return SessionPresentationFingerprint(value: hasher.finalize())
    }
}
