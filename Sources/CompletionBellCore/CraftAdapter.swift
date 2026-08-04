import Foundation

public final class CraftAdapter: SessionAdapter {
    public let tool: ToolKind = .craft
    public var watchRoots: [URL] { [root] }
    private let root: URL
    private let catalog: IncrementalFileCatalog
    private var cache: [String: SnapshotCacheEntry] = [:]

    public init(root: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".craft-agent/workspaces")) {
        self.root = root
        self.catalog = IncrementalFileCatalog(root: root, limit: 500) { url in
            url.lastPathComponent == "session.jsonl" && url.path.contains("/sessions/")
        }
    }

    public func invalidateCache() {
        // A host-side rename is metadata-only and some Craft releases preserve
        // the session file's size and modification date. Manual refresh must
        // therefore force a metadata reread instead of trusting the signature.
        cache.removeAll(keepingCapacity: false)
        catalog.invalidate()
    }

    public func scan(now: Date = Date()) -> AdapterScanResult {
        scan(now: now, changes: nil)
    }

    public func scan(now: Date = Date(), changes: AdapterChangeSet?) -> AdapterScanResult {
        let catalogSnapshot = catalog.snapshot(now: now, changes: changes)
        let discovered = catalogSnapshot.files

        var sessions: [SessionSnapshot] = []
        var errors: [String] = []
        var parsedFileCount = 0
        let parseStarted = Date()
        for file in discovered {
            let url = file.url
            let signature = file.signature
            if let cached = cache[url.path], cached.signature == signature {
                sessions.append(cached.snapshot)
                continue
            }
            do {
                parsedFileCount += 1
                guard let metadata = try JSONLReader.firstObject(at: url),
                      let sessionID = metadata["id"] as? String else { continue }

                let objects = try JSONLReader.tailObjects(
                    at: url,
                    maxBytes: 384 * 1024,
                    containingAny: [
                        "\"type\":\"user\"", "\"type\": \"user\"",
                        "\"type\":\"assistant\"", "\"type\": \"assistant\""
                    ]
                )
                var lastUserIndex = -1
                var lastFinalAssistantIndex = -1
                var finalAssistantID: String?
                var lastUserDate: Date?
                var lastFinalAssistantDate: Date?
                var latestEventDate: Date?

                for (index, object) in objects.enumerated() {
                    if let parsed = DateParser.parse(object["timestamp"]),
                       latestEventDate == nil || parsed > latestEventDate! {
                        latestEventDate = parsed
                    }
                    guard let type = object["type"] as? String else { continue }
                    if type == "user" {
                        lastUserIndex = index
                        lastUserDate = DateParser.parse(object["timestamp"]) ?? lastUserDate
                    } else if type == "assistant", object["isIntermediate"] as? Bool != true {
                        lastFinalAssistantIndex = index
                        finalAssistantID = object["id"] as? String
                        lastFinalAssistantDate = DateParser.parse(object["timestamp"]) ?? lastFinalAssistantDate
                    }
                }

                let title = normalizedTitle(metadata["name"] as? String, fallback: "Craft 会话")
                let rawStatus = (metadata["sessionStatus"] as? String ?? "").lowercased()
                let lastRole = (metadata["lastMessageRole"] as? String ?? "").lowercased()
                let metadataFinalID = metadata["lastFinalMessageId"] as? String
                let finalID = finalAssistantID ?? metadataFinalID
                let isCompleted = lastFinalAssistantIndex >= 0
                    ? lastFinalAssistantIndex > lastUserIndex && !(finalID ?? "").isEmpty
                    : lastRole == "assistant" && !(metadataFinalID ?? "").isEmpty
                let status: SessionStatus = isCompleted
                    ? .completed
                    : runningStatus(
                        rawStatus: rawStatus,
                        lastRole: lastRole,
                        lastUserIndex: lastUserIndex,
                        lastFinalAssistantIndex: lastFinalAssistantIndex
                    )
                let modifiedAt = file.modifiedAt
                let metadataDate = DateParser.parse(metadata["lastMessageAt"])
                    ?? DateParser.parse(metadata["lastUsedAt"])
                    ?? .distantPast
                let lastActivity = [latestEventDate ?? .distantPast, metadataDate, modifiedAt].max() ?? modifiedAt
                let labels = metadata["labels"] as? [String] ?? []
                let isScheduled = metadata["triggeredBy"] is [String: Any]
                    || labels.contains { $0.caseInsensitiveCompare("Scheduled") == .orderedSame }
                let isArchived = metadata["isArchived"] as? Bool ?? false
                let origin: SessionOrigin = isScheduled ? .scheduled : (isArchived ? .detached : .interactive)
                let triggeredAt = (metadata["triggeredBy"] as? [String: Any]).flatMap { DateParser.parse($0["timestamp"]) }
                let turnStartedAt = lastUserDate ?? triggeredAt
                let turnCompletedAt = isCompleted ? (lastFinalAssistantDate ?? metadataDate) : nil

                let snapshot = SessionSnapshot(
                    tool: .craft,
                    sessionID: sessionID,
                    title: title,
                    status: status,
                    lastActivity: lastActivity,
                    completionFingerprint: isCompleted ? "craft:\(finalID!)" : nil,
                    sourceFile: url.path,
                    projectPath: metadata["workingDirectory"] as? String,
                    hasUnread: metadata["hasUnread"] as? Bool ?? false,
                    origin: origin,
                    isHostVisible: !isArchived && !isScheduled,
                    turnStartedAt: turnStartedAt,
                    turnCompletedAt: turnCompletedAt
                )
                cache[url.path] = SnapshotCacheEntry(signature: signature, snapshot: snapshot)
                sessions.append(snapshot)
            } catch {
                errors.append("\(url.lastPathComponent): \(error.localizedDescription)")
                if let cached = cache[url.path] { sessions.append(cached.snapshot) }
            }
        }
        let discoveredPaths = Set(discovered.map(\.url.path))
        cache = cache.filter { discoveredPaths.contains($0.key) }
        return AdapterScanResult(
            tool: .craft,
            sessions: sessions,
            errors: errors,
            diagnostics: AdapterScanDiagnostics(
                didFullDiscovery: catalogSnapshot.didFullDiscovery,
                changedPathCount: changes?.pathCount ?? 0,
                discoveryDuration: catalogSnapshot.duration,
                parseDuration: Date().timeIntervalSince(parseStarted),
                parsedFileCount: parsedFileCount,
                fullScanReason: changes?.fullScanReason
            )
        )
    }

    private func runningStatus(
        rawStatus: String,
        lastRole: String,
        lastUserIndex: Int,
        lastFinalAssistantIndex: Int
    ) -> SessionStatus {
        if lastUserIndex > lastFinalAssistantIndex { return .running }
        if ["running", "working", "queued", "thinking", "waiting"].contains(rawStatus) { return .running }
        if lastRole == "user" || lastRole == "tool" { return .running }
        if rawStatus == "done" { return .idle }
        return .unknown
    }

    private func normalizedTitle(_ value: String?, fallback: String) -> String {
        let title = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? fallback : title
    }
}
