import CoreServices
import CompletionBellCore
import Foundation

/// Thin FSEvents wrapper for event-driven scanning: watches each adapter's
/// session root and reports which adapter a filesystem change belongs to,
/// plus vnode watchers for state-bearing metadata files so host-side renames
/// surface without polling. Returns nil when nothing can be watched — the
/// caller falls back to interval polling.
///
/// Must be created and stopped on the same serial queue that `onEvent` should
/// fire on; all internal state is confined to that queue.
final class FileEventMonitor {
    private struct WatchedRoot {
        let path: String
        let index: Int
        let isMetadata: Bool
    }

    private var stream: FSEventStreamRef?
    private var fileSources: [String: DispatchSourceFileSystemObject] = [:]
    private var stopped = false
    private let queue: DispatchQueue
    private let onEvent: (Int, AdapterChangeSet) -> Void
    private let roots: [WatchedRoot]
    private let watchedFiles: [(path: String, index: Int)]

    init?(
        roots: [(index: Int, url: URL, isMetadata: Bool)],
        watchedFiles: [(index: Int, url: URL)],
        queue: DispatchQueue,
        onEvent: @escaping (Int, AdapterChangeSet) -> Void
    ) {
        let existing = roots.filter { FileManager.default.fileExists(atPath: $0.url.path) }
        guard !existing.isEmpty else { return nil }
        self.queue = queue
        self.onEvent = onEvent
        self.roots = existing.map {
            WatchedRoot(
                path: $0.url.standardizedFileURL.path,
                index: $0.index,
                isMetadata: $0.isMetadata
            )
        }
        self.watchedFiles = watchedFiles.map { ($0.url.path, $0.index) }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, numEvents, eventPaths, eventFlags, _ in
            guard let info, numEvents > 0 else { return }
            let monitor = Unmanaged<FileEventMonitor>.fromOpaque(info).takeUnretainedValue()
            guard let paths = unsafeBitCast(eventPaths, to: CFArray.self) as NSArray as? [String] else { return }
            let flags = Array(UnsafeBufferPointer(start: eventFlags, count: numEvents))
            monitor.handleEvents(paths: paths, flags: flags)
        }
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            self.roots.map(\.path) as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.2,
            FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagUseCFTypes
                    | kFSEventStreamCreateFlagNoDefer
                    | kFSEventStreamCreateFlagWatchRoot
                    | kFSEventStreamCreateFlagFileEvents
            )
        ) else { return nil }

        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return nil
        }
        self.stream = stream
        queue.async { [weak self] in
            guard let self else { return }
            for file in self.watchedFiles {
                self.openFileWatcher(path: file.path, index: file.index)
            }
        }
    }

    var watchedRootCount: Int { roots.count }

    func stop() {
        stopped = true
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
        for source in fileSources.values {
            source.cancel()
        }
        fileSources.removeAll()
    }

    private func handleEvents(paths: [String], flags: [FSEventStreamEventFlags]) {
        var changesByIndex: [Int: AdapterChangeSet] = [:]
        let lossMask = FSEventStreamEventFlags(
            kFSEventStreamEventFlagMustScanSubDirs
                | kFSEventStreamEventFlagUserDropped
                | kFSEventStreamEventFlagKernelDropped
                | kFSEventStreamEventFlagEventIdsWrapped
        )
        if flags.contains(where: { $0 & lossMask != 0 }) {
            for index in Set(roots.map(\.index)) {
                changesByIndex[index] = AdapterChangeSet(
                    requiresFullScan: true,
                    fullScanReason: "event_loss"
                )
            }
        }
        for (offset, rawPath) in paths.enumerated() {
            let path = URL(fileURLWithPath: rawPath).standardizedFileURL.path
            let eventFlags = offset < flags.count ? flags[offset] : 0
            for root in roots where path == root.path || path.hasPrefix(root.path + "/") {
                var changes = changesByIndex[root.index] ?? AdapterChangeSet()
                if root.isMetadata {
                    changes.metadataPaths.insert(path)
                } else {
                    changes.contentPaths.insert(path)
                }
                if let reason = fullScanReason(flags: eventFlags, path: path, root: root.path) {
                    changes.requiresFullScan = true
                    changes.fullScanReason = changes.fullScanReason ?? reason
                }
                changesByIndex[root.index] = changes
            }
        }
        for index in changesByIndex.keys.sorted() {
            if let changes = changesByIndex[index] { onEvent(index, changes) }
        }
    }

    private func fullScanReason(
        flags: FSEventStreamEventFlags,
        path: String,
        root: String
    ) -> String? {
        let droppedOrCoalesced = FSEventStreamEventFlags(
            kFSEventStreamEventFlagMustScanSubDirs
                | kFSEventStreamEventFlagUserDropped
                | kFSEventStreamEventFlagKernelDropped
                | kFSEventStreamEventFlagEventIdsWrapped
        )
        if flags & droppedOrCoalesced != 0 { return "event_loss" }
        if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged) != 0 { return "root_changed" }
        if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed) != 0 { return "renamed" }
        if path == root,
           flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0 {
            return "root_event"
        }
        if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0,
           flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemRemoved) != 0 {
            return "directory_removed"
        }
        return nil
    }

    /// Vnode watcher for a single state-bearing file (SQLite WAL, rename
    /// log). Such files can vanish and reappear — the WAL when the last
    /// Codex connection closes, the index on rotation — so retry on a slow
    /// clock; the reconcile scan covers the gap either way.
    private func openFileWatcher(path: String, index: Int) {
        guard !stopped, fileSources[path] == nil else { return }
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else {
            scheduleFileRetry(path: path, index: index)
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .delete, .rename],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            guard let self, let current = self.fileSources[path] else { return }
            self.onEvent(index, AdapterChangeSet(metadataPaths: [path]))
            if current.data.contains(.delete) || current.data.contains(.rename) {
                current.cancel()
                self.fileSources[path] = nil
                self.scheduleFileRetry(path: path, index: index)
            }
        }
        source.setCancelHandler { close(descriptor) }
        fileSources[path] = source
        source.resume()
    }

    private func scheduleFileRetry(path: String, index: Int) {
        queue.asyncAfter(deadline: .now() + 30) { [weak self] in
            self?.openFileWatcher(path: path, index: index)
        }
    }
}
