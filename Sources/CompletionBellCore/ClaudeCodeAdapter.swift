import Foundation

public final class ClaudeCodeAdapter: SessionAdapter {
    public let tool: ToolKind = .claudeCode
    public var watchRoots: [URL] { [root] }
    public var metadataWatchRoots: [URL] { desktopIndex.map { [$0.root] } ?? [] }
    private let root: URL
    private let desktopIndex: ClaudeDesktopSessionIndex?
    private let craftRoot: URL?
    private let maxAge: TimeInterval
    private let maxFiles: Int
    private struct CacheEntry {
        let signature: FileDiscovery.Signature
        let facts: ParsedTranscript
        let snapshot: SessionSnapshot
        /// Desktop-index inputs the snapshot was built from, so a rename or
        /// archive flip invalidates a signature-identical transcript.
        let desktopKey: String
    }

    private struct ParsedTranscript {
        let sessionID: String
        let cwd: String?
        let isSidechain: Bool
        let hasAgentID: Bool
        let status: SessionStatus
        let lastActivity: Date
        let completionFingerprint: String?
        let sourceFile: String
        let turnStartedAt: Date?
        let turnCompletedAt: Date?
    }

    private var cache: [String: CacheEntry] = [:]
    private let catalog: IncrementalFileCatalog
    private var craftSDKSessionIDs: Set<String> = []
    private var craftSDKLoadedAt = Date.distantPast

