import Foundation

public enum ActivityKind: String, Codable, Hashable {
    case taskStarted
    case assistantCompleted
    case handled
    case appForeground
}

public struct ActivityRecord: Codable, Hashable, Identifiable {
    public let id: String
    public let kind: ActivityKind
    public let timestamp: Date
    public let startedAt: Date?
    public let durationSeconds: TimeInterval?
    public let tool: ToolKind?
    public let sessionID: String?
    public let turnID: String?
    public let title: String?
    public let projectPath: String?
    public let origin: SessionOrigin?
    public let handledMethod: HandledMethod?

    public init(
        id: String = UUID().uuidString,
        kind: ActivityKind,
        timestamp: Date,
        startedAt: Date? = nil,
        durationSeconds: TimeInterval? = nil,
        tool: ToolKind? = nil,
        sessionID: String? = nil,
        turnID: String? = nil,
        title: String? = nil,
        projectPath: String? = nil,
        origin: SessionOrigin? = nil,
        handledMethod: HandledMethod? = nil
    ) {
        self.id = id
        self.kind = kind
        self.timestamp = timestamp
        self.startedAt = startedAt
        self.durationSeconds = durationSeconds
        self.tool = tool
        self.sessionID = sessionID
        self.turnID = turnID
        self.title = title
        self.projectPath = projectPath
        self.origin = origin
        self.handledMethod = handledMethod
    }

    public init(transition: InboxTransition) {
        let duration = transition.startedAt.map { max(0, transition.timestamp.timeIntervalSince($0)) }
        self.init(
            id: "\(transition.kind.rawValue):\(transition.session.id):\(transition.turnID)",
            kind: ActivityKind(rawValue: transition.kind.rawValue) ?? .taskStarted,
            timestamp: transition.timestamp,
            startedAt: transition.startedAt,
            durationSeconds: duration,
            tool: transition.session.tool,
            sessionID: transition.session.id,
            turnID: transition.turnID,
            title: transition.session.title,
            projectPath: transition.session.projectPath,
            origin: transition.session.origin,
            handledMethod: transition.handledMethod
        )
    }
}

public final class ActivityLogStore: @unchecked Sendable {
    public let url: URL
    private let lock = NSLock()
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    /// In-memory mirror of the on-disk log. Appends go to disk first, then to
    /// the cache, so other processes (CLI) always see a complete file while
    /// in-process readers stop paying a full parse on every call. A file-size
    /// mismatch (external truncation/rotation) drops the cache for a reload.
    private var cachedRecords: [ActivityRecord]?
    private var knownFileSize: UInt64 = 0

    public init(url: URL) {
        self.url = url
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    public func append(_ record: ActivityRecord) {
        lock.lock()
        defer { lock.unlock() }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            var data = try encoder.encode(record)
            data.append(0x0A)
            if cachedRecords != nil && actualFileSize() != knownFileSize {
                cachedRecords = nil
            }
            if !FileManager.default.fileExists(atPath: url.path) {
                try data.write(to: url, options: .atomic)
                cachedRecords?.append(record)
                knownFileSize = UInt64(data.count)
                return
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            let end = try handle.seekToEnd()
            try handle.write(contentsOf: data)
            cachedRecords?.append(record)
            knownFileSize = end + UInt64(data.count)
        } catch {
            return
        }
    }

    public func records() -> [ActivityRecord] {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cachedRecords, actualFileSize() == knownFileSize {
            return cached
        }
        guard let data = try? Data(contentsOf: url) else {
            cachedRecords = []
            knownFileSize = 0
            return []
        }
        let loaded = data.split(separator: 0x0A).compactMap { line in
            try? decoder.decode(ActivityRecord.self, from: Data(line))
        }
        cachedRecords = loaded
        knownFileSize = UInt64(data.count)
        return loaded
    }

    private func actualFileSize() -> UInt64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else { return 0 }
        return size.uint64Value
    }
}

public struct TimelineSegment: Identifiable, Hashable {
    public let id: String
    public let tool: ToolKind
    public let sessionID: String
    public let title: String
    public let origin: SessionOrigin
    public let start: Date
    public let end: Date
    public let completed: Bool

    public init(
        id: String,
        tool: ToolKind,
        sessionID: String,
        title: String,
        origin: SessionOrigin,
        start: Date,
        end: Date,
        completed: Bool
    ) {
        self.id = id
        self.tool = tool
        self.sessionID = sessionID
        self.title = title
        self.origin = origin
        self.start = start
        self.end = end
        self.completed = completed
    }

    public var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }
    public var isBackground: Bool { origin.isBackground }
    public var isRoutine: Bool { origin.isRoutine }
}

public struct ForegroundSegment: Identifiable, Hashable {
    public let id: String
    public let tool: ToolKind
    public let start: Date
    public let end: Date

    public init(id: String, tool: ToolKind, start: Date, end: Date) {
        self.id = id
        self.tool = tool
        self.start = start
        self.end = end
    }

    public var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }
}

public struct DailyTimeline: Hashable {
    public let tasks: [TimelineSegment]
    public let foreground: [ForegroundSegment]
    public let startHour: Int
    public let endHour: Int

    public init(tasks: [TimelineSegment], foreground: [ForegroundSegment], startHour: Int, endHour: Int) {
        self.tasks = tasks
        self.foreground = foreground
        self.startHour = startHour
        self.endHour = endHour
    }
}

