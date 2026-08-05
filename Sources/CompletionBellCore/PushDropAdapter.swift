import Foundation

/// The push half of Bladecall's integration story. Watched tools are read at
/// the source; every other agent can *report itself* by writing one small JSON
/// file — no per-tool adapter, no reverse engineering:
///
///     ~/.jianling/drops/<tool>/<sessionID>.json
///     {
///       "schemaVersion": 1,
///       "title": "Refactor login flow",
///       "status": "started" | "progress" | "done" | "failed",
///       "timestamp": "2026-08-04T12:00:00Z",
///       "projectPath": "/path/to/repo",      // optional
///       "origin": "interactive" | "scheduled" | "subagent"   // optional
///     }
///
/// The tool slug and session identity come from the file's location, not from
/// the payload — a drop cannot claim to be another tool. Self-reports are
/// honest about their nature: a `done` drop is the agent's own claim, so these
/// sessions surface under the External tier rather than pretending to be
/// natively watched.
public final class PushDropAdapter: SessionAdapter {
    public static let defaultRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".jianling/drops")

    /// Statuses an agent may report. Anything else is a bad drop and is
    /// isolated as an error instead of guessing.
    public static let allowedStatuses: Set<String> = ["started", "progress", "done", "failed"]

    public let tool: ToolKind = .external
    public var watchRoots: [URL] { [root] }

    private let root: URL
    private let catalog: IncrementalFileCatalog
    private var cache: [String: SnapshotCacheEntry] = [:]

    public init(root: URL = PushDropAdapter.defaultRoot) {
        self.root = root.standardizedFileURL
        self.catalog = IncrementalFileCatalog(root: root, limit: 400) { url in
            url.pathExtension == "json"
        }
        // The drop directory is Bladecall's own integration point. Creating it
        // up front both advertises the contract and guarantees the FSEvents
        // watcher has a root to attach to on first launch.
        try? FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
    }

    public func invalidateCache() {
        cache.removeAll(keepingCapacity: false)
        catalog.invalidate()
    }

    public func scan(now: Date = Date()) -> AdapterScanResult {
        scan(now: now, changes: nil)
    }

    public func scan(now: Date = Date(), changes: AdapterChangeSet?) -> AdapterScanResult {
        let catalogSnapshot = catalog.snapshot(now: now, changes: changes)

        var sessions: [SessionSnapshot] = []
        var errors: [String] = []
        var parsedFileCount = 0
        let parseStarted = Date()
        for file in catalogSnapshot.files {
            let url = file.url
            if let cached = cache[url.path], cached.signature == file.signature {
                sessions.append(cached.snapshot)
                continue
            }
            parsedFileCount += 1
            // Identity comes from the path: drops/<slug>/<file>.json.
            guard url.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL.path == root.path,
                  let slug = Self.sanitizedSlug(url.deletingLastPathComponent().lastPathComponent) else {
                errors.append("push: drop outside <tool>/ layout at \(url.lastPathComponent)")
                continue
            }
            do {
                let data = try Data(contentsOf: url)
                guard data.count <= 64 * 1024 else {
                    errors.append("push:\(slug)/\(url.lastPathComponent) exceeds 64KB")
                    continue
                }
                guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    errors.append("push:\(slug)/\(url.lastPathComponent) is not a JSON object")
                    continue
                }
                let mapping = Self.snapshot(
                    slug: slug,
                    fileID: url.deletingPathExtension().lastPathComponent,
                    object: object,
                    fileModified: file.modifiedAt,
                    sourceFile: url.path
                )
                if let snapshot = mapping.snapshot {
                    cache[url.path] = SnapshotCacheEntry(signature: file.signature, snapshot: snapshot)
                    sessions.append(snapshot)
                } else if let reason = mapping.error {
                    errors.append("push:\(slug)/\(url.lastPathComponent): \(reason)")
                }
            } catch {
                errors.append("push:\(slug)/\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }

        // Cache hygiene: forget files that no longer exist.
        let livePaths = Set(catalogSnapshot.files.map(\.url.path))
        if cache.count > livePaths.count {
            cache = cache.filter { livePaths.contains($0.key) }
        }

        return AdapterScanResult(
            tool: .external,
            sessions: sessions,
            errors: errors,
            diagnostics: AdapterScanDiagnostics(
                didFullDiscovery: catalogSnapshot.didFullDiscovery,
                changedPathCount: changes?.pathCount ?? 0,
                discoveryDuration: catalogSnapshot.duration,
                parseDuration: Date().timeIntervalSince(parseStarted),
                parsedFileCount: parsedFileCount
            )
        )
    }

    // MARK: - Pure mapping (tested without a filesystem)

    /// Lowercased tool slug safe for identity and asset lookup. Rejects
    /// anything that could smuggle path segments or look unlike a tool id.
    public static func sanitizedSlug(_ raw: String) -> String? {
        let slug = raw.lowercased()
        guard !slug.isEmpty, slug.count <= 40,
              slug.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }),
              slug != ".", slug != ".." else { return nil }
        return slug
    }

    /// Maps one drop payload to a session snapshot. `fileModified` anchors
    /// times when the payload omits a timestamp; the explicit timestamp wins
    /// so rewriting an identical `done` does not mint a fresh fingerprint.
    public static func snapshot(
        slug: String,
        fileID: String,
        object: [String: Any],
        fileModified: Date,
        sourceFile: String
    ) -> (snapshot: SessionSnapshot?, error: String?) {
        guard let statusRaw = (object["status"] as? String)?.lowercased(),
              allowedStatuses.contains(statusRaw) else {
            return (nil, "status must be one of \(allowedStatuses.sorted().joined(separator: "|"))")
        }
        let timestampString = object["timestamp"] as? String
        let reportedAt = DateParser.parse(object["timestamp"]) ?? fileModified
        let title = ((object["title"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines))
            .flatMap { $0.isEmpty ? nil : $0 } ?? fileID
        let origin: SessionOrigin
        switch (object["origin"] as? String)?.lowercased() {
        case "scheduled": origin = .scheduled
        case "subagent": origin = .subagent
        default: origin = .interactive
        }
        let fingerprintSeed = timestampString ?? String(reportedAt.timeIntervalSince1970)
        let sessionID = "\(slug)/\(fileID)"

        let status: SessionStatus
        var fingerprint: String?
        var turnStartedAt: Date?
        var turnCompletedAt: Date?
        switch statusRaw {
        case "started":
            status = .running
            turnStartedAt = reportedAt
        case "progress":
            status = .running
        case "done":
            status = .completed
            fingerprint = "push:\(sessionID):done:\(fingerprintSeed)"
            turnCompletedAt = reportedAt
        case "failed":
            // A reported failure is still a report-back worth a glance —
            // unlike a silent crash, which simply stops updating and ages out.
            status = .completed
            fingerprint = "push:\(sessionID):failed:\(fingerprintSeed)"
            turnCompletedAt = reportedAt
        default:
            return (nil, "unreachable status")
        }

        return (
            SessionSnapshot(
                tool: .external,
                sessionID: sessionID,
                title: title,
                status: status,
                lastActivity: reportedAt,
                completionFingerprint: fingerprint,
                sourceFile: sourceFile,
                projectPath: object["projectPath"] as? String,
                origin: origin,
                isHostVisible: true,
                turnStartedAt: turnStartedAt,
                turnCompletedAt: turnCompletedAt,
                externalTool: slug
            ),
            nil
        )
    }
}