    public init(
        root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects"),
        craftRoot: URL? = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".craft-agent/workspaces"),
        desktopSessionsRoot: URL? = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/claude-code-sessions"),
        maxAge: TimeInterval = 14 * 24 * 60 * 60,
        maxFiles: Int = 100
    ) {
        self.root = root
        self.craftRoot = craftRoot
        self.maxAge = maxAge
        self.maxFiles = maxFiles
        self.catalog = IncrementalFileCatalog(root: root, maxAge: maxAge, limit: maxFiles) {
            $0.pathExtension == "jsonl"
        }
        if let desktopSessionsRoot, FileManager.default.fileExists(atPath: desktopSessionsRoot.path) {
            self.desktopIndex = ClaudeDesktopSessionIndex(root: desktopSessionsRoot)
        } else {
            self.desktopIndex = nil
        }
    }

    public func invalidateCache() {
        // Transcript titles are derived from the cwd and refresh naturally
        // when a transcript changes. Only reload the lightweight Craft SDK
        // mapping; reparsing every Claude transcript can take minutes.
        desktopIndex?.invalidate()
        craftSDKSessionIDs.removeAll()
        craftSDKLoadedAt = .distantPast
    }

    public func scan(now: Date = Date()) -> AdapterScanResult {
        scan(now: now, changes: nil)
    }

    public func scan(now: Date = Date(), changes: AdapterChangeSet?) -> AdapterScanResult {
        let metadataChanged = changes?.metadataPaths.isEmpty == false
        let shouldRefreshMetadata = metadataChanged && changes?.contentPaths.isEmpty != false
        if shouldRefreshMetadata { desktopIndex?.invalidate() }
        let craftSDKSessionIDs = loadCraftSDKSessionIDs(now: now, force: changes == nil)
        let catalogSnapshot = catalog.snapshot(now: now, changes: changes)
        let discovered = catalogSnapshot.files

        var sessions: [SessionSnapshot] = []
        var errors: [String] = []
        let desktopRecords: [String: ClaudeDesktopSessionIndex.Record]
        if let desktopIndex {
            if changes != nil, !shouldRefreshMetadata, desktopIndex.hasLoaded {
                desktopRecords = desktopIndex.cachedRecords
            } else {
                desktopRecords = desktopIndex.records()
            }
        } else {
            desktopRecords = [:]
        }
        var parsedFileCount = 0
        let parseStarted = Date()
        for file in discovered {
            let url = file.url
            let signature = file.signature
            if let cached = cache[url.path], cached.signature == signature {
                let record = desktopRecords[cached.facts.sessionID]
                let key = Self.desktopKey(record)
                if cached.desktopKey == key {
                    sessions.append(cached.snapshot)
                } else {
                    let snapshot = makeSnapshot(
                        from: cached.facts,
                        desktopRecord: record,
                        craftSDKSessionIDs: craftSDKSessionIDs
                    )
                    cache[url.path] = CacheEntry(
                        signature: signature,
                        facts: cached.facts,
                        snapshot: snapshot,
                        desktopKey: key
                    )
                    sessions.append(snapshot)
                }
                continue
            }
            do {
                parsedFileCount += 1
                guard let facts = try parseFacts(file: file) else { continue }
                let desktopRecord = desktopRecords[facts.sessionID]
                let snapshot = makeSnapshot(
                    from: facts,
                    desktopRecord: desktopRecord,
                    craftSDKSessionIDs: craftSDKSessionIDs
                )
                cache[url.path] = CacheEntry(
                    signature: signature,
                    facts: facts,
                    snapshot: snapshot,
                    desktopKey: Self.desktopKey(desktopRecord)
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
            tool: .claudeCode,
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

    private func parseFacts(file: FileDiscovery.DiscoveredFile) throws -> ParsedTranscript? {
        let url = file.url
        let objects = try JSONLReader.tailIndexedObjects(
            at: url,
            maxBytes: 192 * 1024,
            containingAny: [
                "\"type\":\"user\"", "\"type\": \"user\"",
                "\"type\":\"assistant\"", "\"type\": \"assistant\"",
                "\"isSidechain\"", "\"agentId\"", "\"cwd\""
            ]
        )
        guard !objects.isEmpty else { return nil }

                var lastUserIndex = -1
                var lastAssistantIndex = -1
                var lastCompletionIndex = -1
                var completionID: String?
                var cwd: String?
                var lastUserDate: Date?
                var lastCompletionDate: Date?
                var isSidechain = false
                var hasAgentID = false
                var sawConversationEvent = false
        var lastActivity = file.modifiedAt

        for item in objects {
            let index = item.lineIndex
            let object = item.object
                    if let parsed = DateParser.parse(object["timestamp"]), parsed > lastActivity {
                        lastActivity = parsed
                    }
                    if let path = object["cwd"] as? String { cwd = path }
                    if object["isSidechain"] as? Bool == true { isSidechain = true }
                    if object["agentId"] as? String != nil { hasAgentID = true }
                    guard let type = object["type"] as? String else { continue }
                    if type == "user" || type == "assistant" { sawConversationEvent = true }
                    if type == "user", isHumanUserEvent(object) {
                        lastUserIndex = index
                        lastUserDate = DateParser.parse(object["timestamp"]) ?? lastUserDate
                    } else if type == "assistant", let message = object["message"] as? [String: Any] {
                        lastAssistantIndex = index
                        if message["stop_reason"] as? String == "end_turn" {
                            lastCompletionIndex = index
                            completionID = (object["uuid"] as? String) ?? (message["id"] as? String)
                            lastCompletionDate = DateParser.parse(object["timestamp"]) ?? lastCompletionDate
                        }
                    }
                }

        guard sawConversationEvent else { return nil }
        let completed = lastCompletionIndex >= 0
                    && lastCompletionIndex == lastAssistantIndex
                    && lastCompletionIndex > lastUserIndex
        let status: SessionStatus
        if completed {
            status = .completed
        } else if lastUserIndex > lastCompletionIndex {
            status = .running
        } else if lastCompletionIndex == -1 {
                    // A tool-heavy turn can push both the human message and
                    // any end_turn out of the tail window, leaving pure tool
                    // traffic. Conversation events without a completion mean
                    // the turn is still in flight — not an idle session.
            status = .running
        } else {
            status = .idle
        }
        let sessionID = url.deletingPathExtension().lastPathComponent
        return ParsedTranscript(
            sessionID: sessionID,
            cwd: cwd,
            isSidechain: isSidechain,
            hasAgentID: hasAgentID,
            status: status,
            lastActivity: lastActivity,
            completionFingerprint: completed ? "claude:\(completionID ?? sessionID):\(lastCompletionIndex)" : nil,
            sourceFile: url.path,
            turnStartedAt: lastUserDate,
            turnCompletedAt: completed ? lastCompletionDate : nil
        )
    }

    private func makeSnapshot(
        from facts: ParsedTranscript,
        desktopRecord: ClaudeDesktopSessionIndex.Record?,
        craftSDKSessionIDs: Set<String>
    ) -> SessionSnapshot {
                let isMultica = facts.cwd?.contains("/multica_workspaces_") == true
                let origin: SessionOrigin
                if facts.isSidechain || facts.hasAgentID {
                    origin = .subagent
                } else if isMultica {
                    origin = .externalRuntime
                } else if let desktopRecord {
                    // The Claude desktop app keeps one record per sidebar
                    // conversation — the positive UI mapping raw transcripts
                    // lack. Present in the sidebar means the user drives it.
                    origin = desktopRecord.isArchived ? .detached : .interactive
                } else if craftSDKSessionIDs.contains(facts.sessionID) {
                    origin = .detached
                } else {
                    // No UI mapping (headless/SDK runs): a runtime, not a
                    // visible inbox chat.
                    origin = .externalRuntime
                }
                var title = projectTitle(
                    from: facts.cwd,
                    sessionID: facts.sessionID,
                    origin: origin,
                    archivedDesktop: desktopRecord?.isArchived == true
                )
                if origin == .interactive,
                   let named = desktopRecord?.title, !named.isEmpty, named != "New session" {
                    title = named
                }

                let snapshot = SessionSnapshot(
                    tool: .claudeCode,
                    sessionID: facts.sessionID,
                    title: title,
                    status: facts.status,
                    lastActivity: facts.lastActivity,
                    completionFingerprint: facts.completionFingerprint,
                    sourceFile: facts.sourceFile,
                    projectPath: facts.cwd,
                    origin: origin,
                    isHostVisible: origin == .interactive,
                    turnStartedAt: facts.turnStartedAt,
                    turnCompletedAt: facts.turnCompletedAt
                )
        return snapshot
    }

    private func projectTitle(from cwd: String?, sessionID: String, origin: SessionOrigin, archivedDesktop: Bool) -> String {
        if origin == .externalRuntime {
            let project = cwd.flatMap { URL(fileURLWithPath: $0).lastPathComponent.nonEmpty }
            if cwd?.contains("/multica_workspaces_") == true {
                return "Multica · \(project ?? String(sessionID.prefix(8)))"
            }
            return project.map { "Claude 后台 · \($0)" } ?? "Claude 后台 · \(sessionID.prefix(8))"
        }
        if origin == .detached {
            let project = cwd.flatMap { URL(fileURLWithPath: $0).lastPathComponent.nonEmpty }
            let label = archivedDesktop ? "Claude 归档" : "Craft 运行时"
            return project.map { "\(label) · \($0)" } ?? "\(label) · \(sessionID.prefix(8))"
        }
        guard let cwd, !cwd.isEmpty else { return "Claude Code 会话" }
        let component = URL(fileURLWithPath: cwd).lastPathComponent
        return component.isEmpty ? "Claude Code 会话" : "Claude · \(component)"
    }

    private func loadCraftSDKSessionIDs(now: Date, force: Bool) -> Set<String> {
        guard let craftRoot else { return [] }
        if !force || now.timeIntervalSince(craftSDKLoadedAt) < 30 { return craftSDKSessionIDs }
        craftSDKLoadedAt = now
        let urls = FileDiscovery.files(
            under: craftRoot,
            matching: { $0.lastPathComponent == "session.jsonl" && $0.path.contains("/sessions/") },
            limit: 500
        )
        craftSDKSessionIDs = Set(urls.compactMap { url in
            (try? JSONLReader.firstObject(at: url))??["sdkSessionId"] as? String
        })
        return craftSDKSessionIDs
    }

    private func isHumanUserEvent(_ object: [String: Any]) -> Bool {
        if object["isMeta"] as? Bool == true || object["toolUseResult"] != nil { return false }
        guard let message = object["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]],
              !content.isEmpty else { return true }
        return content.contains { ($0["type"] as? String) != "tool_result" }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

extension ClaudeCodeAdapter {
    fileprivate static func desktopKey(_ record: ClaudeDesktopSessionIndex.Record?) -> String {
        guard let record else { return "-" }
        return "\(record.title ?? "")\u{1}\(record.isArchived)"
    }
}

/// The Claude desktop app keeps one JSON record per sidebar conversation
/// (claude-code-sessions/<org>/<project>/local_*.json). `cliSessionId` maps
/// straight onto the transcript filename in ~/.claude/projects — the positive
/// UI mapping that decides interactive vs headless, plus the app-side title.
final class ClaudeDesktopSessionIndex {
    struct Record {
        let title: String?
        let isArchived: Bool
        let lastFocusedAt: Double?
    }

    /// A claude://resume import leaves a second record claiming the same CLI
    /// session. The record the user actually drives must win: unarchived over
    /// archived, then the most recently focused.
    static func preferring(_ lhs: Record, _ rhs: Record) -> Record {
        if lhs.isArchived != rhs.isArchived { return lhs.isArchived ? rhs : lhs }
        return (rhs.lastFocusedAt ?? 0) > (lhs.lastFocusedAt ?? 0) ? rhs : lhs
    }

    let root: URL
    private var cache: [String: Record] = [:]
    private var lastLoadedAt = Date.distantPast

    init(root: URL) {
        self.root = root
    }

    func invalidate() {
        lastLoadedAt = .distantPast
    }

    var hasLoaded: Bool { lastLoadedAt != .distantPast }
    var cachedRecords: [String: Record] { cache }

    func records() -> [String: Record] {
        let now = Date()
        if now.timeIntervalSince(lastLoadedAt) < 30 { return cache }
        var updated: [String: Record] = [:]
        if let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsPackageDescendants]
        ) {
            for case let url as URL in enumerator
            where url.pathExtension == "json" && url.lastPathComponent.hasPrefix("local_") {
                guard let data = try? Data(contentsOf: url),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let cliSessionID = object["cliSessionId"] as? String else { continue }
                let record = Record(
                    title: (object["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                    isArchived: object["isArchived"] as? Bool ?? false,
                    lastFocusedAt: object["lastFocusedAt"] as? Double
                )
                if let existing = updated[cliSessionID] {
                    updated[cliSessionID] = Self.preferring(existing, record)
                } else {
                    updated[cliSessionID] = record
                }
            }
        }
        cache = updated
        lastLoadedAt = now
        return cache
    }
}
