import Foundation

public final class CodexAdapter: SessionAdapter {
    private struct ParsedRollout {
        let sessionID: String
        let cwd: String?
        let threadSource: String
        let originator: String
        let sourceName: String?
        let sourceIsSubagent: Bool
        let hasParentThread: Bool
        let agentPath: String?
        let agentNickname: String?
        let status: SessionStatus
        let lastActivity: Date
        let completionFingerprint: String?
        let sourceFile: String
        let turnStartedAt: Date?
        let turnCompletedAt: Date?
    }

    private struct CacheEntry {
        let signature: FileDiscovery.Signature
        let facts: ParsedRollout
        let snapshot: SessionSnapshot
        /// Database-derived inputs the snapshot's title/visibility were built
        /// from. Comparing this key (instead of raw title vs display title,
        /// which never match for subagent/exec sessions) decides whether a
        /// signature-identical rollout still needs a rebuild.
        let titleInputKey: String
    }

    public let tool: ToolKind = .codex
    public var watchRoots: [URL] { [root] }
    /// Files outside the session root that carry title/visibility state.
    /// Codex's WAL also changes for ordinary task progress, so treating it as
    /// a rename signal creates a needless SQLite reload every few seconds.
    /// Desktop renames are delivered by session_index.jsonl; the database file
    /// covers checkpoints, and the 5-minute reconcile covers missed WAL-only
    /// metadata without putting it on the hot path.
    public var metadataWatchFiles: [URL] {
        guard let titleResolver else { return [] }
        return [titleResolver.databaseFileURL, titleResolver.sessionIndexURL]
    }
    /// Number of rollout files parsed since init; scans that fully hit the
    /// cache leave it unchanged. Exposed for tests and diagnostics.
    public private(set) var parsedRolloutCount = 0
    /// Number of actual SQLite/title-index reloads. Content-only FSEvents must
    /// not increase this counter.
    public var metadataReloadCount: Int { titleResolver?.reloadCount ?? 0 }
    private let root: URL
    private let maxAge: TimeInterval
    private let maxFiles: Int
    private let titleResolver: CodexTitleResolver?
    private let catalog: IncrementalFileCatalog
    private var cache: [String: CacheEntry] = [:]

    public init(
        root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions"),
        databaseURL: URL? = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/state_5.sqlite"),
        maxAge: TimeInterval = 14 * 24 * 60 * 60,
        maxFiles: Int = 100
    ) {
        self.root = root
        self.maxAge = maxAge
        self.maxFiles = maxFiles
        self.catalog = IncrementalFileCatalog(root: root, maxAge: maxAge, limit: maxFiles) {
            $0.pathExtension == "jsonl" && $0.lastPathComponent.hasPrefix("rollout-")
        }
        if let databaseURL, FileManager.default.fileExists(atPath: databaseURL.path) {
            self.titleResolver = CodexTitleResolver(databaseURL: databaseURL)
        } else {
            self.titleResolver = nil
        }
    }

    public func invalidateCache() {
        // A host-side rename updates state_5.sqlite without touching the
        // rollout JSONL. Refresh the title index but retain parsed rollouts;
        // scan() will rebuild only snapshots whose title/visibility changed.
        titleResolver?.invalidate()
    }

    public func scan(now: Date = Date()) -> AdapterScanResult {
        scan(now: now, changes: nil)
    }

