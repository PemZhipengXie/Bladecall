import Foundation

/// Captures what the UI would render right now for a set of sessions: each
/// session's attention state, time-decayed display bucket, and snoozed flag,
/// plus the day key. Adapter output being unchanged is not enough to skip a
/// UI pass — buckets decay with wall-clock time (active → background →
/// hidden), snoozes expire, and the timeline resets at midnight — so an idle
/// tick may only be skipped while this fingerprint also stays equal; a change
/// escalates one full pass. `activeSnoozeIDs` intentionally has no default:
/// every caller must supply the live set or an expiring snooze would be
/// frozen out of the UI by the idle short-circuit.
public struct DisplayFingerprint: Equatable {
    private let value: Int

    private init(value: Int) { self.value = value }

    public static func compute(
        sessions: [SessionSnapshot],
        attentionStates: [String: AttentionState],
        activeSnoozeIDs: Set<String>,
        policy: SessionDisplayPolicy,
        now: Date,
        calendar: Calendar = .current
    ) -> DisplayFingerprint {
        var hasher = Hasher()
        for session in sessions.sorted(by: { $0.id < $1.id }) {
            let attention = attentionStates[session.id]
                ?? (session.status == .running ? .running : .handled)
            hasher.combine(session.id)
            hasher.combine(attention)
            hasher.combine(policy.bucket(for: session, attention: attention, now: now))
            hasher.combine(activeSnoozeIDs.contains(session.id))
        }
        hasher.combine(calendar.startOfDay(for: now))
        return DisplayFingerprint(value: hasher.finalize())
    }
}
