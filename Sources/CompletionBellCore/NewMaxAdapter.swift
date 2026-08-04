import Foundation

/// Reads NewMax's local conversation state without retaining or exposing
/// message bodies. Titles and task metadata come from SQLite; the JSONL reader
/// only uses roles, timestamps, message IDs, and tool-call statuses.
public final class NewMaxAdapter: SessionAdapter {
    public let tool: ToolKind = .newMax
    public var watchRoots: [URL] { [root] }
    public var metadataWatchFiles: [URL] {
        (metadataResolver?.watchFiles ?? []) + (hermesResolver?.watchFiles ?? [])
    }

    private let root: URL
    private let maxAge: TimeInterval
    private let maxFiles: Int
    private let completionSettleInterval: TimeInterval
    private let metadataResolver: NewMaxMetadataResolver?
    private let hermesResolver: NewMaxHermesResolver?
    private let catalog: IncrementalFileCatalog
    private var cache: [String: NewMaxMessageCacheEntry] = [:]

    public init(
        root: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".newmax/conversations"),
        databaseURL: URL? = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".newmax/newmax.db"),
        hermesDatabaseURL: URL? = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".newmax/hermes-tasks.db"),
        maxAge: TimeInterval = 14 * 24 * 60 * 60,
        maxFiles: Int = 120,
        completionSettleInterval: TimeInterval = 2.5
    ) {
        self.root = root
        self.maxAge = maxAge
        self.maxFiles = maxFiles
        self.completionSettleInterval = completionSettleInterval
        self.catalog = IncrementalFileCatalog(root: root, maxAge: maxAge, limit: maxFiles) {
            $0.lastPathComponent == "messages.jsonl"
        }
        self.metadataResolver = databaseURL.map(NewMaxMetadataResolver.init(databaseURL:))
        self.hermesResolver = hermesDatabaseURL.map(NewMaxHermesResolver.init(databaseURL:))
    }

    public func invalidateCache() {
        // Conversation renames and execution-state updates live in SQLite and
        // do not necessarily touch messages.jsonl.
        metadataResolver?.invalidate()
        hermesResolver?.invalidate()
    }

    public func scan(now: Date = Date()) -> AdapterScanResult {
        scan(now: now, changes: nil)
    }

    public func scan(now: Date = Date(), changes: AdapterChangeSet?) -> AdapterScanResult {
        let metadataChanged = changes?.metadataPaths.isEmpty == false
        let shouldRefreshMetadata = metadataChanged && changes?.contentPaths.isEmpty != false
        if shouldRefreshMetadata {
            metadataResolver?.invalidate()
            hermesResolver?.invalidate()
        }
        let records: [String: NewMaxConversationRecord]
        if let metadataResolver {
            if changes != nil, !shouldRefreshMetadata, metadataResolver.hasLoaded {
                records = metadataResolver.cachedRecords
            } else {
                records = metadataResolver.records()
            }
        } else {
            records = [:]
        }
        let catalogSnapshot = catalog.snapshot(now: now, changes: changes)
        let discovered = catalogSnapshot.files

        var sessions: [SessionSnapshot] = []
        var errors: [String] = []
        var parsedFileCount = 0
        let parseStarted = Date()
        for file in discovered {
            let url = file.url
            let signature = file.signature
            let state: NewMaxMessageState
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
                    cache[url.path] = NewMaxMessageCacheEntry(signature: signature, state: state)
                } catch {
                    errors.append("\(url.deletingLastPathComponent().lastPathComponent): \(error.localizedDescription)")
                    guard let cached = cache[url.path] else { continue }
                    state = cached.state
                }
            }

            let record = records[state.sessionID]
            sessions.append(snapshot(from: state, record: record, now: now))
        }

        if let hermesResolver {
            let refreshHermes = changes == nil || shouldRefreshMetadata || !hermesResolver.hasLoaded
            sessions.append(contentsOf: hermesResolver.snapshots(refresh: refreshHermes))
        }

        let discoveredPaths = Set(discovered.map(\.url.path))
        cache = cache.filter { discoveredPaths.contains($0.key) }
        return AdapterScanResult(
            tool: .newMax,
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
        previous: NewMaxMessageState?
    ) throws -> NewMaxMessageState {
        guard let latest = try JSONLReader.lastObject(at: url, matching: { object in
            guard let role = object["role"] as? String else { return false }
            return role == "user" || role == "assistant"
        }) else {
            throw NewMaxAdapterError.noMessageRecord
        }

        let sessionID = url.deletingLastPathComponent().lastPathComponent
        let role = (latest["role"] as? String ?? "").lowercased()
        let messageID = (latest["id"] as? String)?.nonEmpty ?? "message-\(signature.size)"
        let timestamp = DateParser.parse(latest["timestamp"])
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
                matching: { ($0["role"] as? String)?.lowercased() == "user" }
            )
        } else {
            lastUser = nil
        }

        let turnStartedAt = DateParser.parse(lastUser?["timestamp"])
            ?? previous?.turnStartedAt
            ?? timestamp
            ?? modifiedAt
        let lastUserID = (lastUser?["id"] as? String)?.nonEmpty
            ?? previous?.lastUserID
            ?? "user-\(Int(turnStartedAt.timeIntervalSince1970 * 1_000))"

        let toolCalls = latest["toolCalls"] as? [[String: Any]] ?? []
        let hasActiveToolCall = toolCalls.contains { call in
            let status = (call["status"] as? String ?? "").lowercased()
            return !Self.terminalToolStatuses.contains(status)
        }
        // NewMax keeps the final answer in this top-level string. We only test
        // whether a final response exists; the text is never stored or emitted.
        let hasFinalResponse = (latest["content"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false

        let phase: NewMaxMessagePhase
        if role == "user" || hasActiveToolCall || !hasFinalResponse {
            phase = .running
        } else {
            phase = .finalCandidate
        }

        return NewMaxMessageState(
            sessionID: sessionID,
            latestMessageID: messageID,
            lastUserID: lastUserID,
            phase: phase,
            lastActivity: max(modifiedAt, timestamp ?? .distantPast),
            turnStartedAt: turnStartedAt,
            completionFingerprint: phase == .finalCandidate
                ? "newmax:\(lastUserID):\(messageID):\(signature.size)"
                : nil,
            sourceFile: url.path
        )
    }

    private func snapshot(
        from state: NewMaxMessageState,
        record: NewMaxConversationRecord?,
        now: Date
    ) -> SessionSnapshot {
        let executionStatus = record?.executionStatus?.lowercased()
        let executionIsTerminal = executionStatus.map(Self.terminalExecutionStatuses.contains) == true
        let executionIsActive = executionStatus.map(Self.activeExecutionStatuses.contains) == true
        let fileHasSettled = now.timeIntervalSince(state.lastActivity) >= completionSettleInterval

        let completed = executionIsTerminal
            || (!executionIsActive && state.phase == .finalCandidate && fileHasSettled)
        let status: SessionStatus = completed ? .completed : .running
        let origin = sessionOrigin(record: record)
        let lastActivity = [
            state.lastActivity,
            record?.updatedAt ?? .distantPast,
            record?.executionFinishedAt ?? .distantPast,
            record?.executionStartedAt ?? .distantPast
        ].max() ?? state.lastActivity
        let completedAt = completed
            ? (record?.executionFinishedAt ?? state.lastActivity)
            : nil
        let fingerprint: String?
        if executionIsTerminal, let record {
            let marker = record.executionFinishedAt?.timeIntervalSince1970
                ?? record.updatedAt.timeIntervalSince1970
            fingerprint = "newmax-execution:\(record.executionID ?? record.id):\(executionStatus ?? "done"):\(Int(marker * 1_000))"
        } else {
            fingerprint = completed ? state.completionFingerprint : nil
        }

        let title = record?.title.nonEmpty
            ?? (origin == .subagent
                ? "NewMax 子 Agent · \(state.sessionID.prefix(8))"
                : "NewMax · \(state.sessionID.prefix(8))")
        let isHostVisible = record != nil
            && !record!.isArchived
            && origin == .interactive

        return SessionSnapshot(
            tool: .newMax,
            sessionID: state.sessionID,
            title: title,
            status: status,
            lastActivity: lastActivity,
            completionFingerprint: fingerprint,
            sourceFile: state.sourceFile,
            projectPath: record?.workspacePath,
            origin: origin,
            isHostVisible: isHostVisible,
            turnStartedAt: record?.executionStartedAt ?? state.turnStartedAt,
            turnCompletedAt: completedAt
        )
    }

    private func sessionOrigin(record: NewMaxConversationRecord?) -> SessionOrigin {
        guard let record else { return .subagent }
        let source = record.source.lowercased()
        let executionType = record.executionType?.lowercased()

        if source.contains("scheduled")
            || source.contains("automation")
            || source == "daily_review"
            || executionType == "auto" {
            return .scheduled
        }
        if record.isArchived { return .detached }
        if source == "app" { return .interactive }
        return .externalRuntime
    }

    private static let terminalToolStatuses: Set<String> = [
        "completed", "complete", "success", "succeeded", "error", "failed", "cancelled", "canceled"
    ]
    private static let terminalExecutionStatuses: Set<String> = [
        "completed", "complete", "done", "success", "succeeded", "error", "failed", "timeout", "cancelled", "canceled"
    ]
    private static let activeExecutionStatuses: Set<String> = [
        "pending", "queued", "starting", "started", "running", "in_progress"
    ]
}

