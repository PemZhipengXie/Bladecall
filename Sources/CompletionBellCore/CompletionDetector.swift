import Foundation

public final class CompletionDetector {
    private var initialized = false
    private var fingerprints: [String: String] = [:]
    private var knownSessionIDs: Set<String> = []
    private var statuses: [String: SessionStatus] = [:]
    private var startedAt: Date?

    public init() {}

    public func process(_ snapshots: [SessionSnapshot], at now: Date = Date()) -> [CompletionEvent] {
        if !initialized {
            initialized = true
            startedAt = now
            for snapshot in snapshots {
                knownSessionIDs.insert(snapshot.id)
                statuses[snapshot.id] = snapshot.status
                if let fingerprint = snapshot.completionFingerprint {
                    fingerprints[snapshot.id] = fingerprint
                }
            }
            return []
        }

        var events: [CompletionEvent] = []
        for snapshot in snapshots {
            let wasKnown = knownSessionIDs.contains(snapshot.id)
            let previousStatus = statuses[snapshot.id]
            knownSessionIDs.insert(snapshot.id)
            statuses[snapshot.id] = snapshot.status

            guard snapshot.status == .completed,
                  let fingerprint = snapshot.completionFingerprint else { continue }

            let previous = fingerprints[snapshot.id]
            fingerprints[snapshot.id] = fingerprint
            guard previous != fingerprint else { continue }

            if previous != nil {
                events.append(CompletionEvent(session: snapshot, detectedAt: now))
                continue
            }

            if wasKnown, previousStatus != .completed {
                events.append(CompletionEvent(session: snapshot, detectedAt: now))
                continue
            }

            if !wasKnown, let startedAt, snapshot.lastActivity >= startedAt.addingTimeInterval(-1) {
                events.append(CompletionEvent(session: snapshot, detectedAt: now))
            }
        }
        return events
    }
}
