import Foundation

/// Reads WorkBuddy's local session and automation state. Message bodies,
/// reasoning, tool arguments, and tool outputs are never retained or emitted.
public final class WorkBuddyAdapter: SessionAdapter {
    public let tool: ToolKind = .workBuddy
    public var watchRoots: [URL] { [root] }
    public var metadataWatchFiles: [URL] { metadataResolver?.watchFiles ?? [] }

    private let root: URL
    private let maxAge: TimeInterval
    private let maxFiles: Int
    private let completionSettleInterval: TimeInterval
    private let metadataResolver: WorkBuddyMetadataResolver?
    private let catalog: IncrementalFileCatalog
    private var cache: [String: WorkBuddyMessageCacheEntry] = [:]

    public init(
        root: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".workbuddy/projects"),
        databaseURL: URL? = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".workbuddy/workbuddy.db"),
        maxAge: TimeInterval = 14 * 24 * 60 * 60,
        maxFiles: Int = 160,
        completionSettleInterval: TimeInterval = 2.5
    ) {
        self.root = root
        self.maxAge = maxAge
        self.maxFiles = maxFiles
        self.completionSettleInterval = completionSettleInterval
        self.catalog = IncrementalFileCatalog(root: root, maxAge: maxAge, limit: maxFiles) {
            $0.pathExtension.lowercased() == "jsonl"
        }
        self.metadataResolver = databaseURL.map(WorkBuddyMetadataResolver.init(databaseURL:))
    }

    public func invalidateCache() {
        // Renames, deletion, and automation state live in SQLite and may not
        // change the conversation JSONL file.
        metadataResolver?.invalidate()
    }

    public func scan(now: Date = Date()) -> AdapterScanResult {
        scan(now: now, changes: nil)
    }

    public func scan(now: Date = Date(), changes: AdapterChangeSet?) -> AdapterScanResult {
        let metadataChanged = changes?.metadataPaths.isEmpty == false
        let shouldRefreshMetadata = metadataChanged && changes?.contentPaths.isEmpty != false
        if shouldRefreshMetadata { metadataResolver?.invalidate() }
        let metadata: WorkBuddyMetadata
        if let metadataResolver {
            if changes != nil, !shouldRefreshMetadata, metadataResolver.hasLoaded {
                metadata = metadataResolver.cachedMetadata
            } else {
                metadata = metadataResolver.metadata()
            }
        } else {
            metadata = .empty
        }
        let catalogSnapshot = catalog.snapshot(now: now, changes: changes)
        let discovered = catalogSnapshot.files

        var sessions: [SessionSnapshot] = []
        var seenSessionIDs = Set<String>()
        var errors: [String] = []
        var parsedFileCount = 0
        let parseStarted = Date()

        for file in discovered {
            let url = file.url
            let signature = file.signature
            let state: WorkBuddyMessageState
            if let cached = cache[url.path], cached.signature == signature {
                state = cached.state
            } else {
                do {
                    parsedFileCount += 1
                    state = try messageState(
                        at: url,
                        signature: signature,
                        previous: cache[url.path]?.state
                    )
                    cache[url.path] = WorkBuddyMessageCacheEntry(signature: signature, state: state)
                } catch {
                    errors.append("\(url.lastPathComponent): \(error.localizedDescription)")
                    guard let cached = cache[url.path] else { continue }
                    state = cached.state
                }
            }

            let record = metadata.sessions[state.sessionID]
            sessions.append(snapshot(
                from: state,
                record: record,
                isScheduled: metadata.scheduledSessionIDs.contains(state.sessionID),
                now: now
            ))
            seenSessionIDs.insert(state.sessionID)
        }

        // WorkBuddy writes the SQLite session row before the first JSONL event.
        // Including recent active rows avoids the several-second blind spot at
        // the beginning of a task.
        for record in metadata.sessions.values where !seenSessionIDs.contains(record.id) {
            guard Self.activeStatuses.contains(record.status.lowercased()) else { continue }
            guard now.timeIntervalSince(record.lastActivity) <= maxAge else { continue }
            sessions.append(snapshot(
                fromActiveRecord: record,
                isScheduled: metadata.scheduledSessionIDs.contains(record.id)
            ))
            seenSessionIDs.insert(record.id)
        }

        // A WorkBuddy automation run may have a database result before its
        // conversation file is materialized. It belongs to the routine inbox,
        // not to background runtime noise.
        for run in metadata.automationRuns where !seenSessionIDs.contains(run.threadID) {
            sessions.append(snapshot(from: run))
            seenSessionIDs.insert(run.threadID)
        }

        let discoveredPaths = Set(discovered.map(\.url.path))
        cache = cache.filter { discoveredPaths.contains($0.key) }
        return AdapterScanResult(
            tool: .workBuddy,
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

    private func messageState(
        at url: URL,
        signature: FileDiscovery.Signature,
        previous: WorkBuddyMessageState?
    ) throws -> WorkBuddyMessageState {
        guard let latest = try JSONLReader.lastObject(
            at: url,
            containingAny: ["\"type\":\"message\"", "\"role\":\"user\"", "\"role\":\"assistant\""],
            matching: { object in
                guard (object["type"] as? String)?.lowercased() == "message",
                      let role = (object["role"] as? String)?.lowercased() else { return false }
                return role == "user" || role == "assistant"
            }
        ) else {
            throw WorkBuddyAdapterError.noMessageRecord
        }

        let sessionID = ((latest["sessionId"] as? String)?.trimmedNonEmpty)
            ?? url.deletingPathExtension().lastPathComponent
        let role = (latest["role"] as? String ?? "").lowercased()
        let messageID = (latest["id"] as? String)?.trimmedNonEmpty ?? "message-\(signature.size)"
        let messageTimestamp = DateParser.parse(latest["timestamp"])
        let modifiedAt = FileDiscovery.modificationDate(of: url)

        let shouldReloadUser = role == "user"
            || previous == nil
            || previous?.latestMessageID != messageID
        let lastUser: [String: Any]?
        if role == "user" {
            lastUser = latest
        } else if shouldReloadUser {
            lastUser = try JSONLReader.lastObject(
                at: url,
                containingAny: ["\"role\":\"user\""],
                matching: { object in
                    (object["type"] as? String)?.lowercased() == "message"
                        && (object["role"] as? String)?.lowercased() == "user"
                }
            )
        } else {
            lastUser = nil
        }

        let turnStartedAt = DateParser.parse(lastUser?["timestamp"])
            ?? previous?.turnStartedAt
            ?? messageTimestamp
            ?? modifiedAt
        let lastUserID = (lastUser?["id"] as? String)?.trimmedNonEmpty
            ?? previous?.lastUserID
            ?? "user-\(Int(turnStartedAt.timeIntervalSince1970 * 1_000))"
        let messageStatus = (latest["status"] as? String ?? "").lowercased()
        let phase: WorkBuddyMessagePhase = role == "assistant"
            && Self.terminalStatuses.contains(messageStatus)
            ? .finalCandidate
            : .running
        let activity = max(modifiedAt, messageTimestamp ?? .distantPast)

        return WorkBuddyMessageState(
            sessionID: sessionID,
            latestMessageID: messageID,
            lastUserID: lastUserID,
            phase: phase,
            lastActivity: activity,
            turnStartedAt: turnStartedAt,
            turnCompletedAt: phase == .finalCandidate ? (messageTimestamp ?? modifiedAt) : nil,
            completionFingerprint: phase == .finalCandidate
                ? "workbuddy:\(lastUserID):\(messageID)"
                : nil,
            sourceFile: url.path
        )
    }

    private func snapshot(
        from state: WorkBuddyMessageState,
        record: WorkBuddySessionRecord?,
        isScheduled: Bool,
        now: Date
    ) -> SessionSnapshot {
        // The JSONL is authoritative for a new user turn. WorkBuddy can leave
        // the database status on "completed" briefly after the user replies.
        let fileHasSettled = now.timeIntervalSince(state.lastActivity) >= completionSettleInterval
        let completed = state.phase == .finalCandidate && fileHasSettled
        let origin = sessionOrigin(record: record, isScheduled: isScheduled)
        let lastActivity = max(state.lastActivity, record?.lastActivity ?? .distantPast)
        let title = record?.displayTitle
            ?? (origin == .scheduled
                ? "WorkBuddy 例行任务"
                : "WorkBuddy · \(state.sessionID.prefix(8))")

        return SessionSnapshot(
            tool: .workBuddy,
            sessionID: state.sessionID,
            title: title,
            status: completed ? .completed : .running,
            lastActivity: lastActivity,
            completionFingerprint: completed ? state.completionFingerprint : nil,
            sourceFile: state.sourceFile,
            projectPath: record?.cwd,
            origin: origin,
            isHostVisible: record?.deletedAt == nil && origin == .interactive,
            turnStartedAt: state.turnStartedAt,
            turnCompletedAt: completed ? state.turnCompletedAt : nil
        )
    }

    private func snapshot(
        fromActiveRecord record: WorkBuddySessionRecord,
        isScheduled: Bool
    ) -> SessionSnapshot {
        let origin = sessionOrigin(record: record, isScheduled: isScheduled)
        return SessionSnapshot(
            tool: .workBuddy,
            sessionID: record.id,
            title: record.displayTitle ?? "WorkBuddy · \(record.id.prefix(8))",
            status: .running,
            lastActivity: record.lastActivity,
            completionFingerprint: nil,
            sourceFile: metadataResolver?.databasePath ?? "~/.workbuddy/workbuddy.db",
            projectPath: record.cwd,
            origin: origin,
            isHostVisible: record.deletedAt == nil && origin == .interactive,
            turnStartedAt: record.createdAt,
            turnCompletedAt: nil
        )
    }

    private func snapshot(from run: WorkBuddyAutomationRunRecord) -> SessionSnapshot {
        let rawStatus = run.status.lowercased()
        let completed = Self.terminalStatuses.contains(rawStatus)
        let sessionID = run.threadID.trimmedNonEmpty ?? "automation:\(run.automationID)"
        return SessionSnapshot(
            tool: .workBuddy,
            sessionID: sessionID,
            title: run.title.trimmedNonEmpty ?? "WorkBuddy 例行任务",
            status: completed ? .completed : .running,
            lastActivity: run.updatedAt,
            completionFingerprint: completed
                ? "workbuddy-automation:\(sessionID):\(rawStatus):\(Int(run.updatedAt.timeIntervalSince1970 * 1_000))"
                : nil,
            sourceFile: metadataResolver?.databasePath ?? "~/.workbuddy/workbuddy.db",
            projectPath: run.sourceCWD,
            origin: .scheduled,
            isHostVisible: false,
            turnStartedAt: run.createdAt,
            turnCompletedAt: completed ? run.updatedAt : nil
        )
    }

    private func sessionOrigin(record: WorkBuddySessionRecord?, isScheduled: Bool) -> SessionOrigin {
        guard let record else { return isScheduled ? .scheduled : .detached }
        if isScheduled || record.isBackgroundAutomation { return .scheduled }
        if record.deletedAt != nil { return .detached }
        let source = record.sourceMode.lowercased()
        if source.contains("automation") || source.contains("scheduled") { return .scheduled }
        return .interactive
    }

    fileprivate static let terminalStatuses: Set<String> = [
        "completed", "complete", "done", "success", "succeeded", "error", "failed",
        "timeout", "cancelled", "canceled", "stopped"
    ]
    fileprivate static let activeStatuses: Set<String> = [
        "pending", "queued", "starting", "started", "running", "in_progress", "working"
    ]
}

private enum WorkBuddyAdapterError: LocalizedError {
    case noMessageRecord

    var errorDescription: String? {
        switch self {
        case .noMessageRecord: return "没有找到可识别的 WorkBuddy 会话状态"
        }
    }
}

private enum WorkBuddyMessagePhase {
    case running
    case finalCandidate
}

private struct WorkBuddyMessageState {
    let sessionID: String
    let latestMessageID: String
    let lastUserID: String
    let phase: WorkBuddyMessagePhase
    let lastActivity: Date
    let turnStartedAt: Date
    let turnCompletedAt: Date?
    let completionFingerprint: String?
    let sourceFile: String
}

private struct WorkBuddyMessageCacheEntry {
    let signature: FileDiscovery.Signature
    let state: WorkBuddyMessageState
}

private struct WorkBuddySessionRecord {
    let id: String
    let title: String?
    let customTitle: String?
    let status: String
    let cwd: String?
    let sourceMode: String
    let isBackgroundAutomation: Bool
    let createdAt: Date
    let updatedAt: Date
    let lastActivityAt: Date?
    let deletedAt: Date?

    var displayTitle: String? { customTitle?.trimmedNonEmpty ?? title?.trimmedNonEmpty }
    var lastActivity: Date { max(lastActivityAt ?? .distantPast, updatedAt) }
}

private struct WorkBuddyAutomationRunRecord {
    let threadID: String
    let automationID: String
    let status: String
    let title: String
    let sourceCWD: String?
    let createdAt: Date
    let updatedAt: Date
}

private struct WorkBuddyMetadata {
    let sessions: [String: WorkBuddySessionRecord]
    let automationRuns: [WorkBuddyAutomationRunRecord]
    let scheduledSessionIDs: Set<String>

    static let empty = WorkBuddyMetadata(sessions: [:], automationRuns: [], scheduledSessionIDs: [])
}

private final class WorkBuddyMetadataResolver {
    private struct StorageSignature: Equatable {
        let database: FileDiscovery.Signature?
        let writeAheadLog: FileDiscovery.Signature?
    }

    private let databaseURL: URL
    private var cache = WorkBuddyMetadata.empty
    private var lastLoadedAt = Date.distantPast
    private var lastStorageSignature: StorageSignature?

    init(databaseURL: URL) {
        self.databaseURL = databaseURL
    }

    var watchFiles: [URL] {
        [databaseURL, URL(fileURLWithPath: databaseURL.path + "-wal")]
    }

    var databasePath: String { databaseURL.path }

    func invalidate() {
        lastLoadedAt = .distantPast
        lastStorageSignature = nil
    }

    var hasLoaded: Bool { lastStorageSignature != nil }
    var cachedMetadata: WorkBuddyMetadata { cache }

    func metadata() -> WorkBuddyMetadata {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return .empty }
        let now = Date()
        let signature = StorageSignature(
            database: FileDiscovery.signature(of: databaseURL),
            writeAheadLog: FileDiscovery.signature(of: URL(fileURLWithPath: databaseURL.path + "-wal"))
        )
        if signature == lastStorageSignature, now.timeIntervalSince(lastLoadedAt) < 30 {
            return cache
        }

        let sessionSQL = """
        SELECT id, title, custom_title, status, cwd, source_mode,
               is_background_automation, created_at, updated_at,
               last_activity_at, deleted_at
        FROM sessions;
        """
        let sessionRows = WorkBuddySQLiteJSON.query(databaseURL: databaseURL, sql: sessionSQL) ?? []
        var sessions: [String: WorkBuddySessionRecord] = [:]
        for row in sessionRows {
            guard let id = row["id"] as? String else { continue }
            let createdAt = DateParser.parse(row["created_at"]) ?? .distantPast
            let updatedAt = DateParser.parse(row["updated_at"]) ?? createdAt
            sessions[id] = WorkBuddySessionRecord(
                id: id,
                title: row["title"] as? String,
                customTitle: row["custom_title"] as? String,
                status: row["status"] as? String ?? "pending",
                cwd: (row["cwd"] as? String)?.trimmedNonEmpty,
                sourceMode: row["source_mode"] as? String ?? "working",
                isBackgroundAutomation: (row["is_background_automation"] as? NSNumber)?.boolValue ?? false,
                createdAt: createdAt,
                updatedAt: updatedAt,
                lastActivityAt: DateParser.parse(row["last_activity_at"]),
                deletedAt: DateParser.parse(row["deleted_at"])
            )
        }

        let runSQL = """
        SELECT ar.thread_id, ar.automation_id, ar.status,
               COALESCE(NULLIF(ar.thread_title, ''), a.name, '') AS title,
               ar.source_cwd, ar.created_at, ar.updated_at
        FROM automation_runs ar
        LEFT JOIN automations a ON a.id = ar.automation_id;
        """
        let runRows = WorkBuddySQLiteJSON.query(databaseURL: databaseURL, sql: runSQL) ?? []
        var scheduledSessionIDs = Set<String>()
        var runs: [WorkBuddyAutomationRunRecord] = []
        for row in runRows {
            guard let threadID = row["thread_id"] as? String,
                  let automationID = row["automation_id"] as? String else { continue }
            let createdAt = DateParser.parse(row["created_at"]) ?? .distantPast
            let updatedAt = DateParser.parse(row["updated_at"]) ?? createdAt
            scheduledSessionIDs.insert(threadID)
            runs.append(WorkBuddyAutomationRunRecord(
                threadID: threadID,
                automationID: automationID,
                status: row["status"] as? String ?? "running",
                title: row["title"] as? String ?? "",
                sourceCWD: (row["source_cwd"] as? String)?.trimmedNonEmpty,
                createdAt: createdAt,
                updatedAt: updatedAt
            ))
        }

        let runtimeSQL = """
        SELECT running_conversation_id
        FROM automation_runtime_state
        WHERE running = 1 AND running_conversation_id IS NOT NULL;
        """
        let runtimeRows = WorkBuddySQLiteJSON.query(databaseURL: databaseURL, sql: runtimeSQL) ?? []
        for row in runtimeRows {
            if let id = (row["running_conversation_id"] as? String)?.trimmedNonEmpty {
                scheduledSessionIDs.insert(id)
            }
        }

        cache = WorkBuddyMetadata(
            sessions: sessions,
            automationRuns: runs,
            scheduledSessionIDs: scheduledSessionIDs
        )
        lastLoadedAt = now
        lastStorageSignature = signature
        return cache
    }
}

private enum WorkBuddySQLiteJSON {
    static func query(databaseURL: URL, sql: String) -> [[String: Any]]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-readonly", "-json", databaseURL.path, sql]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        } catch {
            return nil
        }
    }
}

private extension String {
    var trimmedNonEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
