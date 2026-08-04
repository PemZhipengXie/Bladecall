import AppKit
import CompletionBellCore
import Foundation

enum RuntimePaths {
    static let applicationSupportDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/CompletionBell", isDirectory: true)
    static let inboxStateURL = applicationSupportDirectory.appendingPathComponent("inbox-state.json")
    static let activityLogURL = applicationSupportDirectory.appendingPathComponent("activity.jsonl")
    static let reportsDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Documents/AI会话监控浮窗/日报", isDirectory: true)
}

@MainActor
final class ForegroundUsageTracker {
    private let store: ActivityLogStore
    private let workspace = NSWorkspace.shared
    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?
    private var activeTool: ToolKind?
    private var intervalStartedAt: Date?

    init(store: ActivityLogStore) {
        self.store = store
    }

    func start() {
        guard observers.isEmpty else { return }
        let center = workspace.notificationCenter
        observers.append(center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            Task { @MainActor in self?.switchTo(bundleIdentifier: application.bundleIdentifier, at: Date()) }
        })
        observers.append(center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.pause(at: Date()) }
        })
        observers.append(center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.resume(at: Date()) }
        })

        switchTo(bundleIdentifier: workspace.frontmostApplication?.bundleIdentifier, at: Date())
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkpoint(at: Date()) }
        }
    }

    func stop() {
        pause(at: Date())
        timer?.invalidate()
        timer = nil
        let center = workspace.notificationCenter
        for observer in observers { center.removeObserver(observer) }
        observers.removeAll()
    }

    func checkpoint(at now: Date = Date()) {
        guard let tool = activeTool else { return }
        closeInterval(at: now)
        activeTool = tool
        intervalStartedAt = now
    }

    private func pause(at now: Date) {
        closeInterval(at: now)
        activeTool = nil
        intervalStartedAt = nil
    }

    private func resume(at now: Date) {
        switchTo(bundleIdentifier: workspace.frontmostApplication?.bundleIdentifier, at: now)
    }

    private func switchTo(bundleIdentifier: String?, at now: Date) {
        closeInterval(at: now)
        activeTool = ToolKind.allCases.first { $0.bundleIdentifier == bundleIdentifier }
        intervalStartedAt = activeTool == nil ? nil : now
    }

    private func closeInterval(at end: Date) {
        guard let tool = activeTool, let startedAt = intervalStartedAt else { return }
        let duration = max(0, end.timeIntervalSince(startedAt))
        if duration >= 0.5 {
            store.append(ActivityRecord(
                kind: .appForeground,
                timestamp: end,
                startedAt: startedAt,
                durationSeconds: duration,
                tool: tool
            ))
        }
    }
}

final class DailyReportService: @unchecked Sendable {
    private let store: ActivityLogStore
    private let reportsDirectory: URL
    private let generator = DailyReportGenerator()
    private let calendar: Calendar
    private let generationQueue = DispatchQueue(label: "completion-bell.daily-report", qos: .utility)

    init(store: ActivityLogStore, reportsDirectory: URL = RuntimePaths.reportsDirectory, calendar: Calendar = .current) {
        self.store = store
        self.reportsDirectory = reportsDirectory
        self.calendar = calendar
    }

    func generateMissingReportsAsync(includeBackground: Bool, now: Date = Date()) {
        generationQueue.async { [weak self] in
            self?.generateMissingReports(includeBackground: includeBackground, now: now)
        }
    }

    func generateMissingReports(includeBackground: Bool, now: Date = Date()) {
        let records = store.records()
        guard let earliest = records.compactMap({ $0.startedAt ?? $0.timestamp }).min() else { return }
        let today = calendar.startOfDay(for: now)
        var day = calendar.startOfDay(for: earliest)
        while day < today {
            let urls = reportURLs(for: day)
            if !FileManager.default.fileExists(atPath: urls.markdown.path)
                || !FileManager.default.fileExists(atPath: urls.html.path)
                || !FileManager.default.fileExists(atPath: urls.englishHTML.path)
                || needsHTMLTemplateUpgrade(at: urls.html)
                || needsHTMLTemplateUpgrade(at: urls.englishHTML) {
                writeReports(
                    for: day,
                    records: records,
                    currentSessions: [],
                    includeBackground: includeBackground,
                    now: now
                )
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
    }

    private func needsHTMLTemplateUpgrade(at url: URL) -> Bool {
        guard let html = try? String(contentsOf: url, encoding: .utf8) else { return true }
        return !DailyReportGenerator.isCurrentHTMLTemplate(html)
    }

    func latestReportURL() -> URL? {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: reportsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return urls.filter { $0.pathExtension == "html" }.sorted { $0.lastPathComponent > $1.lastPathComponent }.first
    }

    func openTodayReport(
        currentSessions: [SessionSnapshot],
        includeBackground: Bool,
        language: DailyReportLanguage = .chinese,
        now: Date = Date()
    ) {
        do {
            try FileManager.default.createDirectory(at: reportsDirectory, withIntermediateDirectories: true)
        } catch {
            return
        }
        let day = calendar.startOfDay(for: now)
        writeReports(
            for: day,
            records: store.records(),
            currentSessions: currentSessions,
            includeBackground: includeBackground,
            now: now
        )
        let urls = reportURLs(for: day)
        NSWorkspace.shared.open(language == .english ? urls.englishHTML : urls.html)
    }

    func regenerateReportIfClosedDay(
        _ day: Date,
        includeBackground: Bool,
        now: Date = Date()
    ) {
        let target = calendar.startOfDay(for: day)
        guard target < calendar.startOfDay(for: now) else { return }
        writeReports(
            for: target,
            records: store.records(),
            currentSessions: [],
            includeBackground: includeBackground,
            now: now
        )
    }

    private func reportURLs(for day: Date) -> (markdown: URL, html: URL, englishHTML: URL) {
        let date = Self.dayFormatter.string(from: day)
        let name = "\(date)_剑令日报"
        return (
            reportsDirectory.appendingPathComponent("\(name).md"),
            reportsDirectory.appendingPathComponent("\(name).html"),
            reportsDirectory.appendingPathComponent("\(date)_Bladecall_Daily_Report_EN.html")
        )
    }

    private func writeReports(
        for day: Date,
        records: [ActivityRecord],
        currentSessions: [SessionSnapshot],
        includeBackground: Bool,
        now: Date
    ) {
        do {
            try FileManager.default.createDirectory(at: reportsDirectory, withIntermediateDirectories: true)
            let urls = reportURLs(for: day)
            let markdown = generator.markdown(
                for: day,
                records: records,
                includeBackground: includeBackground,
                calendar: calendar
            )
            let html = generator.html(
                for: day,
                records: records,
                currentSessions: currentSessions,
                includeBackground: includeBackground,
                now: now,
                calendar: calendar
            )
            let englishHTML = generator.html(
                for: day,
                records: records,
                currentSessions: currentSessions,
                includeBackground: includeBackground,
                language: .english,
                now: now,
                calendar: calendar
            )
            try markdown.write(to: urls.markdown, atomically: true, encoding: .utf8)
            try html.write(to: urls.html, atomically: true, encoding: .utf8)
            try englishHTML.write(to: urls.englishHTML, atomically: true, encoding: .utf8)
            AppLogger.shared.write("daily_report_generated", fields: [
                "date": Self.dayFormatter.string(from: day),
                "path": urls.html.path,
                "include_background": includeBackground
            ])
        } catch {
            AppLogger.shared.write("daily_report_error", fields: ["error": error.localizedDescription])
        }
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
