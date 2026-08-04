import Foundation

/// Pure scheduling logic for event-driven scanning. File events mark an
/// adapter dirty; the scheduler answers when it should actually be scanned:
/// a short debounce window batches bursts of writes, a per-adapter minimum
/// interval caps storm throughput, and a low-frequency reconcile clock
/// backstops lost file events. All clocks are passed in, so the logic is
/// fully testable without timers.
public final class ScanScheduler {
    private let adapterCount: Int
    private let debounce: TimeInterval
    private let minAdapterInterval: TimeInterval
    private let reconcileInterval: TimeInterval
    /// Adapter index → first un-taken dirty mark. Kept at the burst's first
    /// event so latency stays bounded even under continuous writes.
    private var dirtySince: [Int: Date] = [:]
    private var lastTakenAt: [Int: Date] = [:]
    private var lastFullScanAt: Date

    public init(
        adapterCount: Int,
        debounce: TimeInterval = 0.5,
        minAdapterInterval: TimeInterval = 2,
        reconcileInterval: TimeInterval = 5 * 60,
        now: Date = Date()
    ) {
        self.adapterCount = adapterCount
        self.debounce = debounce
        self.minAdapterInterval = minAdapterInterval
        self.reconcileInterval = reconcileInterval
        self.lastFullScanAt = now
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

    public func reconcileDue(at now: Date) -> Bool {
        now.timeIntervalSince(lastFullScanAt) >= reconcileInterval
    }

    /// A full scan (reconcile, wake, manual refresh) covers every adapter:
    /// absorb pending dirty marks and reset both clocks.
    public func noteFullScan(at now: Date) {
        dirtySince.removeAll()
        for index in 0..<adapterCount {
            lastTakenAt[index] = now
        }
        lastFullScanAt = now
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
