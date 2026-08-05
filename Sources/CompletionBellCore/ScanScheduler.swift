import Foundation

/// Pure scheduling logic for event-driven scanning. File events mark an
/// adapter dirty; the scheduler answers when it should actually be scanned:
/// a short debounce window batches bursts of writes, a per-adapter minimum
/// interval caps storm throughput, and a low-frequency reconcile rotation
/// backstops lost file events one adapter per tick instead of a whole-fleet
/// spike. All clocks are passed in, so the logic is fully testable without
/// timers.
public final class ScanScheduler {
    private let adapterCount: Int
    private let debounce: TimeInterval
    private let minAdapterInterval: TimeInterval
    private let reconcileInterval: TimeInterval
    /// Slack subtracted from the reconcile deadline so a timer fire landing
    /// fractionally early (wall-clock drift, leeway) still takes the turn
    /// instead of deferring it a whole tick. Must stay well below one tick
    /// so neighboring turns never collide.
    private let reconcileTolerance: TimeInterval
    /// Adapter index → first un-taken dirty mark. Kept at the burst's first
    /// event so latency stays bounded even under continuous writes.
    private var dirtySince: [Int: Date] = [:]
    private var lastTakenAt: [Int: Date] = [:]
    /// Adapter index → when its data was last fully covered (a full scan or
    /// its own reconcile turn). Phases are staggered one tick apart so the
    /// backstop rotates through adapters instead of scanning them all at once.
    private var lastReconcileAt: [Int: Date] = [:]

    public init(
        adapterCount: Int,
        debounce: TimeInterval = 0.5,
        minAdapterInterval: TimeInterval = 2,
        reconcileInterval: TimeInterval = 5 * 60,
        reconcileTolerance: TimeInterval = 5,
        now: Date = Date()
    ) {
        self.adapterCount = adapterCount
        self.debounce = debounce
        self.minAdapterInterval = minAdapterInterval
        self.reconcileInterval = reconcileInterval
        self.reconcileTolerance = reconcileTolerance
        staggerReconcilePhases(from: now)
    }

    public func markDirty(_ index: Int, at now: Date) {
        guard index >= 0 && index < adapterCount else { return }
        if dirtySince[index] == nil {
            dirtySince[index] = now
        }
    }

    /// Adapters whose debounce and minimum interval have both elapsed.
    /// Taking them clears their dirty mark and stamps their scan time.
    public func takeDue(at now: Date) -> Set<Int> {
        var due: Set<Int> = []
        for index in dirtySince.keys where dueTime(for: index).map({ $0 <= now }) == true {
            due.insert(index)
        }
        for index in due {
            dirtySince.removeValue(forKey: index)
            lastTakenAt[index] = now
        }
        return due
    }

    /// Delay until the earliest pending adapter becomes due, or nil when
    /// nothing is dirty. The caller uses this to arm a one-shot timer instead
    /// of polling.
    public func nextDueDelay(at now: Date) -> TimeInterval? {
        let times = dirtySince.keys.compactMap { dueTime(for: $0) }
        guard let earliest = times.min() else { return nil }
        return max(0, earliest.timeIntervalSince(now))
    }

    /// Timer cadence for the reconcile backstop: one adapter turn per tick,
    /// so full coverage still completes once per reconcile interval without
    /// ever paying a whole-fleet scan in a single tick.
    public var reconcileTickInterval: TimeInterval {
        reconcileInterval / Double(max(1, adapterCount))
    }

    /// Adapters whose reconcile turn has arrived. Taking a turn stamps the
    /// coverage clock at hand-out time — scan duration can never push the
    /// next turn past its interval — and absorbs the adapter's dirty mark,
    /// because the turn's scan is a full discovery for that adapter.
    public func takeReconcileDue(at now: Date) -> Set<Int> {
        var due: Set<Int> = []
        for index in 0..<adapterCount {
            guard let last = lastReconcileAt[index] else { continue }
            if now.timeIntervalSince(last) >= reconcileInterval - reconcileTolerance {
                due.insert(index)
            }
        }
        for index in due {
            lastReconcileAt[index] = now
            lastTakenAt[index] = now
            dirtySince.removeValue(forKey: index)
        }
        return due
    }

    /// A full scan (initial, wake, manual refresh) covers every adapter:
    /// absorb pending dirty marks, stamp every throttle clock, and restart
    /// the staggered rotation from `now`.
    public func noteFullScan(at now: Date) {
        dirtySince.removeAll()
        for index in 0..<adapterCount {
            lastTakenAt[index] = now
        }
        staggerReconcilePhases(from: now)
    }

    /// Backdate each adapter's coverage clock so turn `i` first lands at
    /// `now + (i + 1) * reconcileTickInterval`: coverage just happened, so
    /// the earliest turn waits one tick and the rest follow one per tick.
    private func staggerReconcilePhases(from now: Date) {
        for index in 0..<adapterCount {
            lastReconcileAt[index] = now.addingTimeInterval(Double(index + 1) * reconcileTickInterval - reconcileInterval)
        }
    }

    private func dueTime(for index: Int) -> Date? {
        guard let dirty = dirtySince[index] else { return nil }
        var due = dirty.addingTimeInterval(debounce)
        if let taken = lastTakenAt[index] {
            due = max(due, taken.addingTimeInterval(minAdapterInterval))
        }
        return due
    }
}