public struct DailyTimelineBuilder {
    public let activeWindow: TimeInterval

    public init(activeWindow: TimeInterval = 15 * 60) {
        self.activeWindow = activeWindow
    }

    public func build(
        for day: Date,
        records: [ActivityRecord],
        currentSessions: [SessionSnapshot] = [],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> DailyTimeline {
        let dayStart = calendar.startOfDay(for: day)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86_400)
        let currentByID = Dictionary(uniqueKeysWithValues: currentSessions.map { ($0.id, $0) })
        let starts = records.filter { $0.kind == .taskStarted && $0.timestamp < dayEnd }
            .sorted { $0.timestamp < $1.timestamp }
        let completions = records.filter {
            $0.kind == .assistantCompleted
                && $0.timestamp >= dayStart
                && $0.timestamp < dayEnd
        }

        var tasks = completions.compactMap { record -> TimelineSegment? in
            guard let tool = record.tool, let sessionID = record.sessionID else { return nil }
            let rawStart = record.startedAt ?? record.timestamp
            let start = max(rawStart, dayStart)
            let end = min(record.timestamp, dayEnd)
            guard end > start else { return nil }
            return TimelineSegment(
                id: "complete:\(record.id)",
                tool: tool,
                sessionID: sessionID,
                title: record.title ?? "未命名任务",
                origin: record.origin ?? .interactive,
                start: start,
                end: end,
                completed: true
            )
        }

        for (index, record) in starts.enumerated() {
            guard record.timestamp >= dayStart,
                  let tool = record.tool,
                  let sessionID = record.sessionID else { continue }
            let nextStart = starts.dropFirst(index + 1).first {
                $0.sessionID == sessionID && $0.timestamp > record.timestamp
            }?.timestamp ?? dayEnd
            let hasCompletion = completions.contains {
                $0.sessionID == sessionID
                    && $0.timestamp >= record.timestamp
                    && $0.timestamp < nextStart
            }
            guard !hasCompletion else { continue }

            let snapshot = currentByID[sessionID]
            let observedEnd = snapshot?.lastActivity ?? record.timestamp.addingTimeInterval(activeWindow)
            let liveCap = min(now, dayEnd)
            let end = min(max(observedEnd, record.timestamp.addingTimeInterval(1)), liveCap)
            guard end > record.timestamp else { continue }
            tasks.append(TimelineSegment(
                id: "open:\(record.id)",
                tool: tool,
                sessionID: sessionID,
                title: record.title ?? snapshot?.title ?? "未命名任务",
                origin: record.origin ?? snapshot?.origin ?? .interactive,
                start: record.timestamp,
                end: end,
                completed: false
            ))
        }

        let foreground = records.compactMap { record -> ForegroundSegment? in
            guard record.kind == .appForeground,
                  let tool = record.tool,
                  let rawStart = record.startedAt else { return nil }
            let rawEnd = record.durationSeconds.map { rawStart.addingTimeInterval($0) } ?? record.timestamp
            let start = max(rawStart, dayStart)
            let end = min(rawEnd, dayEnd)
            guard end > start else { return nil }
            return ForegroundSegment(id: record.id, tool: tool, start: start, end: end)
        }

        tasks.sort { $0.start < $1.start }
        let allDates = tasks.flatMap { [$0.start, $0.end] } + foreground.flatMap { [$0.start, $0.end] }
        let startHour: Int
        let endHour: Int
        if allDates.isEmpty {
            startHour = 8
            endHour = 20
        } else {
            let earliest = allDates.min() ?? dayStart
            let latest = allDates.max() ?? earliest
            startHour = max(0, calendar.component(.hour, from: earliest) - 1)
            let latestHour = calendar.component(.hour, from: latest)
            let hasMinutes = calendar.component(.minute, from: latest) > 0 || calendar.component(.second, from: latest) > 0
            endHour = min(24, max(startHour + 1, latestHour + (hasMinutes ? 2 : 1)))
        }
        return DailyTimeline(tasks: tasks, foreground: foreground, startHour: startHour, endHour: endHour)
    }
}

public enum DailyReportLanguage: String, Codable, Hashable {
    case chinese
    case english
}

/// Answers whether an on-disk report still carries the current HTML template
/// without reading whole documents: the `jianling-report-template` meta tag
/// sits within the first few hundred bytes of `<head>`, so probing a 4 KB
/// prefix is enough, and verdicts are cached per (path, mtime, size) so the
/// once-a-minute report sweep never re-reads unchanged files.
public final class DailyReportTemplateProbe: @unchecked Sendable {
    private struct Verdict {
        let modificationDate: Date
        let size: Int
        let needsUpgrade: Bool
    }

    private let prefixLength: Int
    private let lock = NSLock()
    private var verdicts: [String: Verdict] = [:]

    public init(prefixLength: Int = 4096) {
        self.prefixLength = prefixLength
    }

