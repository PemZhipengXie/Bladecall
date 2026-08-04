import Foundation

public enum InboxTransitionKind: String, Codable, Hashable {
    case taskStarted
    case assistantCompleted
    case handled
}

public enum HandledMethod: String, Codable, Hashable {
    case manual
    case replied
}

public struct InboxTransition: Hashable {
    public let kind: InboxTransitionKind
    public let session: SessionSnapshot
    public let timestamp: Date
    public let turnID: String
    public let startedAt: Date?
    public let handledMethod: HandledMethod?

    public init(
        kind: InboxTransitionKind,
        session: SessionSnapshot,
        timestamp: Date,
        turnID: String,
        startedAt: Date? = nil,
        handledMethod: HandledMethod? = nil
    ) {
        self.kind = kind
        self.session = session
        self.timestamp = timestamp
        self.turnID = turnID
        self.startedAt = startedAt
        self.handledMethod = handledMethod
    }
}

public struct InboxReconciliation {
    public let attentionStates: [String: AttentionState]
    public let completionEvents: [CompletionEvent]
    public let transitions: [InboxTransition]
}

public final class InboxStateStore {
    private struct SessionRecord: Codable, Equatable {
        var lastSeenFingerprint: String?
        var pendingFingerprint: String?
        var pendingCompletedAt: Date?
        var readFingerprint: String?
        var handledFingerprint: String?
        var lastTurnStartedAt: Date?
        var lastStatus: SessionStatus?
        var snoozedUntil: Date?
    }

    private struct PersistedState: Codable {
        var schemaVersion = 2
        var initializedAt: Date?
        var lastScanAt: Date?
        var sessions: [String: SessionRecord] = [:]
    }

    private let url: URL
    private var state: PersistedState
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let idlePersistInterval: TimeInterval
    private var lastSavedAt: Date?
    private var hasUnpersistedChanges = false