private enum NewMaxAdapterError: LocalizedError {
    case noMessageRecord

    var errorDescription: String? {
        switch self {
        case .noMessageRecord: return "没有找到可识别的会话状态"
        }
    }
}

private enum NewMaxMessagePhase {
    case running
    case finalCandidate
}

private struct NewMaxMessageState {
    let sessionID: String
    let latestMessageID: String
    let lastUserID: String
    let phase: NewMaxMessagePhase
    let lastActivity: Date
    let turnStartedAt: Date
    let completionFingerprint: String?
    let sourceFile: String
}

private struct NewMaxMessageCacheEntry {
    let signature: FileDiscovery.Signature
    let state: NewMaxMessageState
}

private struct NewMaxConversationRecord {
    let id: String
    let title: String
    let source: String
    let executionID: String?
    let executionStatus: String?
    let executionType: String?
    let executionStartedAt: Date?
    let executionFinishedAt: Date?
    let workspacePath: String?
    let updatedAt: Date
    let isArchived: Bool
}

private final class NewMaxMetadataResolver {
    private struct StorageSignature: Equatable {
        let database: FileDiscovery.Signature?
        let writeAheadLog: FileDiscovery.Signature?
    }

    private let databaseURL: URL
    private var cache: [String: NewMaxConversationRecord] = [:]
    private var lastLoadedAt = Date.distantPast
    private var lastStorageSignature: StorageSignature?