    /// True when the file is missing, unreadable, or does not carry the
    /// current template marker within the probe prefix.
    public func needsUpgrade(at url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modificationDate = attributes[.modificationDate] as? Date,
              let size = (attributes[.size] as? NSNumber)?.intValue else {
            return true
        }
        lock.lock()
        defer { lock.unlock() }
        if let cached = verdicts[url.path],
           cached.modificationDate == modificationDate,
           cached.size == size {
            return cached.needsUpgrade
        }
        let needsUpgrade = !Self.prefixCarriesCurrentTemplate(at: url, prefixLength: prefixLength)
        verdicts[url.path] = Verdict(modificationDate: modificationDate, size: size, needsUpgrade: needsUpgrade)
        return needsUpgrade
    }

    private static func prefixCarriesCurrentTemplate(at url: URL, prefixLength: Int) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: prefixLength), !data.isEmpty else { return false }
        // The marker is pure ASCII; a multi-byte character cut at the prefix
        // boundary decodes lossily without affecting the match.
        return DailyReportGenerator.isCurrentHTMLTemplate(String(decoding: data, as: UTF8.self))
    }
}

public struct DailyReportGenerator {
    public init() {}

    public static let htmlTemplateVersion = 4

    public static func isCurrentHTMLTemplate(_ html: String) -> Bool {
        html.contains("<meta name=\"jianling-report-template\" content=\"\(htmlTemplateVersion)\">")
    }

    public func markdown(
        for day: Date,
        records: [ActivityRecord],
        includeBackground: Bool = true,
        calendar: Calendar = .current
    ) -> String {
        let reportRecords = records.filter { includeBackground || $0.origin?.isBackground != true }
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        let discrete = reportRecords.filter { $0.timestamp >= start && $0.timestamp < end }
        let foreground = reportRecords.filter { $0.kind == .appForeground && overlaps($0, start: start, end: end) }
        let started = discrete.filter { $0.kind == .taskStarted }
        let completed = discrete.filter { $0.kind == .assistantCompleted }
        let handled = discrete.filter { $0.kind == .handled }
        let routineCompleted = completed.filter { $0.origin == .scheduled }
        let backgroundCompleted = completed.filter { $0.origin?.isBackground == true }
        let pendingAtEnd = pendingTurnIDs(records: reportRecords, before: end).count

        let dateText = Self.dayFormatter.string(from: start)
        var lines: [String] = [
            "# 剑令日报 · \(dateText)",
            "",
            "> 数据来自剑令记录的本地事件，不会读取对话内容。",
            "",
            "## 今日概览",
            "",
            "- 前台使用：\(formatDuration(totalForeground(foreground, start: start, end: end)))",
            "- 发起任务：\(started.count) 次",
            "- AI 完成：\(completed.count) 次",
            "- 例行任务完成：\(routineCompleted.count) 次",
            "- 已处理：\(handled.count) 次",
            "- 日终待处理：\(pendingAtEnd) 个",
            "- AI 累计运行：\(formatDuration(completed.compactMap(\.durationSeconds).reduce(0, +)))（含并行重叠）",
            "- AI 忙碌覆盖：\(formatDuration(unionDuration(completed.compactMap { interval($0, start: start, end: end) })))（并行去重）",
            "- 完成后等待处理：\(formatDuration(handled.compactMap(\.durationSeconds).reduce(0, +)))",
            "",
            "## 前台应用时间",
            "",
            "| App | 使用时间 |",
            "|---|---:|"
        ]

        if includeBackground {
            lines.insert("- 幕后任务完成：\(backgroundCompleted.count) 次", at: 13)
        } else {
            lines.insert("> 本页已隐藏子 Agent、外部运行和宿主中不可见的会话；例行任务仍会保留。", at: 3)
        }

        for tool in ToolKind.allCases {
            let seconds = foreground.filter { $0.tool == tool }
                .compactMap { clippedDuration($0, start: start, end: end) }
                .reduce(0, +)
            lines.append("| \(tool.displayName) | \(formatDuration(seconds)) |")
        }

        lines.append(contentsOf: [
            "",
            "## App 任务流",
            "",
            "| App | 发起 | AI 完成 | 已处理 | AI 累计运行 |",
            "|---|---:|---:|---:|---:|"
        ])
        for tool in ToolKind.allCases {
            let toolStarted = started.filter { $0.tool == tool }.count
            let toolCompleted = completed.filter { $0.tool == tool }
            let toolHandled = handled.filter { $0.tool == tool }.count
            lines.append("| \(tool.displayName) | \(toolStarted) | \(toolCompleted.count) | \(toolHandled) | \(formatDuration(toolCompleted.compactMap(\.durationSeconds).reduce(0, +))) |")
        }

        lines.append(contentsOf: ["", "## 项目与会话", "", "| 项目 / 会话 | 完成次数 | AI 运行 |", "|---|---:|---:|"])
        let grouped = Dictionary(grouping: completed) { record -> String in
            let project = record.projectPath.flatMap { URL(fileURLWithPath: $0).lastPathComponent.nonEmpty }
            return project ?? record.title?.nonEmpty ?? "未分组"
        }
        if grouped.isEmpty {
            lines.append("| 暂无完成记录 | 0 | 0 分钟 |")
        } else {
            for (name, values) in grouped.sorted(by: { lhs, rhs in
                if lhs.value.count != rhs.value.count { return lhs.value.count > rhs.value.count }
                return lhs.key < rhs.key
            }).prefix(10) {
                lines.append("| \(escape(name)) | \(values.count) | \(formatDuration(values.compactMap(\.durationSeconds).reduce(0, +))) |")
            }
        }

        lines.append(contentsOf: [
            "",
            "## 例行剑令",
            "",
            "- 定时任务完成：\(routineCompleted.count)"
        ])

        if includeBackground {
            lines.append(contentsOf: [
                "",
                "## 幕后任务",
                "",
                "- 子 Agent 完成：\(backgroundCompleted.filter { $0.origin == .subagent }.count)",
                "- Multica / 外部运行完成：\(backgroundCompleted.filter { $0.origin == .externalRuntime }.count)",
                "- 宿主中不可见的会话：\(backgroundCompleted.filter { $0.origin == .detached }.count)",
            ])
        }
        lines.append(contentsOf: [
            "",
            "---",
            "",
            "前台时间表示哪个 App 当时在最前面，不会把阅读、思考或等待硬算成某段工作的精确用时。"
        ])
        return lines.joined(separator: "\n") + "\n"
    }

