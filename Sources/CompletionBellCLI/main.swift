import CompletionBellCore
import Foundation

let command = CommandLine.arguments.dropFirst().first ?? "doctor"

switch command {
case "doctor":
    let home = FileManager.default.homeDirectoryForCurrentUser
    let roots: [(String, URL)] = [
        ("craft", home.appendingPathComponent(".craft-agent/workspaces")),
        ("claudeCode", home.appendingPathComponent(".claude/projects")),
        ("codex", home.appendingPathComponent(".codex/sessions")),
        ("newMax", home.appendingPathComponent(".newmax/conversations")),
        ("workBuddy", home.appendingPathComponent(".workbuddy/projects")),
        ("external(drops)", home.appendingPathComponent(".jianling/drops"))
    ]
    for (name, url) in roots {
        print("\(name)\t\(FileManager.default.fileExists(atPath: url.path) ? "ready" : "missing")")
    }

case "scan":
    let adapters: [SessionAdapter] = [CraftAdapter(), ClaudeCodeAdapter(), CodexAdapter(), NewMaxAdapter(), WorkBuddyAdapter(), PushDropAdapter()]
    for adapter in adapters {
        let started = Date()
        let result = adapter.scan(now: started)
        let running = result.sessions.filter { $0.status == .running }.count
        let completed = result.sessions.filter { $0.status == .completed }.count
        let background = result.sessions.filter(\.isBackground).count
        let elapsed = Date().timeIntervalSince(started)
        print("\(adapter.tool.rawValue)\ttotal=\(result.sessions.count)\trunning=\(running)\tcompleted=\(completed)\tbackground=\(background)\terrors=\(result.errors.count)\tscan_ms=\(Int(elapsed * 1000))")
    }

case "simulate":
    let detector = CompletionDetector()
    let baseDate = Date()
    func snapshot(fingerprint: String) -> SessionSnapshot {
        SessionSnapshot(
            tool: .craft,
            sessionID: "simulation",
            title: "模拟会话",
            status: .completed,
            lastActivity: baseDate,
            completionFingerprint: fingerprint,
            sourceFile: "/tmp/simulation.jsonl"
        )
    }

    let historical = detector.process([snapshot(fingerprint: "history")], at: baseDate).count
    var detected = 0
    var duplicate = 0
    for index in 1...10 {
        let current = snapshot(fingerprint: "event-\(index)")
        detected += detector.process([current], at: baseDate.addingTimeInterval(Double(index))).count
        duplicate += detector.process([current], at: baseDate.addingTimeInterval(Double(index) + 0.1)).count
    }
    print("expected=10 detected=\(detected) duplicate=\(duplicate) history_replayed=\(historical)")

case "benchmark":
    let adapters: [SessionAdapter] = [CraftAdapter(), ClaudeCodeAdapter(), CodexAdapter(), NewMaxAdapter(), WorkBuddyAdapter()]
    for round in 1...5 {
        let started = Date()
        var total = 0
        for adapter in adapters {
            total += adapter.scan(now: started).sessions.count
        }
        let elapsed = Date().timeIntervalSince(started)
        print("round=\(round) sessions=\(total) scan_ms=\(Int(elapsed * 1000))")
    }

case "idle-bench":
    let adapters: [SessionAdapter] = [CraftAdapter(), ClaudeCodeAdapter(), CodexAdapter(), NewMaxAdapter(), WorkBuddyAdapter()]
    var previousCanonical: [SessionSnapshot]?
    var previousErrors: [String] = []
    for round in 1...12 {
        let started = Date()
        var sessions: [SessionSnapshot] = []
        var errors: [String] = []
        for adapter in adapters {
            let result = adapter.scan(now: started)
            sessions.append(contentsOf: result.sessions)
            errors.append(contentsOf: result.errors.map { "\(result.tool.rawValue): \($0)" })
        }
        let elapsed = Date().timeIntervalSince(started)
        let canonical = ScanChangeDetector.canonical(sessions)
        let unchanged = ScanChangeDetector.isUnchanged(
            canonicalSessions: canonical,
            errors: errors,
            previousCanonicalSessions: previousCanonical,
            previousErrors: previousErrors
        )
        var changeSummary = ""
        if !unchanged, let previous = previousCanonical {
            let previousByID = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let currentByID = Dictionary(canonical.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            var changedIDs: [String] = []
            for (id, snapshot) in currentByID where previousByID[id] != snapshot {
                changedIDs.append(id)
            }
            for id in previousByID.keys where currentByID[id] == nil {
                changedIDs.append("\(id) (removed)")
            }
            changeSummary = " changed=\(changedIDs.count) sample=\(changedIDs.sorted().prefix(3).joined(separator: ","))"
        }
        previousCanonical = canonical
        previousErrors = errors
        print("round=\(round) sessions=\(sessions.count) scan_ms=\(Int(elapsed * 1000)) unchanged=\(unchanged)\(changeSummary)")
    }

case "running":
    let adapters: [SessionAdapter] = [CraftAdapter(), ClaudeCodeAdapter(), CodexAdapter(), NewMaxAdapter(), WorkBuddyAdapter()]
    for adapter in adapters {
        let sessions = adapter.scan(now: Date()).sessions
            .filter { $0.status == .running }
            .sorted { $0.lastActivity > $1.lastActivity }
        for session in sessions.prefix(20) {
            print("\(adapter.tool.rawValue)\t\(session.origin.rawValue)\t\(session.sessionID)\t\(ISO8601DateFormatter().string(from: session.lastActivity))\t\(session.title)")
        }
    }

case "classify":
    let adapters: [SessionAdapter] = [CraftAdapter(), ClaudeCodeAdapter(), CodexAdapter(), NewMaxAdapter(), WorkBuddyAdapter()]
    for adapter in adapters {
        let sessions = adapter.scan(now: Date()).sessions
        for origin in SessionOrigin.allCases {
            let values = sessions.filter { $0.origin == origin }
            guard !values.isEmpty else { continue }
            let running = values.filter { $0.status == .running }.count
            let completed = values.filter { $0.status == .completed }.count
            print("\(adapter.tool.rawValue)\t\(origin.rawValue)\ttotal=\(values.count)\trunning=\(running)\tcompleted=\(completed)")
        }
    }

case "report", "report-en":
    let home = FileManager.default.homeDirectoryForCurrentUser
    let activityURL = home.appendingPathComponent("Library/Application Support/CompletionBell/activity.jsonl")
    let reportsDirectory = home.appendingPathComponent("Documents/AI会话监控浮窗/日报", isDirectory: true)
    let records = ActivityLogStore(url: activityURL).records()
    let reportAdapters: [SessionAdapter] = [CraftAdapter(), ClaudeCodeAdapter(), CodexAdapter(), NewMaxAdapter(), WorkBuddyAdapter()]
    let sessions = reportAdapters.flatMap { $0.scan(now: Date()).sessions }
    let generator = DailyReportGenerator()
    let day = Calendar.current.startOfDay(for: Date())
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    let english = command == "report-en"
    let name = english
        ? "\(formatter.string(from: day))_Bladecall_Daily_Report_EN"
        : "\(formatter.string(from: day))_剑令日报"
    let markdownURL = reportsDirectory.appendingPathComponent("\(name).md")
    let htmlURL = reportsDirectory.appendingPathComponent("\(name).html")
    try FileManager.default.createDirectory(at: reportsDirectory, withIntermediateDirectories: true)
    if !english {
        try generator.markdown(for: day, records: records, includeBackground: false)
            .write(to: markdownURL, atomically: true, encoding: .utf8)
    }
    try generator.html(
        for: day,
        records: records,
        currentSessions: sessions,
        includeBackground: false,
        language: english ? .english : .chinese
    ).write(to: htmlURL, atomically: true, encoding: .utf8)
    print(htmlURL.path)

case "task":
    // The official pen for the push drop protocol: any agent (or shell hook)
    // reports a task with one command, and Bladecall's inbox picks it up.
    //   completion-bell-cli task --tool hermes --session abc123 \
    //     --status done --title "Refactor login" [--project /path] [--origin scheduled]
    var options: [String: String] = [:]
    var argIndex = 2
    let arguments = CommandLine.arguments
    while argIndex + 1 < arguments.count {
        let key = arguments[argIndex]
        guard key.hasPrefix("--") else { argIndex += 1; continue }
        options[String(key.dropFirst(2))] = arguments[argIndex + 1]
        argIndex += 2
    }
    guard let rawTool = options["tool"], let slug = PushDropAdapter.sanitizedSlug(rawTool) else {
        fputs("task: --tool is required (lowercase letters, digits, - _ .)\n", stderr)
        exit(2)
    }
    guard let rawStatus = options["status"]?.lowercased(),
          PushDropAdapter.allowedStatuses.contains(rawStatus) else {
        fputs("task: --status must be one of \(PushDropAdapter.allowedStatuses.sorted().joined(separator: "|"))\n", stderr)
        exit(2)
    }
    guard let rawSession = options["session"], !rawSession.isEmpty else {
        fputs("task: --session is required\n", stderr)
        exit(2)
    }
    let fileID = String(rawSession.map { character in
        character.isLetter || character.isNumber || character == "-" || character == "_" || character == "." ? character : "-"
    }).prefix(120)
    let root = options["root"].map { URL(fileURLWithPath: $0) } ?? PushDropAdapter.defaultRoot
    let dropDirectory = root.appendingPathComponent(slug, isDirectory: true)
    try FileManager.default.createDirectory(at: dropDirectory, withIntermediateDirectories: true)
    let iso = ISO8601DateFormatter()
    var payload: [String: Any] = [
        "schemaVersion": 1,
        "tool": slug,
        "sessionID": String(fileID),
        "status": rawStatus,
        "timestamp": iso.string(from: Date())
    ]
    if let title = options["title"], !title.isEmpty { payload["title"] = title }
    if let project = options["project"], !project.isEmpty { payload["projectPath"] = project }
    if let origin = options["origin"], !origin.isEmpty { payload["origin"] = origin }
    let dropURL = dropDirectory.appendingPathComponent("\(fileID).json")
    let dropData = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    try dropData.write(to: dropURL, options: .atomic)
    print(dropURL.path)

default:
    fputs("Usage: completion-bell-cli [doctor|scan|simulate|benchmark|idle-bench|running|classify|report|report-en|task]\n", stderr)
    exit(2)
}
