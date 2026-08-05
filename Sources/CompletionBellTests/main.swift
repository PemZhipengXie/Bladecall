import CompletionBellCore
import CloudKit
import Foundation
import JianlingCloudSync
import JianlingShared
import JianlingSync

enum TestFailure: Error, CustomStringConvertible {
    case assertion(String)
    var description: String {
        switch self { case .assertion(let message): return message }
    }
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw TestFailure.assertion(message) }
}

func unwrap<Value>(_ value: Value?, _ message: String) throws -> Value {
    guard let value else { throw TestFailure.assertion(message) }
    return value
}

func writeLines(_ objects: [[String: Any]], to url: URL) throws {
    let lines = try objects.map { object -> String in
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
    try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
}

func appendLines(_ objects: [[String: Any]], to url: URL) throws {
    let lines = try objects.map { object -> String in
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
    let data = Data((lines.joined(separator: "\n") + "\n").utf8)
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: data)
}

func withTempDirectory(_ body: (URL) throws -> Void) throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: url) }
    try body(url)
}

func waitUntil(timeout: TimeInterval = 3, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    return condition()
}

final class LockedValue<Value> {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) { storage = value }

    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); storage = newValue; lock.unlock() }
    }
}

final class FakeCloudTransport: JianlingCloudTransport {
    var status: CKAccountStatus = .available
    var snapshot: JianlingInboxSnapshot?
    var actions: [JianlingRemoteAction] = []

    func accountStatus(completion: @escaping (Result<CKAccountStatus, Error>) -> Void) {
        completion(.success(status))
    }

    func upload(
        snapshot: JianlingInboxSnapshot,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        self.snapshot = snapshot
        completion(.success(()))
    }

    func fetchSnapshot(
        completion: @escaping (Result<JianlingInboxSnapshot?, Error>) -> Void
    ) {
        completion(.success(snapshot))
    }

    func upload(
        action: JianlingRemoteAction,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        actions.removeAll { $0.id == action.id }
        actions.append(action)
        completion(.success(()))
    }

    func fetchActions(
        completion: @escaping (Result<[JianlingRemoteAction], Error>) -> Void
    ) {
        completion(.success(actions))
    }

    func removeAction(id: UUID, completion: @escaping (Result<Void, Error>) -> Void) {
        actions.removeAll { $0.id == id }
        completion(.success(()))
    }
}

func makeSnapshot(_ fingerprint: String, at date: Date, sessionID: String = "same-session") -> SessionSnapshot {
    SessionSnapshot(
        tool: .craft,
        sessionID: sessionID,
        title: "测试",
        status: .completed,
        lastActivity: date,
        completionFingerprint: fingerprint,
        sourceFile: "/tmp/test.jsonl"
    )
}

func makeSession(
    status: SessionStatus,
    fingerprint: String?,
    startedAt: Date?,
    completedAt: Date?,
    sessionID: String = "inbox-session",
    origin: SessionOrigin = .interactive
) -> SessionSnapshot {
    SessionSnapshot(
        tool: .craft,
        sessionID: sessionID,
        title: "收件箱测试",
        status: status,
        lastActivity: completedAt ?? startedAt ?? Date(),
        completionFingerprint: fingerprint,
        sourceFile: "/tmp/inbox.jsonl",
        projectPath: "/tmp/project",
        origin: origin,
        isHostVisible: origin == .interactive,
        turnStartedAt: startedAt,
        turnCompletedAt: completedAt
    )
}

func createCodexDatabase(at url: URL) throws {
    try runSQLite(
        at: url,
        sql: "CREATE TABLE threads (id TEXT PRIMARY KEY, title TEXT, archived INTEGER); INSERT INTO threads VALUES ('detached-1','已归档任务',1);"
    )
}

func createNewMaxDatabase(at url: URL) throws {
    try runSQLite(
        at: url,
        sql: """
        CREATE TABLE workspaces (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            path TEXT NOT NULL,
            created_at INTEGER NOT NULL,
            last_used_at INTEGER NOT NULL
        );
        CREATE TABLE conversations (
            id TEXT PRIMARY KEY,
            workspace_id TEXT NOT NULL,
            title TEXT NOT NULL,
            source TEXT NOT NULL DEFAULT 'app',
            execution_id TEXT,
            updated_at INTEGER NOT NULL,
            is_archived INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE project_tasks (
            id TEXT PRIMARY KEY,
            execution_type TEXT NOT NULL DEFAULT 'manual'
        );
        CREATE TABLE task_executions (
            id TEXT PRIMARY KEY,
            task_id TEXT NOT NULL,
            conversation_id TEXT NOT NULL,
            status TEXT NOT NULL DEFAULT 'running',
            started_at INTEGER NOT NULL,
            finished_at INTEGER
        );
        INSERT INTO workspaces VALUES ('workspace-1','测试工作区','/tmp/newmax-project',1784700000000,1784700000000);
        """
    )
}

func createWorkBuddyDatabase(at url: URL) throws {
    try runSQLite(
        at: url,
        sql: """
        CREATE TABLE sessions (
            id TEXT PRIMARY KEY,
            cwd TEXT,
            user_id TEXT,
            title TEXT,
            custom_title TEXT,
            status TEXT DEFAULT 'Pending',
            created_at INTEGER,
            updated_at INTEGER,
            deleted_at INTEGER,
            source_mode TEXT,
            is_background_automation INTEGER,
            last_activity_at INTEGER
        );
        CREATE TABLE automations (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            prompt TEXT NOT NULL,
            status TEXT NOT NULL,
            schedule_type TEXT NOT NULL DEFAULT 'recurring',
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL
        );
        CREATE TABLE automation_runs (
            thread_id TEXT PRIMARY KEY,
            automation_id TEXT NOT NULL,
            status TEXT NOT NULL,
            read_at INTEGER,
            thread_title TEXT,
            source_cwd TEXT,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL
        );
        CREATE TABLE automation_runtime_state (
            automation_id TEXT PRIMARY KEY,
            running INTEGER NOT NULL DEFAULT 0,
            running_started_at INTEGER,
            running_conversation_id TEXT
        );
        """
    )
}

func runSQLite(at url: URL, sql: String) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    process.arguments = [url.path, sql]
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    try process.run()
    process.waitUntilExit()
    try expect(process.terminationStatus == 0, "Failed to create Codex fixture database")
}