    public func html(
        for day: Date,
        records: [ActivityRecord],
        currentSessions: [SessionSnapshot] = [],
        includeBackground: Bool = true,
        language: DailyReportLanguage = .chinese,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        DailyReportHTMLRenderer(
            day: day,
            records: records,
            currentSessions: currentSessions,
            includeBackground: includeBackground,
            language: language,
            now: now,
            calendar: calendar
        ).render()
    }

    private func legacyHTML(
        for day: Date,
        records: [ActivityRecord],
        currentSessions: [SessionSnapshot] = [],
        includeBackground: Bool = true,
        language: DailyReportLanguage = .chinese,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        let isEnglish = language == .english
        func localized(_ chinese: String, _ english: String) -> String {
            isEnglish ? english : chinese
        }
        let reportRecords = records.filter { includeBackground || $0.origin?.isBackground != true }
        let reportSessions = currentSessions.filter { includeBackground || !$0.isBackground }
        let start = calendar.startOfDay(for: day)
        let timeline = DailyTimelineBuilder().build(
            for: day,
            records: reportRecords,
            currentSessions: reportSessions,
            now: now,
            calendar: calendar
        )
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        let dayRecords = reportRecords.filter { $0.timestamp >= start && $0.timestamp < end }
        let completed = dayRecords.filter { $0.kind == .assistantCompleted }
        let routineCompleted = completed.filter { $0.origin == .scheduled }
        let handled = dayRecords.filter { $0.kind == .handled }
        let pending = pendingTurnIDs(records: reportRecords, before: min(end, now)).count
        let foregroundSeconds = timeline.foreground.reduce(0) { $0 + $1.duration }
        let aiSeconds = timeline.tasks.reduce(0) { $0 + $1.duration }
        let dateText = Self.dayFormatter.string(from: start)
        let nowMinute = max(0, min(1_440, now.timeIntervalSince(start) / 60))
        let ganttRows = ToolKind.allCases.compactMap { tool -> String? in
            let toolTasks = timeline.tasks.filter { $0.tool == tool }
            let toolForeground = timeline.foreground.filter { $0.tool == tool }
            guard !toolTasks.isEmpty || !toolForeground.isEmpty else { return nil }

            let foregroundBars = toolForeground.map { segment in
                let offset = max(0, segment.start.timeIntervalSince(start) / 60)
                let duration = max(0.1, segment.duration / 60)
                return "<div class=\"bar foreground-bar\" data-start=\"\(formatNumber(offset))\" data-duration=\"\(formatNumber(duration))\" title=\"\(localized("App 前台", "App in foreground")) · \(timeRange(segment.start, segment.end))\"></div>"
            }.joined(separator: "\n")
            let foregroundRow = toolForeground.isEmpty ? "" : """
            <div class="gantt-row foreground-row">
              <div class="row-label"><b>\(localized("App 位于前台", "App in foreground"))</b><small>\(formatDuration(toolForeground.reduce(0) { $0 + $1.duration }, language: language))</small></div>
              <div class="canvas">\(foregroundBars)<i class="now-line" data-start="\(formatNumber(nowMinute))"></i></div>
            </div>
            """

            let grouped = Dictionary(grouping: toolTasks, by: \.sessionID).values.sorted {
                ($0.map(\.start).min() ?? .distantPast) < ($1.map(\.start).min() ?? .distantPast)
            }
            let sessionRows = grouped.map { segments in
                let sortedSegments = segments.sorted { $0.start < $1.start }
                guard let first = sortedSegments.first else { return "" }
                let totalDuration = sortedSegments.reduce(0) { $0 + $1.duration }
                let sourceText: String
                if first.isRoutine {
                    sourceText = localized("例行剑令", "Routine run")
                } else if first.isBackground {
                    switch first.origin {
                    case .subagent: sourceText = localized("子 Agent", "Subagent")
                    case .externalRuntime: sourceText = localized("外部运行", "External runtime")
                    case .detached: sourceText = localized("不可见 Session", "Detached session")
                    case .interactive: sourceText = localized("对话", "Conversation")
                    case .scheduled: sourceText = localized("例行任务", "Routine run")
                    }
                } else {
                    sourceText = localized("普通对话", "Conversation")
                }
                let taskBars = sortedSegments.map { segment in
                    let offset = max(0, segment.start.timeIntervalSince(start) / 60)
                    let duration = max(0.1, segment.duration / 60)
                    let backgroundClass = segment.isBackground ? " background" : ""
                    let routineClass = segment.isRoutine ? " routine" : ""
                    let openClass = segment.completed ? "" : " open"
                    let marker = segment.completed
                        ? "<i class=\"reply-dot\" title=\"\(localized("AI 在 \(timeText(segment.end)) 回复", "AI completed at \(timeText(segment.end))"))\"></i>"
                        : ""
                    let state = segment.completed ? localized("AI 已回复", "AI completed") : localized("仍在运行", "Still running")
                    return """
                    <div class="bar task-bar\(backgroundClass)\(routineClass)\(openClass)" data-start="\(formatNumber(offset))" data-duration="\(formatNumber(duration))" title="\(htmlEscape(segment.title)) · \(timeRange(segment.start, segment.end)) · \(state)">
                      <strong>\(htmlEscape(segment.title))</strong><small>\(timeRange(segment.start, segment.end))</small>\(marker)
                    </div>
                    """
                }.joined(separator: "\n")
                return """
                <div class="gantt-row task-row">
                  <div class="row-label"><b>\(htmlEscape(first.title))</b><small>\(sourceText) · \(sortedSegments.count) \(localized("轮", sortedSegments.count == 1 ? "turn" : "turns")) · \(formatDuration(totalDuration, language: language))</small></div>
                  <div class="canvas">\(taskBars)<i class="now-line" data-start="\(formatNumber(nowMinute))"></i></div>
                </div>
                """
            }.joined(separator: "\n")

            return """
            <div class="tool-group"><div class="tool-heading"><span>\(htmlEscape(tool.displayName))</span><small>\(toolTasks.count) \(localized("个任务区间", toolTasks.count == 1 ? "task interval" : "task intervals"))</small></div>\(foregroundRow)\(sessionRows)</div>
            """
        }.joined(separator: "\n")
        let ganttContent = ganttRows.isEmpty
            ? "<div class=\"gantt-empty\">\(localized("今天还没有捕获到任务区间。新一轮对话会自动出现在这里。", "No task intervals captured yet. New turns will appear here automatically."))</div>"
            : ganttRows

        let replies = timeline.tasks.filter(\.completed).sorted { $0.end < $1.end }.map { segment in
            "<li><time>\(timeText(segment.end))</time><span class=\"dot tool-\(segment.tool.rawValue)\"></span><b>\(htmlEscape(segment.title))</b><em>\(localized("AI 在这里完成本轮", "AI completed this turn"))</em></li>"
        }.joined(separator: "\n")
        let replyList = replies.isEmpty
            ? "<li class=\"empty\">\(localized("今天还没有捕获到 AI 最终回复。", "No AI completions captured today."))</li>"
            : replies
        let filterBadge = includeBackground
            ? localized("含幕后任务", "Background included")
            : localized("已隐藏幕后任务", "Background hidden")
        let backgroundLegend = includeBackground
            ? "<span class=\"key back\">\(localized("幕后任务", "Background runs"))</span>"
            : ""
        let routineLegend = routineCompleted.isEmpty
            ? ""
            : "<span class=\"key routine\">\(localized("例行剑令", "Routine runs"))</span>"

        return """
        <!doctype html>
        <html lang="\(isEnglish ? "en" : "zh-CN")"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <title>\(localized("剑令日报", "Bladecall Daily Report")) · \(dateText)</title>
        <style>
        :root{color-scheme:light;--ink:#192033;--muted:#71788a;--line:#e7e9ef;--line-strong:#d5d9e2;--card:#fff;--bg:#f5f6fa;--orange:#f47a2a;--blue:#3488ff;--purple:#8664d9;--label-width:260px;--timeline-width:1872px;--grid-width:78px}
        *{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);font:14px -apple-system,BlinkMacSystemFont,"SF Pro Text","PingFang SC",sans-serif}.page{max-width:1540px;margin:0 auto;padding:32px 24px 70px}
        header{display:flex;align-items:flex-end;justify-content:space-between;margin-bottom:20px}h1{font-size:28px;margin:0 0 5px}header p{margin:0;color:var(--muted)}.badge{padding:7px 10px;border-radius:999px;background:#e9f6ee;color:#168547;font-weight:650}
        .metrics{display:grid;grid-template-columns:repeat(6,1fr);gap:10px;margin-bottom:16px}.metric{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:13px}.metric b{display:block;font-size:20px;font-variant-numeric:tabular-nums}.metric span{color:var(--muted);font-size:12px}
        .card{background:var(--card);border:1px solid var(--line);border-radius:16px;margin-top:14px;box-shadow:0 4px 16px rgba(36,44,75,.04);overflow:hidden}.card-head{display:flex;justify-content:space-between;align-items:flex-start;gap:16px;padding:16px 18px}.card h2{font-size:17px;margin:0 0 3px}.card-head p{margin:0;color:var(--muted);font-size:12px}.legend{display:flex;gap:12px;color:var(--muted);font-size:12px;white-space:nowrap}.key:before{content:"";display:inline-block;width:9px;height:9px;border-radius:3px;margin-right:5px}.key.fore:before{background:rgba(134,100,217,.34)}.key.run:before{background:var(--orange)}.key.routine:before{background:var(--purple)}.key.back:before{background:#929baa}.key.reply:before{background:var(--blue);border-radius:50%}
        .timeline-toolbar{display:flex;align-items:center;justify-content:space-between;gap:12px;padding:10px 18px;border-top:1px solid var(--line);background:#fafbfc}.timeline-toolbar .hint{color:var(--muted);font-size:12px}.scale-controls{display:flex;align-items:center;gap:7px}.scale-controls button{appearance:none;border:1px solid var(--line-strong);background:white;color:var(--ink);border-radius:8px;padding:6px 9px;font:inherit;font-size:12px;cursor:pointer}.scale-controls button:hover,.scale-controls button.active{border-color:var(--blue);color:var(--blue);background:#f2f7ff}.scale-controls input{width:126px;accent-color:var(--blue)}#scale-value{min-width:66px;text-align:right;color:var(--muted);font-size:12px;font-variant-numeric:tabular-nums}
        .gantt-scroll{overflow:auto;max-height:650px;border-top:1px solid var(--line);scrollbar-gutter:stable}.gantt-content{min-width:calc(var(--label-width) + var(--timeline-width));background:white}.ruler-row,.gantt-row{display:flex;min-width:max-content}.ruler-row{position:sticky;top:0;z-index:8;height:46px;border-bottom:1px solid var(--line-strong);background:white}.ruler-label,.row-label{position:sticky;left:0;z-index:5;flex:0 0 var(--label-width);width:var(--label-width);background:white;border-right:1px solid var(--line-strong)}.ruler-label{display:flex;align-items:center;padding:0 14px;font-size:12px;color:var(--muted);z-index:10}.ruler{position:relative;flex:0 0 var(--timeline-width);width:var(--timeline-width);height:46px}.tick{position:absolute;bottom:0;height:100%;border-left:1px solid var(--line);padding:8px 0 0 6px;color:var(--muted);font-size:11px;font-variant-numeric:tabular-nums;white-space:nowrap}.tick.major{border-left-color:var(--line-strong);color:var(--ink)}
        .tool-heading{position:sticky;left:0;z-index:7;width:var(--label-width);height:36px;display:flex;align-items:center;justify-content:space-between;padding:0 14px;background:#f2f4f7;border-right:1px solid var(--line-strong);font-weight:650}.tool-heading small{font-weight:400;color:var(--muted)}.tool-group{border-bottom:1px solid var(--line-strong);background:#f8f9fb}.gantt-row{height:58px;border-top:1px solid var(--line)}.row-label{display:flex;flex-direction:column;justify-content:center;padding:0 14px}.row-label b{overflow:hidden;text-overflow:ellipsis;white-space:nowrap;font-size:12px}.row-label small{margin-top:3px;color:var(--muted);font-size:10px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.canvas{position:relative;flex:0 0 var(--timeline-width);width:var(--timeline-width);height:58px;background-color:white;background-image:linear-gradient(to right,var(--line) 1px,transparent 1px);background-size:var(--grid-width) 100%}.foreground-row{height:42px}.foreground-row .canvas{height:42px}.foreground-row .row-label{background:#fbfaff}.bar{position:absolute;overflow:visible}.foreground-bar{top:14px;height:12px;border-radius:4px;background:rgba(134,100,217,.32);border-left:2px solid var(--purple)}.task-bar{top:10px;height:38px;border-radius:9px;background:var(--orange);color:white;padding:5px 9px;box-shadow:0 2px 6px rgba(244,122,42,.18);overflow:hidden}.task-bar.routine{background:var(--purple);box-shadow:0 2px 6px rgba(134,100,217,.18)}.task-bar.background{background:#929baa;box-shadow:none}.task-bar.open{outline:2px dashed rgba(255,255,255,.9);outline-offset:-3px}.task-bar strong{display:block;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;font-size:11px}.task-bar small{display:block;font-size:9px;opacity:.86;white-space:nowrap}.task-bar.is-small{padding:0}.task-bar.is-small strong,.task-bar.is-small small{display:none}.reply-dot{position:absolute;right:-5px;top:14px;width:10px;height:10px;border-radius:50%;background:var(--blue);border:2px solid white;box-shadow:0 0 0 1px var(--blue);z-index:4}.now-line{position:absolute;top:0;bottom:0;width:1px;background:var(--blue);opacity:.42;pointer-events:none}.gantt-empty{padding:50px;text-align:center;color:var(--muted)}
        .events-card{padding:0 18px 8px}.events{list-style:none;margin:0;padding:0}.events li{display:grid;grid-template-columns:56px 12px minmax(120px,1fr) 180px;gap:9px;align-items:center;padding:9px 4px;border-bottom:1px solid var(--line)}.events time{font-variant-numeric:tabular-nums;color:var(--muted)}.events .dot{width:8px;height:8px;background:var(--blue);border-radius:50%}.events em{font-style:normal;color:var(--muted);font-size:12px}.events .empty{display:block;color:var(--muted)}footer{margin-top:18px;color:var(--muted);font-size:12px}
        @media(max-width:760px){:root{--label-width:190px}.page{padding:20px 10px}.metrics{grid-template-columns:repeat(2,1fr)}.card-head,.timeline-toolbar{align-items:flex-start;flex-direction:column}.legend{white-space:normal;flex-wrap:wrap}.scale-controls{flex-wrap:wrap}.events li{grid-template-columns:48px 10px 1fr}.events em{display:none}}
        </style></head><body><main class="page">
        <header><div><h1>\(localized("剑令日报", "Bladecall Daily Report"))</h1><p>\(dateText) · \(localized("只看任务状态，不看对话内容", "Task status only. Conversation content stays private."))</p></div><span class="badge">\(filterBadge)</span></header>
        <section class="metrics">
          <div class="metric"><b>\(formatDuration(foregroundSeconds, language: language))</b><span>\(localized("前台使用", "Foreground time"))</span></div>
          <div class="metric"><b>\(completed.count)</b><span>\(localized("AI 最终回复", "AI completions"))</span></div>
          <div class="metric"><b>\(routineCompleted.count)</b><span>\(localized("例行复命", "Routine results"))</span></div>
          <div class="metric"><b>\(handled.count)</b><span>\(localized("人工处理", "Handled"))</span></div>
          <div class="metric"><b>\(pending)</b><span>\(localized("当前待处理", "Needs attention"))</span></div>
          <div class="metric"><b>\(formatDuration(aiSeconds, language: language))</b><span>\(localized("AI 任务累计（可重叠）", "AI runtime (may overlap)"))</span></div>
        </section>
        <section class="card"><div class="card-head"><div><h2>\(localized("一天横向时间轴", "Daily timeline"))</h2><p>\(localized("同一段对话排在一行；中间留白表示没有交互。", "Each conversation stays on one row; gaps indicate no interaction."))</p></div><div class="legend"><span class="key fore">\(localized("App 在前台", "App in foreground"))</span><span class="key run">\(localized("AI 工作中", "AI working"))</span>\(routineLegend)\(backgroundLegend)<span class="key reply">\(localized("本轮完成", "Turn completed"))</span></div></div>
          <div class="timeline-toolbar"><span class="hint">\(localized("触控板横移或拖动底部滚动条；按住 ⌘ 滚轮也可缩放。", "Scroll horizontally with a trackpad or the bottom scrollbar. Hold ⌘ while scrolling to zoom."))</span><div class="scale-controls" role="group" aria-label="\(localized("调整时间尺度", "Adjust timeline scale"))"><button type="button" data-fit="true">\(localized("适合窗口", "Fit to window"))</button><button type="button" data-ppm="1.3">\(localized("1 小时", "1 hour"))</button><button type="button" data-ppm="2.6">\(localized("30 分钟", "30 min"))</button><button type="button" data-ppm="5.2">\(localized("15 分钟", "15 min"))</button><input id="zoom" type="range" min="0.5" max="6" step="0.1" value="1.3" aria-label="\(localized("时间轴缩放", "Timeline zoom"))"><span id="scale-value">\(localized("1 小时/格", "60 min / grid"))</span></div></div>
          <div class="gantt-scroll" id="gantt-scroll"><div class="gantt-content" id="gantt-content"><div class="ruler-row"><div class="ruler-label">\(localized("会话 / 来源", "Conversation / source"))</div><div class="ruler" id="ruler"></div></div>\(ganttContent)</div></div>
        </section>
        <section class="card events-card"><div class="card-head"><h2>\(localized("回复节点", "Completion events"))</h2></div><ul class="events">\(replyList)</ul></section>
        <footer>\(localized("每个时间块在 AI 完成本轮时结束；之后等你查看或继续回复的时间不会算进工作时长。前台时间只表示当时哪个 App 在最前面。", "Each task block ends when AI completes the turn. Time spent waiting for you to review or reply is not counted as work time. Foreground time only indicates which app was frontmost."))</footer>
        </main><script>
        (() => {
          const scroll = document.getElementById('gantt-scroll');
          const content = document.getElementById('gantt-content');
          const ruler = document.getElementById('ruler');
          const zoom = document.getElementById('zoom');
          const scaleValue = document.getElementById('scale-value');
          const labelWidth = () => parseFloat(getComputedStyle(document.documentElement).getPropertyValue('--label-width')) || 260;
          let ppm = 1.3;

          function gridStep(value) { return value >= 4 ? 15 : value >= 2 ? 30 : 60; }
          function renderRuler(step) {
            ruler.replaceChildren();
            for (let minute = 0; minute <= 1440; minute += step) {
              const tick = document.createElement('span');
              tick.className = 'tick' + (minute % 60 === 0 ? ' major' : '');
              tick.style.left = `${minute * ppm}px`;
              const hour = Math.floor(minute / 60) % 24;
              const minutes = minute % 60;
              tick.textContent = `${String(hour).padStart(2,'0')}:${String(minutes).padStart(2,'0')}`;
              ruler.appendChild(tick);
            }
          }
          function applyScale(next, preserve = true) {
            const previous = ppm;
            const centerMinute = Math.max(0, (scroll.scrollLeft + scroll.clientWidth / 2 - labelWidth()) / previous);
            ppm = Math.max(0.5, Math.min(6, Number(next)));
            const step = gridStep(ppm);
            document.documentElement.style.setProperty('--timeline-width', `${1440 * ppm}px`);
            document.documentElement.style.setProperty('--grid-width', `${step * ppm}px`);
            document.querySelectorAll('[data-start]').forEach(el => {
              const start = Number(el.dataset.start || 0);
              el.style.left = `${start * ppm}px`;
              if (el.dataset.duration) {
                const width = Math.max(8, Number(el.dataset.duration) * ppm);
                el.style.width = `${width}px`;
                el.classList.toggle('is-small', width < 70);
              }
            });
            renderRuler(step);
            zoom.value = String(ppm);
            scaleValue.textContent = `${step} \(localized("分钟/格", "min / grid"))`;
            document.querySelectorAll('[data-ppm]').forEach(button => button.classList.toggle('active', Math.abs(Number(button.dataset.ppm) - ppm) < .08));
            if (preserve) scroll.scrollLeft = Math.max(0, labelWidth() + centerMinute * ppm - scroll.clientWidth / 2);
          }
          function fitDay() {
            applyScale(Math.max(.5, (scroll.clientWidth - labelWidth() - 12) / 1440), false);
            scroll.scrollLeft = 0;
          }
          zoom.addEventListener('input', event => applyScale(event.target.value));
          document.querySelectorAll('[data-ppm]').forEach(button => button.addEventListener('click', () => applyScale(button.dataset.ppm)));
          document.querySelector('[data-fit]').addEventListener('click', fitDay);
          scroll.addEventListener('wheel', event => {
            if (!(event.metaKey || event.ctrlKey)) return;
            event.preventDefault();
            applyScale(ppm + (event.deltaY < 0 ? .25 : -.25));
          }, {passive:false});
          applyScale(ppm, false);
          const starts = [...document.querySelectorAll('.task-bar[data-start]')].map(el => Number(el.dataset.start));
          if (starts.length) scroll.scrollLeft = Math.max(0, labelWidth() + Math.min(...starts) * ppm - 120);
        })();
        </script></body></html>
        """
    }

