import AppKit
import CompletionBellCore
import Foundation

final class MonitorService {
    enum ScanTrigger: String {
        case initial
        case timer
        case fsevents
        case reconcile
        case wake
        case manual
    }

    struct Update {
        let sessions: [SessionSnapshot]
        let errors: [String]
        let scanDuration: TimeInterval
        let isManualRefresh: Bool
        let unchangedSinceLastScan: Bool
        let publishReason: String
    }

    var onUpdate: ((Update) -> Void)?
    // Session status is user-facing, time-sensitive UI state. A utility queue
    // can be heavily throttled while the menu-bar app is in the background,
    // turning the same scan from seconds into minutes.
    private let queue = DispatchQueue(label: "completion-bell.monitor", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private let adapters: [SessionAdapter]
    private var scanCount = 0
    private var previousCanonicalSessions: [SessionSnapshot]?
    private var previousPresentationFingerprint: SessionPresentationFingerprint?
    private var previousErrors: [String] = []
    private var lastLoggedParseErrors: [String] = []
    private var unchangedTickCount = 0
    private var lastResults: [AdapterScanResult?]
    private var scheduler: ScanScheduler?
    private var fileMonitor: FileEventMonitor?
    private var pendingDirtyScan: DispatchWorkItem?
    private var pendingChanges: [Int: AdapterChangeSet] = [:]
    private var wakeObserver: NSObjectProtocol?
    private var latestSessions: [SessionSnapshot] = []
    private var latestErrors: [String] = []
    private var latestScanDuration: TimeInterval = 0
    private let forceLegacyPolling = ProcessInfo.processInfo.environment["JIANLING_SCAN_MODE"] == "legacy"

    init(adapters: [SessionAdapter] = [CraftAdapter(), ClaudeCodeAdapter(), CodexAdapter(), NewMaxAdapter(), WorkBuddyAdapter(), PushDropAdapter()]) {
        self.adapters = adapters
        self.lastResults = Array(repeating: nil, count: adapters.count)
    }

    func start() {
        registerWakeObserver()
        queue.async { [weak self] in
            guard let self, self.timer == nil else { return }
            // Watch before the first scan so writes landing during the long
            // cold scan are captured as events instead of waiting for the
            // reconcile backstop.
            self.startFileMonitoring()
            self.scan(only: nil, trigger: .initial)

            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            let interval: Double
            if let scheduler = self.scheduler {
                // Event-driven mode: the timer is only the low-frequency
                // reconcile backstop for lost or coalesced file events. Each
                // tick hands out at most one adapter's staggered turn, so the
                // backstop never pays a whole-fleet scan in a single tick.
                interval = scheduler.reconcileTickInterval
                timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .seconds(5))
                timer.setEventHandler { [weak self] in
                    guard let self, let scheduler = self.scheduler else { return }
                    let due = scheduler.takeReconcileDue(at: Date())
                    guard !due.isEmpty else { return }
                    // The turn's scan is a full discovery for these adapters,
                    // so their accumulated event changes are superseded.
                    for index in due {
                        self.pendingChanges.removeValue(forKey: index)
                    }
                    self.scan(only: due, trigger: .reconcile)
                }
            } else {
                interval = 5
                timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(700))
                timer.setEventHandler { [weak self] in self?.scan(only: nil, trigger: .timer) }
            }
            self.timer = timer
            timer.resume()
            AppLogger.shared.write("monitor_started", fields: [
                "interval_seconds": interval,
                "mode": self.fileMonitor == nil ? "polling" : "events",
                "watched_roots": self.fileMonitor?.watchedRootCount ?? 0
            ])
        }
    }

    func stop() {
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        queue.async { [weak self] in
            guard let self else { return }
            self.timer?.cancel()
            self.timer = nil
            self.pendingDirtyScan?.cancel()
            self.pendingDirtyScan = nil
            self.pendingChanges.removeAll()
            self.fileMonitor?.stop()
            self.fileMonitor = nil
            self.scheduler = nil
            AppLogger.shared.write("monitor_stopped")
        }
    }

    func scanNow(reloadMetadata: Bool = false) {
        queue.async { [weak self] in
            guard let self else { return }
            if reloadMetadata {
                self.adapters.forEach { $0.invalidateCache() }
                AppLogger.shared.write("session_refresh_requested", fields: ["reload_metadata": true])
            }
            self.scan(only: nil, trigger: .manual)
        }
    }

    /// Reuses the app's existing one-minute maintenance clock so relative
    /// labels and age-based buckets advance without a filesystem rescan.
    func publishClockIfNeeded() {
        queue.async { [weak self] in
            guard let self else { return }
            let fingerprint = SessionPresentationFingerprint.compute(sessions: self.latestSessions, now: Date())
            guard fingerprint != self.previousPresentationFingerprint else { return }
            self.previousPresentationFingerprint = fingerprint
            self.onUpdate?(Update(
                sessions: self.latestSessions,
                errors: self.latestErrors,
                scanDuration: self.latestScanDuration,
                isManualRefresh: false,
                unchangedSinceLastScan: false,
                publishReason: "clock"
            ))
        }
    }

    private func startFileMonitoring() {
        guard !forceLegacyPolling else {
            scheduler = nil
            fileMonitor = nil
            AppLogger.shared.write("incremental_scan_disabled", fields: ["source": "environment"])
            return
        }
        let roots = adapters.enumerated().flatMap { index, adapter in
            adapter.watchRoots.map { (index: index, url: $0, isMetadata: false) }
                + adapter.metadataWatchRoots.map { (index: index, url: $0, isMetadata: true) }
        }
        let watchedFiles = adapters.enumerated().flatMap { index, adapter in
            adapter.metadataWatchFiles.map { (index: index, url: $0) }
        }
        scheduler = ScanScheduler(adapterCount: adapters.count)
        fileMonitor = FileEventMonitor(roots: roots, watchedFiles: watchedFiles, queue: queue) { [weak self] index, changes in
            self?.adapterBecameDirty(index, changes: changes)
        }
        if fileMonitor == nil {
            scheduler = nil
            AppLogger.shared.write("file_events_unavailable", fields: ["fallback": "polling"])
        }
    }

    private func adapterBecameDirty(_ index: Int, changes: AdapterChangeSet) {
        guard let scheduler else { return }
        var accumulated = pendingChanges[index] ?? AdapterChangeSet()
        accumulated.merge(changes)
        pendingChanges[index] = accumulated
        scheduler.markDirty(index, at: Date())
        armDirtyScan()
    }

    private func armDirtyScan() {
        guard let scheduler else { return }
        pendingDirtyScan?.cancel()
        guard let delay = scheduler.nextDueDelay(at: Date()) else {
            pendingDirtyScan = nil
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self, let scheduler = self.scheduler else { return }
            let due = scheduler.takeDue(at: Date())
            if !due.isEmpty {
                var changes: [Int: AdapterChangeSet] = [:]
                for index in due {
                    changes[index] = self.pendingChanges.removeValue(forKey: index) ?? AdapterChangeSet()
                }
                self.scan(only: due, trigger: .fsevents, changesByIndex: changes)
            }
            self.armDirtyScan()
        }
        pendingDirtyScan = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func registerWakeObserver() {
        guard wakeObserver == nil else { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.queue.async { self.scan(only: nil, trigger: .wake) }
        }
    }

    private func scan(
        only: Set<Int>?,
        trigger: ScanTrigger,
        changesByIndex: [Int: AdapterChangeSet] = [:]
    ) {
        scanCount += 1
        let started = Date()
        var scannedAdapters = 0
        var scanDiagnostics: [AdapterScanDiagnostics] = []
        for (index, adapter) in adapters.enumerated() {
            if let only, !only.contains(index), lastResults[index] != nil { continue }
            let changes = only == nil ? nil : changesByIndex[index]
            let result = autoreleasepool {
                adapter.scan(now: started, changes: changes)
            }
            lastResults[index] = result
            scanDiagnostics.append(result.diagnostics)
            scannedAdapters += 1
        }
        var sessions: [SessionSnapshot] = []
        var errors: [String] = []
        for result in lastResults.compactMap({ $0 }) {
            sessions.append(contentsOf: result.sessions)
            errors.append(contentsOf: result.errors.map { "\(result.tool.rawValue): \($0)" })
        }
        if only == nil {
            // Stamp coverage at scan start: the results reflect the tree as
            // of `started`, and end-stamping would let scan duration silently
            // stretch the reconcile cadence past its interval.
            scheduler?.noteFullScan(at: started)
            pendingChanges.removeAll()
        }
        let duration = Date().timeIntervalSince(started)
        let isManualRefresh = trigger == .manual
        let canonicalSessions = ScanChangeDetector.canonical(sessions)
        let presentationFingerprint = SessionPresentationFingerprint.compute(sessions: sessions, now: Date())
        let presentationChanged = presentationFingerprint != previousPresentationFingerprint
        let errorsChanged = errors != previousErrors
        // Manual refresh always reports as changed so the user gets visible
        // refresh feedback even when nothing moved.
        let unchanged = !isManualRefresh && ScanChangeDetector.isUnchanged(
            canonicalSessions: canonicalSessions,
            errors: errors,
            previousCanonicalSessions: previousCanonicalSessions,
            previousErrors: previousErrors
        )
        previousCanonicalSessions = canonicalSessions
        previousErrors = errors
        previousPresentationFingerprint = presentationFingerprint
        latestSessions = sessions
        latestErrors = errors
        latestScanDuration = duration
        let publishReason: String?
        if isManualRefresh {
            publishReason = "manual"
        } else if errorsChanged {
            publishReason = "errors"
        } else if presentationChanged {
            publishReason = trigger.rawValue
        } else {
            publishReason = nil
        }
        if unchanged { unchangedTickCount += 1 }
        if !errors.isEmpty && errors != lastLoggedParseErrors {
            AppLogger.shared.write("parse_errors", fields: ["count": errors.count, "sample": Array(errors.prefix(3))])
        }
        lastLoggedParseErrors = errors
        // The rotating backstop reconciles one adapter per tick; logging only
        // adapter 0's turn keeps idle health-log volume at the cadence of the
        // old whole-fleet reconcile.
        let reconcileHealthDue = trigger == .reconcile && (only?.contains(0) ?? true)
        if scanCount == 1 || scanCount % 12 == 0 || reconcileHealthDue {
            let grouped = Dictionary(grouping: sessions, by: { $0.tool.rawValue }).mapValues(\.count)
            let running = Dictionary(
                grouping: sessions.filter { $0.status == .running },
                by: { $0.tool.rawValue }
            ).mapValues(\.count)
            AppLogger.shared.write("scan_health", fields: [
                "scan_number": scanCount,
                "duration_seconds": duration,
                "session_counts": grouped,
                "running_counts": running,
                "error_count": errors.count,
                "unchanged_ticks": unchangedTickCount,
                "trigger": trigger.rawValue,
                "mode": fileMonitor == nil ? "polling" : "events",
                "scanned_adapters": scannedAdapters,
                "incremental_path_count": changesByIndex.values.reduce(0) { $0 + $1.pathCount },
                "full_discovery_count": scanDiagnostics.filter(\.didFullDiscovery).count,
                "discovery_seconds": scanDiagnostics.reduce(0) { $0 + $1.discoveryDuration },
                "parse_seconds": scanDiagnostics.reduce(0) { $0 + $1.parseDuration },
                "parsed_file_count": scanDiagnostics.reduce(0) { $0 + $1.parsedFileCount },
                "full_scan_reasons": scanDiagnostics.compactMap(\.fullScanReason),
                "ui_publish_reason": publishReason ?? "suppressed"
            ])
        }
        if isManualRefresh {
            AppLogger.shared.write("session_refresh_completed", fields: [
                "session_count": sessions.count,
                "duration_seconds": duration,
                "error_count": errors.count
            ])
        }
        if let publishReason {
            onUpdate?(Update(
                sessions: sessions,
                errors: errors,
                scanDuration: duration,
                isManualRefresh: isManualRefresh,
                unchangedSinceLastScan: false,
                publishReason: publishReason
            ))
        }
    }
}