    init(databaseURL: URL) {
        self.databaseURL = databaseURL
    }

    var watchFiles: [URL] {
        [databaseURL, URL(fileURLWithPath: databaseURL.path + "-wal")]
    }

    func invalidate() {
        lastLoadedAt = .distantPast
        lastStorageSignature = nil
    }

    var hasLoaded: Bool { lastStorageSignature != nil }
    var cachedRecords: [String: NewMaxConversationRecord] { cache }

    func records() -> [String: NewMaxConversationRecord] {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return [:] }
        let now = Date()
        let signature = StorageSignature(
            database: FileDiscovery.signature(of: databaseURL),
            writeAheadLog: FileDiscovery.signature(of: URL(fileURLWithPath: databaseURL.path + "-wal"))
        )
        if signature == lastStorageSignature, now.timeIntervalSince(lastLoadedAt) < 30 {
            return cache
        }

        let sql = """
        SELECT c.id,
               c.title,
               c.source,
               c.execution_id,
               c.updated_at,
               c.is_archived,
               w.path AS workspace_path,
               te.status AS execution_status,
               te.started_at AS execution_started_at,
               te.finished_at AS execution_finished_at,
               pt.execution_type
        FROM conversations c
        LEFT JOIN workspaces w ON w.id = c.workspace_id
        LEFT JOIN task_executions te ON te.id = COALESCE(
            NULLIF(c.execution_id, ''),
            (SELECT latest.id
             FROM task_executions latest
             WHERE latest.conversation_id = c.id
             ORDER BY latest.started_at DESC
             LIMIT 1)
        )
        LEFT JOIN project_tasks pt ON pt.id = te.task_id;
        """
        guard let rows = SQLiteJSON.query(databaseURL: databaseURL, sql: sql) else { return cache }