    public func scan(now: Date = Date(), changes: AdapterChangeSet?) -> AdapterScanResult {
        let metadataChanged = changes?.metadataPaths.isEmpty == false
        let renameIndexChanged = changes?.metadataPaths.contains(
            where: { $0 == titleResolver?.sessionIndexURL.path }
        ) == true
        // Codex updates its SQLite WAL as part of normal task progress. When
        // that update is delivered in the same batch as a rollout append it
        // is not a rename signal and querying the full thread table would
        // reintroduce a ~100 ms fixed cost. A standalone database event, an
        // index rename event, manual refresh, or the 5-minute reconcile still
        // refreshes metadata.
        let shouldRefreshMetadata = metadataChanged
            && (changes?.contentPaths.isEmpty != false || renameIndexChanged)
        if shouldRefreshMetadata { titleResolver?.invalidate() }
        let threadRecords: [String: CodexThreadRecord]
        if let titleResolver {
            // File-level FSEvents make content and host metadata independent.
            // Reusing the loaded map here avoids spawning sqlite3 for every
            // rollout append while a task is running.
            if changes != nil, !shouldRefreshMetadata, titleResolver.hasLoaded {
                threadRecords = titleResolver.cachedRecords
            } else {
                threadRecords = titleResolver.records()
            }
        } else {
            threadRecords = [:]
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
            if let cached = cache[url.path], cached.signature == signature {
                let record = threadRecords[cached.facts.sessionID]
                let inputKey = Self.titleInputKey(record)
                if cached.titleInputKey == inputKey {
                    sessions.append(cached.snapshot)
                } else {
                    let snapshot = makeSnapshot(from: cached.facts, record: record)
                    cache[url.path] = CacheEntry(
                        signature: signature,
                        facts: cached.facts,
                        snapshot: snapshot,
                        titleInputKey: inputKey
                    )
                    sessions.append(snapshot)
                }
                continue
            }
            do {
                parsedFileCount += 1
                parsedRolloutCount += 1
                guard let facts = try parseFacts(file: file) else { continue }
                let record = threadRecords[facts.sessionID]
                let snapshot = makeSnapshot(from: facts, record: record)
                cache[url.path] = CacheEntry(
                    signature: signature,
                    facts: facts,
                    snapshot: snapshot,
                    titleInputKey: Self.titleInputKey(record)
                )
                sessions.append(snapshot)
            } catch {
                errors.append("\(url.lastPathComponent): \(error.localizedDescription)")
                if let cached = cache[url.path] { sessions.append(cached.snapshot) }
            }
        }
        let discoveredPaths = Set(discovered.map(\.url.path))
        cache = cache.filter { discoveredPaths.contains($0.key) }
        return AdapterScanResult(
            tool: .codex,
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

    private func parseFacts(file: FileDiscovery.DiscoveredFile) throws -> ParsedRollout? {
        let url = file.url
        guard let metadata = try JSONLReader.firstObject(at: url),
              let payload = metadata["payload"] as? [String: Any],
              let sessionID = payload["id"] as? String else { return nil }
        var objects = try JSONLReader.tailIndexedObjects(
            at: url,
            maxBytes: 320 * 1024,
            containingAny: ["\"task_started\"", "\"task_complete\"", "\"turn_aborted\""]
        )
        if !objects.contains(where: { Self.isTaskBoundary($0.object) }),
                   let boundary = try JSONLReader.lastObject(
                       at: url,
                       containingAny: ["task_started", "task_complete", "turn_aborted"],
                       matching: Self.isTaskBoundary
                   ) {
            objects = [JSONLReader.IndexedObject(lineIndex: 0, object: boundary)]
        }

        var lastStartedIndex = -1
        var lastCompletedIndex = -1
        var completionID: String?
        var lastStartedDate: Date?
        var lastCompletedDate: Date?

        for item in objects {
            let object = item.object
            guard object["type"] as? String == "event_msg",
                  let event = object["payload"] as? [String: Any],
                  let eventType = event["type"] as? String else { continue }
            if eventType == "task_started" {
                lastStartedIndex = item.lineIndex
                lastStartedDate = DateParser.parse(object["timestamp"]) ?? lastStartedDate
            } else if eventType == "task_complete" {
                lastCompletedIndex = item.lineIndex
                completionID = (event["turn_id"] as? String) ?? (object["timestamp"] as? String)
                lastCompletedDate = DateParser.parse(object["timestamp"]) ?? lastCompletedDate
            } else if eventType == "turn_aborted" {
                lastCompletedIndex = -1
                completionID = nil
            }
        }

        guard lastStartedIndex >= 0 || lastCompletedIndex >= 0 else { return nil }
        let completed = lastCompletedIndex >= 0 && lastCompletedIndex > lastStartedIndex
        let source = payload["source"]
        return ParsedRollout(
            sessionID: sessionID,
            cwd: payload["cwd"] as? String,
            threadSource: (payload["thread_source"] as? String ?? "").lowercased(),
            originator: (payload["originator"] as? String ?? "").lowercased(),
            sourceName: source as? String,
            sourceIsSubagent: (source as? [String: Any])?["subagent"] != nil,
            hasParentThread: payload["parent_thread_id"] != nil,
            agentPath: payload["agent_path"] as? String,
            agentNickname: payload["agent_nickname"] as? String,
            status: completed ? .completed : .running,
            lastActivity: file.modifiedAt,
            completionFingerprint: completed ? "codex:\(completionID ?? sessionID):\(lastCompletedIndex)" : nil,
            sourceFile: url.path,
            turnStartedAt: lastStartedDate,
            turnCompletedAt: completed ? lastCompletedDate : nil
        )
    }

    private func makeSnapshot(from facts: ParsedRollout, record: CodexThreadRecord?) -> SessionSnapshot {
        let origin = sessionOrigin(facts: facts, record: record)
        return SessionSnapshot(
            tool: .codex,
            sessionID: facts.sessionID,
            title: sessionTitle(facts: facts, origin: origin, record: record),
            status: facts.status,
            lastActivity: facts.lastActivity,
            completionFingerprint: facts.completionFingerprint,
            sourceFile: facts.sourceFile,
            projectPath: facts.cwd,
            origin: origin,
            isHostVisible: record?.isHostVisible == true && origin == .interactive,
            turnStartedAt: facts.turnStartedAt,
            turnCompletedAt: facts.turnCompletedAt
        )
    }

    private func projectTitle(from cwd: String?, sessionID: String) -> String {
        if let cwd, !cwd.isEmpty {
            let component = URL(fileURLWithPath: cwd).lastPathComponent
            if !component.isEmpty { return "Codex · \(component)" }
        }
        return "Codex · \(sessionID.prefix(8))"
    }

    private static func isTaskBoundary(_ object: [String: Any]) -> Bool {
        guard object["type"] as? String == "event_msg",
              let event = object["payload"] as? [String: Any],
              let type = event["type"] as? String else { return false }
        return type == "task_started" || type == "task_complete" || type == "turn_aborted"
    }

    /// Codex ≥ 0.145 stopped writing generated summaries into threads.title —
    /// the column now holds the raw first user message. A record's usable
    /// content title is therefore: the manual rename (name column) if present,
    /// then a title that differs from the first message (a real summary from
    /// older versions), then a headline synthesized from the raw message.
    private func contentTitle(for record: CodexThreadRecord?) -> String? {
        guard let record else { return nil }
        if let curated = record.curatedTitle { return curated }
        if let raw = record.rawFirstMessage { return CodexAdapter.synthesizedTitle(fromFirstMessage: raw) }
        return nil
    }

    /// First line of the raw message with slash commands, paths, and URLs
    /// stripped, capped at 32 characters. Returns nil when nothing readable
    /// remains (e.g. the message was only a path).
    public static func synthesizedTitle(fromFirstMessage message: String) -> String? {
        guard let firstLine = message
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map({ String($0).trimmingCharacters(in: .whitespacesAndNewlines) }),
            !firstLine.isEmpty else { return nil }
        let tokens = firstLine.split(separator: " ").filter { token in
            !token.hasPrefix("/") && !token.hasPrefix("~") && !token.lowercased().hasPrefix("http")
        }
        var text = tokens.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return nil }
        if text.count > 32 {
            text = String(text.prefix(32)) + "…"
        }
        return text
    }

    private static func titleInputKey(_ record: CodexThreadRecord?) -> String {
        guard let record else { return "-" }
        return "\(record.curatedTitle ?? "")\u{1}\(record.rawFirstMessage ?? "")\u{1}\(record.isHostVisible)"
    }

    private func sessionTitle(
        facts: ParsedRollout,
        origin: SessionOrigin,
        record: CodexThreadRecord?
    ) -> String {
        let project = facts.cwd.flatMap { URL(fileURLWithPath: $0).lastPathComponent.nonEmpty }
        switch origin {
        case .subagent:
            let agent = facts.agentNickname?.nonEmpty
                ?? facts.agentPath.flatMap { URL(fileURLWithPath: $0).lastPathComponent.nonEmpty }
                ?? "子 Agent"
            return project.map { "\(agent) · \($0)" } ?? agent
        case .externalRuntime:
            let prefix = facts.originator.contains("multica") ? "Multica" : (facts.originator == "claude code" ? "Claude 后台" : "Codex 后台")
            let content = contentTitle(for: record) ?? project ?? String(facts.sessionID.prefix(8))
            return "\(prefix) · \(content)"
        case .scheduled:
            return contentTitle(for: record) ?? project.map { "自动任务 · \($0)" } ?? "Codex 自动任务"
        case .interactive, .detached:
            return contentTitle(for: record) ?? projectTitle(from: facts.cwd, sessionID: facts.sessionID)
        }
    }

    private func sessionOrigin(facts: ParsedRollout, record: CodexThreadRecord?) -> SessionOrigin {
        if facts.sourceIsSubagent || facts.threadSource == "subagent" || facts.hasParentThread || facts.agentPath != nil {
            return .subagent
        }
        if facts.threadSource == "automation" {
            return .scheduled
        }
        if facts.originator.contains("multica") || facts.originator == "claude code" || facts.originator == "codex_exec" || facts.sourceName == "exec" {
            return .externalRuntime
        }
        if let record, !record.isHostVisible {
            return .detached
        }
        if titleResolver != nil && record == nil {
            return .detached
        }
        return .interactive
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

private struct CodexThreadRecord {
    /// A title a human chose or a summary Codex generated: the name column,
    /// or a title that differs from the first user message.
    let curatedTitle: String?
    /// The raw first user message, kept for headline synthesis.
    let rawFirstMessage: String?
    let isHostVisible: Bool
}

private final class CodexTitleResolver {
    private struct StorageSignature: Equatable {
        let database: FileDiscovery.Signature?
        let writeAheadLog: FileDiscovery.Signature?
        let sessionIndex: FileDiscovery.Signature?
    }

    private let databaseURL: URL
    private var cache: [String: CodexThreadRecord] = [:]
    private var lastLoadedAt = Date.distantPast
    private var lastStorageSignature: StorageSignature?
    private var useLegacySchema = false
    private(set) var reloadCount = 0

    init(databaseURL: URL) {
        self.databaseURL = databaseURL
    }

    var databaseFileURL: URL { databaseURL }

    var writeAheadLogURL: URL {
        URL(fileURLWithPath: databaseURL.path + "-wal")
    }

    /// Codex Desktop's display names live in this append-only rename log,
    /// not in the threads table: each generation/rename appends a line and
    /// the last line per thread wins.
    var sessionIndexURL: URL {
        databaseURL.deletingLastPathComponent().appendingPathComponent("session_index.jsonl")
    }

    var hasLoaded: Bool { lastStorageSignature != nil }
    var cachedRecords: [String: CodexThreadRecord] { cache }

    func invalidate() {
        lastLoadedAt = .distantPast
        lastStorageSignature = nil
    }

    func records() -> [String: CodexThreadRecord] {
        let now = Date()
        let storageSignature = StorageSignature(
            database: FileDiscovery.signature(of: databaseURL),
            writeAheadLog: FileDiscovery.signature(
                of: URL(fileURLWithPath: databaseURL.path + "-wal")
            ),
            sessionIndex: FileDiscovery.signature(of: sessionIndexURL)
        )
        if storageSignature == lastStorageSignature,
           now.timeIntervalSince(lastLoadedAt) < 30 {
            return cache
        }

        // Newer Codex schemas carry name/first_user_message; older databases
        // (other machines, older installs) fail that SELECT, so fall back to
        // the legacy column set and treat its title as curated.
        var rows: [[String: Any]]?
        var legacy = useLegacySchema
        if !legacy {
            rows = query("SELECT id, title, archived, name, first_user_message FROM threads;")
            if rows == nil {
                legacy = true
            }
        }
        if rows == nil {
            rows = query("SELECT id, title, archived FROM threads;")
        }
        guard let rows else { return cache }
        useLegacySchema = legacy

        var updated: [String: CodexThreadRecord] = [:]
        for row in rows {
            guard let id = row["id"] as? String else { continue }
            let title = ((row["title"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let archived = (row["archived"] as? NSNumber)?.boolValue ?? false
            let name = ((row["name"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let firstMessage = ((row["first_user_message"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

            let curated: String?
            if !name.isEmpty {
                curated = name
            } else if legacy || firstMessage.isEmpty {
                curated = title.nonEmpty
            } else {
                curated = title == firstMessage ? nil : title.nonEmpty
            }
            let raw = firstMessage.nonEmpty ?? title.nonEmpty
            guard curated != nil || raw != nil || archived else { continue }
            updated[id] = CodexThreadRecord(
                curatedTitle: curated,
                rawFirstMessage: raw,
                isHostVisible: !archived
            )
        }
        for (id, name) in loadSessionIndexNames() {
            let existing = updated[id]
            guard Self.isCuratedIndexName(name, rawFirstMessage: existing?.rawFirstMessage) else { continue }
            updated[id] = CodexThreadRecord(
                curatedTitle: name,
                rawFirstMessage: existing?.rawFirstMessage,
                isHostVisible: existing?.isHostVisible ?? true
            )
        }
        cache = updated
        lastLoadedAt = now
        lastStorageSignature = storageSignature
        reloadCount += 1
        return cache
    }

    /// Append-only log: later lines are newer, so the last occurrence per
    /// thread id is the current display name.
    private func loadSessionIndexNames() -> [String: String] {
        guard let data = try? Data(contentsOf: sessionIndexURL) else { return [:] }
        var names: [String: String] = [:]
        for line in data.split(separator: 0x0A) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let id = object["id"] as? String,
                  let name = object["thread_name"] as? String else { continue }
            names[id] = name
        }
        return names
    }

    /// The index's initial entry for a thread is the raw first message,
    /// truncated with a trailing ellipsis when long. Only a name that is
    /// neither the raw message nor such a truncation counts as curated;
    /// ellipsis-suffixed names always fall through to synthesis, which is
    /// cheaper than mistaking truncated raw text for a real title.
    static func isCuratedIndexName(_ name: String, rawFirstMessage: String?) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasSuffix("…") else { return false }
        guard let rawFirstMessage else { return true }
        return trimmed != rawFirstMessage
    }

    private func query(_ sql: String) -> [[String: Any]]? {
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
            if data.isEmpty { return [] }
            return try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        } catch {
            return nil
        }
    }
}