    public init(url: URL, idlePersistInterval: TimeInterval = 300) {
        self.url = url
        self.idlePersistInterval = idlePersistInterval
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: url), let decoded = try? decoder.decode(PersistedState.self, from: data) {
            self.state = decoded
        } else {
            self.state = PersistedState()
        }
    }

    public var trackingStartedAt: Date? { state.initializedAt }

    public func reconcile(_ snapshots: [SessionSnapshot], at now: Date = Date()) -> InboxReconciliation {
        if state.initializedAt == nil {
            state.initializedAt = now
            state.lastScanAt = now
            for snapshot in snapshots {
                state.sessions[snapshot.id] = baselineRecord(for: snapshot)
            }
            save(at: now)
            return InboxReconciliation(
                attentionStates: attentionStates(for: snapshots),
                completionEvents: [],
                transitions: []
            )
        }

        let previousScanAt = state.lastScanAt ?? now
        let trackingStartedAt = state.initializedAt ?? now
        var completionEvents: [CompletionEvent] = []
        var transitions: [InboxTransition] = []
        var substantiveDirty = false

        for snapshot in snapshots {
            let wasKnown = state.sessions[snapshot.id] != nil
            var record = state.sessions[snapshot.id] ?? SessionRecord()
            let startedAt = snapshot.turnStartedAt
            if let snoozedUntil = record.snoozedUntil, snoozedUntil <= now {
                record.snoozedUntil = nil
            }
            let startedChanged = startedAt != nil && !sameMoment(startedAt, record.lastTurnStartedAt)
            let recentEnough = (startedAt ?? snapshot.turnCompletedAt ?? snapshot.lastActivity) >= previousScanAt.addingTimeInterval(-1)

            if let pending = record.pendingFingerprint,
               startedChanged,
               let startedAt,
               startedAt >= (record.pendingCompletedAt ?? .distantPast) {
                transitions.append(InboxTransition(
                    kind: .handled,
                    session: snapshot,
                    timestamp: startedAt,
                    turnID: pending,
                    startedAt: record.pendingCompletedAt,
                    handledMethod: .replied
                ))
                record.handledFingerprint = pending
                record.pendingFingerprint = nil
                record.pendingCompletedAt = nil
                record.readFingerprint = nil
                record.snoozedUntil = nil
            }

            if startedChanged && (wasKnown || recentEnough), let startedAt {
                transitions.append(InboxTransition(
                    kind: .taskStarted,
                    session: snapshot,
                    timestamp: startedAt,
                    turnID: "\(snapshot.id):\(startedAt.timeIntervalSince1970)"
                ))
            }

            if snapshot.status == .completed, let fingerprint = snapshot.completionFingerprint {
                let isNewCompletion = fingerprint != record.lastSeenFingerprint
                let completedAt = snapshot.turnCompletedAt ?? snapshot.lastActivity
                if isNewCompletion && (wasKnown || completedAt >= previousScanAt.addingTimeInterval(-1)) {
                    record.pendingFingerprint = fingerprint
                    record.pendingCompletedAt = completedAt
                    record.readFingerprint = nil
                    // A snooze is pinned to the previous result; a fresh
                    // completion must surface immediately.
                    record.snoozedUntil = nil
                    completionEvents.append(CompletionEvent(session: snapshot, detectedAt: now))
                    transitions.append(InboxTransition(
                        kind: .assistantCompleted,
                        session: snapshot,
                        timestamp: completedAt,
                        turnID: fingerprint,
                        startedAt: maxDate(snapshot.turnStartedAt, trackingStartedAt)
                    ))
                }
                record.lastSeenFingerprint = fingerprint
            }

            record.lastTurnStartedAt = snapshot.turnStartedAt ?? record.lastTurnStartedAt
            record.lastStatus = snapshot.status
            if state.sessions[snapshot.id] != record { substantiveDirty = true }
            state.sessions[snapshot.id] = record
        }

        state.lastScanAt = now
        persistAfterScan(
            dirty: substantiveDirty || !transitions.isEmpty || !completionEvents.isEmpty,
            now: now
        )
        return InboxReconciliation(
            attentionStates: attentionStates(for: snapshots),
            completionEvents: completionEvents,
            transitions: transitions
        )
    }

    public func markHandled(_ snapshot: SessionSnapshot, at now: Date = Date()) -> InboxTransition? {
        guard var record = state.sessions[snapshot.id], let pending = record.pendingFingerprint else { return nil }
        let completedAt = record.pendingCompletedAt
        record.handledFingerprint = pending
        record.pendingFingerprint = nil
        record.pendingCompletedAt = nil
        record.readFingerprint = nil
        record.snoozedUntil = nil
        state.sessions[snapshot.id] = record
        save(at: now)
        return InboxTransition(
            kind: .handled,
            session: snapshot,
            timestamp: now,
            turnID: pending,
            startedAt: completedAt,
            handledMethod: .manual
        )
    }

    @discardableResult
    public func markRead(_ snapshot: SessionSnapshot) -> Bool {
        guard var record = state.sessions[snapshot.id],
              let pending = record.pendingFingerprint,
              pending == snapshot.completionFingerprint else { return false }
        guard record.readFingerprint != pending else { return false }
        record.readFingerprint = pending
        state.sessions[snapshot.id] = record
        save(at: Date())
        return true
    }

    /// Hide a finished session until `until` (the 「推」 action). Only sessions
    /// with an outstanding completion (unread/pending) can be snoozed; the
    /// attention chain is untouched so the session later returns in its
    /// original state. Persists immediately — a crash must not resurface a
    /// pushed-away row.
    @discardableResult
    public func snooze(_ snapshot: SessionSnapshot, until: Date, at now: Date = Date()) -> Bool {
        guard var record = state.sessions[snapshot.id], record.pendingFingerprint != nil else { return false }
        record.snoozedUntil = until
        state.sessions[snapshot.id] = record
        save(at: now)
        return true
    }

    /// IDs whose snooze is still in the future and whose completion is still
    /// outstanding. Pure query — expiry cleanup happens in reconcile.
    public func activeSnoozes(now: Date = Date()) -> Set<String> {
        var result: Set<String> = []
        for (id, record) in state.sessions {
            if let until = record.snoozedUntil, until > now, record.pendingFingerprint != nil {
                result.insert(id)
            }
        }
        return result
    }

    /// Persist any state that a throttled scan left in memory (at minimum the
    /// rolling lastScanAt). Called on app termination so the offline-recovery
    /// window stays anchored to the true last scan.
    public func flush(at now: Date = Date()) {
        guard hasUnpersistedChanges else { return }
        save(at: now)
    }

    public func attentionStates(for snapshots: [SessionSnapshot]) -> [String: AttentionState] {
        var result: [String: AttentionState] = [:]
        for snapshot in snapshots {
            if snapshot.status == .running {
                result[snapshot.id] = .running
            } else if let fingerprint = snapshot.completionFingerprint,
                      state.sessions[snapshot.id]?.pendingFingerprint == fingerprint {
                result[snapshot.id] = state.sessions[snapshot.id]?.readFingerprint == fingerprint ? .pending : .unread
            } else {
                result[snapshot.id] = .handled
            }
        }
        return result
    }

    private func baselineRecord(for snapshot: SessionSnapshot) -> SessionRecord {
        SessionRecord(
            lastSeenFingerprint: snapshot.completionFingerprint,
            pendingFingerprint: nil,
            pendingCompletedAt: nil,
            readFingerprint: nil,
            handledFingerprint: snapshot.completionFingerprint,
            lastTurnStartedAt: snapshot.turnStartedAt,
            lastStatus: snapshot.status
        )
    }

    /// Substantive changes hit the disk immediately; unchanged scans only touch
    /// the in-memory lastScanAt and fall back to a low-frequency heartbeat so
    /// idle ticks stop rewriting the state file. A failed write leaves
    /// lastSavedAt untouched so the next tick retries.
    private func persistAfterScan(dirty: Bool, now: Date) {
        let heartbeatDue = lastSavedAt.map { now.timeIntervalSince($0) >= idlePersistInterval } ?? true
        if dirty || heartbeatDue {
            save(at: now)
        } else {
            hasUnpersistedChanges = true
        }
    }

    private func save(at now: Date) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try encoder.encode(state)
            try data.write(to: url, options: .atomic)
            lastSavedAt = now
            hasUnpersistedChanges = false
        } catch {
            return
        }
    }

    private func maxDate(_ lhs: Date?, _ rhs: Date) -> Date {
        guard let lhs else { return rhs }
        return max(lhs, rhs)
    }

    private func sameMoment(_ lhs: Date?, _ rhs: Date?) -> Bool {
        guard let lhs, let rhs else { return lhs == nil && rhs == nil }
        return abs(lhs.timeIntervalSince(rhs)) < 1
    }
}