    private func pendingTurnIDs(records: [ActivityRecord], before end: Date) -> Set<String> {
        var pending: Set<String> = []
        for record in records.filter({ $0.timestamp < end }).sorted(by: { $0.timestamp < $1.timestamp }) {
            guard let turnID = record.turnID else { continue }
            if record.kind == .assistantCompleted { pending.insert(turnID) }
            if record.kind == .handled { pending.remove(turnID) }
        }
        return pending
    }

    private func totalForeground(_ records: [ActivityRecord], start: Date, end: Date) -> TimeInterval {
        records.compactMap { clippedDuration($0, start: start, end: end) }.reduce(0, +)
    }

    private func overlaps(_ record: ActivityRecord, start: Date, end: Date) -> Bool {
        guard let interval = interval(record, start: .distantPast, end: .distantFuture) else { return false }
        return interval.0 < end && interval.1 > start
    }

    private func clippedDuration(_ record: ActivityRecord, start: Date, end: Date) -> TimeInterval? {
        interval(record, start: start, end: end).map { max(0, $0.1.timeIntervalSince($0.0)) }
    }

    private func interval(_ record: ActivityRecord, start: Date, end: Date) -> (Date, Date)? {
        guard let rawStart = record.startedAt else { return nil }
        let rawEnd = record.durationSeconds.map { rawStart.addingTimeInterval($0) } ?? record.timestamp
        let clippedStart = max(rawStart, start)
        let clippedEnd = min(rawEnd, end)
        guard clippedEnd > clippedStart else { return nil }
        return (clippedStart, clippedEnd)
    }