        var updated: [String: NewMaxConversationRecord] = [:]
        for row in rows {
            guard let id = row["id"] as? String else { continue }
            updated[id] = NewMaxConversationRecord(
                id: id,
                title: (row["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                source: row["source"] as? String ?? "app",
                executionID: (row["execution_id"] as? String)?.nonEmpty,
                executionStatus: (row["execution_status"] as? String)?.nonEmpty,
                executionType: (row["execution_type"] as? String)?.nonEmpty,
                executionStartedAt: DateParser.parse(row["execution_started_at"]),
                executionFinishedAt: DateParser.parse(row["execution_finished_at"]),
                workspacePath: (row["workspace_path"] as? String)?.nonEmpty,
                updatedAt: DateParser.parse(row["updated_at"]) ?? .distantPast,
                isArchived: (row["is_archived"] as? NSNumber)?.boolValue ?? false
            )
        }
        cache = updated
        lastLoadedAt = now
        lastStorageSignature = signature
        return cache
    }
}

private struct NewMaxHermesRecord {
    let id: String
    let title: String
    let status: String
    let source: String
    let createdAt: Date
    let completedAt: Date?
}

private final class NewMaxHermesResolver {
    private struct StorageSignature: Equatable {
        let database: FileDiscovery.Signature?
        let writeAheadLog: FileDiscovery.Signature?
    }

    private let databaseURL: URL
    private var cache: [NewMaxHermesRecord] = []
    private var lastLoadedAt = Date.distantPast
    private var lastStorageSignature: StorageSignature?

    init(databaseURL: URL) {
        self.databaseURL = databaseURL
    }

    var watchFiles: [URL] {
        [databaseURL, URL(fileURLWithPath: databaseURL.path + "-wal")]
    }

    func invalidate() {
        lastLoadedAt = .distantPast
        lastStorageSignature = nil
    }

    var hasLoaded: Bool { lastStorageSignature != nil }

    func snapshots(refresh: Bool = true) -> [SessionSnapshot] {
        let source = refresh ? records() : cache
        return source.map { record in
            let rawStatus = record.status.lowercased()
            let completed = NewMaxAdapterTerminalStatuses.execution.contains(rawStatus)
            let scheduled = record.source.lowercased().contains("scheduled")
                || record.source.lowercased().contains("automation")
            return SessionSnapshot(
                tool: .newMax,
                sessionID: "hermes:\(record.id)",
                title: record.title.nonEmpty ?? "NewMax 幕后任务",
                status: completed ? .completed : .running,
                lastActivity: record.completedAt ?? record.createdAt,
                completionFingerprint: completed
                    ? "newmax-hermes:\(record.id):\(rawStatus):\(Int((record.completedAt ?? record.createdAt).timeIntervalSince1970 * 1_000))"
                    : nil,
                sourceFile: databaseURL.path,
                origin: scheduled ? .scheduled : .externalRuntime,
                isHostVisible: false,
                turnStartedAt: record.createdAt,
                turnCompletedAt: completed ? (record.completedAt ?? record.createdAt) : nil
            )
        }
    }

    private func records() -> [NewMaxHermesRecord] {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return [] }
        let now = Date()
        let signature = StorageSignature(
            database: FileDiscovery.signature(of: databaseURL),
            writeAheadLog: FileDiscovery.signature(of: URL(fileURLWithPath: databaseURL.path + "-wal"))
        )
        if signature == lastStorageSignature, now.timeIntervalSince(lastLoadedAt) < 30 {
            return cache
        }
        let sql = "SELECT id, title, status, source, created_at, completed_at FROM hermes_tasks;"
        guard let rows = SQLiteJSON.query(databaseURL: databaseURL, sql: sql) else { return cache }
        cache = rows.compactMap { row in
            guard let id = row["id"] as? String,
                  let createdAt = DateParser.parse(row["created_at"]) else { return nil }
            return NewMaxHermesRecord(
                id: id,
                title: row["title"] as? String ?? "",
                status: row["status"] as? String ?? "running",
                source: row["source"] as? String ?? "manual",
                createdAt: createdAt,
                completedAt: DateParser.parse(row["completed_at"])
            )
        }
        lastLoadedAt = now
        lastStorageSignature = signature
        return cache
    }
}

private enum NewMaxAdapterTerminalStatuses {
    static let execution: Set<String> = [
        "completed", "complete", "done", "success", "succeeded", "error", "failed", "timeout", "cancelled", "canceled"
    ]
}

private enum SQLiteJSON {
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
    var nonEmpty: String? { isEmpty ? nil : self }
}