let tests: [(String, () throws -> Void)] = [
    ("Codex quota parser keeps dynamic weekly window", {
        let snapshot = QuotaParser.codex(from: [
            "rateLimitsByLimitId": [
                "codex": [
                    "primary": [
                        "usedPercent": 81,
                        "windowDurationMins": 10_080,
                        "resetsAt": 1_784_995_692
                    ]
                ]
            ]
        ])
        try expect(snapshot.availability == .ready, "Codex quota should be available")
        try expect(snapshot.windows.count == 1, "Codex should not invent a missing session window")
        try expect(snapshot.windows[0].id == "codex:primary", "Codex window id must stay stable")
        try expect(snapshot.windows[0].kind == .weekly, "Seven-day Codex window should be weekly")
        try expect(snapshot.windows[0].remainingPercent == 19, "Codex remaining percentage mismatch")
    }),
    ("Codex quota parser supports session plus weekly", {
        let snapshot = QuotaParser.codex(from: [
            "rateLimits": [
                "primary": ["usedPercent": 25, "windowDurationMins": 300],
                "secondary": ["usedPercent": 40, "windowDurationMins": 10_080]
            ]
        ])
        try expect(snapshot.windows.map(\.kind) == [.session, .weekly], "Codex window classification changed")
        try expect(snapshot.windows.map(\.remainingPercent) == [75, 60], "Codex remaining percentages mismatch")
    }),
    ("Claude quota parser discovers model windows", {
        let snapshot = QuotaParser.claude(from: [
            "five_hour": ["utilization": 32.5, "resets_at": "2026-07-20T10:30:00Z"],
            "seven_day": ["utilization": 48, "resets_at": "2026-07-26T10:30:00Z"],
            "limits": [[
                "group": "weekly",
                "percent": 12,
                "resets_at": "2026-07-26T10:30:00Z",
                "scope": ["model": ["display_name": "Fable"]]
            ]]
        ])
        try expect(snapshot.availability == .ready, "Claude quota should be available")
        try expect(snapshot.windows.count == 3, "Claude dynamic model window missing")
        try expect(snapshot.windows.contains { $0.id == "claude:model:weekly-fable" }, "Claude model window id must be stable")
        try expect(snapshot.windows.first?.remainingPercent == 67.5, "Claude session remaining percentage mismatch")
    }),
    ("Claude CLI usage parser keeps dynamic subscription windows", {
        let snapshot = QuotaParser.claudeUsageText("""
        You are currently using your subscription to power your Claude Code usage

        Current session: 28% used · resets Jul 23 at 3:40pm (Asia/Shanghai)
        Current week (all models): 41% used · resets Jul 26 at 8am (Asia/Shanghai)
        Current week (Fable): 12.5% used
        """)
        try expect(snapshot.availability == .ready, "Claude CLI quota should be available")
        try expect(snapshot.windows.count == 3, "Claude CLI should expose every returned quota window")
        try expect(snapshot.windows.map(\.kind) == [.session, .weekly, .model], "Claude CLI quota classification changed")
        try expect(snapshot.windows.map(\.remainingPercent) == [72, 59, 87.5], "Claude CLI remaining percentages mismatch")
        try expect(snapshot.windows[2].id == "claude:cli:week-fable", "Claude CLI model window id must stay stable")
        try expect(snapshot.windows[2].labelChinese == "周 · Fable", "Claude CLI model label mismatch")
    }),
    ("Bilingual product language", {
        try expect(JianlingLanguage.chinese.productName == "剑令", "Chinese product name changed")
        try expect(JianlingLanguage.english.productName == "Bladecall", "English product name missing")
        try expect(
            JianlingLanguage.english.text("行剑中", "In progress") == "In progress",
            "English copy did not resolve"
        )
        try expect(
            JianlingLanguage.chinese.text("归鞘", "Done") == "归鞘",
            "Chinese copy did not resolve"
        )
        try expect(
            JianlingLanguage.system.displayName(in: .english) == "System",
            "Language picker should follow the active interface language"
        )
    }),
    ("Private iCloud payload codec", {
        let timestamp = Date(timeIntervalSince1970: 1_784_082_149)
        let snapshot = JianlingInboxSnapshot(
            generatedAt: timestamp,
            revision: 12,
            tasks: [JianlingTaskSnapshot(
                id: "codex:cloud",
                sessionID: "cloud",
                tool: .codex,
                title: "私人 iCloud 同步",
                state: .unread,
                origin: .interactive,
                updatedAt: timestamp,
                completedAt: timestamp,
                isHostVisible: true
            )],
            todayHandledCount: 5,
            hideBackgroundTasks: true
        )
        let data = try JianlingCloudCodec.encode(snapshot)
        let decoded = try JianlingCloudCodec.decode(JianlingInboxSnapshot.self, from: data)
        try expect(decoded == snapshot, "CloudKit payload changed the shared snapshot")
    }),
    ("Private iCloud authority and companion round trip", {
        try withTempDirectory { root in
            let transport = FakeCloudTransport()
            let macStore = JianlingSharedStore(directoryURL: root.appendingPathComponent("mac"))
            let phoneStore = JianlingSharedStore(directoryURL: root.appendingPathComponent("phone"))
            let timestamp = Date(timeIntervalSince1970: 1_784_082_149)
            let task = JianlingTaskSnapshot(
                id: "codex:cloud-roundtrip",
                sessionID: "cloud-roundtrip",
                tool: .codex,
                title: "云端往返",
                state: .unread,
                origin: .interactive,
                updatedAt: timestamp,
                completedAt: timestamp,
                isHostVisible: true
            )
            let macSnapshot = JianlingInboxSnapshot(
                generatedAt: timestamp,
                revision: 20,
                tasks: [task],
                todayHandledCount: 3,
                hideBackgroundTasks: true
            )
            try macStore.writeSnapshot(macSnapshot)
            try phoneStore.writeSnapshot(JianlingInboxSnapshot(
                generatedAt: timestamp.addingTimeInterval(-10),
                revision: 19,
                tasks: [],
                todayHandledCount: 2,
                hideBackgroundTasks: true
            ))

            let macBridge = JianlingCloudBridge(transport: transport, store: macStore)
            let phoneBridge = JianlingCloudBridge(transport: transport, store: phoneStore)
            let published = LockedValue(false)
            macBridge.publish(snapshot: macSnapshot) { if case .success = $0 { published.value = true } }
            try expect(published.value, "Mac snapshot was not published")

            let receivedRevision = LockedValue<Int64?>(nil)
            phoneBridge.fetchNewerSnapshot { result in
                if case .success(let snapshot) = result { receivedRevision.value = snapshot?.revision }
            }
            try expect(receivedRevision.value == 20, "Phone did not accept the newer Mac snapshot")
            let receivedTasks = try phoneStore.readSnapshot().tasks
            try expect(receivedTasks == [task], "Phone cache did not receive the task")

            let action = JianlingRemoteAction(
                kind: .markHandled,
                taskID: task.id,
                createdAt: timestamp.addingTimeInterval(2),
                sourceDeviceName: "测试 iPhone"
            )
            try phoneStore.enqueue(action)
            let uploadedActions = LockedValue(-1)
            phoneBridge.uploadPendingActions { result in
                if case .success(let report) = result { uploadedActions.value = report.uploadedActions }
            }
            try expect(uploadedActions.value == 1, "Phone action was not uploaded")
            let phonePending = try phoneStore.pendingActions()
            try expect(phonePending == [action], "Handled action must stay optimistic until a Mac snapshot acknowledges it")

            let importedActions = LockedValue(-1)
            macBridge.importRemoteActions { result in
                if case .success(let report) = result { importedActions.value = report.importedActions }
            }
            try expect(importedActions.value == 1, "Mac did not import the phone action")
            let macPending = try macStore.pendingActions()
            try expect(macPending == [action], "Imported phone action did not enter the durable Mac queue")
            try expect(transport.actions.isEmpty, "Cloud action was not acknowledged after durable import")

            transport.snapshot = JianlingInboxSnapshot(
                generatedAt: timestamp.addingTimeInterval(5),
                revision: 21,
                tasks: [],
                todayHandledCount: 4,
                hideBackgroundTasks: true
            )
            phoneBridge.fetchNewerSnapshot { _ in }
            let acknowledgedPhoneActions = try phoneStore.pendingActions()
            try expect(acknowledgedPhoneActions.isEmpty, "Mac snapshot did not acknowledge the handled action")
        }
    }),
    ("A delayed old-turn action cannot hide a newer turn", {
        try withTempDirectory { root in
            let store = JianlingSharedStore(directoryURL: root)
            let action = JianlingRemoteAction(
                kind: .markHandled,
                taskID: "codex:reused-session",
                turnFingerprint: "turn-old"
            )
            try store.enqueue(action)
            let newerTask = JianlingTaskSnapshot(
                id: "codex:reused-session",
                sessionID: "reused-session",
                tool: .codex,
                title: "新一轮任务",
                state: .unread,
                origin: .interactive,
                updatedAt: Date(),
                completedAt: Date(),
                turnFingerprint: "turn-new",
                isHostVisible: true
            )
            let removed = try store.reconcilePendingActions(with: JianlingInboxSnapshot(
                generatedAt: Date(),
                revision: 2,
                tasks: [newerTask],
                todayHandledCount: 1,
                hideBackgroundTasks: true
            ))
            try expect(removed == 1, "Old-turn action was not retired")
            let pending = try store.pendingActions()
            try expect(pending.isEmpty, "Old-turn action would still hide the newer completion")
        }
    }),
    ("Dual route action receipt suppresses duplicate side effects", {
        try withTempDirectory { root in
            let store = JianlingSharedStore(directoryURL: root)
            let transport = FakeCloudTransport()
            let bridge = JianlingCloudBridge(transport: transport, store: store)
            let action = JianlingRemoteAction(kind: .open, taskID: "codex:once")

            try store.markActionProcessed(id: action.id)
            transport.actions = [action]
            let imported = LockedValue(-1)
            bridge.importRemoteActions { result in
                if case .success(let report) = result { imported.value = report.importedActions }
            }
            try expect(imported.value == 0, "A processed action should not be imported again")
            let pending = try store.pendingActions()
            try expect(pending.isEmpty, "A duplicate open action re-entered the Mac queue")
            try expect(transport.actions.isEmpty, "Duplicate cloud action should still be acknowledged")
            let hasReceipt = try store.hasProcessedAction(id: action.id)
            try expect(hasReceipt, "Persistent action receipt was lost")
        }
    }),
    ("Shared mobile snapshot and optimistic handling", {
        try withTempDirectory { root in
            let store = JianlingSharedStore(directoryURL: root)
            let timestamp = Date(timeIntervalSince1970: 1_784_082_149)
            let task = JianlingTaskSnapshot(
                id: "codex:mobile",
                sessionID: "mobile",
                tool: .codex,
                title: "手机共享测试",
                state: .unread,
                origin: .interactive,
                updatedAt: timestamp,
                completedAt: timestamp,
                isHostVisible: true
            )
            try store.writeSnapshot(JianlingInboxSnapshot(
                generatedAt: timestamp,
                revision: 1,
                tasks: [task],
                todayHandledCount: 2,
                hideBackgroundTasks: true
            ))
            let roundTrip = try store.readSnapshot()
            try expect(roundTrip.tasks == [task], "Shared snapshot round trip failed")
            let action = JianlingRemoteAction(kind: .markHandled, taskID: task.id, createdAt: timestamp)
            try store.enqueue(action)
            let optimistic = try store.readSnapshot()
            try expect(optimistic.tasks.isEmpty, "Pending handled action should hide the task immediately")
            try expect(optimistic.todayHandledCount == 3, "Optimistic handled count mismatch")
            let pending = try store.pendingActions()
            try expect(pending == [action], "Remote action queue mismatch")
            try store.removeAction(id: action.id)
            let acknowledged = try store.pendingActions()
            try expect(acknowledged.isEmpty, "Remote action acknowledgement failed")
        }
    }),
    ("Routine tasks stay visible while technical background is hidden", {
        let timestamp = Date(timeIntervalSince1970: 1_784_082_149)
        func task(_ id: String, origin: JianlingTaskOrigin, visible: Bool) -> JianlingTaskSnapshot {
            JianlingTaskSnapshot(
                id: "codex:\(id)",
                sessionID: id,
                tool: .codex,
                title: id,
                state: .unread,
                origin: origin,
                updatedAt: timestamp,
                completedAt: timestamp,
                isHostVisible: visible
            )
        }
        let interactive = task("interactive", origin: .interactive, visible: true)
        let routine = task("routine", origin: .scheduled, visible: false)
        let subagent = task("subagent", origin: .subagent, visible: false)
        let snapshot = JianlingInboxSnapshot(
            generatedAt: timestamp,
            revision: 2,
            tasks: [interactive, routine, subagent],
            todayHandledCount: 0,
            hideBackgroundTasks: true
        )
        try expect(snapshot.schemaVersion == 5, "WorkBuddy support should publish the v5 shared schema")
        try expect(snapshot.visibleTasks.map(\.id) == [interactive.id, routine.id], "Scheduled results should survive the background filter")
        try expect(snapshot.routineCount == 1, "Routine count should be independent from background noise")
    }),
    ("Local pairing protocol framing", {
        let peer = JianlingPeerDescriptor(
            deviceID: UUID(),
            name: "iPhone",
            platform: .iOS,
            appVersion: "0.1"
        )
        guard let code = JianlingPairingCode(rawValue: "123456") else {
            throw TestFailure.assertion("Valid pairing code rejected")
        }
        let timestamp = Date(timeIntervalSince1970: 1_784_082_149)
        let pair = JianlingWireEnvelope(kind: .pairRequest, sentAt: timestamp, peer: peer, pairingCode: code)
        let ping = JianlingWireEnvelope(kind: .ping, sentAt: timestamp.addingTimeInterval(1))
        let first = try JianlingWireCodec.encode(pair)
        var buffer = Data(first.prefix(5))
        let partialResult = try JianlingWireCodec.decodeAvailable(from: &buffer)
        try expect(partialResult.isEmpty, "Partial network frame decoded too early")
        buffer.append(first.dropFirst(5))
        buffer.append(try JianlingWireCodec.encode(ping))
        let decoded = try JianlingWireCodec.decodeAvailable(from: &buffer)
        try expect(decoded == [pair, ping], "Multiple network frames failed")
        try expect(buffer.isEmpty, "Network decoder left consumed bytes behind")
    }),
    ("Local peer loopback pairing and action", {
        let code = JianlingPairingCode(rawValue: "654321")!
        let snapshot = JianlingInboxSnapshot(
            generatedAt: Date(timeIntervalSince1970: 1_784_082_149),
            revision: 9,
            tasks: [],
            todayHandledCount: 4,
            hideBackgroundTasks: true
        )
        let serverReady = LockedValue(false)
        let receivedAction = LockedValue<JianlingRemoteAction?>(nil)
        let server = JianlingLocalServer(
            pairingCode: code,
            peer: JianlingPeerDescriptor(deviceID: UUID(), name: "测试 Mac", platform: .macOS, appVersion: "0.1"),
            snapshotProvider: { snapshot },
            actionHandler: { receivedAction.value = $0 }
        )
        server.onStateChange = { state in
            if state == .ready { serverReady.value = true }
        }
        try server.start()
        try expect(waitUntil { serverReady.value }, "Local server did not become ready")
        guard let port = server.listeningPort else {
            throw TestFailure.assertion("Local server did not expose a port")
        }

        let paired = LockedValue(false)
        let receivedSnapshot = LockedValue<JianlingInboxSnapshot?>(nil)
        let acknowledged = LockedValue(false)
        let client = JianlingLocalClient(
            peer: JianlingPeerDescriptor(deviceID: UUID(), name: "测试 iPhone", platform: .iOS, appVersion: "0.1")
        )
        client.onStateChange = { state in
            if case .paired = state { paired.value = true }
        }
        client.onSnapshot = { receivedSnapshot.value = $0 }
        client.connect(host: "127.0.0.1", port: port, pairingCode: code)
        try expect(waitUntil { paired.value && receivedSnapshot.value == snapshot }, "PIN pairing did not deliver a snapshot")

        let action = JianlingRemoteAction(kind: .markHandled, taskID: "codex:loopback")
        client.send(action) { acknowledged.value = $0 }
        try expect(waitUntil {
            acknowledged.value
                && receivedAction.value?.id == action.id
                && receivedAction.value?.kind == action.kind
                && receivedAction.value?.taskID == action.taskID
        }, "Remote action was not acknowledged")
        client.disconnect()
        server.stop()
    }),
    ("Session deep links", {
        let codex = SessionSnapshot(
            tool: .codex,
            sessionID: "019f-test-thread",
            title: "Codex",
            status: .completed,
            lastActivity: Date(),
            completionFingerprint: "codex-final",
            sourceFile: "/tmp/codex.jsonl"
        )
        let claude = SessionSnapshot(
            tool: .claudeCode,
            sessionID: "550e8400-e29b-41d4-a716-446655440000",
            title: "Claude",
            status: .completed,
            lastActivity: Date(),
            completionFingerprint: "claude-final",
            sourceFile: "/tmp/claude.jsonl"
        )
        let craft = makeSnapshot("craft-final", at: Date())
        let newMax = SessionSnapshot(
            tool: .newMax,
            sessionID: "conv-1781509398901",
            title: "NewMax",
            status: .completed,
            lastActivity: Date(),
            completionFingerprint: "newmax-final",
            sourceFile: "/tmp/newmax/messages.jsonl"
        )
        let workBuddy = SessionSnapshot(
            tool: .workBuddy,
            sessionID: "a8f1e749-940f-4313-bf10-3eb51d85d501",
            title: "WorkBuddy",
            status: .completed,
            lastActivity: Date(),
            completionFingerprint: "workbuddy-final",
            sourceFile: "/tmp/workbuddy/session.jsonl"
        )
        try expect(SessionDeepLink.url(for: codex)?.absoluteString == "codex://threads/019f-test-thread", "Codex thread deep link mismatch")
        try expect(SessionDeepLink.url(for: claude) == nil, "Claude must fall back to app activation: claude://resume forks a duplicate conversation")
        try expect(SessionDeepLink.url(for: craft) == nil, "Craft must fall back to app activation without a registered deep link")
        try expect(SessionDeepLink.url(for: newMax)?.absoluteString == "newmax://open?conversation=conv-1781509398901", "NewMax conversation deep link mismatch")
        try expect(SessionDeepLink.url(for: workBuddy)?.absoluteString == "workbuddy://chat/a8f1e749-940f-4313-bf10-3eb51d85d501", "WorkBuddy conversation deep link mismatch")
    }),
    ("Claude resume fork URL carries session and cwd", {
        let claude = SessionSnapshot(
            tool: .claudeCode,
            sessionID: "550e8400-e29b-41d4-a716-446655440000",
            title: "Claude",
            status: .completed,
            lastActivity: Date(),
            completionFingerprint: "claude-final",
            sourceFile: "/tmp/claude.jsonl",
            projectPath: "/Users/pem/My Proj"
        )
        try expect(
            SessionDeepLink.claudeResumeForkURL(for: claude)?.absoluteString
                == "claude://resume?session=550e8400-e29b-41d4-a716-446655440000&cwd=/Users/pem/My%20Proj",
            "Fork URL must carry the bare session id plus percent-encoded cwd"
        )
        let noCwd = SessionSnapshot(
            tool: .claudeCode,
            sessionID: "550e8400-e29b-41d4-a716-446655440000",
            title: "Claude",
            status: .completed,
            lastActivity: Date(),
            completionFingerprint: "claude-final",
            sourceFile: "/tmp/claude.jsonl"
        )
        try expect(SessionDeepLink.claudeResumeForkURL(for: noCwd) == nil, "Missing cwd must not build a fork URL — resuming into the wrong directory is worse than none")
        let codex = SessionSnapshot(
            tool: .codex,
            sessionID: "019f-test-thread",
            title: "Codex",
            status: .completed,
            lastActivity: Date(),
            completionFingerprint: "codex-final",
            sourceFile: "/tmp/codex.jsonl",
            projectPath: "/tmp/project"
        )
        try expect(SessionDeepLink.claudeResumeForkURL(for: codex) == nil, "Fork URL is Claude-only")
        try expect(SessionDeepLink.url(for: claude) == nil, "Row click must still fall back to app activation even when a fork URL exists")
    }),
    ("Snooze applies only to unread and pending sessions", {
        try withTempDirectory { root in
            let store = InboxStateStore(url: root.appendingPathComponent("state.json"))
            let t0 = Date()
            let running = makeSession(status: .running, fingerprint: nil, startedAt: t0, completedAt: nil, sessionID: "s-run")
            _ = store.reconcile([running, makeSession(status: .running, fingerprint: nil, startedAt: t0, completedAt: nil)], at: t0)
            let t1 = t0.addingTimeInterval(60)
            let done = makeSession(status: .completed, fingerprint: "fp-1", startedAt: t0, completedAt: t1)
            _ = store.reconcile([running, done], at: t1)
            try expect(store.snooze(done, until: t1.addingTimeInterval(3600), at: t1), "Unread session must accept a snooze")
            try expect(store.activeSnoozes(now: t1) == [done.id], "Active snoozes must contain the pushed session")
            try expect(!store.snooze(running, until: t1.addingTimeInterval(3600), at: t1), "Running session must reject a snooze")
            _ = store.markHandled(done, at: t1)
            try expect(!store.snooze(done, until: t1.addingTimeInterval(7200), at: t1), "Handled session must reject a snooze")
            try expect(store.activeSnoozes(now: t1).isEmpty, "Sheathing must clear the snooze set")
        }
    }),
    ("Snooze expires back to the original attention state silently", {
        try withTempDirectory { root in
            let store = InboxStateStore(url: root.appendingPathComponent("state.json"))
            let t0 = Date()
            _ = store.reconcile([
                makeSession(status: .running, fingerprint: nil, startedAt: t0, completedAt: nil),
                makeSession(status: .running, fingerprint: nil, startedAt: t0, completedAt: nil, sessionID: "s-read")
            ], at: t0)
            let t1 = t0.addingTimeInterval(60)
            let unread = makeSession(status: .completed, fingerprint: "fp-1", startedAt: t0, completedAt: t1)
            let reviewed = makeSession(status: .completed, fingerprint: "fp-2", startedAt: t0, completedAt: t1, sessionID: "s-read")
            _ = store.reconcile([unread, reviewed], at: t1)
            _ = store.markRead(reviewed)
            let until = t1.addingTimeInterval(3600)
            _ = store.snooze(unread, until: until, at: t1)
            _ = store.snooze(reviewed, until: until, at: t1)
            try expect(store.activeSnoozes(now: until.addingTimeInterval(-1)).count == 2, "Both snoozes must hold just before expiry")
            try expect(store.activeSnoozes(now: until.addingTimeInterval(1)).isEmpty, "Expiry must empty the active set")
            let expired = store.reconcile([unread, reviewed], at: until.addingTimeInterval(1))
            try expect(expired.completionEvents.isEmpty, "Expiry must not re-fire completion events — the return is silent")
            try expect(expired.attentionStates[unread.id] == .unread, "Unread must return as unread")
            try expect(expired.attentionStates[reviewed.id] == .pending, "Reviewed must return as pending")
        }
    }),
    ("Snooze persists immediately despite idle throttling", {
        try withTempDirectory { root in
            let url = root.appendingPathComponent("state.json")
            let store = InboxStateStore(url: url, idlePersistInterval: 3600)
            let t0 = Date()
            _ = store.reconcile([makeSession(status: .running, fingerprint: nil, startedAt: t0, completedAt: nil)], at: t0)
            let t1 = t0.addingTimeInterval(60)
            let done = makeSession(status: .completed, fingerprint: "fp-1", startedAt: t0, completedAt: t1)
            _ = store.reconcile([done], at: t1)
            let until = t1.addingTimeInterval(3600)
            _ = store.snooze(done, until: until, at: t1)
            try expect(InboxStateStore(url: url).activeSnoozes(now: t1) == [done.id], "Snooze must hit the disk immediately, not wait for the heartbeat")
            _ = store.reconcile([done], at: until.addingTimeInterval(1))
            try expect(InboxStateStore(url: url).activeSnoozes(now: until.addingTimeInterval(-1)).isEmpty, "Expiry cleanup must persist immediately too")
        }
    }),
    ("New completion clears an active snooze", {
        try withTempDirectory { root in
            let store = InboxStateStore(url: root.appendingPathComponent("state.json"))
            let t0 = Date()
            _ = store.reconcile([makeSession(status: .running, fingerprint: nil, startedAt: t0, completedAt: nil)], at: t0)
            let t1 = t0.addingTimeInterval(60)
            let first = makeSession(status: .completed, fingerprint: "fp-1", startedAt: t0, completedAt: t1)
            _ = store.reconcile([first], at: t1)
            _ = store.snooze(first, until: t1.addingTimeInterval(3600), at: t1)
            let t2 = t1.addingTimeInterval(120)
            let second = makeSession(status: .completed, fingerprint: "fp-2", startedAt: t0, completedAt: t2)
            let result = store.reconcile([second], at: t2)
            try expect(result.completionEvents.count == 1, "A fresh completion must fire its event")
            try expect(store.activeSnoozes(now: t2).isEmpty, "A fresh completion must surface immediately, dropping the snooze")
            try expect(result.attentionStates[second.id] == .unread, "The new result must land as unread")
        }
    }),
    ("Reply and manual sheathe both drop the snooze", {
        try withTempDirectory { root in
            let store = InboxStateStore(url: root.appendingPathComponent("state.json"))
            let t0 = Date()
            _ = store.reconcile([
                makeSession(status: .running, fingerprint: nil, startedAt: t0, completedAt: nil, sessionID: "s-reply"),
                makeSession(status: .running, fingerprint: nil, startedAt: t0, completedAt: nil, sessionID: "s-manual")
            ], at: t0)
            let t1 = t0.addingTimeInterval(60)
            let replied = makeSession(status: .completed, fingerprint: "fp-a", startedAt: t0, completedAt: t1, sessionID: "s-reply")
            let manual = makeSession(status: .completed, fingerprint: "fp-b", startedAt: t0, completedAt: t1, sessionID: "s-manual")
            _ = store.reconcile([replied, manual], at: t1)
            let until = t1.addingTimeInterval(3600)
            _ = store.snooze(replied, until: until, at: t1)
            _ = store.snooze(manual, until: until, at: t1)
            let t2 = t1.addingTimeInterval(120)
            let newTurn = makeSession(status: .running, fingerprint: "fp-a", startedAt: t2, completedAt: nil, sessionID: "s-reply")
            let result = store.reconcile([newTurn, manual], at: t2)
            try expect(result.transitions.contains { $0.kind == .handled && $0.handledMethod == .replied }, "A new turn after completion must count as replied")
            _ = store.markHandled(manual, at: t2)
            try expect(store.activeSnoozes(now: t2).isEmpty, "Reply and manual sheathe must both clear snoozes")
        }
    }),
    ("Snooze options compute deterministic fire dates", {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try unwrap(TimeZone(identifier: "Asia/Shanghai"), "Timezone must exist")
        func date(_ day: Int, _ hour: Int) throws -> Date {
            try unwrap(
                calendar.date(from: DateComponents(year: 2026, month: 7, day: day, hour: hour, minute: 0)),
                "Date must be constructible"
            )
        }
        let morning = try date(20, 10)
        let tonight = try date(20, 20)
        let nextMorning = try date(21, 9)
        try expect(SnoozeOption.oneHour.until(from: morning, calendar: calendar) == morning.addingTimeInterval(3600), "One hour must add 3600s")
        try expect(SnoozeOption.threeHours.until(from: morning, calendar: calendar) == morning.addingTimeInterval(3 * 3600), "Three hours must add 10800s")
        try expect(SnoozeOption.tonight.until(from: morning, calendar: calendar) == tonight, "Tonight must be today's 20:00")
        try expect(SnoozeOption.tomorrowMorning.until(from: morning, calendar: calendar) == nextMorning, "Tomorrow morning from 10:00 must be the next day's 09:00")
        let lateNight = try date(20, 21)
        try expect(!SnoozeOption.visibleOptions(now: lateNight, calendar: calendar).contains(.tonight), "Past 20:00 the tonight option must hide")
        try expect(SnoozeOption.visibleOptions(now: morning, calendar: calendar).count == 4, "All options stay visible before 20:00")
        let smallHours = try date(20, 3)
        let sameDayMorning = try date(20, 9)
        try expect(SnoozeOption.tomorrowMorning.until(from: smallHours, calendar: calendar) == sameDayMorning, "At 03:00 'tomorrow morning' means today's 09:00 — matching speech")
    }),
    ("Display fingerprint reacts to snooze set changes", {
        let policy = SessionDisplayPolicy()
        let now = Date()
        let session = makeSession(status: .completed, fingerprint: "fp-z", startedAt: now.addingTimeInterval(-120), completedAt: now.addingTimeInterval(-60))
        let attention: [String: AttentionState] = [session.id: .unread]
        let bare = DisplayFingerprint.compute(sessions: [session], attentionStates: attention, activeSnoozeIDs: [], policy: policy, now: now)
        let snoozed = DisplayFingerprint.compute(sessions: [session], attentionStates: attention, activeSnoozeIDs: [session.id], policy: policy, now: now)
        let snoozedAgain = DisplayFingerprint.compute(sessions: [session], attentionStates: attention, activeSnoozeIDs: [session.id], policy: policy, now: now)
        try expect(bare != snoozed, "Snoozing must change the display fingerprint so the idle short-circuit re-renders")
        try expect(snoozed == snoozedAgain, "Identical snooze sets must produce stable fingerprints")
    }),
    ("Batch sheathe candidates skip running at the store level", {
        try withTempDirectory { root in
            let store = InboxStateStore(url: root.appendingPathComponent("state.json"))
            let t0 = Date()
            _ = store.reconcile([
                makeSession(status: .running, fingerprint: nil, startedAt: t0, completedAt: nil, sessionID: "s-run"),
                makeSession(status: .running, fingerprint: nil, startedAt: t0, completedAt: nil, sessionID: "s-new")
            ], at: t0)
            let t1 = t0.addingTimeInterval(60)
            let running = makeSession(status: .running, fingerprint: nil, startedAt: t1, completedAt: nil, sessionID: "s-run")
            let unread = makeSession(status: .completed, fingerprint: "fp-u", startedAt: t0, completedAt: t1, sessionID: "s-new")
            _ = store.reconcile([running, unread], at: t1)
            try expect(store.markHandled(running, at: t1) == nil, "A running session has nothing to sheathe")
            try expect(store.markHandled(unread, at: t1) != nil, "宗 must sheathe unread rows directly, without a prior read")
        }
    }),

    ("NewMax running snapshot completes after final response", {
        try withTempDirectory { temp in
            let root = temp.appendingPathComponent("conversations")
            let directory = root.appendingPathComponent("conv-live")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let databaseURL = temp.appendingPathComponent("newmax.db")
            try createNewMaxDatabase(at: databaseURL)
            try runSQLite(
                at: databaseURL,
                sql: "INSERT INTO conversations VALUES ('conv-live','workspace-1','旧标题','app',NULL,1784700000000,0);"
            )
            let file = directory.appendingPathComponent("messages.jsonl")
            try writeLines([
                ["role": "user", "id": "user-1", "timestamp": 1_784_700_000_000, "content": "fixture"],
                ["role": "assistant", "id": "assistant-1", "timestamp": 1_784_700_000_001, "content": "", "toolCalls": [["id": "tool-1", "status": "running"]]]
            ], to: file)

            let adapter = NewMaxAdapter(
                root: root,
                databaseURL: databaseURL,
                hermesDatabaseURL: nil,
                maxAge: 100 * 365 * 24 * 60 * 60,
                maxFiles: 10,
                completionSettleInterval: 0
            )
            var session = try unwrap(adapter.scan().sessions.first, "NewMax running fixture missing")
            try expect(session.status == .running, "NewMax running tool call was not detected")
            try expect(session.title == "旧标题", "NewMax title database was not used")
            try expect(session.origin == .interactive && session.isHostVisible, "NewMax app conversation should be host-visible")

            try appendLines([
                ["role": "assistant", "id": "assistant-1", "timestamp": 1_784_700_000_001, "content": "finished", "toolCalls": [["id": "tool-1", "status": "completed"]]]
            ], to: file)
            session = try unwrap(adapter.scan().sessions.first, "NewMax final fixture missing")
            try expect(session.status == .completed, "NewMax final response was not detected")
            try expect(session.completionFingerprint?.contains("assistant-1") == true, "NewMax completion fingerprint missing")

            try runSQLite(at: databaseURL, sql: "UPDATE conversations SET title='新标题', updated_at=1784700005000 WHERE id='conv-live';")
            adapter.invalidateCache()
            session = try unwrap(adapter.scan().sessions.first, "NewMax renamed fixture missing")
            try expect(session.title == "新标题", "NewMax manual refresh did not reload the title")
        }
    }),

    ("NewMax blank continuation stays running", {
        try withTempDirectory { temp in
            let root = temp.appendingPathComponent("conversations")
            let directory = root.appendingPathComponent("conv-continue")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let databaseURL = temp.appendingPathComponent("newmax.db")
            try createNewMaxDatabase(at: databaseURL)
            try runSQLite(
                at: databaseURL,
                sql: "INSERT INTO conversations VALUES ('conv-continue','workspace-1','继续执行','app',NULL,1784700000000,0);"
            )
            try writeLines([
                ["role": "user", "id": "user-1", "timestamp": 1_784_700_000_000, "content": "fixture"],
                ["role": "assistant", "id": "assistant-1", "timestamp": 1_784_700_000_001, "content": "first result", "toolCalls": []],
                ["role": "assistant", "id": "assistant-1", "timestamp": 1_784_700_005_000, "content": "", "toolCalls": [["id": "tool-1", "status": "completed"]]]
            ], to: directory.appendingPathComponent("messages.jsonl"))
            let session = try unwrap(NewMaxAdapter(
                root: root,
                databaseURL: databaseURL,
                hermesDatabaseURL: nil,
                maxAge: 100 * 365 * 24 * 60 * 60,
                maxFiles: 10,
                completionSettleInterval: 0
            ).scan().sessions.first, "NewMax continuation fixture missing")
            try expect(session.status == .running, "Blank continuation must not be mistaken for a final response")
        }
    }),

    ("NewMax automatic execution overrides stale tool state", {
        try withTempDirectory { temp in
            let root = temp.appendingPathComponent("conversations")
            let directory = root.appendingPathComponent("conv-routine")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let databaseURL = temp.appendingPathComponent("newmax.db")
            try createNewMaxDatabase(at: databaseURL)
            try runSQLite(
                at: databaseURL,
                sql: """
                INSERT INTO project_tasks VALUES ('task-1','auto');
                INSERT INTO task_executions VALUES ('exec-1','task-1','conv-routine','timeout',1784700000000,1784700060000);
                INSERT INTO conversations VALUES ('conv-routine','workspace-1','每日自动扫描','app','exec-1',1784700060000,0);
                """
            )
            try writeLines([
                ["role": "user", "id": "user-1", "timestamp": 1_784_700_000_000, "content": "fixture"],
                ["role": "assistant", "id": "assistant-1", "timestamp": 1_784_700_000_001, "content": "", "toolCalls": [["id": "tool-1", "status": "running"]]]
            ], to: directory.appendingPathComponent("messages.jsonl"))
            let session = try unwrap(NewMaxAdapter(
                root: root,
                databaseURL: databaseURL,
                hermesDatabaseURL: nil,
                maxAge: 100 * 365 * 24 * 60 * 60,
                maxFiles: 10,
                completionSettleInterval: 0
            ).scan().sessions.first, "NewMax routine fixture missing")
            try expect(session.status == .completed, "Terminal execution state must override stale running tool data")
            try expect(session.origin == .scheduled && session.isRoutine, "Automatic NewMax execution should be a routine run")
            try expect(!session.isBackground, "Routine NewMax result must not be hidden as technical background")
        }
    }),

    ("NewMax Hermes tasks stay in background", {
        try withTempDirectory { temp in
            let root = temp.appendingPathComponent("conversations")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let hermesURL = temp.appendingPathComponent("hermes-tasks.db")
            try runSQLite(
                at: hermesURL,
                sql: """
                CREATE TABLE hermes_tasks (
                    id TEXT PRIMARY KEY,
                    title TEXT NOT NULL,
                    status TEXT NOT NULL,
                    source TEXT NOT NULL,
                    created_at INTEGER NOT NULL,
                    completed_at INTEGER
                );
                INSERT INTO hermes_tasks VALUES ('hermes-1','内部资料整理','success','manual',1784700000000,1784700060000);
                """
            )
            let session = try unwrap(NewMaxAdapter(
                root: root,
                databaseURL: nil,
                hermesDatabaseURL: hermesURL,
                maxAge: 100 * 365 * 24 * 60 * 60,
                maxFiles: 10,
                completionSettleInterval: 0
            ).scan().sessions.first, "NewMax Hermes fixture missing")
            try expect(session.status == .completed, "Completed Hermes task was not detected")
            try expect(session.origin == .externalRuntime && session.isBackground, "Hermes task should remain background noise")
            try expect(SessionDeepLink.url(for: session) == nil, "Hermes task must not claim an unsupported conversation deep link")
        }
    }),
    ("WorkBuddy follows live turns and reloads renamed titles", {
        try withTempDirectory { temp in
            let root = temp.appendingPathComponent("projects")
            let directory = root.appendingPathComponent("Users-tester-WorkBuddy-test")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let databaseURL = temp.appendingPathComponent("workbuddy.db")
            try createWorkBuddyDatabase(at: databaseURL)
            try runSQLite(
                at: databaseURL,
                sql: """
                INSERT INTO sessions (
                    id,cwd,user_id,title,custom_title,status,created_at,updated_at,
                    deleted_at,source_mode,is_background_automation,last_activity_at
                ) VALUES (
                    'wb-live','/tmp/workbuddy-project','user-1','旧标题',NULL,'completed',
                    1784700000000,1784700000000,NULL,'working',0,1784700000000
                );
                """
            )
            let file = directory.appendingPathComponent("wb-live.jsonl")
            try writeLines([
                ["type": "message", "role": "user", "id": "user-1", "sessionId": "wb-live", "timestamp": 1_784_700_000_000, "content": "fixture"]
            ], to: file)

            let adapter = WorkBuddyAdapter(
                root: root,
                databaseURL: databaseURL,
                maxAge: 100 * 365 * 24 * 60 * 60,
                maxFiles: 10,
                completionSettleInterval: 0
            )
            var session = try unwrap(adapter.scan().sessions.first, "WorkBuddy running fixture missing")
            try expect(session.status == .running, "A new WorkBuddy user turn must override stale completed database state")
            try expect(session.title == "旧标题", "WorkBuddy database title was not used")
            try expect(session.origin == .interactive && session.isHostVisible, "WorkBuddy chat should be host-visible")

            try appendLines([
                ["type": "message", "role": "assistant", "status": "completed", "id": "assistant-1", "sessionId": "wb-live", "timestamp": 1_784_700_005_000, "content": "fixture"]
            ], to: file)
            session = try unwrap(adapter.scan().sessions.first, "WorkBuddy completed fixture missing")
            try expect(session.status == .completed, "WorkBuddy final assistant event was not detected")
            try expect(session.completionFingerprint == "workbuddy:user-1:assistant-1", "WorkBuddy completion fingerprint should be stable")

            try runSQLite(
                at: databaseURL,
                sql: "UPDATE sessions SET custom_title='新标题', updated_at=1784700006000 WHERE id='wb-live';"
            )
            adapter.invalidateCache()
            session = try unwrap(adapter.scan().sessions.first, "WorkBuddy renamed fixture missing")
            try expect(session.title == "新标题", "WorkBuddy manual refresh did not reload the renamed title")
        }
    }),
    ("WorkBuddy automations stay in the routine inbox", {
        try withTempDirectory { temp in
            let root = temp.appendingPathComponent("projects")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let databaseURL = temp.appendingPathComponent("workbuddy.db")
            try createWorkBuddyDatabase(at: databaseURL)
            try runSQLite(
                at: databaseURL,
                sql: """
                INSERT INTO automations VALUES ('auto-1','每日工作扫描','fixture','active','recurring',1784700000000,1784700000000);
                INSERT INTO automation_runs VALUES ('wb-auto-1','auto-1','completed',NULL,'今日扫描','/tmp/workbuddy-project',1784700000000,1784700060000);
                """
            )
            let session = try unwrap(WorkBuddyAdapter(
                root: root,
                databaseURL: databaseURL,
                maxAge: 100 * 365 * 24 * 60 * 60,
                maxFiles: 10,
                completionSettleInterval: 0
            ).scan().sessions.first, "WorkBuddy automation fixture missing")
            try expect(session.status == .completed, "Completed WorkBuddy automation was not detected")
            try expect(session.origin == .scheduled && session.isRoutine, "WorkBuddy automation should be a routine run")
            try expect(!session.isBackground, "WorkBuddy routine result must not be hidden as background noise")
        }
    }),
    ("Craft final metadata", {
        try withTempDirectory { root in
            let sessionDirectory = root.appendingPathComponent("sessions/test-session")
            try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
            let file = sessionDirectory.appendingPathComponent("session.jsonl")
            try writeLines([
                ["id": "craft-1", "name": "测试等待", "sessionStatus": "done", "lastMessageRole": "assistant",
                 "lastFinalMessageId": "final-9", "lastMessageAt": Date().timeIntervalSince1970 * 1000, "hasUnread": true],
                ["type": "assistant", "id": "final-9", "content": "正文不参与状态判断"]
            ], to: file)
            let result = CraftAdapter(root: root).scan()
            try expect(result.errors.isEmpty, "Craft parser returned errors")
            try expect(result.sessions.count == 1, "Craft session count should be 1")
            try expect(result.sessions[0].status == .completed, "Craft session should be completed")
            try expect(result.sessions[0].completionFingerprint == "craft:final-9", "Craft fingerprint mismatch")
        }
    }),
    ("Craft follows appended user and final assistant", {
        try withTempDirectory { root in
            let sessionDirectory = root.appendingPathComponent("sessions/live-session")
            try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
            let file = sessionDirectory.appendingPathComponent("session.jsonl")
            let metadata: [String: Any] = [
                "id": "craft-live", "name": "实时会话", "sessionStatus": "todo", "lastMessageRole": "tool",
                "lastFinalMessageId": "old-final", "lastMessageAt": Date().timeIntervalSince1970 * 1000
            ]
            try writeLines([
                metadata,
                ["type": "assistant", "id": "old-final", "isIntermediate": false, "timestamp": 1_000],
                ["type": "user", "id": "new-user", "timestamp": 2_000]
            ], to: file)

            let adapter = CraftAdapter(root: root)
            var result = adapter.scan()
            try expect(result.sessions[0].status == .running, "Craft appended user should be running")
            try expect(result.sessions[0].completionFingerprint == nil, "Old final must not complete a new turn")

            try writeLines([
                metadata,
                ["type": "assistant", "id": "old-final", "isIntermediate": false, "timestamp": 1_000],
                ["type": "user", "id": "new-user", "timestamp": 2_000],
                ["type": "assistant", "id": "new-final", "isIntermediate": false, "timestamp": 3_000]
            ], to: file)
            result = adapter.scan()
            try expect(result.sessions[0].status == .completed, "Craft appended final assistant should complete")
            try expect(result.sessions[0].completionFingerprint == "craft:new-final", "Craft should follow the appended final id")
        }
    }),
    ("Manual refresh reloads renamed Craft metadata", {
        try withTempDirectory { root in
            let sessionDirectory = root.appendingPathComponent("sessions/renamed-session")
            try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
            let file = sessionDirectory.appendingPathComponent("session.jsonl")
            let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
            let events: [[String: Any]] = [
                ["id": "craft-rename", "name": "旧名称", "sessionStatus": "done", "lastMessageRole": "assistant",
                 "lastFinalMessageId": "final-1", "lastMessageAt": 1_700_000_000_000 as Double],
                ["type": "assistant", "id": "final-1", "isIntermediate": false, "timestamp": 1_700_000_000_000 as Double]
            ]
            try writeLines(events, to: file)
            try FileManager.default.setAttributes([.modificationDate: fixedDate], ofItemAtPath: file.path)

            let adapter = CraftAdapter(root: root)
            try expect(adapter.scan().sessions.first?.title == "旧名称", "Initial Craft title missing")

            var renamed = events
            renamed[0]["name"] = "新名称"
            try writeLines(renamed, to: file)
            try FileManager.default.setAttributes([.modificationDate: fixedDate], ofItemAtPath: file.path)

            try expect(adapter.scan().sessions.first?.title == "旧名称", "Fixture should preserve the cached signature")
            adapter.invalidateCache()
            try expect(adapter.scan().sessions.first?.title == "新名称", "Manual refresh did not reload renamed Craft metadata")
        }
    }),
    ("Claude end_turn", {
        try withTempDirectory { root in
            let file = root.appendingPathComponent("claude-1.jsonl")
            try writeLines([
                ["type": "user", "uuid": "u1", "timestamp": "2026-07-15T00:00:00.000Z", "cwd": "/tmp/project", "isSidechain": false],
                ["type": "assistant", "uuid": "a1", "timestamp": "2026-07-15T00:00:01.000Z", "cwd": "/tmp/project", "isSidechain": false,
                 "message": ["role": "assistant", "stop_reason": "tool_use", "id": "msg1"]],
                ["type": "assistant", "uuid": "a2", "timestamp": "2026-07-15T00:00:02.000Z", "cwd": "/tmp/project", "isSidechain": false,
                 "message": ["role": "assistant", "stop_reason": "end_turn", "id": "msg2"]]
            ], to: file)
            let result = ClaudeCodeAdapter(root: root, craftRoot: nil, maxAge: 100 * 365 * 24 * 60 * 60, maxFiles: 10).scan()
            try expect(result.sessions.count == 1, "Claude session count should be 1")
            try expect(result.sessions[0].status == .completed, "Claude session should complete only on end_turn")
            try expect(result.sessions[0].completionFingerprint?.contains("a2") == true, "Claude fingerprint mismatch")
            try expect(result.sessions[0].origin == .externalRuntime, "Unmapped Claude transcript must be background")
            try expect(!result.sessions[0].isHostVisible, "Raw Claude transcript must not claim host visibility")
        }
    }),
    ("Claude tool results are not new user turns", {
        try withTempDirectory { root in
            let file = root.appendingPathComponent("claude-tools.jsonl")
            try writeLines([
                ["type": "user", "uuid": "u1", "timestamp": "2026-07-15T00:00:00.000Z", "cwd": "/tmp/project", "message": ["content": [["type": "text", "text": "task"]]]],
                ["type": "assistant", "uuid": "a1", "timestamp": "2026-07-15T00:00:01.000Z", "cwd": "/tmp/project", "message": ["stop_reason": "tool_use", "id": "msg1"]],
                ["type": "user", "uuid": "tool-result", "timestamp": "2026-07-15T00:00:02.000Z", "cwd": "/tmp/project", "toolUseResult": ["status": "ok"], "message": ["content": [["type": "tool_result"]]]],
                ["type": "assistant", "uuid": "a2", "timestamp": "2026-07-15T00:00:03.000Z", "cwd": "/tmp/project", "message": ["stop_reason": "end_turn", "id": "msg2"]]
            ], to: file)
            let session = ClaudeCodeAdapter(root: root, craftRoot: nil, maxAge: 100 * 365 * 24 * 60 * 60, maxFiles: 10).scan().sessions[0]
            let expectedStart = DateParser.parse("2026-07-15T00:00:00.000Z")!
            try expect(session.status == .completed, "Claude tool flow should still complete")
            try expect(abs((session.turnStartedAt ?? .distantPast).timeIntervalSince(expectedStart)) < 0.01, "Tool result must not replace the human turn start")
        }
    }),
    ("Codex task_complete", {
        try withTempDirectory { root in
            let file = root.appendingPathComponent("rollout-test.jsonl")
            try writeLines([
                ["type": "session_meta", "timestamp": "2026-07-15T00:00:00.000Z", "payload": ["id": "codex-1", "cwd": "/tmp/project"]],
                ["type": "event_msg", "timestamp": "2026-07-15T00:00:01.000Z", "payload": ["type": "task_started", "turn_id": "turn-1"]],
                ["type": "event_msg", "timestamp": "2026-07-15T00:00:02.000Z", "payload": ["type": "task_complete", "turn_id": "turn-1"]]
            ], to: file)
            let result = CodexAdapter(root: root, databaseURL: nil, maxAge: 100 * 365 * 24 * 60 * 60, maxFiles: 10).scan()
            try expect(result.sessions.count == 1, "Codex session count should be 1")
            try expect(result.sessions[0].status == .completed, "Codex task_complete not detected")
            try expect(result.sessions[0].completionFingerprint?.contains("turn-1") == true, "Codex fingerprint mismatch")
        }
    }),
    ("Manual refresh reloads a renamed Codex thread", {
        try withTempDirectory { root in
            let databaseURL = root.appendingPathComponent("state.sqlite")
            try runSQLite(
                at: databaseURL,
                sql: "CREATE TABLE threads (id TEXT PRIMARY KEY, title TEXT, archived INTEGER); INSERT INTO threads VALUES ('rename-1','旧名称',0);"
            )
            let file = root.appendingPathComponent("rollout-rename.jsonl")
            try writeLines([
                ["type": "session_meta", "timestamp": "2026-07-15T00:00:00.000Z", "payload": ["id": "rename-1", "cwd": "/tmp/project"]],
                ["type": "event_msg", "timestamp": "2026-07-15T00:00:01.000Z", "payload": ["type": "task_started", "turn_id": "turn-1"]],
                ["type": "event_msg", "timestamp": "2026-07-15T00:00:02.000Z", "payload": ["type": "task_complete", "turn_id": "turn-1"]]
            ], to: file)

            let adapter = CodexAdapter(
                root: root,
                databaseURL: databaseURL,
                maxAge: 100 * 365 * 24 * 60 * 60,
                maxFiles: 10
            )
            try expect(adapter.scan().sessions.first?.title == "旧名称", "Initial Codex title missing")
            try runSQLite(at: databaseURL, sql: "UPDATE threads SET title='新名称' WHERE id='rename-1';")

            // The rollout did not change, so this exercises metadata refresh
            // instead of accidentally relying on a transcript modification.
            adapter.invalidateCache()
            let refreshed = adapter.scan().sessions.first
            try expect(refreshed?.title == "新名称", "Manual refresh did not reload the renamed Codex title")
            try expect(refreshed?.status == .completed, "Metadata refresh changed the task state")
        }
    }),
    ("Codex rename refreshes when its title database changes", {
        try withTempDirectory { root in
            let databaseURL = root.appendingPathComponent("state.sqlite")
            try runSQLite(
                at: databaseURL,
                sql: "CREATE TABLE threads (id TEXT PRIMARY KEY, title TEXT, archived INTEGER); INSERT INTO threads VALUES ('rename-auto','旧名称',0);"
            )
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)],
                ofItemAtPath: databaseURL.path
            )
            let file = root.appendingPathComponent("rollout-rename-auto.jsonl")
            try writeLines([
                ["type": "session_meta", "timestamp": "2026-07-15T00:00:00.000Z", "payload": ["id": "rename-auto", "cwd": "/tmp/project"]],
                ["type": "event_msg", "timestamp": "2026-07-15T00:00:01.000Z", "payload": ["type": "task_started", "turn_id": "turn-1"]],
                ["type": "event_msg", "timestamp": "2026-07-15T00:00:02.000Z", "payload": ["type": "task_complete", "turn_id": "turn-1"]]
            ], to: file)

            let adapter = CodexAdapter(
                root: root,
                databaseURL: databaseURL,
                maxAge: 100 * 365 * 24 * 60 * 60,
                maxFiles: 10
            )
            try expect(adapter.scan().sessions.first?.title == "旧名称", "Initial Codex title missing")
            try runSQLite(at: databaseURL, sql: "UPDATE threads SET title='新名称' WHERE id='rename-auto';")

            let refreshed = adapter.scan().sessions.first
            try expect(refreshed?.title == "新名称", "Codex title did not follow the changed title database")
            try expect(refreshed?.status == .completed, "Automatic title refresh changed the task state")
        }
    }),
    ("Codex running survives oversized output and restart", {
        try withTempDirectory { root in
            let file = root.appendingPathComponent("rollout-large-running.jsonl")
            try writeLines([
                ["type": "session_meta", "timestamp": "2026-07-15T00:00:00.000Z", "payload": ["id": "codex-large", "cwd": "/tmp/project"]],
                ["type": "event_msg", "timestamp": "2026-07-15T00:00:01.000Z", "payload": ["type": "task_started", "turn_id": "turn-large"]]
            ], to: file)

            let adapter = CodexAdapter(root: root, databaseURL: nil, maxAge: 100 * 365 * 24 * 60 * 60, maxFiles: 10)
            try expect(adapter.scan().sessions.first?.status == .running, "Codex fixture should begin running")

            let oversizedOutput = (0..<420).map { index in
                [
                    "type": "response_item",
                    "timestamp": "2026-07-15T00:00:02.000Z",
                    "payload": ["index": index, "output": String(repeating: "x", count: 1_024)]
                ] as [String: Any]
            }
            try appendLines(oversizedOutput, to: file)

            try expect(adapter.scan().sessions.first?.status == .running, "Growing output must not make a running Codex task disappear")
            let restarted = CodexAdapter(root: root, databaseURL: nil, maxAge: 100 * 365 * 24 * 60 * 60, maxFiles: 10)
            try expect(restarted.scan().sessions.first?.status == .running, "Restart must recover a running task beyond the tail window")
        }
    }),
    ("History and duplicate suppression", {
        let detector = CompletionDetector()
        let now = Date()
        try expect(detector.process([makeSnapshot("old", at: now)], at: now).isEmpty, "History replayed at baseline")
        try expect(detector.process([makeSnapshot("old", at: now)], at: now.addingTimeInterval(1)).isEmpty, "Duplicate historical event")
        try expect(detector.process([makeSnapshot("new", at: now.addingTimeInterval(2))], at: now.addingTimeInterval(2)).count == 1, "New completion missing")
        try expect(detector.process([makeSnapshot("new", at: now.addingTimeInterval(2))], at: now.addingTimeInterval(3)).isEmpty, "New completion duplicated")
    }),
    ("Ten exact transitions", {
        let detector = CompletionDetector()
        let now = Date()
        _ = detector.process([makeSnapshot("baseline", at: now)], at: now)
        var events = 0
        var duplicates = 0
        for index in 1...10 {
            let value = makeSnapshot("event-\(index)", at: now.addingTimeInterval(Double(index)))
            events += detector.process([value], at: now.addingTimeInterval(Double(index))).count
            duplicates += detector.process([value], at: now.addingTimeInterval(Double(index) + 0.1)).count
        }
        try expect(events == 10, "Expected 10 events, got \(events)")
        try expect(duplicates == 0, "Expected 0 duplicates, got \(duplicates)")
    }),
    ("New session after startup", {
        let detector = CompletionDetector()
        let now = Date()
        _ = detector.process([], at: now)
        let session = makeSnapshot("first-final", at: now.addingTimeInterval(2), sessionID: "new-session")
        try expect(detector.process([session], at: now.addingTimeInterval(3)).count == 1, "New session completion missing")
    }),
    ("Known running session notifies on first completion", {
        let detector = CompletionDetector()
        let now = Date()
        let running = SessionSnapshot(
            tool: .craft,
            sessionID: "live-session",
            title: "实时会话",
            status: .running,
            lastActivity: now,
            completionFingerprint: nil,
            sourceFile: "/tmp/live.jsonl"
        )
        _ = detector.process([running], at: now)
        let completed = makeSnapshot("first-final", at: now.addingTimeInterval(2), sessionID: "live-session")
        try expect(detector.process([completed], at: now.addingTimeInterval(3)).count == 1, "Running-to-completed transition missing")
    }),
    ("Craft scheduled origin classification", {
        try withTempDirectory { root in
            let directory = root.appendingPathComponent("sessions/scheduled")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("session.jsonl")
            try writeLines([
                ["id": "craft-scheduled", "name": "每日任务", "triggeredBy": ["automationName": "每日任务", "timestamp": 2_000], "labels": ["Scheduled"]],
                ["type": "assistant", "id": "final", "isIntermediate": false, "timestamp": 3_000]
            ], to: file)
            let sessions = CraftAdapter(root: root).scan().sessions
            try expect(sessions.count == 1, "Craft scheduled fixture missing")
            let session = sessions[0]
            try expect(session.origin == .scheduled, "Craft scheduled session was not classified")
            try expect(session.isRoutine, "Craft scheduled session should enter the routine inbox")
            try expect(!session.isBackground, "Craft scheduled result should not be technical background")
            try expect(session.turnStartedAt != nil && session.turnCompletedAt != nil, "Craft turn timestamps missing")
        }
    }),
    ("Claude Multica and subagent classification", {
        try withTempDirectory { root in
            try writeLines([
                ["type": "user", "uuid": "u1", "timestamp": "2026-07-15T01:00:00.000Z", "cwd": "/Users/tester/multica_workspaces_desktop-api.multica.ai/a/b/workdir"],
                ["type": "assistant", "uuid": "a1", "timestamp": "2026-07-15T01:01:00.000Z", "cwd": "/Users/tester/multica_workspaces_desktop-api.multica.ai/a/b/workdir", "message": ["stop_reason": "end_turn", "id": "m1"]]
            ], to: root.appendingPathComponent("multica.jsonl"))
            try writeLines([
                ["type": "user", "uuid": "u2", "timestamp": "2026-07-15T01:00:00.000Z", "cwd": "/tmp/project", "isSidechain": true, "agentId": "agent-1"],
                ["type": "assistant", "uuid": "a2", "timestamp": "2026-07-15T01:01:00.000Z", "cwd": "/tmp/project", "isSidechain": true, "agentId": "agent-1", "message": ["stop_reason": "end_turn", "id": "m2"]]
            ], to: root.appendingPathComponent("subagent.jsonl"))
            let sessions = ClaudeCodeAdapter(root: root, craftRoot: nil, maxAge: 100 * 365 * 24 * 60 * 60, maxFiles: 10).scan().sessions
            try expect(sessions.contains { $0.origin == .externalRuntime }, "Claude Multica origin missing")
            try expect(sessions.contains { $0.origin == .subagent }, "Claude subagent origin missing")
            try expect(sessions.allSatisfy(\.isBackground), "Claude background sessions should not be host-visible")
        }
    }),
    ("Claude Craft runtime deduplication", {
        try withTempDirectory { root in
            let claudeRoot = root.appendingPathComponent("claude")
            let craftRoot = root.appendingPathComponent("craft")
            try FileManager.default.createDirectory(at: claudeRoot, withIntermediateDirectories: true)
            let craftSession = craftRoot.appendingPathComponent("sessions/craft-session")
            try FileManager.default.createDirectory(at: craftSession, withIntermediateDirectories: true)
            try writeLines([
                ["id": "craft-session", "name": "Craft 对话", "sdkSessionId": "craft-sdk"]
            ], to: craftSession.appendingPathComponent("session.jsonl"))
            try writeLines([
                ["type": "user", "uuid": "u1", "timestamp": "2026-07-15T01:00:00.000Z", "cwd": "/tmp/project"],
                ["type": "assistant", "uuid": "a1", "timestamp": "2026-07-15T01:01:00.000Z", "cwd": "/tmp/project", "message": ["stop_reason": "end_turn", "id": "m1"]]
            ], to: claudeRoot.appendingPathComponent("craft-sdk.jsonl"))
            let session = ClaudeCodeAdapter(
                root: claudeRoot,
                craftRoot: craftRoot,
                maxAge: 100 * 365 * 24 * 60 * 60,
                maxFiles: 10
            ).scan().sessions[0]
            try expect(session.origin == .detached, "Craft SDK transcript should be grouped as detached background")
            try expect(session.title.contains("Craft 运行时"), "Craft runtime title should explain the duplicate source")
        }
    }),
    ("Codex subagent external and detached classification", {
        try withTempDirectory { root in
            let databaseURL = root.appendingPathComponent("state.sqlite")
            try createCodexDatabase(at: databaseURL)
            let fixtures: [(String, [String: Any])] = [
                ("subagent", ["id": "sub-1", "cwd": "/tmp/project", "thread_source": "subagent", "parent_thread_id": "parent", "source": ["subagent": [:]]]),
                ("external", ["id": "external-1", "cwd": "/tmp/project", "source": "vscode", "originator": "multica-agent-sdk"]),
                ("detached", ["id": "detached-1", "cwd": "/tmp/project", "source": "vscode", "originator": "Codex Desktop"])
            ]
            for (name, payload) in fixtures {
                try writeLines([
                    ["type": "session_meta", "timestamp": "2026-07-15T00:00:00.000Z", "payload": payload],
                    ["type": "event_msg", "timestamp": "2026-07-15T00:00:01.000Z", "payload": ["type": "task_started", "turn_id": "turn-\(name)"]],
                    ["type": "event_msg", "timestamp": "2026-07-15T00:00:02.000Z", "payload": ["type": "task_complete", "turn_id": "turn-\(name)"]]
                ], to: root.appendingPathComponent("rollout-\(name).jsonl"))
            }
            let sessions = CodexAdapter(root: root, databaseURL: databaseURL, maxAge: 100 * 365 * 24 * 60 * 60, maxFiles: 10).scan().sessions
            try expect(sessions.contains { $0.origin == .subagent }, "Codex subagent origin missing")
            try expect(sessions.contains { $0.origin == .externalRuntime }, "Codex external runtime origin missing")
            try expect(sessions.contains { $0.origin == .detached }, "Codex detached origin missing")
        }
    }),
    ("Inbox lifecycle and manual handling", {
        try withTempDirectory { root in
            let now = Date()
            let store = InboxStateStore(url: root.appendingPathComponent("state.json"))
            let running = makeSession(status: .running, fingerprint: nil, startedAt: now, completedAt: nil)
            var update = store.reconcile([running], at: now)
            try expect(update.attentionStates[running.id] == .running, "Baseline running state missing")
            try expect(update.completionEvents.isEmpty, "Baseline should not create completion events")

            let completed = makeSession(status: .completed, fingerprint: "turn-1", startedAt: now, completedAt: now.addingTimeInterval(30))
            update = store.reconcile([completed], at: now.addingTimeInterval(31))
            try expect(update.attentionStates[completed.id] == .unread, "Completion should arrive as unread")
            try expect(update.completionEvents.count == 1, "Completion event missing")

            try expect(store.markRead(completed), "Unread completion should be markable as read")
            try expect(store.attentionStates(for: [completed])[completed.id] == .pending, "Read completion should wait for a decision")

            let handled = store.markHandled(completed, at: now.addingTimeInterval(40))
            try expect(handled?.handledMethod == .manual, "Manual handled transition missing")
            try expect(store.attentionStates(for: [completed])[completed.id] == .handled, "Handled session should leave inbox")

            let nextRunning = makeSession(status: .running, fingerprint: nil, startedAt: now.addingTimeInterval(60), completedAt: nil)
            update = store.reconcile([nextRunning], at: now.addingTimeInterval(61))
            try expect(update.attentionStates[nextRunning.id] == .running, "New reply should make old session visible again")

            let nextCompleted = makeSession(status: .completed, fingerprint: "turn-2", startedAt: now.addingTimeInterval(60), completedAt: now.addingTimeInterval(90))
            update = store.reconcile([nextCompleted], at: now.addingTimeInterval(91))
            try expect(update.attentionStates[nextCompleted.id] == .unread, "Second completion should arrive as unread")

            let replied = makeSession(status: .running, fingerprint: nil, startedAt: now.addingTimeInterval(120), completedAt: nil)
            update = store.reconcile([replied], at: now.addingTimeInterval(121))
            try expect(update.transitions.contains { $0.kind == .handled && $0.handledMethod == .replied }, "Reply should handle previous turn")
        }
    }),
    ("Inbox persistence and offline recovery", {
        try withTempDirectory { root in
            let url = root.appendingPathComponent("state.json")
            let now = Date()
            _ = InboxStateStore(url: url).reconcile([], at: now)

            let offlineCompletion = makeSession(
                status: .completed,
                fingerprint: "offline-final",
                startedAt: now.addingTimeInterval(10),
                completedAt: now.addingTimeInterval(20),
                sessionID: "offline"
            )
            var update = InboxStateStore(url: url).reconcile([offlineCompletion], at: now.addingTimeInterval(30))
            try expect(update.completionEvents.count == 1, "Offline completion should recover after restart")
            try expect(update.attentionStates[offlineCompletion.id] == .unread, "Recovered completion should persist as unread")

            try expect(InboxStateStore(url: url).markRead(offlineCompletion), "Recovered completion should be markable as read")

            update = InboxStateStore(url: url).reconcile([offlineCompletion], at: now.addingTimeInterval(40))
            try expect(update.completionEvents.isEmpty, "Recovered completion must not duplicate")
            try expect(update.attentionStates[offlineCompletion.id] == .pending, "Read state should survive another restart")
        }
    }),
    ("Inbox restart ignores timestamp precision drift", {
        try withTempDirectory { root in
            let url = root.appendingPathComponent("state.json")
            let start = Date(timeIntervalSince1970: 1_784_082_149.456)
            let running = makeSession(status: .running, fingerprint: nil, startedAt: start, completedAt: nil, sessionID: "precision")
            _ = InboxStateStore(url: url).reconcile([running], at: start.addingTimeInterval(1))
            let update = InboxStateStore(url: url).reconcile([running], at: start.addingTimeInterval(2))
            try expect(!update.transitions.contains { $0.kind == .taskStarted }, "Restart must not replay a task because ISO dates lost milliseconds")
        }
    }),
    ("Display policy separates active stalled and background", {
        let now = Date()
        let policy = SessionDisplayPolicy(activeWindow: 15 * 60, backgroundWindow: 6 * 60 * 60)
        let active = makeSession(status: .running, fingerprint: nil, startedAt: now.addingTimeInterval(-60), completedAt: nil)
        let stalled = makeSession(status: .running, fingerprint: nil, startedAt: now.addingTimeInterval(-20 * 60), completedAt: nil, sessionID: "stalled")
        let hidden = makeSession(status: .running, fingerprint: nil, startedAt: now.addingTimeInterval(-7 * 60 * 60), completedAt: nil, sessionID: "hidden")
        let scheduled = makeSession(status: .running, fingerprint: nil, startedAt: now.addingTimeInterval(-60), completedAt: nil, sessionID: "scheduled", origin: .scheduled)
        try expect(policy.bucket(for: active, attention: .running, now: now) == .active, "Recent interaction should be active")
        try expect(policy.bucket(for: stalled, attention: .running, now: now) == .background, "Stale technical running state should move to background")
        try expect(policy.isStalled(stalled, attention: .running, now: now), "Stalled interactive session should be labelled")
        try expect(policy.bucket(for: hidden, attention: .running, now: now) == .hidden, "Very old running state should not occupy the inbox")
        try expect(policy.bucket(for: scheduled, attention: .running, now: now) == .routine, "Scheduled work should enter the routine group")
        try expect(policy.bucket(for: active, attention: .unread, now: now) == .pending, "Unread interactive work should remain in the inbox")
        try expect(policy.bucket(for: scheduled, attention: .pending, now: now) == .routine, "Read scheduled work should remain grouped as routine")
    }),
    ("Timeline stops at reply and preserves turn boundaries", {
        let calendar = Calendar(identifier: .gregorian)
        let day = calendar.startOfDay(for: Date())
        let records = [
            ActivityRecord(kind: .assistantCompleted, timestamp: day.addingTimeInterval(300), startedAt: day.addingTimeInterval(100), durationSeconds: 200, tool: .craft, sessionID: "craft:1", turnID: "one", title: "连续对话", origin: .interactive),
            ActivityRecord(kind: .handled, timestamp: day.addingTimeInterval(900), startedAt: day.addingTimeInterval(300), durationSeconds: 600, tool: .craft, sessionID: "craft:1", turnID: "one", title: "连续对话", origin: .interactive, handledMethod: .manual),
            ActivityRecord(kind: .assistantCompleted, timestamp: day.addingTimeInterval(1_100), startedAt: day.addingTimeInterval(1_000), durationSeconds: 100, tool: .craft, sessionID: "craft:1", turnID: "two", title: "连续对话", origin: .interactive)
        ]
        let timeline = DailyTimelineBuilder().build(for: day, records: records, now: day.addingTimeInterval(2_000), calendar: calendar)
        try expect(timeline.tasks.count == 2, "Each active turn should keep its own exact interval")
        try expect(abs(timeline.tasks[0].end.timeIntervalSince(day.addingTimeInterval(300))) < 0.01, "Waiting after AI reply must not extend the task block")
        try expect(timeline.tasks[1].start == day.addingTimeInterval(1_000), "A later reply should start a new active interval")
    }),
    ("Daily report metrics and privacy", {
        let calendar = Calendar(identifier: .gregorian)
        let start = calendar.startOfDay(for: Date())
        let records: [ActivityRecord] = [
            ActivityRecord(kind: .appForeground, timestamp: start.addingTimeInterval(3_600), startedAt: start, durationSeconds: 3_600, tool: .craft),
            ActivityRecord(kind: .taskStarted, timestamp: start.addingTimeInterval(100), tool: .craft, sessionID: "craft:1", turnID: "start-1", title: "任务一", projectPath: "/tmp/project", origin: .interactive),
            ActivityRecord(kind: .assistantCompleted, timestamp: start.addingTimeInterval(700), startedAt: start.addingTimeInterval(100), durationSeconds: 600, tool: .craft, sessionID: "craft:1", turnID: "final-1", title: "任务一", projectPath: "/tmp/project", origin: .interactive),
            ActivityRecord(kind: .handled, timestamp: start.addingTimeInterval(1_000), startedAt: start.addingTimeInterval(700), durationSeconds: 300, tool: .craft, sessionID: "craft:1", turnID: "final-1", title: "任务一", projectPath: "/tmp/project", origin: .interactive, handledMethod: .manual),
            ActivityRecord(kind: .assistantCompleted, timestamp: start.addingTimeInterval(750), startedAt: start.addingTimeInterval(250), durationSeconds: 500, tool: .craft, sessionID: "craft:routine", turnID: "routine-1", title: "每日扫描", projectPath: "/tmp/routine", origin: .scheduled),
            ActivityRecord(kind: .assistantCompleted, timestamp: start.addingTimeInterval(800), startedAt: start.addingTimeInterval(200), durationSeconds: 600, tool: .codex, sessionID: "codex:2", turnID: "final-2", title: "后台任务", projectPath: "/tmp/project", origin: .subagent)
        ]
        let report = DailyReportGenerator().markdown(for: start, records: records, calendar: calendar)
        try expect(report.contains("前台使用：1 小时 0 分钟"), "Foreground usage missing from report")
        try expect(report.contains("AI 完成：3 次"), "Completion count missing from report")
        try expect(report.contains("例行任务完成：1 次"), "Routine completion metric missing from report")
        try expect(report.contains("定时任务完成：1"), "Routine section missing from report")
        try expect(report.contains("子 Agent 完成：1"), "Background breakdown missing from report")
        try expect(report.contains("日终待处理：2 个"), "Pending count missing from report")
        try expect(!report.contains("message"), "Report must not contain message body fields")

        let quietReport = DailyReportGenerator().markdown(
            for: start,
            records: records,
            includeBackground: false,
            calendar: calendar
        )
        try expect(quietReport.contains("AI 完成：2 次"), "Hidden background work must preserve interactive and routine metrics")
        try expect(quietReport.contains("| routine | 1"), "Scheduled project metrics must remain when technical background is hidden")
        try expect(quietReport.contains("例行任务仍会保留"), "Background filter copy should explain that routines remain")
        try expect(!quietReport.contains("后台任务"), "Hidden background work must not leak into project rows")
        try expect(!quietReport.contains("子 Agent 完成"), "Hidden background section must be removed")
        let quietHTML = DailyReportGenerator().html(
            for: start,
            records: records,
            includeBackground: false,
            now: start.addingTimeInterval(2_000),
            calendar: calendar
        )
        try expect(quietHTML.contains("已隐藏幕后任务"), "Visual report should show the active filter")
        try expect(quietHTML.contains("例行剑令"), "Visual report should keep routine tasks visible")
        try expect(quietHTML.contains("每日扫描"), "Visual report should retain the scheduled task title")
        try expect(!quietHTML.contains("data-session=\"codex:2\""), "Background rows must be absent from the visual report")
        try expect(!quietHTML.contains("data-origin=\"subagent\""), "Hidden background work must not leak through task metadata")

        let englishHTML = DailyReportGenerator().html(
            for: start,
            records: records,
            includeBackground: false,
            language: .english,
            now: start.addingTimeInterval(2_000),
            calendar: calendar
        )
        try expect(englishHTML.contains("<html lang=\"en\">"), "English report language metadata missing")
        try expect(englishHTML.contains("Bladecall Daily Report"), "English report title missing")
        try expect(englishHTML.contains("Routine runs"), "English routine legend missing")
        try expect(englishHTML.contains("Background hidden"), "English background filter missing")
        try expect(!englishHTML.contains("一天横向时间轴"), "English report should not retain Chinese interface labels")
    }),
    ("Daily report empty day", {
        let report = DailyReportGenerator().markdown(for: Date(), records: [])
        try expect(report.contains("AI 完成：0 次"), "Empty report should render zero metrics")
        try expect(report.contains("暂无完成记录"), "Empty report should include a clear empty state")
        let html = DailyReportGenerator().html(for: Date(), records: [])
        try expect(html.contains("一天横向时间轴"), "Horizontal visual timeline missing")
        try expect(html.contains("gantt-scroll"), "Horizontally scrollable timeline missing")
        try expect(html.contains("id=\"zoom\""), "Adjustable time scale control missing")
        try expect(html.contains("每个时间块在 AI 完成本轮时结束"), "Timeline cutoff explanation missing")
    }),
    ("Report template probe reads a prefix and caches by file identity", {
        try withTempDirectory { dir in
            let probe = DailyReportTemplateProbe()
            let day = Date(timeIntervalSince1970: 1_784_700_000)
            let pinnedMTime = Date(timeIntervalSince1970: 1_784_700_000)
            let reportURL = dir.appendingPathComponent("report.html")
            let html = DailyReportGenerator().html(for: day, records: [], now: day.addingTimeInterval(3_600))
            try html.write(to: reportURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: pinnedMTime], ofItemAtPath: reportURL.path)
            try expect(!probe.needsUpgrade(at: reportURL), "The rendered report must expose its template marker within the probe prefix")

            let versionText = "\(DailyReportGenerator.htmlTemplateVersion)"
            let stale = html.replacingOccurrences(
                of: "jianling-report-template\" content=\"\(versionText)\"",
                with: "jianling-report-template\" content=\"\(String(repeating: "0", count: versionText.count))\""
            )
            try expect(stale != html, "Test setup must actually rewrite the template marker")
            try stale.write(to: reportURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: pinnedMTime], ofItemAtPath: reportURL.path)
            try expect(!probe.needsUpgrade(at: reportURL), "An unchanged (path, mtime, size) identity must reuse the cached verdict without re-reading")

            try FileManager.default.setAttributes([.modificationDate: pinnedMTime.addingTimeInterval(5)], ofItemAtPath: reportURL.path)
            try expect(probe.needsUpgrade(at: reportURL), "A touched file must be re-probed and its stale marker detected")

            let buriedURL = dir.appendingPathComponent("buried.html")
            try (String(repeating: " ", count: 8_192) + html).write(to: buriedURL, atomically: true, encoding: .utf8)
            try expect(probe.needsUpgrade(at: buriedURL), "A marker beyond the probe prefix must be treated as needing regeneration")
            try expect(probe.needsUpgrade(at: dir.appendingPathComponent("missing.html")), "A missing report must be regenerated")
        }
    }),
    ("Daily report v2 operations console structure", {
        let calendar = Calendar(identifier: .gregorian)
        let start = calendar.startOfDay(for: Date())
        let records = [
            ActivityRecord(kind: .taskStarted, timestamp: start.addingTimeInterval(3_600), tool: .codex, sessionID: "codex:active", turnID: "s1", title: "修复扫描器", origin: .interactive),
            ActivityRecord(kind: .assistantCompleted, timestamp: start.addingTimeInterval(4_200), startedAt: start.addingTimeInterval(3_600), durationSeconds: 600, tool: .codex, sessionID: "codex:active", turnID: "c1", title: "修复扫描器", origin: .interactive),
            ActivityRecord(kind: .assistantCompleted, timestamp: start.addingTimeInterval(7_200), startedAt: start.addingTimeInterval(6_600), durationSeconds: 600, tool: .craft, sessionID: "craft:routine", turnID: "c2", title: "每日扫描", origin: .scheduled),
            ActivityRecord(kind: .assistantCompleted, timestamp: start.addingTimeInterval(7_800), startedAt: start.addingTimeInterval(7_400), durationSeconds: 400, tool: .newMax, sessionID: "newMax:conv-1", turnID: "c3", title: "NewMax 调研", origin: .interactive),
            ActivityRecord(kind: .assistantCompleted, timestamp: start.addingTimeInterval(8_400), startedAt: start.addingTimeInterval(8_000), durationSeconds: 400, tool: .workBuddy, sessionID: "workBuddy:conv-1", turnID: "c4", title: "WorkBuddy 调研", origin: .interactive)
        ]
        let html = DailyReportGenerator().html(for: start, records: records, now: start.addingTimeInterval(8_000), calendar: calendar)
        try expect(DailyReportGenerator.isCurrentHTMLTemplate(html), "Report should carry the current template marker")
        try expect(html.contains("class=\"sidebar\""), "Fixed filter sidebar missing")
        try expect(html.contains("data-filter-value=\"interactive\""), "Conversation source filter missing")
        try expect(html.contains("data-filter-value=\"routine\""), "Routine source filter missing")
        try expect(html.contains("data-filter-value=\"background\""), "Background source filter missing")
        try expect(html.contains("id=\"density-canvas\""), "Completion density band missing")
        try expect(html.contains("id=\"detail-drawer\""), "Task detail drawer missing")
        try expect(html.contains("data-open-completions"), "Completion metric should open all completion events")
        try expect(html.contains("data-end-minute=\"70.0\""), "Completion event should expose an aligned timeline minute")
        try expect(html.contains("@media(max-width:900px)"), "Responsive compact filter layout missing")
        try expect(html.contains("@media(max-width:680px)"), "Narrow-window layout missing")
        try expect(html.contains("data-filter-value=\"newMax\""), "NewMax report filter missing")
        try expect(html.contains("data-tool=\"newMax\""), "NewMax timeline group missing")
        try expect(html.contains("class=\"key newmax\""), "NewMax report legend missing")
        try expect(html.contains("data-filter-value=\"workBuddy\""), "WorkBuddy report filter missing")
        try expect(html.contains("data-tool=\"workBuddy\""), "WorkBuddy timeline group missing")
        try expect(html.contains("class=\"key workbuddy\""), "WorkBuddy report legend missing")
        try expect(!html.contains("<strong>修复扫描器</strong>"), "Task bars should not repeat titles inside the timeline")
    }),
    ("Daily report template migration marker", {
        try expect(!DailyReportGenerator.isCurrentHTMLTemplate("<html><body>legacy</body></html>"), "Legacy reports must be detected")
        try expect(DailyReportGenerator.isCurrentHTMLTemplate("<meta name=\"jianling-report-template\" content=\"4\">"), "Current reports must not be regenerated")
    }),
    ("Snapshot content equality ignores generatedAt and revision", {
        let task = JianlingTaskSnapshot(
            id: "craft:one",
            sessionID: "one",
            tool: .craft,
            title: "内容守卫",
            state: .unread,
            origin: .interactive,
            updatedAt: Date(timeIntervalSince1970: 1_784_700_000),
            completedAt: Date(timeIntervalSince1970: 1_784_700_100),
            turnFingerprint: "fp-1",
            projectName: "剑令",
            isHostVisible: true
        )
        let base = JianlingInboxSnapshot(
            generatedAt: Date(timeIntervalSince1970: 1_784_700_200),
            revision: 100,
            tasks: [task],
            todayHandledCount: 2,
            hideBackgroundTasks: true
        )
        let republished = JianlingInboxSnapshot(
            generatedAt: base.generatedAt.addingTimeInterval(300),
            revision: base.revision + 60,
            tasks: base.tasks,
            todayHandledCount: base.todayHandledCount,
            hideBackgroundTasks: base.hideBackgroundTasks
        )
        try expect(base.hasSameContent(as: republished), "generatedAt/revision drift must not count as a content change")

        let stateChanged = JianlingInboxSnapshot(
            generatedAt: base.generatedAt,
            revision: base.revision,
            tasks: [JianlingTaskSnapshot(
                id: task.id,
                sessionID: task.sessionID,
                tool: task.tool,
                title: task.title,
                state: .pending,
                origin: task.origin,
                updatedAt: task.updatedAt,
                completedAt: task.completedAt,
                turnFingerprint: task.turnFingerprint,
                projectName: task.projectName,
                isHostVisible: task.isHostVisible
            )],
            todayHandledCount: base.todayHandledCount,
            hideBackgroundTasks: base.hideBackgroundTasks
        )
        try expect(!base.hasSameContent(as: stateChanged), "Task state change must count as a content change")

        let handledChanged = JianlingInboxSnapshot(
            generatedAt: base.generatedAt,
            revision: base.revision,
            tasks: base.tasks,
            todayHandledCount: base.todayHandledCount + 1,
            hideBackgroundTasks: base.hideBackgroundTasks
        )
        try expect(!base.hasSameContent(as: handledChanged), "todayHandledCount change must count as a content change")

        let visibilityChanged = JianlingInboxSnapshot(
            generatedAt: base.generatedAt,
            revision: base.revision,
            tasks: base.tasks,
            todayHandledCount: base.todayHandledCount,
            hideBackgroundTasks: !base.hideBackgroundTasks
        )
        try expect(!base.hasSameContent(as: visibilityChanged), "hideBackgroundTasks change must count as a content change")
    }),
    ("Idle reconcile skips disk writes", {
        try withTempDirectory { temp in
            let url = temp.appendingPathComponent("inbox-state.json")
            let store = InboxStateStore(url: url)
            let base = Date(timeIntervalSince1970: 1_784_700_000)
            let running = makeSession(status: .running, fingerprint: nil, startedAt: base, completedAt: nil)

            _ = store.reconcile([running], at: base)
            let initialBytes = try Data(contentsOf: url)

            _ = store.reconcile([running], at: base.addingTimeInterval(5))
            _ = store.reconcile([running], at: base.addingTimeInterval(10))
            let idleBytes = try Data(contentsOf: url)
            try expect(idleBytes == initialBytes, "Unchanged reconciles must not rewrite the state file")

            let completed = makeSession(
                status: .completed,
                fingerprint: "fp-idle-1",
                startedAt: base,
                completedAt: base.addingTimeInterval(12)
            )
            let result = store.reconcile([completed], at: base.addingTimeInterval(15))
            try expect(result.completionEvents.count == 1, "Completion must still be detected after idle ticks")
            let dirtyBytes = try Data(contentsOf: url)
            try expect(dirtyBytes != initialBytes, "Substantive change must hit the disk immediately")
        }
    }),
    ("Idle heartbeat persists lastScanAt after interval", {
        try withTempDirectory { temp in
            let url = temp.appendingPathComponent("inbox-state.json")
            let store = InboxStateStore(url: url, idlePersistInterval: 1)
            let base = Date(timeIntervalSince1970: 1_784_700_000)
            let running = makeSession(status: .running, fingerprint: nil, startedAt: base, completedAt: nil)

            _ = store.reconcile([running], at: base)
            let initialBytes = try Data(contentsOf: url)

            _ = store.reconcile([running], at: base.addingTimeInterval(0.5))
            let throttledBytes = try Data(contentsOf: url)
            try expect(throttledBytes == initialBytes, "Idle tick inside the interval must not write")

            let heartbeat = store.reconcile([running], at: base.addingTimeInterval(2))
            try expect(heartbeat.transitions.isEmpty, "Heartbeat round must not invent transitions")
            let heartbeatBytes = try Data(contentsOf: url)
            try expect(heartbeatBytes != initialBytes, "Heartbeat must persist the rolling lastScanAt")
        }
    }),
    ("Throttled lastScanAt only widens offline recovery", {
        try withTempDirectory { temp in
            let url = temp.appendingPathComponent("inbox-state.json")
            let base = Date(timeIntervalSince1970: 1_784_700_000)

            let storeA = InboxStateStore(url: url, idlePersistInterval: 3600)
            _ = storeA.reconcile([], at: base)
            _ = storeA.reconcile([], at: base.addingTimeInterval(120))

            let storeB = InboxStateStore(url: url)
            let offlineCompleted = makeSession(
                status: .completed,
                fingerprint: "fp-offline-1",
                startedAt: base.addingTimeInterval(30),
                completedAt: base.addingTimeInterval(60),
                sessionID: "offline-session"
            )
            let result = storeB.reconcile([offlineCompleted], at: base.addingTimeInterval(180))
            try expect(result.completionEvents.count == 1, "Offline completion inside the widened window must be recovered")
            let attention = try unwrap(result.attentionStates[offlineCompleted.id], "Recovered session must have an attention state")
            try expect(attention == .unread, "Recovered offline completion must surface as unread")
        }
    }),
    ("Activity log cache appends in memory and survives truncation", {
        try withTempDirectory { temp in
            let url = temp.appendingPathComponent("activity.jsonl")
            let store = ActivityLogStore(url: url)
            let base = Date(timeIntervalSince1970: 1_784_700_000)
            func record(_ turnID: String, offset: TimeInterval) -> ActivityRecord {
                ActivityRecord(
                    kind: .assistantCompleted,
                    timestamp: base.addingTimeInterval(offset),
                    tool: .craft,
                    sessionID: "craft:cache",
                    turnID: turnID,
                    title: "缓存测试",
                    origin: .interactive
                )
            }

            store.append(record("t1", offset: 0))
            store.append(record("t2", offset: 60))
            try expect(store.records().map(\.turnID) == ["t1", "t2"], "Cache must mirror appended records in order")

            let freshReader = ActivityLogStore(url: url)
            try expect(freshReader.records().count == 2, "A separate instance (CLI process) must read the same records from disk")

            try Data().write(to: url)
            try expect(store.records().isEmpty, "External truncation must drop the cache and reload from disk")

            store.append(record("t3", offset: 120))
            try expect(store.records().map(\.turnID) == ["t3"], "Appends after truncation must rebuild a consistent view")

            let postRotationReader = ActivityLogStore(url: url)
            try expect(postRotationReader.records().map(\.turnID) == ["t3"], "Disk must stay the source of truth after rotation")
        }
    }),
    ("Scan change detector short-circuits identical scans", {
        let base = Date(timeIntervalSince1970: 1_784_700_000)
        let running = makeSession(status: .running, fingerprint: nil, startedAt: base, completedAt: nil, sessionID: "alpha")
        let completed = makeSession(status: .completed, fingerprint: "fp-b", startedAt: base, completedAt: base.addingTimeInterval(60), sessionID: "beta")
        let routine = makeSession(status: .completed, fingerprint: "fp-c", startedAt: base, completedAt: base.addingTimeInterval(90), sessionID: "gamma", origin: .scheduled)
        let previous = ScanChangeDetector.canonical([running, completed, routine])

        try expect(!ScanChangeDetector.isUnchanged(
            canonicalSessions: previous,
            errors: [],
            previousCanonicalSessions: nil,
            previousErrors: []
        ), "The first scan has no baseline and must not short-circuit")

        try expect(ScanChangeDetector.isUnchanged(
            canonicalSessions: ScanChangeDetector.canonical([routine, running, completed]),
            errors: [],
            previousCanonicalSessions: previous,
            previousErrors: []
        ), "Identical content in a different order must short-circuit")

        let drifted = makeSession(status: .completed, fingerprint: "fp-b", startedAt: base, completedAt: base.addingTimeInterval(60.001), sessionID: "beta")
        try expect(!ScanChangeDetector.isUnchanged(
            canonicalSessions: ScanChangeDetector.canonical([running, drifted, routine]),
            errors: [],
            previousCanonicalSessions: previous,
            previousErrors: []
        ), "A 1ms lastActivity drift must defeat the short-circuit")

        try expect(!ScanChangeDetector.isUnchanged(
            canonicalSessions: previous,
            errors: ["craft: boom"],
            previousCanonicalSessions: previous,
            previousErrors: []
        ), "A new adapter error must defeat the short-circuit")
    }),
    ("Scan change detector keeps settled completions flowing", {
        let base = Date(timeIntervalSince1970: 1_784_700_000)
        let stalled = makeSession(status: .running, fingerprint: nil, startedAt: base, completedAt: nil, sessionID: "settle")
        let previous = ScanChangeDetector.canonical([stalled])

        try expect(ScanChangeDetector.isUnchanged(
            canonicalSessions: ScanChangeDetector.canonical([stalled]),
            errors: [],
            previousCanonicalSessions: previous,
            previousErrors: []
        ), "A stalled running session with byte-identical output must short-circuit")

        let settled = makeSession(status: .completed, fingerprint: "fp-settle", startedAt: base, completedAt: base.addingTimeInterval(90), sessionID: "settle")
        try expect(!ScanChangeDetector.isUnchanged(
            canonicalSessions: ScanChangeDetector.canonical([settled]),
            errors: [],
            previousCanonicalSessions: previous,
            previousErrors: []
        ), "A settle flip (running → completed) in adapter output must defeat the short-circuit")
    }),
    ("Display fingerprint escalates on bucket and day boundaries", {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try unwrap(TimeZone(identifier: "Asia/Shanghai"), "Time zone must exist")
        let policy = SessionDisplayPolicy()
        let noon = try unwrap(
            calendar.date(from: DateComponents(year: 2026, month: 7, day: 20, hour: 12, minute: 0)),
            "Reference date must be constructible"
        )

        let decaying = makeSession(
            status: .running,
            fingerprint: nil,
            startedAt: noon.addingTimeInterval(-14 * 60),
            completedAt: nil,
            sessionID: "decay"
        )
        let attention: [String: AttentionState] = [decaying.id: .running]

        let first = DisplayFingerprint.compute(sessions: [decaying], attentionStates: attention, activeSnoozeIDs: [], policy: policy, now: noon, calendar: calendar)
        let repeated = DisplayFingerprint.compute(sessions: [decaying], attentionStates: attention, activeSnoozeIDs: [], policy: policy, now: noon, calendar: calendar)
        try expect(first == repeated, "Same inputs at the same instant must produce a stable fingerprint")

        let crossedActiveWindow = DisplayFingerprint.compute(
            sessions: [decaying],
            attentionStates: attention,
            activeSnoozeIDs: [],
            policy: policy,
            now: noon.addingTimeInterval(2 * 60),
            calendar: calendar
        )
        try expect(first != crossedActiveWindow, "Crossing the 15-minute active window must change the fingerprint")

        let unreadOvernight = makeSession(
            status: .completed,
            fingerprint: "fp-night",
            startedAt: noon,
            completedAt: noon.addingTimeInterval(60),
            sessionID: "night"
        )
        let unreadAttention: [String: AttentionState] = [unreadOvernight.id: .unread]
        let night = try unwrap(
            calendar.date(from: DateComponents(year: 2026, month: 7, day: 20, hour: 23, minute: 59)),
            "Night date must be constructible"
        )
        let beforeMidnight = DisplayFingerprint.compute(sessions: [unreadOvernight], attentionStates: unreadAttention, activeSnoozeIDs: [], policy: policy, now: night, calendar: calendar)
        let afterMidnight = DisplayFingerprint.compute(sessions: [unreadOvernight], attentionStates: unreadAttention, activeSnoozeIDs: [], policy: policy, now: night.addingTimeInterval(2 * 60), calendar: calendar)
        try expect(beforeMidnight != afterMidnight, "Crossing midnight must change the fingerprint even for stable buckets")
    }),
    ("Codex derives content titles when the database keeps raw first messages", {
        try withTempDirectory { root in
            let databaseURL = root.appendingPathComponent("state.sqlite")
            try runSQLite(
                at: databaseURL,
                sql: """
                CREATE TABLE threads (
                    id TEXT PRIMARY KEY,
                    title TEXT NOT NULL,
                    archived INTEGER NOT NULL DEFAULT 0,
                    name TEXT,
                    first_user_message TEXT NOT NULL DEFAULT ''
                );
                INSERT INTO threads VALUES ('raw-1','/goal /tmp/x 帮我把日报重构一遍 谢谢',0,NULL,'/goal /tmp/x 帮我把日报重构一遍 谢谢');
                INSERT INTO threads VALUES ('named-1','原始消息一',0,'手动改名','原始消息一');
                INSERT INTO threads VALUES ('curated-1','精炼标题',0,NULL,'原始消息二');
                """
            )
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)],
                ofItemAtPath: databaseURL.path
            )
            for id in ["raw-1", "named-1", "curated-1"] {
                try writeLines([
                    ["type": "session_meta", "timestamp": "2026-07-15T00:00:00.000Z", "payload": ["id": id, "cwd": "/tmp/project"]],
                    ["type": "event_msg", "timestamp": "2026-07-15T00:00:01.000Z", "payload": ["type": "task_started", "turn_id": "turn-\(id)"]],
                    ["type": "event_msg", "timestamp": "2026-07-15T00:00:02.000Z", "payload": ["type": "task_complete", "turn_id": "turn-\(id)"]]
                ], to: root.appendingPathComponent("rollout-\(id).jsonl"))
            }

            let adapter = CodexAdapter(
                root: root,
                databaseURL: databaseURL,
                maxAge: 100 * 365 * 24 * 60 * 60,
                maxFiles: 10
            )
            let titles = Dictionary(uniqueKeysWithValues: adapter.scan().sessions.map { ($0.sessionID, $0.title) })
            try expect(titles["raw-1"] == "帮我把日报重构一遍 谢谢", "Raw first-message title must drop slash tokens, got \(titles["raw-1"] ?? "nil")")
            try expect(titles["named-1"] == "手动改名", "Manual rename in the name column must win, got \(titles["named-1"] ?? "nil")")
            try expect(titles["curated-1"] == "精炼标题", "A curated title differing from the first message must be used, got \(titles["curated-1"] ?? "nil")")

            try runSQLite(at: databaseURL, sql: "UPDATE threads SET name='改名二' WHERE id='named-1';")
            let renamed = Dictionary(uniqueKeysWithValues: adapter.scan().sessions.map { ($0.sessionID, $0.title) })
            try expect(renamed["named-1"] == "改名二", "A later rename must flow into the snapshot, got \(renamed["named-1"] ?? "nil")")
        }
    }),
    ("Codex exec automations get distinguishable titles", {
        try withTempDirectory { root in
            let databaseURL = root.appendingPathComponent("state.sqlite")
            try runSQLite(
                at: databaseURL,
                sql: """
                CREATE TABLE threads (
                    id TEXT PRIMARY KEY,
                    title TEXT NOT NULL,
                    archived INTEGER NOT NULL DEFAULT 0,
                    name TEXT,
                    first_user_message TEXT NOT NULL DEFAULT ''
                );
                INSERT INTO threads VALUES ('exec-1','你是每日卫生巡检员，检查文件归档情况',0,NULL,'你是每日卫生巡检员，检查文件归档情况');
                """
            )
            try writeLines([
                ["type": "session_meta", "timestamp": "2026-07-15T00:00:00.000Z", "payload": ["id": "exec-1", "cwd": "/tmp/feishu-team-mgmt", "originator": "codex_exec"]],
                ["type": "event_msg", "timestamp": "2026-07-15T00:00:01.000Z", "payload": ["type": "task_started", "turn_id": "turn-1"]],
                ["type": "event_msg", "timestamp": "2026-07-15T00:00:02.000Z", "payload": ["type": "task_complete", "turn_id": "turn-1"]]
            ], to: root.appendingPathComponent("rollout-exec.jsonl"))

            let session = try unwrap(
                CodexAdapter(root: root, databaseURL: databaseURL, maxAge: 100 * 365 * 24 * 60 * 60, maxFiles: 10)
                    .scan().sessions.first,
                "Exec session missing"
            )
            try expect(session.origin == .externalRuntime, "codex_exec must classify as externalRuntime")
            try expect(session.title.hasPrefix("Codex 后台 · "), "Exec title must keep the backstage prefix, got \(session.title)")
            try expect(session.title.contains("巡检"), "Exec title must carry content instead of only the project name, got \(session.title)")
        }
    }),
    ("Codex cache stops reparsing stable threads with database records", {
        try withTempDirectory { root in
            let databaseURL = root.appendingPathComponent("state.sqlite")
            try runSQLite(
                at: databaseURL,
                sql: """
                CREATE TABLE threads (
                    id TEXT PRIMARY KEY,
                    title TEXT NOT NULL,
                    archived INTEGER NOT NULL DEFAULT 0,
                    name TEXT,
                    first_user_message TEXT NOT NULL DEFAULT ''
                );
                INSERT INTO threads VALUES ('sub-1','子任务原始消息',0,NULL,'子任务原始消息');
                """
            )
            try writeLines([
                ["type": "session_meta", "timestamp": "2026-07-15T00:00:00.000Z", "payload": ["id": "sub-1", "cwd": "/tmp/project", "parent_thread_id": "parent-1"]],
                ["type": "event_msg", "timestamp": "2026-07-15T00:00:01.000Z", "payload": ["type": "task_started", "turn_id": "turn-1"]],
                ["type": "event_msg", "timestamp": "2026-07-15T00:00:02.000Z", "payload": ["type": "task_complete", "turn_id": "turn-1"]]
            ], to: root.appendingPathComponent("rollout-sub.jsonl"))

            let adapter = CodexAdapter(root: root, databaseURL: databaseURL, maxAge: 100 * 365 * 24 * 60 * 60, maxFiles: 10)
            let first = adapter.scan().sessions.first
            try expect(first?.origin == .subagent, "Fixture must classify as subagent")
            let parsesAfterFirstScan = adapter.parsedRolloutCount
            _ = adapter.scan()
            _ = adapter.scan()
            try expect(
                adapter.parsedRolloutCount == parsesAfterFirstScan,
                "Stable thread with an unchanged database record must hit the cache, parses went \(parsesAfterFirstScan) -> \(adapter.parsedRolloutCount)"
            )
        }
    }),
    ("Codex prefers display names from the session index", {
        try withTempDirectory { root in
            let databaseURL = root.appendingPathComponent("state.sqlite")
            try runSQLite(
                at: databaseURL,
                sql: """
                CREATE TABLE threads (
                    id TEXT PRIMARY KEY,
                    title TEXT NOT NULL,
                    archived INTEGER NOT NULL DEFAULT 0,
                    name TEXT,
                    first_user_message TEXT NOT NULL DEFAULT ''
                );
                INSERT INTO threads VALUES ('goal-1','/goal /tmp/x 帮我把监控浮窗做出来',0,NULL,'/goal /tmp/x 帮我把监控浮窗做出来');
                INSERT INTO threads VALUES ('plain-1','/goal /tmp/y 整理日报数据 谢谢',0,NULL,'/goal /tmp/y 整理日报数据 谢谢');
                """
            )
            try writeLines([
                ["id": "goal-1", "thread_name": "/goal /tmp/x 帮我把监控…", "updated_at": "2026-07-15T00:00:00.000000Z"],
                ["id": "plain-1", "thread_name": "/goal /tmp/y 整理日报…", "updated_at": "2026-07-15T00:00:01.000000Z"],
                ["id": "goal-1", "thread_name": "剑令App开发", "updated_at": "2026-07-19T00:00:00.000000Z"]
            ], to: root.appendingPathComponent("session_index.jsonl"))
            for id in ["goal-1", "plain-1"] {
                try writeLines([
                    ["type": "session_meta", "timestamp": "2026-07-15T00:00:00.000Z", "payload": ["id": id, "cwd": "/tmp/project"]],
                    ["type": "event_msg", "timestamp": "2026-07-15T00:00:01.000Z", "payload": ["type": "task_started", "turn_id": "turn-\(id)"]],
                    ["type": "event_msg", "timestamp": "2026-07-15T00:00:02.000Z", "payload": ["type": "task_complete", "turn_id": "turn-\(id)"]]
                ], to: root.appendingPathComponent("rollout-\(id).jsonl"))
            }

            let adapter = CodexAdapter(
                root: root,
                databaseURL: databaseURL,
                maxAge: 100 * 365 * 24 * 60 * 60,
                maxFiles: 10
            )
            let titles = Dictionary(uniqueKeysWithValues: adapter.scan().sessions.map { ($0.sessionID, $0.title) })
            try expect(titles["goal-1"] == "剑令App开发", "The latest session-index name must win, got \(titles["goal-1"] ?? "nil")")
            try expect(titles["plain-1"] == "整理日报数据 谢谢", "A truncated raw-message index entry must not count as curated, got \(titles["plain-1"] ?? "nil")")
        }
    }),
    ("Codex session index rename flows into snapshots", {
        try withTempDirectory { root in
            let databaseURL = root.appendingPathComponent("state.sqlite")
            try runSQLite(
                at: databaseURL,
                sql: """
                CREATE TABLE threads (
                    id TEXT PRIMARY KEY,
                    title TEXT NOT NULL,
                    archived INTEGER NOT NULL DEFAULT 0,
                    name TEXT,
                    first_user_message TEXT NOT NULL DEFAULT ''
                );
                INSERT INTO threads VALUES ('rename-idx','原始消息内容',0,NULL,'原始消息内容');
                """
            )
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)],
                ofItemAtPath: databaseURL.path
            )
            try writeLines([
                ["type": "session_meta", "timestamp": "2026-07-15T00:00:00.000Z", "payload": ["id": "rename-idx", "cwd": "/tmp/project"]],
                ["type": "event_msg", "timestamp": "2026-07-15T00:00:01.000Z", "payload": ["type": "task_started", "turn_id": "turn-1"]],
                ["type": "event_msg", "timestamp": "2026-07-15T00:00:02.000Z", "payload": ["type": "task_complete", "turn_id": "turn-1"]]
            ], to: root.appendingPathComponent("rollout-rename-idx.jsonl"))

            try writeLines(
                [["id": "rename-idx", "thread_name": "原始消息内容", "updated_at": "2026-07-15T00:00:00.000000Z"]],
                to: root.appendingPathComponent("session_index.jsonl")
            )

            let adapter = CodexAdapter(
                root: root,
                databaseURL: databaseURL,
                maxAge: 100 * 365 * 24 * 60 * 60,
                maxFiles: 10
            )
            try expect(adapter.scan().sessions.first?.title == "原始消息内容", "Initial title should come from synthesis, got \(adapter.scan().sessions.first?.title ?? "nil")")

            try appendLines(
                [["id": "rename-idx", "thread_name": "改名后的标题", "updated_at": "2026-07-19T00:00:00.000000Z"]],
                to: root.appendingPathComponent("session_index.jsonl")
            )
            let refreshed = adapter.scan().sessions.first
            try expect(refreshed?.title == "改名后的标题", "An appended session-index rename must flow into the snapshot, got \(refreshed?.title ?? "nil")")
        }
    }),
    ("Claude desktop index promotes sidebar sessions to interactive", {
        try withTempDirectory { temp in
            let root = temp.appendingPathComponent("projects")
            let desktop = temp.appendingPathComponent("desktop/org/proj")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: desktop, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: [
                "sessionId": "local_x", "cliSessionId": "ui-1", "title": "标题来自桌面", "isArchived": false
            ]).write(to: desktop.appendingPathComponent("local_x.json"))
            try JSONSerialization.data(withJSONObject: [
                "sessionId": "local_y", "cliSessionId": "arch-1", "title": "已归档", "isArchived": true
            ]).write(to: desktop.appendingPathComponent("local_y.json"))
            for id in ["ui-1", "arch-1", "headless-1"] {
                try writeLines([
                    ["type": "user", "uuid": "u-\(id)", "timestamp": "2026-07-15T01:00:00.000Z", "cwd": "/tmp/proj"],
                    ["type": "assistant", "uuid": "a-\(id)", "timestamp": "2026-07-15T01:01:00.000Z", "cwd": "/tmp/proj", "message": ["stop_reason": "end_turn", "id": "m-\(id)"]]
                ], to: root.appendingPathComponent("\(id).jsonl"))
            }

            let adapter = ClaudeCodeAdapter(
                root: root,
                craftRoot: nil,
                desktopSessionsRoot: temp.appendingPathComponent("desktop"),
                maxAge: 100 * 365 * 24 * 60 * 60,
                maxFiles: 10
            )
            let byID = Dictionary(uniqueKeysWithValues: adapter.scan().sessions.map { ($0.sessionID, $0) })
            try expect(byID["ui-1"]?.origin == .interactive, "Sidebar session must be interactive, got \(String(describing: byID["ui-1"]?.origin))")
            try expect(byID["ui-1"]?.isHostVisible == true, "Sidebar session must be host visible")
            try expect(byID["ui-1"]?.title == "标题来自桌面", "Desktop title must win, got \(byID["ui-1"]?.title ?? "nil")")
            try expect(byID["arch-1"]?.origin == .detached, "Archived sidebar session must be detached, got \(String(describing: byID["arch-1"]?.origin))")
            try expect(byID["headless-1"]?.origin == .externalRuntime, "Unmapped transcript must stay a runtime, got \(String(describing: byID["headless-1"]?.origin))")
        }
    }),
    ("Claude desktop index lets the live record beat an archived import", {
        try withTempDirectory { temp in
            let root = temp.appendingPathComponent("projects")
            let desktop = temp.appendingPathComponent("desktop/org/proj")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: desktop, withIntermediateDirectories: true)
            // claude://resume import residue: archived, untitled, named after the CLI id.
            try JSONSerialization.data(withJSONObject: [
                "sessionId": "local_dup-1", "cliSessionId": "dup-1", "isArchived": true,
                "lastFocusedAt": 1_784_900_000_000.0
            ]).write(to: desktop.appendingPathComponent("local_dup-1.json"))
            // The conversation the user actually drives.
            try JSONSerialization.data(withJSONObject: [
                "sessionId": "local_native", "cliSessionId": "dup-1", "title": "剑令", "isArchived": false,
                "lastFocusedAt": 1_784_945_000_000.0
            ]).write(to: desktop.appendingPathComponent("local_native.json"))
            // Two live windows over one CLI id: the most recently focused wins.
            try JSONSerialization.data(withJSONObject: [
                "sessionId": "local_stale", "cliSessionId": "twin-1", "title": "旧窗", "isArchived": false,
                "lastFocusedAt": 1_784_000_000_000.0
            ]).write(to: desktop.appendingPathComponent("local_stale.json"))
            try JSONSerialization.data(withJSONObject: [
                "sessionId": "local_fresh", "cliSessionId": "twin-1", "title": "新窗", "isArchived": false,
                "lastFocusedAt": 1_784_945_000_000.0
            ]).write(to: desktop.appendingPathComponent("local_fresh.json"))
            for id in ["dup-1", "twin-1"] {
                try writeLines([
                    ["type": "user", "uuid": "u-\(id)", "timestamp": "2026-07-15T01:00:00.000Z", "cwd": "/tmp/proj"],
                    ["type": "assistant", "uuid": "a-\(id)", "timestamp": "2026-07-15T01:01:00.000Z", "cwd": "/tmp/proj", "message": ["stop_reason": "end_turn", "id": "m-\(id)"]]
                ], to: root.appendingPathComponent("\(id).jsonl"))
            }
            let adapter = ClaudeCodeAdapter(
                root: root,
                craftRoot: nil,
                desktopSessionsRoot: temp.appendingPathComponent("desktop"),
                maxAge: 100 * 365 * 24 * 60 * 60,
                maxFiles: 10
            )
            let byID = Dictionary(uniqueKeysWithValues: adapter.scan().sessions.map { ($0.sessionID, $0) })
            try expect(byID["dup-1"]?.origin == .interactive, "The live sidebar record must beat the archived import, got \(String(describing: byID["dup-1"]?.origin))")
            try expect(byID["dup-1"]?.title == "剑令", "The live record's title must win, got \(byID["dup-1"]?.title ?? "nil")")
            try expect(byID["twin-1"]?.title == "新窗", "With two live records the most recently focused must win, got \(byID["twin-1"]?.title ?? "nil")")
        }
    }),
    ("Claude tool-heavy tail window still counts as running", {
        try withTempDirectory { temp in
            let root = temp.appendingPathComponent("projects")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            // One giant tool result pushes the human message and any end_turn
            // past the 192KB tail window the adapter reads.
            let bulk = String(repeating: "x", count: 250 * 1024)
            try writeLines([
                ["type": "user", "uuid": "u-1", "timestamp": "2026-07-25T01:00:00.000Z", "cwd": "/tmp/proj", "message": ["content": "开始干活"]],
                ["type": "assistant", "uuid": "a-1", "timestamp": "2026-07-25T01:00:05.000Z", "cwd": "/tmp/proj", "message": ["stop_reason": "tool_use", "id": "m-1"]],
                ["type": "user", "uuid": "u-2", "timestamp": "2026-07-25T01:00:10.000Z", "cwd": "/tmp/proj", "toolUseResult": ["ok": true], "message": ["content": [["type": "tool_result", "content": bulk]]]],
                ["type": "assistant", "uuid": "a-2", "timestamp": "2026-07-25T01:00:15.000Z", "cwd": "/tmp/proj", "message": ["stop_reason": "tool_use", "id": "m-2"]]
            ], to: root.appendingPathComponent("busy-1.jsonl"))
            let adapter = ClaudeCodeAdapter(
                root: root,
                craftRoot: nil,
                desktopSessionsRoot: temp.appendingPathComponent("desktop"),
                maxAge: 100 * 365 * 24 * 60 * 60,
                maxFiles: 10
            )
            let session = adapter.scan().sessions.first { $0.sessionID == "busy-1" }
            try expect(session?.status == .running, "Pure tool traffic in the tail window means the turn is in flight, got \(String(describing: session?.status))")
            try expect(session?.completionFingerprint == nil, "No completion may be minted from a truncated window")
        }
    }),
    ("Inbox surface chrome keeps compact panels lean", {
        let menu = SurfaceChromePolicy(surface: .menu)
        let floating = SurfaceChromePolicy(surface: .floating)
        let notch = SurfaceChromePolicy(surface: .notchExpanded)
        let edge = SurfaceChromePolicy(surface: .edgeExpanded)
        try expect(menu.showsHeader && menu.showsSummary && menu.showsEnergy && menu.showsFooter, "Menu must retain all chrome")
        try expect(floating.showsEnergy, "Floating mode must retain the energy belt")
        try expect(!notch.showsEnergy, "The top host keeps quota in its capsule and leaves the expanded inbox lean")
        try expect(notch.showsHeader && notch.showsSummary && notch.showsFooter, "Notch mode must retain essential chrome")
        try expect(edge.showsHeader && edge.showsSummary && edge.showsFooter, "Edge mode must retain essential chrome")
        try expect(edge.showsEnergy, "The edge panel must carry the energy belt too")
        try expect(
            // 5 items keeps the total clear of both the 380 floor and the 630
            // ceiling, so the belt's own height is what is actually measured.
            PresentationLayout.edgePanelHeight(itemCount: 5, groupCount: 0, isEmpty: false, showsEnergy: true)
                - PresentationLayout.edgePanelHeight(itemCount: 5, groupCount: 0, isEmpty: false, showsEnergy: false)
                == PresentationLayout.energyBeltHeight,
            "Turning the belt on must reserve exactly its own height, or the panel clips its footer"
        )
        try expect(PresentationLayout.edgeTagVisualWidth == 30, "The visible edge tag width is part of the product contract")
        try expect(
            PresentationLayout.edgeTagHitWidth >= PresentationLayout.edgeTagVisualWidth + 20,
            "The hit region must stay comfortably wider than the visible tag"
        )
        try expect(PresentationLayout.edgeTagHitWidth >= 44, "The edge tag hit target must remain accessible")
    }),
    ("Edge hover waits before expand and collapse", {
        let base = Date(timeIntervalSince1970: 1_784_700_000)
        let hover = EdgeHoverStateMachine(now: base)
        let delay = hover.expandDelay
        // The contract is relative to the configured delay, not a hard-coded
        // millisecond value, so tuning the reveal speed does not require
        // rewriting the guarantee it has to keep.
        try expect(delay >= 0.1 && delay <= 0.25, "The reveal delay must stay in the deliberate-hover band, got \(delay)")
        _ = hover.send(.entryEntered, at: base)
        try expect(!hover.advance(to: base.addingTimeInterval(delay - 0.01)).isExpanded, "A pass shorter than the delay must not expand")
        try expect(hover.advance(to: base.addingTimeInterval(delay + 0.01)).isExpanded, "A deliberate hover must expand once the delay elapses")
        let exitedAt = delay + 0.02
        _ = hover.send(.entryExited, at: base.addingTimeInterval(exitedAt))
        let grace = hover.collapseDelay
        try expect(hover.advance(to: base.addingTimeInterval(exitedAt + grace - 0.01)).isExpanded, "Collapse must wait for its grace period")
        try expect(!hover.advance(to: base.addingTimeInterval(exitedAt + grace + 0.01)).isExpanded, "The panel must collapse once the grace period elapses")
    }),
    ("Edge hover treats entry and panel as one hot region", {
        let base = Date(timeIntervalSince1970: 1_784_700_000)
        let hover = EdgeHoverStateMachine(now: base)
        _ = hover.send(.entryEntered, at: base)
        for step in 1...3 {
            _ = hover.send(.pointerValidation(isInsideHotRegion: true), at: base.addingTimeInterval(Double(step) * 0.1))
        }
        _ = hover.advance(to: base.addingTimeInterval(0.3))
        _ = hover.send(.entryExited, at: base.addingTimeInterval(0.31))
        for step in 4...8 {
            _ = hover.send(.pointerValidation(isInsideHotRegion: true), at: base.addingTimeInterval(Double(step) * 0.1))
        }
        try expect(hover.advance(to: base.addingTimeInterval(1.2)).isExpanded, "A production validation sequence inside the panel must cancel collapse")
    }),
    ("Edge hover pauses collapse while a menu is open", {
        let base = Date(timeIntervalSince1970: 1_784_700_000)
        let hover = EdgeHoverStateMachine(now: base)
        _ = hover.send(.entryClicked, at: base)
        _ = hover.send(.entryExited, at: base.addingTimeInterval(0.1))
        _ = hover.send(.menuOpened, at: base.addingTimeInterval(0.2))
        try expect(hover.advance(to: base.addingTimeInterval(2)).isExpanded, "An open snooze menu must hold the panel")
        _ = hover.send(.menuClosed, at: base.addingTimeInterval(2.1))
        try expect(!hover.advance(to: base.addingTimeInterval(2.73)).isExpanded, "Closing the menu outside must re-arm collapse")
    }),
    ("Click collapse disarms hover until the pointer leaves", {
        let base = Date(timeIntervalSince1970: 1_784_700_000)
        let hover = EdgeHoverStateMachine(now: base)
        _ = hover.send(.entryEntered, at: base)
        _ = hover.advance(to: base.addingTimeInterval(0.3))
        let collapsed = hover.send(.entryClicked, at: base.addingTimeInterval(0.31))
        try expect(!collapsed.isExpanded && !collapsed.isHoverArmed, "Click collapse must disarm hover")
        try expect(!hover.advance(to: base.addingTimeInterval(1)).isExpanded, "The stationary pointer must not reopen the panel")
        let left = hover.send(.pointerValidation(isInsideHotRegion: false), at: base.addingTimeInterval(1.1))
        try expect(left.isHoverArmed, "Leaving once must re-arm hover")
        _ = hover.send(.entryEntered, at: base.addingTimeInterval(1.2))
        try expect(hover.advance(to: base.addingTimeInterval(1.43)).isExpanded, "A later deliberate hover may expand again")
    }),
    ("Pointer validation recovers a lost exit event", {
        let base = Date(timeIntervalSince1970: 1_784_700_000)
        let hover = EdgeHoverStateMachine(now: base)
        _ = hover.send(.entryClicked, at: base)
        _ = hover.send(.pointerValidation(isInsideHotRegion: false), at: base.addingTimeInterval(0.1))
        try expect(!hover.advance(to: base.addingTimeInterval(0.73)).isExpanded, "Position validation must collapse a panel whose exit event was lost")
    }),
    ("Pinned edge panel resists automatic and content collapse", {
        let base = Date(timeIntervalSince1970: 1_784_700_000)
        let hover = EdgeHoverStateMachine(now: base)
        _ = hover.send(.pinChanged(true), at: base)
        _ = hover.send(.pointerValidation(isInsideHotRegion: false), at: base.addingTimeInterval(0.1))
        _ = hover.send(.contentActivated, at: base.addingTimeInterval(0.2))
        try expect(hover.advance(to: base.addingTimeInterval(2)).isExpanded, "Pinned mode must stay expanded")
        _ = hover.send(.pinChanged(false), at: base.addingTimeInterval(2.1))
        try expect(!hover.advance(to: base.addingTimeInterval(2.73)).isExpanded, "Unpinning outside must resume normal collapse")
    }),
    ("Presentation router honors launch reopen and status menu", {
        let router = PresentationRouter()
        for trigger in [PresentationTrigger.launch, .dockReopen, .statusMenuShow] {
            let floating = router.route(mode: .floating, trigger: trigger)
            let notch = router.route(mode: .notch, trigger: trigger)
            let edge = router.route(mode: .rightEdge, trigger: trigger)
            try expect(floating.present == .floating, "Floating mode must present floating for \(trigger)")
            try expect(notch.present == .notch, "Notch mode must present the top host for \(trigger)")
            try expect(edge.present == .rightEdge, "Edge mode must present the edge host for \(trigger)")
            try expect(edge.destroy == [.floating, .notch], "Only the selected host may remain active")
        }
    }),
    ("Presentation router switches by destroying the old host", {
        let router = PresentationRouter()
        let switched = router.route(mode: .rightEdge, trigger: .modeChanged(from: .floating, to: .rightEdge))
        try expect(switched.present == .rightEdge, "Switch must present the new host")
        try expect(switched.destroy == [.floating, .notch], "Switch must destroy every inactive host")
        let fallback = router.route(mode: .rightEdge, trigger: .hostCreationFailed(.rightEdge))
        try expect(fallback.present == .floating && fallback.persistedMode == .floating && fallback.didFallback, "Creation failure must recover to floating")
        let notch = router.route(mode: .notch, trigger: .launch)
        try expect(notch.present == .notch && notch.persistedMode == .notch && !notch.didFallback, "Notch mode is a supported first-class host")
    }),
    ("Edge placement falls back to main screen and clamps ratio", {
        let main = EdgeScreenDescriptor(
            id: "main",
            frame: EdgeRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: EdgeRect(x: 0, y: 0, width: 1512, height: 950),
            isMain: true
        )
        let resolver = EdgePlacementResolver(now: Date(timeIntervalSince1970: 0))
        let placement = try unwrap(resolver.resolve(
            screens: [main],
            preference: EdgePlacementPreference(screenID: "unplugged", verticalRatio: 2),
            size: (44, 68)
        ), "A valid main screen must produce a placement")
        try expect(placement.screenID == "main" && placement.fellBackToMainScreen, "An unplugged display must fall back to main")
        try expect(placement.frame.maxX == main.visibleFrame.maxX, "The hit frame must hug the visible right edge")
        try expect(placement.verticalRatio == 1, "Stored ratios must clamp to the safe range")
        try expect(placement.frame.maxY <= 700.001, "The default notification exclusion must be respected")
        let expanded = try unwrap(resolver.resolve(
            screens: [main],
            preference: EdgePlacementPreference(screenID: "main", verticalRatio: 0.5),
            size: (372, 630)
        ), "Expanded panel must resolve on a short screen")
        try expect(expanded.frame.height == 600, "An expanded panel must shrink to the safe visible height")
        try expect(expanded.frame.minY >= 100 && expanded.frame.maxY <= 700, "The expanded frame must avoid both system exclusion zones")
    }),
    ("Edge placement never vanishes when every screen is flagged invalid", {
        // Regression: the AppKit layer once derived isValid from
        // CGDisplayUnitNumber != 0, which flags the built-in panel (unit 0)
        // invalid. Every screen was filtered out, resolve returned nil, and
        // the edge host failed to create on every attempt.
        let builtIn = EdgeScreenDescriptor(
            id: "built-in",
            frame: EdgeRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: EdgeRect(x: 0, y: 0, width: 1512, height: 944),
            isMain: true,
            isValid: false
        )
        let resolver = EdgePlacementResolver(now: Date(timeIntervalSince1970: 0))
        let placement = try unwrap(resolver.resolve(
            screens: [builtIn],
            preference: EdgePlacementPreference(screenID: nil, verticalRatio: 0.5),
            size: (44, 68)
        ), "A drawable screen must still place the tag even when flagged invalid")
        try expect(placement.screenID == "built-in", "The only drawable screen must be chosen")
        let ghost = EdgeScreenDescriptor(
            id: "ghost",
            frame: EdgeRect(x: 0, y: 0, width: 1, height: 1),
            visibleFrame: EdgeRect(x: 0, y: 0, width: 1512, height: 944),
            isMain: false,
            isValid: false
        )
        let real = EdgeScreenDescriptor(
            id: "real",
            frame: EdgeRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: EdgeRect(x: 0, y: 0, width: 1512, height: 944),
            isMain: true,
            isValid: true
        )
        let mixed = try unwrap(resolver.resolve(
            screens: [ghost, real],
            preference: EdgePlacementPreference(screenID: nil, verticalRatio: 0.5),
            size: (44, 68)
        ), "A mixed set must resolve")
        try expect(mixed.screenID == "real", "When any screen is valid, ghosts must still be filtered out")
    }),
    ("Edge placement survives resolution changes and a right Dock", {
        let screen = EdgeScreenDescriptor(
            id: "external",
            frame: EdgeRect(x: 1512, y: 0, width: 1920, height: 1080),
            visibleFrame: EdgeRect(x: 1512, y: 0, width: 1840, height: 1055),
            isMain: false
        )
        let resolver = EdgePlacementResolver(now: Date(timeIntervalSince1970: 0))
        let placement = try unwrap(resolver.resolve(
            screens: [screen],
            preference: EdgePlacementPreference(screenID: "external", verticalRatio: 0.5),
            size: (372, 630),
            exclusions: EdgePlacementExclusions(top: 0, bottom: 0)
        ), "External screen must resolve")
        try expect(placement.dockConflict, "A visible frame narrowed on the right indicates a Dock conflict")
        try expect(placement.frame.maxX == screen.visibleFrame.maxX, "The panel must remain outside the Dock")
        let ratio = resolver.verticalRatio(forY: -999, screen: screen, height: 68)
        try expect(ratio == 0, "Dragged positions below the safe area must clamp")
    }),
    ("Edge screen changes debounce and ignore ghost displays", {
        let base = Date(timeIntervalSince1970: 1_784_700_000)
        let resolver = EdgePlacementResolver(initialScreenIDs: ["main"], displayChangeDebounce: 0.35, now: base)
        let main = EdgeScreenDescriptor(id: "main", frame: EdgeRect(x: 0, y: 0, width: 1, height: 1), visibleFrame: EdgeRect(x: 0, y: 0, width: 1, height: 1), isMain: true)
        let ghost = EdgeScreenDescriptor(id: "ghost", frame: EdgeRect(x: 0, y: 0, width: 0, height: 0), visibleFrame: EdgeRect(x: 0, y: 0, width: 0, height: 0), isMain: false, isValid: false)
        resolver.noteScreenChange([main, ghost], at: base)
        try expect(!resolver.takeScreenChangeDue(at: base.addingTimeInterval(1)), "A ghost-only notification must not trigger layout")
        let external = EdgeScreenDescriptor(id: "external", frame: EdgeRect(x: 0, y: 0, width: 1, height: 1), visibleFrame: EdgeRect(x: 0, y: 0, width: 1, height: 1), isMain: false)
        resolver.noteScreenChange([main, external], at: base.addingTimeInterval(2))
        try expect(!resolver.takeScreenChangeDue(at: base.addingTimeInterval(2.34)), "Display changes must debounce")
        try expect(resolver.takeScreenChangeDue(at: base.addingTimeInterval(2.36)), "A stable UUID set must eventually trigger one recompute")
        try expect(!resolver.takeScreenChangeDue(at: base.addingTimeInterval(3)), "Taking the change must clear it")
    }),
    ("Scan scheduler batches a burst into one due set", {
        let base = Date(timeIntervalSince1970: 1_784_700_000)
        let scheduler = ScanScheduler(adapterCount: 5, debounce: 0.5, minAdapterInterval: 2, reconcileInterval: 90, now: base)

        try expect(scheduler.nextDueDelay(at: base) == nil, "A clean scheduler has nothing due")
        scheduler.markDirty(1, at: base)
        scheduler.markDirty(1, at: base.addingTimeInterval(0.1))
        scheduler.markDirty(1, at: base.addingTimeInterval(0.2))
        try expect(scheduler.takeDue(at: base.addingTimeInterval(0.3)).isEmpty, "Debounce window must hold the burst")
        let due = scheduler.takeDue(at: base.addingTimeInterval(0.6))
        try expect(due == [1], "The whole burst must collapse into one due adapter, got \(due)")
        try expect(scheduler.takeDue(at: base.addingTimeInterval(0.7)).isEmpty, "Taking due must clear the dirty mark")
        try expect(scheduler.nextDueDelay(at: base.addingTimeInterval(0.7)) == nil, "Nothing pending after the take")
    }),
    ("Scan scheduler enforces per-adapter minimum interval", {
        let base = Date(timeIntervalSince1970: 1_784_700_000)
        let scheduler = ScanScheduler(adapterCount: 5, debounce: 0.5, minAdapterInterval: 2, reconcileInterval: 90, now: base)

        scheduler.markDirty(0, at: base)
        try expect(scheduler.takeDue(at: base.addingTimeInterval(0.6)) == [0], "First take should fire after debounce")
        scheduler.markDirty(0, at: base.addingTimeInterval(0.7))
        try expect(scheduler.takeDue(at: base.addingTimeInterval(1.3)).isEmpty, "Storm must respect the per-adapter minimum interval")
        let delay = try unwrap(scheduler.nextDueDelay(at: base.addingTimeInterval(1.3)), "A dirty adapter must expose its next due time")
        try expect(abs(delay - 1.3) < 0.01, "Next due should wait for the minimum interval, got \(delay)")
        try expect(scheduler.takeDue(at: base.addingTimeInterval(2.7)) == [0], "Adapter must fire once the interval has passed")
    }),
    ("Scan scheduler tracks adapters independently", {
        let base = Date(timeIntervalSince1970: 1_784_700_000)
        let scheduler = ScanScheduler(adapterCount: 5, debounce: 0.5, minAdapterInterval: 2, reconcileInterval: 90, now: base)

        scheduler.markDirty(0, at: base)
        scheduler.markDirty(2, at: base.addingTimeInterval(0.4))
        try expect(scheduler.takeDue(at: base.addingTimeInterval(0.6)) == [0], "Only the first adapter's debounce has elapsed")
        try expect(scheduler.takeDue(at: base.addingTimeInterval(1.0)) == [2], "The second adapter must fire on its own clock")
    }),
    ("Scan scheduler rotates reconcile turns one adapter per tick", {
        let base = Date(timeIntervalSince1970: 1_784_700_000)
        let scheduler = ScanScheduler(adapterCount: 5, debounce: 0.5, minAdapterInterval: 2, reconcileInterval: 90, reconcileTolerance: 0, now: base)
        try expect(abs(scheduler.reconcileTickInterval - 18) < 0.000_1, "Tick interval must split the reconcile interval across adapters, got \(scheduler.reconcileTickInterval)")
        var turns: [Set<Int>] = []
        for tick in 1...10 {
            turns.append(scheduler.takeReconcileDue(at: base.addingTimeInterval(Double(tick) * 18)))
        }
        try expect(
            turns == [[0], [1], [2], [3], [4], [0], [1], [2], [3], [4]],
            "Turns must rotate one adapter per tick and keep each adapter's coverage period, got \(turns)"
        )
    }),
    ("Scan scheduler reconcile cadence survives scan duration", {
        let base = Date(timeIntervalSince1970: 1_784_700_000)
        let scheduler = ScanScheduler(adapterCount: 1, debounce: 0.5, minAdapterInterval: 2, reconcileInterval: 300, reconcileTolerance: 5, now: base)
        try expect(scheduler.takeReconcileDue(at: base.addingTimeInterval(200)).isEmpty, "Reconcile must not fire early")
        try expect(scheduler.takeReconcileDue(at: base.addingTimeInterval(300)) == [0], "Reconcile must fire at its interval")
        // Regression: turns used to be stamped at scan *end*, so a ~1.5 s
        // reconcile scan made the next 300 s timer fire measure only 298.5 s,
        // skip the round, and halve the backstop to an effective 600 s.
        // Hand-out stamping plus the tolerance must keep every fire on cadence.
        try expect(scheduler.takeReconcileDue(at: base.addingTimeInterval(598.5)) == [0], "A fire landing fractionally before the interval must still reconcile")
        try expect(scheduler.takeReconcileDue(at: base.addingTimeInterval(600)).isEmpty, "A taken turn must not repeat within the same interval")
    }),
    ("Scan scheduler full scan re-staggers reconcile turns", {
        let base = Date(timeIntervalSince1970: 1_784_700_000)
        let scheduler = ScanScheduler(adapterCount: 5, debounce: 0.5, minAdapterInterval: 2, reconcileInterval: 90, reconcileTolerance: 0, now: base)
        scheduler.markDirty(3, at: base.addingTimeInterval(10))
        scheduler.noteFullScan(at: base.addingTimeInterval(12))
        try expect(scheduler.nextDueDelay(at: base.addingTimeInterval(12.1)) == nil, "A full scan absorbs pending dirty marks")
        try expect(scheduler.takeReconcileDue(at: base.addingTimeInterval(29)).isEmpty, "No reconcile turn before one tick after full coverage")
        scheduler.markDirty(0, at: base.addingTimeInterval(29.5))
        try expect(scheduler.takeReconcileDue(at: base.addingTimeInterval(30)) == [0], "The rotation must restart one tick after the full scan")
        try expect(scheduler.nextDueDelay(at: base.addingTimeInterval(30)) == nil, "A reconcile turn absorbs the adapter's own dirty mark")
        scheduler.markDirty(0, at: base.addingTimeInterval(30.4))
        try expect(scheduler.takeDue(at: base.addingTimeInterval(31.9)).isEmpty, "A reconcile turn must stamp the per-adapter throttle clock")
        try expect(scheduler.takeDue(at: base.addingTimeInterval(32)) == [0], "The throttled adapter must fire once the minimum interval passes")
        try expect(scheduler.takeReconcileDue(at: base.addingTimeInterval(48)) == [1], "Later adapters keep their staggered turns")
    }),
    ("Edge hover survives continuous production pointer validation", {
        let base = Date(timeIntervalSince1970: 1_784_700_000)
        let hover = EdgeHoverStateMachine(now: base)
        _ = hover.send(.entryEntered, at: base)
        for step in 1...5 {
            let now = base.addingTimeInterval(Double(step) * 0.1)
            _ = hover.send(.pointerValidation(isInsideHotRegion: true), at: now)
        }
        try expect(hover.advance(to: base.addingTimeInterval(0.51)).isExpanded, "Heartbeat validation must not reset the hover deadline")
    }),
    ("Edge hover collapses despite continuous outside validation", {
        let base = Date(timeIntervalSince1970: 1_784_700_000)
        let hover = EdgeHoverStateMachine(now: base)
        _ = hover.send(.entryClicked, at: base)
        for step in 1...6 {
            _ = hover.send(.pointerValidation(isInsideHotRegion: false), at: base.addingTimeInterval(Double(step) * 0.1))
        }
        try expect(!hover.advance(to: base.addingTimeInterval(0.73)).isExpanded, "Repeated outside heartbeat must not postpone the 620ms collapse")
    }),
    ("Pinned edge click remains expanded", {
        let base = Date(timeIntervalSince1970: 1_784_700_000)
        let hover = EdgeHoverStateMachine(now: base)
        _ = hover.send(.pinChanged(true), at: base)
        let clicked = hover.send(.entryClicked, at: base.addingTimeInterval(0.1))
        try expect(clicked.isPinned && clicked.isExpanded, "Clicking a pinned tag must remain expanded")
        try expect(hover.advance(to: base.addingTimeInterval(2)).isExpanded, "Pinned state must not deadlock collapsed")
    }),
    ("Edge hover uses the production tracking sequence", {
        let base = Date(timeIntervalSince1970: 1_784_700_000)
        let hover = EdgeHoverStateMachine(now: base)
        _ = hover.send(.entryEntered, at: base)
        _ = hover.send(.pointerValidation(isInsideHotRegion: true), at: base.addingTimeInterval(0.1))
        _ = hover.send(.pointerValidation(isInsideHotRegion: true), at: base.addingTimeInterval(0.2))
        try expect(hover.advance(to: base.addingTimeInterval(0.23)).isExpanded, "Production heartbeat must expand the panel")
        _ = hover.send(.entryExited, at: base.addingTimeInterval(0.24))
        _ = hover.send(.pointerValidation(isInsideHotRegion: true), at: base.addingTimeInterval(0.3))
        try expect(hover.advance(to: base.addingTimeInterval(0.8)).isExpanded, "Validation inside the expanded panel must cancel collapse")
        _ = hover.send(.pointerValidation(isInsideHotRegion: false), at: base.addingTimeInterval(0.81))
        try expect(!hover.advance(to: base.addingTimeInterval(1.44)).isExpanded, "A validated exit must eventually collapse")
    }),
    ("Edge placement preserves the compact tag anchor", {
        let screen = EdgeScreenDescriptor(id: "main", frame: EdgeRect(x: 0, y: 0, width: 1512, height: 982), visibleFrame: EdgeRect(x: 0, y: 0, width: 1512, height: 944), isMain: true)
        let resolver = EdgePlacementResolver()
        let preference = EdgePlacementPreference(screenID: "main", verticalRatio: 0.37)
        let compact = try unwrap(resolver.resolve(screens: [screen], preference: preference, size: (44, 68)), "Compact placement")
        let roundTripRatio = resolver.verticalRatio(forY: compact.frame.minY, screen: screen, height: compact.frame.height)
        let roundTrip = try unwrap(resolver.resolve(screens: [screen], preference: EdgePlacementPreference(screenID: "main", verticalRatio: roundTripRatio), size: (44, 68)), "Round-trip placement")
        try expect(abs(roundTrip.frame.minY - compact.frame.minY) < 0.01, "Drag write and resolve read must share the same compact interval")
        let expanded = try unwrap(resolver.resolve(screens: [screen], preference: preference, size: (372, 630)), "Expanded placement")
        try expect(expanded.frame.minY >= 100 && expanded.frame.maxY <= 844, "Expanded placement must remain inside the default safe band")
    }),
    ("Edge placement keeps a draggable span on common screens", {
        let screens = [
            EdgeScreenDescriptor(id: "builtin", frame: EdgeRect(x: 0, y: 0, width: 1512, height: 982), visibleFrame: EdgeRect(x: 0, y: 0, width: 1512, height: 944), isMain: true),
            EdgeScreenDescriptor(id: "1440", frame: EdgeRect(x: 0, y: 0, width: 1440, height: 900), visibleFrame: EdgeRect(x: 0, y: 0, width: 1440, height: 900), isMain: false),
            EdgeScreenDescriptor(id: "1280", frame: EdgeRect(x: 0, y: 0, width: 1280, height: 800), visibleFrame: EdgeRect(x: 0, y: 0, width: 1280, height: 800), isMain: false)
        ]
        let resolver = EdgePlacementResolver()
        for screen in screens {
            let low = try unwrap(resolver.resolve(screens: [screen], preference: EdgePlacementPreference(screenID: screen.id, verticalRatio: 0), size: (44, 68)), "Low placement")
            let high = try unwrap(resolver.resolve(screens: [screen], preference: EdgePlacementPreference(screenID: screen.id, verticalRatio: 1), size: (44, 68)), "High placement")
            try expect(high.frame.minY - low.frame.minY > 1, "Side tag must remain draggable on \(screen.id)")
        }
    }),
    ("Edge hover snapshot exposes the polling decision", {
        let base = Date(timeIntervalSince1970: 1_784_700_000)
        let hover = EdgeHoverStateMachine(now: base)
        try expect(!hover.snapshot.shouldPoll, "Idle hover must stop its heartbeat")
        _ = hover.send(.entryEntered, at: base)
        try expect(hover.snapshot.shouldPoll, "Hot-region entry must keep polling")
        _ = hover.send(.entryClicked, at: base.addingTimeInterval(0.1))
        _ = hover.send(.pinChanged(true), at: base.addingTimeInterval(0.2))
        try expect(!hover.snapshot.shouldPoll, "Pinned state must not keep a redundant heartbeat")
    }),
    ("Presentation router falls back when leaving right edge", {
        let router = PresentationRouter()
        let floating = router.route(mode: .floating, trigger: .modeChanged(from: .rightEdge, to: .floating))
        try expect(floating.destroy == [.notch, .rightEdge] && floating.present == .floating, "Leaving edge mode must destroy inactive hosts")
        let notch = router.route(mode: .notch, trigger: .modeChanged(from: .rightEdge, to: .notch))
        try expect(notch.destroy == [.floating, .rightEdge] && notch.present == .notch && !notch.didFallback, "Notch mode must persist and destroy both inactive hosts")
    }),
    ("Edge tag sizes scale together and keep drag round-trips closed", {
        // Every tier must stay a comfortable click target and grow monotonically,
        // otherwise the picker offers sizes that are unusable or indistinguishable.
        var lastWidth = 0.0
        var lastHeight = 0.0
        for size in EdgeTagSize.allCases {
            try expect(size.hitWidth >= 44, "\(size.rawValue) must keep a 44pt hit target, got \(size.hitWidth)")
            try expect(size.hitWidth > size.visualWidth, "The hit region must exceed the visible tag")
            try expect(size.visualWidth > lastWidth, "Sizes must grow monotonically in width")
            try expect(size.baseHeight > lastHeight, "Sizes must grow monotonically in height")
            lastWidth = size.visualWidth
            lastHeight = size.baseHeight
            try expect(size.height(quotaRowCount: 2) > size.height(quotaRowCount: 0), "Quota rows must add height")
            try expect(size.height(quotaRowCount: 5) == size.height(quotaRowCount: 2), "At most two quota rows are shown")
            try expect(size.height(quotaRowCount: -1) == size.baseHeight, "Negative row counts must clamp")
        }
        // The placement round-trip broke once before when the tag height changed;
        // it must hold for every size × quota-row combination.
        let resolver = EdgePlacementResolver(now: Date(timeIntervalSince1970: 0))
        for size in EdgeTagSize.allCases {
            for rows in 0...2 {
                let tagHeight = size.height(quotaRowCount: rows)
                let screen = EdgeScreenDescriptor(
                    id: "s",
                    frame: EdgeRect(x: 0, y: 0, width: 1440, height: 900),
                    visibleFrame: EdgeRect(x: 0, y: 25, width: 1440, height: 845),
                    isMain: true
                )
                func placedY(_ ratio: Double) throws -> Double {
                    try unwrap(resolver.resolve(
                        screens: [screen],
                        preference: EdgePlacementPreference(screenID: "s", verticalRatio: ratio),
                        size: (size.hitWidth, tagHeight),
                        tagHeight: tagHeight
                    ), "Placement must resolve").frame.minY
                }
                let low = try placedY(0)
                let high = try placedY(1)
                try expect(abs(high - low) > 100, "\(size.rawValue)/\(rows) rows must stay draggable, span \(abs(high - low))")
                let target = (low + high) / 2
                let ratio = resolver.verticalRatio(forY: target, screen: screen, height: tagHeight, tagHeight: tagHeight)
                let landed = try placedY(ratio)
                try expect(abs(landed - target) < 1, "\(size.rawValue)/\(rows) rows broke the drag round-trip")
            }
        }
    }),
    ("Opening a session keeps the panel open while the pointer stays on it", {
        // Regression: clicking 阅 handed focus to the agent app and collapsed
        // the panel instantly, even though the cursor was still on it — the
        // user could not act on the next row.
        let base = Date(timeIntervalSince1970: 1_784_700_000)
        let hover = EdgeHoverStateMachine(now: base)
        _ = hover.send(.entryEntered, at: base)
        var t = 0.0
        while t < 0.4 {
            t += 1.0 / 60
            _ = hover.send(.pointerValidation(isInsideHotRegion: true), at: base.addingTimeInterval(t))
            _ = hover.advance(to: base.addingTimeInterval(t))
        }
        try expect(hover.snapshot.isExpanded, "Precondition: the panel is open")
        let afterOpen = hover.send(.contentActivated, at: base.addingTimeInterval(t))
        try expect(afterOpen.isExpanded, "Opening a session must not collapse the panel under the cursor")
        try expect(afterOpen.isHoverArmed, "The panel must stay armed so hovering keeps working")
        // Still open a second later while the pointer remains.
        while t < 1.6 {
            t += 1.0 / 60
            _ = hover.send(.pointerValidation(isInsideHotRegion: true), at: base.addingTimeInterval(t))
            _ = hover.advance(to: base.addingTimeInterval(t))
        }
        try expect(hover.snapshot.isExpanded, "The panel must persist for continued triage")

        // Leaving after an activation gets the longer grace, then collapses.
        let leftAt = t
        _ = hover.send(.entryExited, at: base.addingTimeInterval(t))
        var collapsedAt: Double?
        while t < leftAt + 4 {
            t += 1.0 / 60
            _ = hover.send(.pointerValidation(isInsideHotRegion: false), at: base.addingTimeInterval(t))
            if !hover.advance(to: base.addingTimeInterval(t)).isExpanded, collapsedAt == nil { collapsedAt = t }
        }
        let waited = (collapsedAt ?? .infinity) - leftAt
        try expect(waited > hover.collapseDelay, "An activation must buy more grace than a plain hover-out, got \(waited)")
        try expect(waited < hover.activationGrace + 0.1, "The grace must still be bounded, got \(waited)")

        // Activating while the pointer is already gone still collapses at once.
        let away = EdgeHoverStateMachine(now: base)
        _ = away.send(.entryEntered, at: base)
        _ = away.advance(to: base.addingTimeInterval(0.3))
        _ = away.send(.entryExited, at: base.addingTimeInterval(0.35))
        try expect(!away.send(.contentActivated, at: base.addingTimeInterval(0.4)).isExpanded,
                   "With the pointer away, opening a session must still get the panel out of the way")
    }),
    ("Dark scheme meets WCAG AA against the surface it is drawn on", {
        // Known reference values keep the formula itself honest.
        try expect(abs(WCAGContrast.ratio(0xFFFFFF, 0x000000) - 21) < 0.01, "White on black must be 21:1")
        try expect(abs(WCAGContrast.ratio(0x808080, 0x808080) - 1) < 0.001, "A colour against itself must be 1:1")
        for pair in JianlingDarkScheme.contrastPairs {
            let ratio = WCAGContrast.ratio(pair.foreground, pair.background)
            try expect(ratio >= 4.5, "\(pair.name) is only \(String(format: "%.2f", ratio)):1 — below WCAG AA on a dark translucent panel")
        }
    }),
    ("Notch geometry splits notch and capsule and survives display changes", {
        let resolver = NotchGeometryResolver()
        // The developer's actual rig: notched built-in plus two external panels.
        let builtIn = EdgeScreenDescriptor(
            id: "built-in",
            frame: EdgeRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: EdgeRect(x: 0, y: 0, width: 1512, height: 944),
            isMain: true,
            safeAreaTop: 32
        )
        let external = EdgeScreenDescriptor(
            id: "studio",
            frame: EdgeRect(x: 1512, y: 0, width: 2560, height: 1440),
            visibleFrame: EdgeRect(x: 1512, y: 0, width: 2560, height: 1415),
            isMain: false
        )
        let panel = (width: 420.0, height: 560.0)

        let notch = try unwrap(resolver.resolve(screens: [builtIn, external], preferredScreenID: "built-in", expandedSize: panel), "Built-in must resolve")
        try expect(notch.presentation == .notch, "A non-zero top safe area means a physical notch")
        try expect(notch.notchRect.maxY == builtIn.frame.maxY, "The notch hugs the very top of the display")
        try expect(abs(notch.notchRect.midX - 756) < 0.01, "The notch is horizontally centred")
        // Collapsed IS the notch — nothing is drawn beside it, so the menu bar
        // stays the system's and the entry is invisible until hovered.
        try expect(notch.collapsedRect == notch.notchRect, "With nothing to report, collapsed must be exactly the notch rect — invisible")
        let withSlots = try unwrap(resolver.resolve(
            screens: [builtIn, external],
            preferredScreenID: "built-in",
            expandedSize: panel,
            compactSlotWidth: NotchGeometryResolver.compactSlotWidth
        ), "Slotted resolve must succeed")
        try expect(
            withSlots.collapsedRect.width == withSlots.notchRect.width + NotchGeometryResolver.compactSlotWidth * 2,
            "With content, the strip extends one slot either side"
        )
        try expect(abs(withSlots.collapsedRect.midX - withSlots.notchRect.midX) < 0.01, "The strip must stay centred on the notch")
        try expect(withSlots.hostFrame.width >= withSlots.collapsedRect.width, "The host frame must cover the slotted strip")
        try expect(notch.expandedRect.maxY == builtIn.frame.maxY, "The expanded shape's top edge must be flush with the screen top — that is what removes the seam")
        try expect(notch.expandedRect.width > notch.notchRect.width, "Expanding must widen beyond the notch")
        try expect(notch.expandedRect.minY >= builtIn.visibleFrame.minY, "The panel must stay on screen")
        // The window never resizes; it is parked over every state.
        try expect(notch.hostFrame.maxY == builtIn.frame.maxY, "The host window must be pinned to the screen top")
        try expect(notch.hostFrame.width >= notch.expandedRect.width, "The host frame must cover the widest state")
        try expect(notch.hostFrame.height >= notch.expandedRect.height, "The host frame must cover the tallest state")

        let capsule = try unwrap(resolver.resolve(screens: [builtIn, external], preferredScreenID: "studio", expandedSize: panel), "External must resolve")
        try expect(capsule.presentation == .capsule, "A display without a top safe area falls back to the capsule")
        try expect(capsule.notchRect.width == 0, "The capsule form has no notch rect")
        try expect(capsule.collapsedRect.maxY < external.frame.maxY, "The capsule hangs below the menu bar, not over it")
        try expect(abs(capsule.collapsedRect.midX - external.frame.midX) < 0.01, "The capsule is centred on its own display")
        try expect(capsule.expandedRect.maxY == capsule.collapsedRect.minY, "The panel hangs under the capsule")

        // The notch width must come from the display's auxiliary areas, not the
        // 200pt guess — 14" and 16" notches differ, and scaling changes both.
        let measured = EdgeScreenDescriptor(
            id: "measured",
            frame: EdgeRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: EdgeRect(x: 0, y: 0, width: 1512, height: 944),
            isMain: true,
            safeAreaTop: 32,
            auxiliaryLeftWidth: 656,
            auxiliaryRightWidth: 656
        )
        try expect(measured.measuredNotchWidth == 200, "Notch width is the remainder between the auxiliary areas")
        let fromAux = try unwrap(resolver.resolve(screens: [measured], preferredScreenID: nil, expandedSize: panel), "Measured screen must resolve")
        try expect(fromAux.notchRect.width == 200, "The resolver must use the measured width, got \(fromAux.notchRect.width)")
        let noAux = try unwrap(resolver.resolve(screens: [builtIn], preferredScreenID: "built-in", expandedSize: panel), "Fallback must resolve")
        try expect(noAux.notchRect.width == NotchGeometryResolver.assumedNotchWidth, "Without auxiliary areas it falls back to the assumed width")

        // Unplugging the chosen display must fall back rather than vanish.
        let fallback = try unwrap(resolver.resolve(screens: [builtIn], preferredScreenID: "studio", expandedSize: panel), "Must fall back")
        try expect(fallback.screenID == "built-in" && fallback.fellBackToMainScreen, "An absent display falls back to main")

        // A ghost display flagged invalid must not strand the host.
        let ghost = EdgeScreenDescriptor(
            id: "ghost",
            frame: EdgeRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: EdgeRect(x: 0, y: 0, width: 1512, height: 944),
            isMain: true,
            isValid: false
        )
        try expect(resolver.resolve(screens: [ghost], preferredScreenID: nil, expandedSize: panel) != nil, "An all-invalid set must still place the host")

        // A short screen must clamp the panel instead of running off the bottom.
        let short = EdgeScreenDescriptor(
            id: "short",
            frame: EdgeRect(x: 0, y: 0, width: 1280, height: 400),
            visibleFrame: EdgeRect(x: 0, y: 0, width: 1280, height: 375),
            isMain: true
        )
        let clamped = try unwrap(resolver.resolve(screens: [short], preferredScreenID: nil, expandedSize: panel), "Short screen must resolve")
        try expect(clamped.expandedRect.minY >= short.visibleFrame.minY, "The panel must clamp to the visible area, got \(clamped.expandedRect.minY)")
        try expect(clamped.expandedRect.width <= short.frame.width, "The panel must never exceed the display width")
    }),
    ("Quota tiers band the remaining percentage at documented thresholds", {
        // Colour is a band, not a continuous readout — these boundaries are the
        // product contract the gem's hue promises.
        try expect(QuotaTier.tier(forRemainingPercent: 100) == .full, "A full window must read as full")
        try expect(QuotaTier.tier(forRemainingPercent: 70) == .full, "70 is the inclusive floor of full")
        try expect(QuotaTier.tier(forRemainingPercent: 69.9) == .good, "Just under 70 must drop to good")
        try expect(QuotaTier.tier(forRemainingPercent: 35) == .good, "35 is the inclusive floor of good")
        try expect(QuotaTier.tier(forRemainingPercent: 34.9) == .low, "Just under 35 must drop to low")
        try expect(QuotaTier.tier(forRemainingPercent: 15) == .low, "15 is the inclusive floor of low")
        try expect(QuotaTier.tier(forRemainingPercent: 14.9) == .critical, "Just under 15 must read as critical")
        try expect(QuotaTier.tier(forRemainingPercent: 0) == .critical, "An exhausted window must read as critical")
        // Out-of-range inputs must clamp rather than fall through to a band by accident.
        try expect(QuotaTier.tier(forRemainingPercent: 140) == .full, "Over-100 readings must clamp to full")
        try expect(QuotaTier.tier(forRemainingPercent: -20) == .critical, "Negative readings must clamp to critical")
    }),
    ("Edge fluid proximity rises continuously and converges to the target", {
        // The rendered scalars ride springs, so a single sample is a point on a
        // trajectory, not the target. Assert the trajectory's shape, then that
        // it converges — a spring-blind single-shot assertion would pass on an
        // instantaneous mapping, which is exactly the stiffness we removed.
        let base = Date(timeIntervalSince1970: 1_784_700_000)
        let model = EdgeFluidDeformationModel(now: base)
        let tag = EdgeRect(x: 100, y: 100, width: 30, height: 88)
        var t = 0.0
        var strengths: [Double] = []
        for distance in stride(from: 80.0, through: 0.0, by: -1.0) {
            t += 1.0 / 120
            let value = model.update(
                pointer: EdgePoint(x: tag.minX - distance, y: 144),
                tagRect: tag,
                proximityThreshold: 80,
                allowsMotion: true,
                isExpanded: false,
                at: base.addingTimeInterval(t)
            )
            strengths.append(value.attractionStrength)
        }
        try expect(strengths == strengths.sorted(), "A steady approach must never reverse the attraction")
        try expect(strengths[0] == 0, "A pointer at the threshold must not deform")
        var settled = 0.0
        for _ in 0..<80 {
            t += 1.0 / 120
            settled = model.update(
                pointer: EdgePoint(x: tag.minX, y: 144),
                tagRect: tag,
                proximityThreshold: 80,
                allowsMotion: true,
                isExpanded: false,
                at: base.addingTimeInterval(t)
            ).attractionStrength
        }
        try expect(settled > 0.99, "Holding the pointer at the tag must converge to full attraction, got \(settled)")
        let maxStep = zip(strengths, strengths.dropFirst()).map { abs($1 - $0) }.max() ?? 0
        try expect(maxStep < 0.1, "No single frame may jump the whole range — that is the mechanical feel, got \(maxStep)")
    }),
    ("Edge fluid respects threshold and tag interior boundaries", {
        let base = Date(timeIntervalSince1970: 1_784_700_000)
        let model = EdgeFluidDeformationModel(now: base)
        let tag = EdgeRect(x: 100, y: 100, width: 30, height: 88)
        let atThreshold = model.update(
            pointer: EdgePoint(x: 20, y: 144),
            tagRect: tag,
            proximityThreshold: 80,
            allowsMotion: true,
            isExpanded: false,
            at: base
        )
        try expect(atThreshold == .zero, "A pointer exactly on the proximity threshold must not start deformation")
        var t = 0.0
        var inside = EdgeFluidDeformation.zero
        for _ in 0..<80 {
            t += 1.0 / 120
            inside = model.update(
                pointer: EdgePoint(x: 110, y: 120),
                tagRect: tag,
                proximityThreshold: 80,
                allowsMotion: true,
                isExpanded: false,
                at: base.addingTimeInterval(t)
            )
        }
        try expect(inside.attractionStrength > 0.99 && inside.bulgeAmplitude > 0.99, "Held inside the tag the springs must converge to full deformation")
        let fresh = EdgeFluidDeformationModel(now: base)
        let outside = fresh.update(
            pointer: EdgePoint(x: 19.99, y: 144),
            tagRect: tag,
            proximityThreshold: 80,
            allowsMotion: true,
            isExpanded: false,
            at: base
        )
        try expect(outside == .zero, "A pointer beyond the threshold must remain idle")
    }),
    ("Edge fluid decays to zero after the pointer leaves", {
        // The spring keeps a decaying tail by design; what must hold is that it
        // reaches exactly zero in bounded time and stops asking for frames.
        let base = Date(timeIntervalSince1970: 1_784_700_000)
        let model = EdgeFluidDeformationModel(now: base)
        let tag = EdgeRect(x: 100, y: 100, width: 30, height: 88)
        var t = 0.0
        for step in 0...12 {
            t += 1.0 / 120
            let distance = 79 - Double(step) * 6
            let value = model.update(
                pointer: EdgePoint(x: tag.minX - distance, y: 144),
                tagRect: tag,
                proximityThreshold: 80,
                allowsMotion: true,
                isExpanded: false,
                at: base.addingTimeInterval(t)
            )
            if step > 0 { try expect(value.attractionStrength > 0, "Every in-range production sample must deform") }
        }
        let leftAt = t
        var zeroedAt: Double?
        var last = EdgeFluidDeformation.zero
        for _ in 0..<180 {
            t += 1.0 / 120
            last = model.update(
                pointer: EdgePoint(x: -400, y: 144),
                tagRect: tag,
                proximityThreshold: 80,
                allowsMotion: true,
                isExpanded: false,
                at: base.addingTimeInterval(t)
            )
            if last == .zero, zeroedAt == nil { zeroedAt = t }
        }
        let elapsed = (zeroedAt ?? .infinity) - leftAt
        try expect(elapsed < 0.8, "The decay tail must be bounded, took \(elapsed)s")
        try expect(last == .zero && !last.needsAnimation, "Once decayed the model must stop requesting frames")
    }),
    ("Edge fluid reduced motion stays identically zero", {
        let base = Date(timeIntervalSince1970: 1_784_700_000)
        let model = EdgeFluidDeformationModel(now: base)
        let tag = EdgeRect(x: 100, y: 100, width: 30, height: 88)
        for step in 0...30 {
            let value = model.update(
                pointer: EdgePoint(x: 95 + Double(step % 10), y: 120 + Double(step)),
                tagRect: tag,
                proximityThreshold: 80,
                allowsMotion: false,
                isExpanded: step >= 10 && step < 20,
                at: base.addingTimeInterval(Double(step) / 120)
            )
            try expect(value == .zero, "Reduced motion must zero pointer and panel transitions on every call")
        }
    }),
    ("Edge fluid pairs expansion fusion with collapse disconnect", {
        let base = Date(timeIntervalSince1970: 1_784_700_000)
        let model = EdgeFluidDeformationModel(fusionInDuration: 0.18, fusionOutDuration: 0.15, now: base)
        let tag = EdgeRect(x: 100, y: 100, width: 30, height: 88)
        let far = EdgePoint(x: -400, y: 144)
        _ = model.update(pointer: far, tagRect: tag, proximityThreshold: 80, allowsMotion: true, isExpanded: false, at: base)
        var previous = -1.0
        for step in 0...24 {
            let value = model.update(
                pointer: far,
                tagRect: tag,
                proximityThreshold: 80,
                allowsMotion: true,
                isExpanded: true,
                at: base.addingTimeInterval(Double(step) / 120)
            )
            try expect(value.fusionProgress + 0.000_001 >= previous, "Repeated expansion samples must progress monotonically")
            previous = value.fusionProgress
        }
        try expect(previous == 1, "Expansion must finish fully fused")

        let collapseStart = base.addingTimeInterval(0.21)
        previous = 2
        var sawRebound = false
        for step in 0...20 {
            let value = model.update(
                pointer: far,
                tagRect: tag,
                proximityThreshold: 80,
                allowsMotion: true,
                isExpanded: false,
                at: collapseStart.addingTimeInterval(Double(step) / 120)
            )
            try expect(value.fusionProgress <= previous + 0.000_001, "Repeated collapse samples must disconnect monotonically")
            if value.needsAnimation && value.bulgeAmplitude > value.fusionProgress * 0.34 + 0.01 { sawRebound = true }
            previous = value.fusionProgress
        }
        try expect(sawRebound, "Collapse must include the specified light rebound")
        try expect(previous == 0, "Collapse must end at a clean zero without an idle animation")
    }),
    ("Edge fluid spring converges smoothly at production cadence", {
        let base = Date(timeIntervalSince1970: 1_784_700_000)
        let model = EdgeFluidDeformationModel(now: base)
        let tag = EdgeRect(x: 100, y: 100, width: 30, height: 88)
        var previous = 0.0
        for step in 0...36 {
            let value = model.update(pointer: EdgePoint(x: -400, y: 144), tagRect: tag, proximityThreshold: 80, allowsMotion: true, isExpanded: true, at: base.addingTimeInterval(Double(step) / 120))
            try expect(value.fusionProgress + 0.0001 >= previous, "Spring fusion must converge monotonically")
            previous = value.fusionProgress
        }
        try expect(previous > 0.99 && previous <= 1, "Spring must settle within the perceptual budget")
    }),
    ("Edge fluid spring reverses without a discontinuous jump", {
        let base = Date(timeIntervalSince1970: 1_784_700_000)
        let model = EdgeFluidDeformationModel(now: base)
        let tag = EdgeRect(x: 100, y: 100, width: 30, height: 88)
        var previous = 0.0
        for step in 0...18 {
            let value = model.update(pointer: EdgePoint(x: -400, y: 144), tagRect: tag, proximityThreshold: 80, allowsMotion: true, isExpanded: true, at: base.addingTimeInterval(Double(step) / 120))
            previous = value.fusionProgress
        }
        let reversed = model.update(pointer: EdgePoint(x: -400, y: 144), tagRect: tag, proximityThreshold: 80, allowsMotion: true, isExpanded: false, at: base.addingTimeInterval(19.0 / 120))
        try expect(abs(previous - reversed.fusionProgress) < 0.2, "Reversing the transition must preserve momentum")
    }),
    ("Edge fluid leaves animation state after a finite exit", {
        let base = Date(timeIntervalSince1970: 1_784_700_000)
        let model = EdgeFluidDeformationModel(now: base)
        let tag = EdgeRect(x: 100, y: 100, width: 30, height: 88)
        _ = model.update(pointer: EdgePoint(x: 110, y: 120), tagRect: tag, proximityThreshold: 80, allowsMotion: true, isExpanded: false, at: base)
        var value = EdgeFluidDeformation.zero
        for step in 1...36 {
            value = model.update(pointer: EdgePoint(x: -400, y: 144), tagRect: tag, proximityThreshold: 80, allowsMotion: true, isExpanded: false, at: base.addingTimeInterval(Double(step) / 120))
        }
        try expect(value == .zero && !value.needsAnimation, "Exit must settle to a clean idle state")
    }),
    ("Edge fluid reduced motion remains zero", {
        let base = Date(timeIntervalSince1970: 1_784_700_000)
        let model = EdgeFluidDeformationModel(now: base)
        let tag = EdgeRect(x: 100, y: 100, width: 30, height: 88)
        for step in 0...36 {
            let value = model.update(pointer: EdgePoint(x: 110, y: 120), tagRect: tag, proximityThreshold: 80, allowsMotion: false, isExpanded: true, at: base.addingTimeInterval(Double(step) / 120))
            try expect(value == .zero, "Reduced motion must disable fluid deformation")
        }
    }),
    ("Edge fluid quantization suppresses sub-pixel publications", {
        let value = EdgeFluidDeformation(attractionStrength: 0.104, bulgeDirectionX: 0.013, bulgeDirectionY: -0.011, bulgeAmplitude: 0.204, bridgeNeckWidth: 0.304, fusionProgress: 0.404, needsAnimation: true)
        let quantized = value.quantized()
        try expect(quantized.attractionStrength == 0.10 && quantized.bulgeDirectionX == 0.02 && quantized.bulgeDirectionY == -0.02, "Quantization steps must be stable")
        let same = value.quantized()
        try expect(same == quantized, "Sub-quantum changes must produce the same publication value")
        let next = EdgeFluidDeformation(attractionStrength: 0.116, bulgeDirectionX: 0.033, bulgeDirectionY: -0.031, bulgeAmplitude: 0.216, bridgeNeckWidth: 0.316, fusionProgress: 0.416, needsAnimation: true).quantized()
        try expect(next != quantized, "Crossing a quantization step must publish a new value")
    }),
    ("Edge compact quota height keeps placement round trips closed", {
        let base = EdgeScreenDescriptor(id: "main", frame: EdgeRect(x: 0, y: 0, width: 1280, height: 800), visibleFrame: EdgeRect(x: 0, y: 0, width: 1280, height: 800), isMain: true)
        let resolver = EdgePlacementResolver()
        let short = PresentationLayout.edgeTagHeight(quotaRowCount: 0)
        let tall = PresentationLayout.edgeTagHeight(quotaRowCount: 2)
        try expect(tall > short, "Quota rows must increase the compact tag height")
        for tagHeight in [short, tall] {
            let preference = EdgePlacementPreference(screenID: "main", verticalRatio: 0.37)
            let placement = try unwrap(resolver.resolve(screens: [base], preference: preference, size: (44, tagHeight), tagHeight: tagHeight), "Quota placement")
            let ratio = resolver.verticalRatio(forY: placement.frame.minY, screen: base, height: tagHeight, tagHeight: tagHeight)
            let roundTrip = try unwrap(resolver.resolve(screens: [base], preference: EdgePlacementPreference(screenID: "main", verticalRatio: ratio), size: (44, tagHeight), tagHeight: tagHeight), "Quota round trip")
            try expect(abs(roundTrip.frame.minY - placement.frame.minY) < 0.01, "Dynamic compact height must preserve drag round trips")
        }
    }),
    ("Presentation router pairs every top-host present with teardown and fallback", {
        let router = PresentationRouter()
        for mode in PresentationMode.allCases {
            let launch = router.route(mode: mode, trigger: .launch)
            try expect(launch.persistedMode == mode, "\(mode.rawValue) must survive launch routing")
            try expect(!launch.destroy.contains(launch.present), "\(mode.rawValue) must not destroy the host it presents")
            try expect(launch.destroy.count == PresentationHost.allCases.count - 1, "\(mode.rawValue) must destroy every inactive host")
            let fallback = router.route(mode: mode, trigger: .hostCreationFailed(launch.present))
            try expect(fallback.present == .floating && fallback.destroy == [launch.present], "Every failed host must have the paired floating fallback")
        }
    }),
    ("Compact quota window picks Codex weekly and Claude five-hour with fallback", {
        func window(_ id: String, _ provider: QuotaProvider, _ kind: QuotaWindowKind, remaining: Double, minutes: Int?) -> QuotaWindowSnapshot {
            QuotaWindowSnapshot(id: id, provider: provider, kind: kind, labelChinese: id, labelEnglish: id, remainingPercent: remaining, windowMinutes: minutes)
        }
        // Codex reports session + weekly: the compact readout is the weekly
        // budget even when the session window is tighter.
        let codex = QuotaProviderSnapshot(provider: .codex, availability: .ready, windows: [
            window("codex:primary", .codex, .session, remaining: 12, minutes: 300),
            window("codex:secondary", .codex, .weekly, remaining: 63, minutes: 10080)
        ])
        let codexPick = try unwrap(codex.compactWindow, "Codex compact window")
        try expect(codexPick.id == "codex:secondary", "Codex compact readout must be the weekly window")
        // Claude reports five-hour + weekly: the compact readout is the
        // five-hour session window even when the weekly one is tighter.
        let claude = QuotaProviderSnapshot(provider: .claude, availability: .ready, windows: [
            window("claude:seven_day", .claude, .weekly, remaining: 8, minutes: 10080),
            window("claude:five_hour", .claude, .session, remaining: 78, minutes: 300)
        ])
        let claudePick = try unwrap(claude.compactWindow, "Claude compact window")
        try expect(claudePick.id == "claude:five_hour", "Claude compact readout must be the five-hour window")
        // When the canonical window is missing, fall back to the most
        // constrained one rather than going blank.
        let partial = QuotaProviderSnapshot(provider: .codex, availability: .ready, windows: [
            window("codex:other", .codex, .other, remaining: 55, minutes: nil),
            window("codex:model", .codex, .model, remaining: 21, minutes: nil)
        ])
        let fallbackPick = try unwrap(partial.compactWindow, "Fallback compact window")
        try expect(fallbackPick.id == "codex:model", "Missing canonical window must fall back to the most constrained")
        let empty = QuotaProviderSnapshot(provider: .claude, availability: .ready, windows: [])
        try expect(empty.compactWindow == nil, "No windows means no compact readout")
    }),
    ("Adapter change sets merge paths and preserve full-scan escalation", {
        var changes = AdapterChangeSet(contentPaths: ["/tmp/a"])
        changes.merge(AdapterChangeSet(
            contentPaths: ["/tmp/b"],
            metadataPaths: ["/tmp/meta"],
            requiresFullScan: true,
            fullScanReason: "event_loss"
        ))
        try expect(changes.contentPaths == ["/tmp/a", "/tmp/b"], "Content paths must coalesce")
        try expect(changes.metadataPaths == ["/tmp/meta"], "Metadata paths must coalesce")
        try expect(changes.requiresFullScan && changes.fullScanReason == "event_loss", "Unsafe events must escalate")
    }),
    ("Craft incremental scan parses only the changed file and removes deleted files", {
        try withTempDirectory { root in
            func makeFile(_ id: String, timestamp: Double) throws -> URL {
                let directory = root.appendingPathComponent("sessions/\(id)")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let file = directory.appendingPathComponent("session.jsonl")
                try writeLines([
                    ["id": id, "name": id, "sessionStatus": "todo", "lastMessageRole": "user"],
                    ["type": "user", "id": "user-\(id)", "timestamp": timestamp]
                ], to: file)
                return file
            }
            let firstFile = try makeFile("first", timestamp: 1_784_700_000_000)
            let secondFile = try makeFile("second", timestamp: 1_784_700_001_000)
            let adapter = CraftAdapter(root: root)
            let initial = adapter.scan()
            try expect(initial.sessions.count == 2 && initial.diagnostics.didFullDiscovery, "Initial scan must build the catalog")

            try appendLines([
                ["type": "assistant", "id": "final-first", "isIntermediate": false, "timestamp": 1_784_700_002_000]
            ], to: firstFile)
            let incremental = adapter.scan(
                changes: AdapterChangeSet(contentPaths: [firstFile.path])
            )
            try expect(!incremental.diagnostics.didFullDiscovery, "Exact append must not walk the tree")
            try expect(incremental.diagnostics.parsedFileCount == 1, "Only the changed transcript should parse")
            try expect(incremental.sessions.count == 2, "Unchanged cached sessions must remain in the complete result")
            try expect(incremental.sessions.first(where: { $0.sessionID == "first" })?.status == .completed, "Changed session must update")

            try FileManager.default.removeItem(at: secondFile)
            let afterDelete = adapter.scan(
                changes: AdapterChangeSet(contentPaths: [secondFile.path])
            )
            try expect(afterDelete.sessions.map(\.sessionID) == ["first"], "Deleted files must leave the catalog without a full scan")
        }
    }),
    ("Codex filtered tail keeps completion fingerprints stable and metadata-only refresh avoids parsing", {
        try withTempDirectory { root in
            let databaseURL = root.appendingPathComponent("state.sqlite")
            try runSQLite(
                at: databaseURL,
                sql: """
                CREATE TABLE threads (
                    id TEXT PRIMARY KEY,
                    title TEXT NOT NULL,
                    archived INTEGER NOT NULL DEFAULT 0,
                    name TEXT,
                    first_user_message TEXT NOT NULL DEFAULT ''
                );
                INSERT INTO threads VALUES ('incremental-1','原始内容',0,'原始标题','原始内容');
                """
            )
            let file = root.appendingPathComponent("rollout-incremental.jsonl")
            try writeLines([
                ["type": "session_meta", "timestamp": "2026-07-15T00:00:00.000Z", "payload": ["id": "incremental-1", "cwd": "/tmp/project"]],
                ["type": "event_msg", "timestamp": "2026-07-15T00:00:01.000Z", "payload": ["type": "task_started", "turn_id": "turn-1"]],
                ["type": "response_item", "timestamp": "2026-07-15T00:00:01.500Z", "payload": ["type": "tool_output"]],
                ["type": "event_msg", "timestamp": "2026-07-15T00:00:02.000Z", "payload": ["type": "task_complete", "turn_id": "turn-1"]]
            ], to: file)
            let adapter = CodexAdapter(root: root, databaseURL: databaseURL, maxAge: 100 * 365 * 24 * 60 * 60, maxFiles: 10)
            let initial = try unwrap(adapter.scan().sessions.first, "Initial Codex snapshot missing")
            let initialFingerprint = initial.completionFingerprint
            let parseCount = adapter.parsedRolloutCount
            let metadataReloadCount = adapter.metadataReloadCount

            try appendLines([
                ["type": "response_item", "timestamp": "2026-07-15T00:00:03.000Z", "payload": ["type": "tool_output"]]
            ], to: file)
            let appended = try unwrap(adapter.scan(
                changes: AdapterChangeSet(contentPaths: [file.path])
            ).sessions.first, "Incremental Codex snapshot missing")
            try expect(appended.completionFingerprint == initialFingerprint, "Filtering irrelevant lines must not renumber the completion fingerprint")
            try expect(adapter.parsedRolloutCount == parseCount + 1, "An appended rollout should parse exactly once")
            try expect(adapter.metadataReloadCount == metadataReloadCount, "A content-only append must reuse cached Codex title metadata")

            _ = adapter.scan(changes: AdapterChangeSet(
                contentPaths: [file.path],
                metadataPaths: [databaseURL.path + "-wal"]
            ))
            try expect(adapter.metadataReloadCount == metadataReloadCount, "A WAL write merged with task progress must not reload Codex title metadata")

            try runSQLite(at: databaseURL, sql: "UPDATE threads SET name='新标题' WHERE id='incremental-1';")
            let renamed = try unwrap(adapter.scan(
                changes: AdapterChangeSet(metadataPaths: [databaseURL.path])
            ).sessions.first, "Renamed Codex snapshot missing")
            try expect(renamed.title == "新标题", "Metadata-only refresh must update the title")
            try expect(adapter.parsedRolloutCount == parseCount + 1, "Metadata-only refresh must not parse the rollout")
            try expect(adapter.metadataReloadCount == metadataReloadCount + 1, "A metadata event must reload Codex title metadata exactly once")
        }
    }),
    ("Presentation fingerprint coalesces raw activity within one minute", {
        let base = Date(timeIntervalSince1970: 1_784_700_000)
        func session(activity: Date, status: SessionStatus = .running) -> SessionSnapshot {
            SessionSnapshot(
                tool: .codex,
                sessionID: "presentation",
                title: "性能修复",
                status: status,
                lastActivity: activity,
                completionFingerprint: status == .completed ? "final" : nil,
                sourceFile: "/tmp/rollout.jsonl"
            )
        }
        let first = SessionPresentationFingerprint.compute(sessions: [session(activity: base)], now: base)
        let sameMinute = SessionPresentationFingerprint.compute(
            sessions: [session(activity: base.addingTimeInterval(20))],
            now: base.addingTimeInterval(20)
        )
        try expect(first == sameMinute, "Sub-minute mtime churn must not republish the UI")
        let completed = SessionPresentationFingerprint.compute(
            sessions: [session(activity: base.addingTimeInterval(20), status: .completed)],
            now: base.addingTimeInterval(20)
        )
        try expect(completed != sameMinute, "Completion must publish immediately")
        let nextMinute = SessionPresentationFingerprint.compute(
            sessions: [session(activity: base.addingTimeInterval(20))],
            now: base.addingTimeInterval(61)
        )
        try expect(nextMinute != sameMinute, "The maintenance clock must refresh relative time once per minute")
    }),
    ("Notch compact slot width grows with quota pairs and keeps the strip centred", {
        let base = NotchGeometryResolver.compactSlotWidth
        try expect(NotchGeometryResolver.compactSlotWidth(quotaPairs: 0) == base, "No quota pairs keeps the base slot")
        let one = NotchGeometryResolver.compactSlotWidth(quotaPairs: 1)
        let two = NotchGeometryResolver.compactSlotWidth(quotaPairs: 2)
        try expect(one >= base && two > one, "The slot must widen as quota pairs are added")
        let builtIn = EdgeScreenDescriptor(
            id: "built-in",
            frame: EdgeRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: EdgeRect(x: 0, y: 38, width: 1512, height: 944),
            isMain: true,
            safeAreaTop: 32
        )
        let geometry = try unwrap(NotchGeometryResolver().resolve(
            screens: [builtIn],
            preferredScreenID: "built-in",
            expandedSize: (420.0, 560.0),
            compactSlotWidth: two
        ), "Wide-slot resolve must succeed")
        try expect(geometry.collapsedRect.width == geometry.notchRect.width + two * 2, "Both slots share the wider width")
        try expect(abs(geometry.collapsedRect.midX - geometry.notchRect.midX) < 0.01, "The wider strip must stay centred on the notch")
        try expect(geometry.hostFrame.width >= geometry.collapsedRect.width + NotchGeometryResolver.compactTopFlareRadius * 2, "The host frame must also cover the flare wings")
    }),
    ("Push drop mapping is honest about statuses, origins and fingerprints", {
        let modified = Date(timeIntervalSince1970: 1_754_000_000)
        func map(_ object: [String: Any], fileID: String = "abc123") -> (snapshot: SessionSnapshot?, error: String?) {
            PushDropAdapter.snapshot(slug: "hermes", fileID: fileID, object: object, fileModified: modified, sourceFile: "/tmp/drop.json")
        }
        let started = try unwrap(map(["status": "started", "title": "重构登录", "timestamp": "2026-08-04T10:00:00Z"]).snapshot, "started maps")
        try expect(started.status == .running && started.completionFingerprint == nil, "started must be running without a fingerprint")
        try expect(started.turnStartedAt != nil, "started carries the turn start")
        try expect(started.id == "external:hermes/abc123" && started.externalTool == "hermes", "Identity comes from the path, not the payload")
        try expect(started.toolDisplayName == "Hermes", "Bare slugs read capitalized")

        let progress = try unwrap(map(["status": "progress"]).snapshot, "progress maps")
        try expect(progress.status == .running && progress.completionFingerprint == nil, "progress stays running")
        try expect(progress.title == "abc123", "Missing title falls back to the file identity")

        let done = try unwrap(map(["status": "done", "timestamp": "2026-08-04T11:00:00Z"]).snapshot, "done maps")
        try expect(done.status == .completed, "done completes")
        let fingerprint = try unwrap(done.completionFingerprint, "done mints a fingerprint")
        try expect(fingerprint.contains("2026-08-04T11:00:00Z"), "The explicit timestamp seeds the fingerprint")
        let rewritten = try unwrap(PushDropAdapter.snapshot(slug: "hermes", fileID: "abc123", object: ["status": "done", "timestamp": "2026-08-04T11:00:00Z"], fileModified: modified.addingTimeInterval(600), sourceFile: "/tmp/drop.json").snapshot, "rewrite maps")
        try expect(rewritten.completionFingerprint == fingerprint, "Rewriting an identical done must not mint a fresh completion")

        let failed = try unwrap(map(["status": "failed", "timestamp": "2026-08-04T11:00:00Z"]).snapshot, "failed maps")
        try expect(failed.status == .completed && failed.completionFingerprint != fingerprint, "A reported failure is a distinct report-back")

        let routine = try unwrap(map(["status": "done", "origin": "scheduled"]).snapshot, "scheduled maps")
        try expect(routine.isRoutine, "Scheduled drops land in the routine inbox")
        let sub = try unwrap(map(["status": "started", "origin": "subagent"]).snapshot, "subagent maps")
        try expect(sub.isBackground, "Subagent drops fold into the background tier")

        try expect(map(["status": "finished"]).snapshot == nil, "Unknown statuses are rejected, not guessed")
        try expect(PushDropAdapter.sanitizedSlug("Hermes") == "hermes", "Slugs normalize to lowercase")
        try expect(PushDropAdapter.sanitizedSlug("../evil") == nil, "Path smuggling slugs are rejected")
        try expect(PushDropAdapter.sanitizedSlug("a b") == nil && PushDropAdapter.sanitizedSlug("") == nil, "Whitespace and empty slugs are rejected")
    }),
    ("Push drop scan isolates bad drops and detects completions once", {
        try withTempDirectory { root in
            let hermes = root.appendingPathComponent("hermes", isDirectory: true)
            let cursor = root.appendingPathComponent("cursor", isDirectory: true)
            try FileManager.default.createDirectory(at: hermes, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: cursor, withIntermediateDirectories: true)
            try Data("{\"status\":\"done\",\"title\":\"迁移脚本\",\"timestamp\":\"2026-08-04T11:00:00Z\"}".utf8)
                .write(to: hermes.appendingPathComponent("t1.json"))
            try Data("not json at all".utf8)
                .write(to: hermes.appendingPathComponent("bad.json"))
            try Data("{\"status\":\"started\",\"timestamp\":\"2026-08-04T11:05:00Z\"}".utf8)
                .write(to: cursor.appendingPathComponent("t2.json"))
            try Data("{\"status\":\"done\"}".utf8)
                .write(to: root.appendingPathComponent("loose.json"))

            let adapter = PushDropAdapter(root: root)
            let now = Date(timeIntervalSince1970: 1_754_100_000)
            let result = adapter.scan(now: now)
            try expect(result.tool == .external, "Scan reports the external tool")
            try expect(result.sessions.count == 2, "Two valid drops survive, got \(result.sessions.count)")
            try expect(result.errors.count == 2, "The garbage drop and the loose drop are isolated as errors, got \(result.errors)")
            let doneSession = try unwrap(result.sessions.first { $0.sessionID == "hermes/t1" }, "hermes drop present")
            try expect(doneSession.status == .completed && doneSession.externalTool == "hermes", "Path decides identity")

            // First sight builds history; flipping the cursor drop to done later
            // must ring exactly once even across repeated scans.
            let detector = CompletionDetector()
            try expect(detector.process(result.sessions, at: now).isEmpty, "First scan only builds the baseline")
            try Data("{\"status\":\"done\",\"timestamp\":\"2026-08-04T11:10:00Z\"}".utf8)
                .write(to: cursor.appendingPathComponent("t2.json"))
            adapter.invalidateCache()
            let second = adapter.scan(now: now.addingTimeInterval(60))
            let events = detector.process(second.sessions, at: now.addingTimeInterval(60))
            try expect(events.count == 1 && events[0].session.sessionID == "cursor/t2", "The cursor completion rings once")
            let third = detector.process(adapter.scan(now: now.addingTimeInterval(120)).sessions, at: now.addingTimeInterval(120))
            try expect(third.isEmpty, "Re-scanning the same done drop stays silent")
        }
    })
]

var failures = 0
for (name, test) in tests {
    do {
        try test()
        print("PASS\t\(name)")
    } catch {
        failures += 1
        print("FAIL\t\(name)\t\(error)")
    }
}
print("TESTS=\(tests.count) FAILURES=\(failures)")
exit(failures == 0 ? 0 : 1)