    private func unionDuration(_ intervals: [(Date, Date)]) -> TimeInterval {
        let sorted = intervals.sorted { $0.0 < $1.0 }
        guard var current = sorted.first else { return 0 }
        var total: TimeInterval = 0
        for next in sorted.dropFirst() {
            if next.0 <= current.1 {
                current.1 = max(current.1, next.1)
            } else {
                total += current.1.timeIntervalSince(current.0)
                current = next
            }
        }
        total += current.1.timeIntervalSince(current.0)
        return total
    }

    private func formatDuration(
        _ seconds: TimeInterval,
        language: DailyReportLanguage = .chinese
    ) -> String {
        let minutes = max(0, Int(seconds.rounded() / 60))
        if language == .english {
            if minutes < 60 { return "\(minutes) min" }
            let hours = minutes / 60
            let remainder = minutes % 60
            return remainder == 0 ? "\(hours) hr" : "\(hours) hr \(remainder) min"
        }
        if minutes < 60 { return "\(minutes) 分钟" }
        return "\(minutes / 60) 小时 \(minutes % 60) 分钟"
    }

    private func blockGeometry(
        start: Date,
        end: Date,
        day: Date,
        startHour: Int,
        pixelsPerMinute: Double,
        calendar: Calendar
    ) -> (top: String, height: Double) {
        let anchor = calendar.date(byAdding: .hour, value: startHour, to: day) ?? day
        let top = max(0, start.timeIntervalSince(anchor) / 60 * pixelsPerMinute)
        let height = max(7, end.timeIntervalSince(start) / 60 * pixelsPerMinute)
        return (formatNumber(top), height)
    }

    private func timeRange(_ start: Date, _ end: Date) -> String {
        "\(timeText(start))–\(timeText(end))"
    }

    private func timeText(_ date: Date) -> String {
        Self.timeFormatter.string(from: date)
    }

    private func formatNumber(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    private func htmlEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
