import Foundation

enum FileDiscovery {
    struct Signature: Equatable {
        let modifiedAt: TimeInterval
        let size: Int
    }

    struct DiscoveredFile {
        let url: URL
        let signature: Signature

        var modifiedAt: Date { Date(timeIntervalSince1970: signature.modifiedAt) }
    }

    /// Enumerates once and captures each file's (mtime, size) signature in the
    /// same pass, so scan loops don't have to stat every file a second time.
    static func discover(
        under root: URL,
        matching predicate: (URL) -> Bool,
        modifiedAfter: Date? = nil,
        limit: Int? = nil
    ) -> [DiscoveredFile] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants]
        ) else { return [] }

        var candidates: [DiscoveredFile] = []
        for case let url as URL in enumerator {
            guard predicate(url) else { continue }
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            let modified = values.contentModificationDate ?? .distantPast
            if let modifiedAfter, modified < modifiedAfter { continue }
            candidates.append(DiscoveredFile(
                url: url,
                signature: Signature(
                    modifiedAt: modified.timeIntervalSince1970,
                    size: values.fileSize ?? 0
                )
            ))
        }

        candidates.sort { $0.signature.modifiedAt > $1.signature.modifiedAt }
        if let limit { return Array(candidates.prefix(limit)) }
        return candidates
    }

    static func files(
        under root: URL,
        matching predicate: (URL) -> Bool,
        modifiedAfter: Date? = nil,
        limit: Int? = nil
    ) -> [URL] {
        discover(under: root, matching: predicate, modifiedAfter: modifiedAfter, limit: limit).map(\.url)
    }

    static func modificationDate(of url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    static func signature(of url: URL) -> Signature? {
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) else { return nil }
        return Signature(
            modifiedAt: values.contentModificationDate?.timeIntervalSince1970 ?? 0,
            size: values.fileSize ?? 0
        )
    }

    static func discoveredFile(at url: URL, matching predicate: (URL) -> Bool) -> DiscoveredFile? {
        guard predicate(url),
              let values = try? url.resourceValues(forKeys: [
                  .isRegularFileKey,
                  .contentModificationDateKey,
                  .fileSizeKey
              ]),
              values.isRegularFile == true else { return nil }
        return DiscoveredFile(
            url: url,
            signature: Signature(
                modifiedAt: values.contentModificationDate?.timeIntervalSince1970 ?? 0,
                size: values.fileSize ?? 0
            )
        )
    }
}

/// Keeps the expensive recursive directory walk off the hot event path.
/// A full refresh records every eligible file so deleting a top-N item can
/// promote the next candidate without another tree walk. Incremental refreshes
/// stat only the paths FSEvents supplied (or one newly-created subtree).
final class IncrementalFileCatalog {
    struct Snapshot {
        let files: [FileDiscovery.DiscoveredFile]
        let didFullDiscovery: Bool
        let duration: TimeInterval
    }

    private let root: URL
    private let maxAge: TimeInterval?
    private let limit: Int?
    private let predicate: (URL) -> Bool
    private var entries: [String: FileDiscovery.DiscoveredFile] = [:]
    private var initialized = false

    init(
        root: URL,
        maxAge: TimeInterval? = nil,
        limit: Int? = nil,
        matching predicate: @escaping (URL) -> Bool
    ) {
        self.root = root.standardizedFileURL
        self.maxAge = maxAge
        self.limit = limit
        self.predicate = predicate
    }

    func invalidate() {
        initialized = false
        entries.removeAll(keepingCapacity: false)
    }

    func snapshot(now: Date, changes: AdapterChangeSet?) -> Snapshot {
        let started = Date()
        let needsFull = !initialized || changes == nil || changes?.requiresFullScan == true
        if needsFull {
            let cutoff = maxAge.map { now.addingTimeInterval(-$0) }
            let discovered = FileDiscovery.discover(
                under: root,
                matching: predicate,
                modifiedAfter: cutoff,
                limit: nil
            )
            entries = Dictionary(
                discovered.map { ($0.url.standardizedFileURL.path, $0) },
                uniquingKeysWith: { _, latest in latest }
            )
            initialized = true
        } else if let changes {
            for rawPath in changes.contentPaths {
                refresh(path: URL(fileURLWithPath: rawPath).standardizedFileURL, now: now)
            }
            pruneExpired(now: now)
        }

        let sorted = entries.values.sorted { lhs, rhs in
            if lhs.signature.modifiedAt == rhs.signature.modifiedAt {
                return lhs.url.path < rhs.url.path
            }
            return lhs.signature.modifiedAt > rhs.signature.modifiedAt
        }
        let selected = limit.map { Array(sorted.prefix($0)) } ?? sorted
        return Snapshot(
            files: selected,
            didFullDiscovery: needsFull,
            duration: Date().timeIntervalSince(started)
        )
    }

    private func refresh(path: URL, now: Date) {
        let rootPath = root.path
        let pathValue = path.path
        guard pathValue == rootPath || pathValue.hasPrefix(rootPath + "/") else { return }

        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: pathValue, isDirectory: &isDirectory)
        if !exists {
            entries.removeValue(forKey: pathValue)
            let prefix = pathValue + "/"
            entries = entries.filter { !$0.key.hasPrefix(prefix) }
            return
        }

        if isDirectory.boolValue {
            let prefix = pathValue + "/"
            entries = entries.filter { key, _ in key != pathValue && !key.hasPrefix(prefix) }
            let cutoff = maxAge.map { now.addingTimeInterval(-$0) }
            let discovered = FileDiscovery.discover(
                under: path,
                matching: predicate,
                modifiedAfter: cutoff,
                limit: nil
            )
            for file in discovered {
                entries[file.url.standardizedFileURL.path] = file
            }
            return
        }

        guard let file = FileDiscovery.discoveredFile(at: path, matching: predicate),
              isRecent(file, now: now) else {
            entries.removeValue(forKey: pathValue)
            return
        }
        entries[pathValue] = file
    }

    private func pruneExpired(now: Date) {
        guard let maxAge else { return }
        let cutoff = now.addingTimeInterval(-maxAge).timeIntervalSince1970
        entries = entries.filter { $0.value.signature.modifiedAt >= cutoff }
    }

    private func isRecent(_ file: FileDiscovery.DiscoveredFile, now: Date) -> Bool {
        guard let maxAge else { return true }
        return file.signature.modifiedAt >= now.addingTimeInterval(-maxAge).timeIntervalSince1970
    }
}

struct SnapshotCacheEntry {
    let signature: FileDiscovery.Signature
    let snapshot: SessionSnapshot
}
