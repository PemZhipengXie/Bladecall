import AppKit
import CompletionBellCore
import Foundation
import JianlingShared
import UserNotifications

@MainActor
final class AppState: ObservableObject {
    @Published var sessions: [SessionSnapshot] = []
    @Published var attentionStates: [String: AttentionState] = [:]
    @Published var language: JianlingLanguage {
        didSet {
            defaults.set(language.rawValue, forKey: Keys.language)
            JianlingSharedPreferences.appLanguage = language
            monitorStatus = language.text("监控中", "Monitoring")
            onLanguageChanged?()
        }
    }
    @Published var appearance: JianlingAppearance {
        didSet { defaults.set(appearance.rawValue, forKey: Keys.appearance) }
    }
    @Published var presentationMode: PresentationMode {
        didSet {
            defaults.set(presentationMode.rawValue, forKey: Keys.presentationMode)
            guard oldValue != presentationMode else { return }
            onPresentationModeChanged?(oldValue, presentationMode)
        }
    }
    @Published var notchScreenChoices: [EdgeScreenChoice] = []
    @Published var notchScreenID: String? {
        didSet {
            guard oldValue != notchScreenID else { return }
            if let notchScreenID {
                defaults.set(notchScreenID, forKey: Keys.notchScreenID)
            } else {
                defaults.removeObject(forKey: Keys.notchScreenID)
            }
            onNotchScreenChanged?(notchScreenID)
        }
    }
    @Published var notchPinned: Bool {
        didSet {
            defaults.set(notchPinned, forKey: Keys.notchPinned)
            onNotchPinnedChanged?(notchPinned)
        }
    }
    /// Display roster for the right-edge tag, published independently of the
    /// host so Settings can offer the choice even while another mode is active.
    @Published var edgeScreenChoices: [EdgeScreenChoice] = []
    @Published var edgeScreenID: String? {
        didSet {
            guard oldValue != edgeScreenID else { return }
            if let edgeScreenID {
                defaults.set(edgeScreenID, forKey: "jianlingRightEdgeScreenID")
            } else {
                defaults.removeObject(forKey: "jianlingRightEdgeScreenID")
            }
            onEdgeScreenChanged?(edgeScreenID)
        }
    }
    @Published var edgeTagSize: EdgeTagSize {
        didSet {
            guard oldValue != edgeTagSize else { return }
            defaults.set(edgeTagSize.rawValue, forKey: Keys.edgeTagSize)
            onEdgeTagSizeChanged?()
        }
    }
    @Published var edgePinned: Bool {
        didSet {
            defaults.set(edgePinned, forKey: Keys.edgePinned)
            onEdgePinnedChanged?(edgePinned)
        }
    }
    @Published var noticeStyle: CompletionNoticeStyle {
        didSet { defaults.set(noticeStyle.rawValue, forKey: Keys.noticeStyle) }
    }
    @Published var motionEnabled: Bool {
        didSet { defaults.set(motionEnabled, forKey: Keys.motionEnabled) }
    }
    @Published var systemNotificationsEnabled: Bool {
        didSet {
            defaults.set(systemNotificationsEnabled, forKey: Keys.systemNotificationsEnabled)
            if systemNotificationsEnabled { notifier.requestAuthorization() }
        }
    }
    @Published var quietHoursEnabled: Bool {
        didSet { defaults.set(quietHoursEnabled, forKey: Keys.quietHours) }
    }
    @Published var displayName: String {
        didSet { defaults.set(displayName, forKey: Keys.displayName) }
    }
    @Published var organization: String {
        didSet { defaults.set(organization, forKey: Keys.organization) }
    }
    @Published var reportSignature: String {
        didSet { defaults.set(reportSignature, forKey: Keys.reportSignature) }
    }
    @Published var fontScale: Double {
        didSet { defaults.set(fontScale, forKey: Keys.fontScale) }
    }
    @Published var sheathSoundEnabled: Bool {
        didSet { defaults.set(sheathSoundEnabled, forKey: Keys.sheathSoundEnabled) }
    }
    @Published var hideBackgroundInReports: Bool {
        didSet {
            defaults.set(hideBackgroundInReports, forKey: Keys.hideBackgroundInReports)
            publishSharedSnapshot()
        }
    }
    @Published var iCloudSyncEnabled: Bool {
        didSet {
            defaults.set(iCloudSyncEnabled, forKey: Keys.iCloudSyncEnabled)
            JianlingSharedPreferences.iCloudSyncEnabled = iCloudSyncEnabled
            onCloudSyncChanged?(iCloudSyncEnabled)
        }
    }
    @Published var energyEnabled: Bool {
        didSet { defaults.set(energyEnabled, forKey: Keys.energyEnabled) }
    }
    @Published var codexEnergyEnabled: Bool {
        didSet { defaults.set(codexEnergyEnabled, forKey: Keys.codexEnergyEnabled) }
    }
    @Published var claudeEnergyEnabled: Bool {
        didSet { defaults.set(claudeEnergyEnabled, forKey: Keys.claudeEnergyEnabled) }
    }
    @Published var disabledQuotaWindowIDs: Set<String> {
        didSet { defaults.set(Array(disabledQuotaWindowIDs).sorted(), forKey: Keys.disabledQuotaWindowIDs) }
    }
    @Published var quotaProviders: [QuotaProviderSnapshot] = []
    @Published var quotaLastUpdated: Date?
    @Published var quotaRefreshing = true
    @Published var sessionRefreshing = false
    @Published var sessionLastRefreshed: Date?
    @Published var expandedGroupIDs: Set<String> = []
    @Published private(set) var snoozedSessionIDs: Set<String> = []
    @Published var floatingAlwaysOnTop: Bool {
        didSet {
            defaults.set(floatingAlwaysOnTop, forKey: Keys.floatingAlwaysOnTop)
            onFloatingPinChanged?(floatingAlwaysOnTop)
        }
    }
    @Published var dockIconVisible: Bool {
        didSet {
            defaults.set(dockIconVisible, forKey: Keys.dockIconVisible)
            onDockIconChanged?(dockIconVisible)
        }
    }
    @Published var monitorStatus = "正在启动"
    @Published var lastScanDuration: TimeInterval = 0
    @Published var parseErrorCount = 0
    @Published var notificationAuthorization: UNAuthorizationStatus = .notDetermined
    @Published var todayHandledCount = 0
    @Published var todayTimeline = DailyTimeline(tasks: [], foreground: [], startHour: 8, endHour: 20)
    @Published var pairingCodeText = "------"
    @Published var phoneConnectionStatus = "正在启动同网连接"
    @Published var iCloudSyncStatus = "未开启，状态只在同网同步"

    var onOpenSettings: (() -> Void)?
    var onQuit: (() -> Void)?
    var onBadgeChanged: ((Int) -> Void)?
    var onSharedSnapshotChanged: ((JianlingInboxSnapshot) -> Void)?
    var onCloudSyncChanged: ((Bool) -> Void)?
    var onLanguageChanged: (() -> Void)?
    var onRefreshQuota: (() -> Void)?
    var onRefreshSessions: (() -> Void)?
    var onFloatingPinChanged: ((Bool) -> Void)?
    var onDockIconChanged: ((Bool) -> Void)?
    var onPresentationModeChanged: ((PresentationMode, PresentationMode) -> Void)?
    var onNotchPinnedChanged: ((Bool) -> Void)?
    var onNotchScreenChanged: ((String?) -> Void)?
    var onEdgePinnedChanged: ((Bool) -> Void)?
    var onEdgeScreenChanged: ((String?) -> Void)?
    var onEdgeTagSizeChanged: (() -> Void)?
    var onSessionOpened: (() -> Void)?

    private enum Keys {
        static let language = "jianlingLanguage"
        static let appearance = "jianlingAppearance"
        static let presentationMode = "jianlingPresentationMode"
        static let notchPinned = "jianlingNotchPinned"
        static let notchScreenID = "jianlingNotchScreenID"
        static let edgePinned = "jianlingEdgePinned"
        static let edgeTagSize = "jianlingEdgeTagSize"
        static let noticeStyle = "jianlingNoticeStyle"
        static let motionEnabled = "jianlingMotionEnabled"
        static let systemNotificationsEnabled = "jianlingSystemNotificationsEnabled"
        static let quietHours = "quietHoursEnabled"
        static let displayName = "jianlingDisplayName"
        static let organization = "jianlingOrganization"
        static let reportSignature = "jianlingReportSignature"
        static let fontScale = "jianlingFontScale"
        static let sheathSoundEnabled = "jianlingSheathSoundEnabled"
        static let hideBackgroundInReports = "jianlingHideBackgroundInReports"
        static let iCloudSyncEnabled = "jianlingICloudSyncEnabled"
        static let energyEnabled = "jianlingEnergyEnabled"
        static let codexEnergyEnabled = "jianlingCodexEnergyEnabled"
        static let claudeEnergyEnabled = "jianlingClaudeEnergyEnabled"
        static let disabledQuotaWindowIDs = "jianlingDisabledQuotaWindowIDs"
        static let floatingAlwaysOnTop = "jianlingFloatingAlwaysOnTop"
        static let dockIconVisible = "jianlingDockIconVisible"
    }

    private let defaults = UserDefaults.standard
    private let notifier: NotificationService
    private let inboxStore: InboxStateStore
    private let activityStore: ActivityLogStore
    private let reportService: DailyReportService
    private let sharedStore: JianlingSharedStore
    private let displayPolicy = SessionDisplayPolicy()
    private let timelineBuilder = DailyTimelineBuilder()
    private var sharedRevision: Int64 = 0
    private var didLogSharedSnapshot = false
    private var lastDisplayFingerprint: DisplayFingerprint?
    private var lastPublishedSnapshot: JianlingInboxSnapshot?

    init(
        notifier: NotificationService,
        inboxStore: InboxStateStore,
        activityStore: ActivityLogStore,
        reportService: DailyReportService,
        sharedStore: JianlingSharedStore = JianlingSharedStore()
    ) {
        self.notifier = notifier
        self.inboxStore = inboxStore
        self.activityStore = activityStore
        self.reportService = reportService
        self.sharedStore = sharedStore
        self.language = JianlingLanguage(
            rawValue: defaults.string(forKey: Keys.language) ?? ""
        ) ?? JianlingSharedPreferences.appLanguage
        self.appearance = JianlingAppearance(rawValue: defaults.string(forKey: Keys.appearance) ?? "") ?? .modern
        self.presentationMode = PresentationMode(rawValue: defaults.string(forKey: Keys.presentationMode) ?? "") ?? .floating
        self.notchPinned = defaults.object(forKey: Keys.notchPinned) as? Bool ?? false
        self.edgePinned = defaults.object(forKey: Keys.edgePinned) as? Bool ?? false
        self.edgeTagSize = (defaults.string(forKey: Keys.edgeTagSize)).flatMap(EdgeTagSize.init(rawValue:)) ?? .medium
        self.noticeStyle = CompletionNoticeStyle(rawValue: defaults.string(forKey: Keys.noticeStyle) ?? "") ?? .quiet
        self.motionEnabled = defaults.object(forKey: Keys.motionEnabled) as? Bool ?? true
        self.systemNotificationsEnabled = defaults.object(forKey: Keys.systemNotificationsEnabled) as? Bool ?? false
        self.quietHoursEnabled = defaults.object(forKey: Keys.quietHours) as? Bool ?? true
        self.floatingAlwaysOnTop = defaults.object(forKey: Keys.floatingAlwaysOnTop) as? Bool ?? true
        self.dockIconVisible = defaults.object(forKey: Keys.dockIconVisible) as? Bool ?? false
        self.displayName = defaults.string(forKey: Keys.displayName) ?? ""
        self.organization = defaults.string(forKey: Keys.organization) ?? ""
        self.reportSignature = defaults.string(forKey: Keys.reportSignature) ?? ""
        self.fontScale = min(1.25, max(0.85, defaults.object(forKey: Keys.fontScale) as? Double ?? 1))
        self.sheathSoundEnabled = defaults.object(forKey: Keys.sheathSoundEnabled) as? Bool ?? true
        self.hideBackgroundInReports = defaults.object(forKey: Keys.hideBackgroundInReports) as? Bool ?? true
        self.iCloudSyncEnabled = defaults.object(forKey: Keys.iCloudSyncEnabled) as? Bool
            ?? JianlingSharedPreferences.iCloudSyncEnabled
        self.energyEnabled = defaults.object(forKey: Keys.energyEnabled) as? Bool ?? true
        self.codexEnergyEnabled = defaults.object(forKey: Keys.codexEnergyEnabled) as? Bool ?? true
        self.claudeEnergyEnabled = defaults.object(forKey: Keys.claudeEnergyEnabled) as? Bool ?? true
        self.disabledQuotaWindowIDs = Set(defaults.stringArray(forKey: Keys.disabledQuotaWindowIDs) ?? [])
        let records = activityStore.records()
        self.todayHandledCount = Self.handledCountToday(in: records)
        self.todayTimeline = timelineBuilder.build(for: Date(), records: records)
        self.monitorStatus = language.text("正在启动", "Starting")
        self.phoneConnectionStatus = language.text("正在启动同网连接", "Starting local connection")
        self.iCloudSyncStatus = language.text("未开启，状态只在同网同步", "Off · syncing only on the same network")
    }

    var unreadCount: Int {
        attentionStates.filter { $0.value == .unread && !snoozedSessionIDs.contains($0.key) }.count
    }

    var pendingCount: Int {
        attentionStates.filter { $0.value.needsUserAttention && !snoozedSessionIDs.contains($0.key) }.count
    }

    var decisionCount: Int {
        attentionStates.filter { $0.value == .pending && !snoozedSessionIDs.contains($0.key) }.count
    }

    var snoozedCount: Int { snoozedSessionIDs.count }

    var totalVisibleCount: Int { visibleSessions.count }

    var visibleQuotaProviders: [QuotaProviderSnapshot] {
        guard energyEnabled else { return [] }
        return QuotaProvider.allCases.compactMap { provider in
            guard isQuotaProviderEnabled(provider),
                  let snapshot = quotaProviders.first(where: { $0.provider == provider }),
                  snapshot.availability == .ready else { return nil }
            let windows = snapshot.windows.filter { isQuotaWindowEnabled($0) }
            guard !windows.isEmpty else { return nil }
            return QuotaProviderSnapshot(
                provider: snapshot.provider,
                availability: snapshot.availability,
                windows: windows,
                updatedAt: snapshot.updatedAt
            )
        }
    }

    var activeSessions: [SessionSnapshot] {
        sorted(sessions.filter { displayBucket(for: $0) == .active && !isSnoozed($0) })
    }

    var pendingSessions: [SessionSnapshot] {
        sorted(sessions.filter { displayBucket(for: $0) == .pending && !isSnoozed($0) })
    }

    var inboxSessions: [SessionSnapshot] {
        sorted(activeSessions + pendingSessions)
    }

    var activeCount: Int { activeSessions.count }

    var routineSessions: [SessionSnapshot] {
        sorted(sessions.filter { displayBucket(for: $0) == .routine && !isSnoozed($0) })
    }

    var routineUnreadCount: Int {
        routineSessions.filter { attentionState(for: $0) == .unread }.count
    }

    var routineRunningCount: Int {
        routineSessions.filter { attentionState(for: $0) == .running }.count
    }

    var backgroundSessions: [SessionSnapshot] {
        sorted(sessions.filter { displayBucket(for: $0) == .background && !isSnoozed($0) })
    }

    func isSnoozed(_ session: SessionSnapshot) -> Bool {
        snoozedSessionIDs.contains(session.id)
    }

    var backgroundUnreadCount: Int {
        backgroundSessions.filter { attentionState(for: $0) == .unread }.count
    }

    func interactiveSessions(for tool: ToolKind) -> [SessionSnapshot] {
        inboxSessions.filter { $0.tool == tool }
    }

    func counts(for tool: ToolKind) -> (running: Int, pending: Int) {
        let values = interactiveSessions(for: tool)
        return (
            values.filter { attentionState(for: $0) == .running }.count,
            values.filter { attentionState(for: $0).needsUserAttention }.count
        )
    }

    var backgroundCounts: (running: Int, pending: Int) {
        (
            backgroundSessions.filter { attentionState(for: $0) == .running }.count,
            backgroundSessions.filter { attentionState(for: $0).needsUserAttention }.count
        )
    }

    func displayBucket(for session: SessionSnapshot, now: Date = Date()) -> SessionDisplayBucket {
        displayPolicy.bucket(for: session, attention: attentionState(for: session), now: now)
    }

    func isStalled(_ session: SessionSnapshot, now: Date = Date()) -> Bool {
        displayPolicy.isStalled(session, attention: attentionState(for: session), now: now)
    }

    var notificationStatusText: String {
        guard systemNotificationsEnabled else { return text("系统通知已关闭", "System notifications are off") }
        switch notificationAuthorization {
        case .authorized, .provisional, .ephemeral: return text("系统通知已开启", "System notifications are on")
        case .denied: return notifier.fallbackAvailable
            ? text("通知兼容模式", "Compatibility notification mode")
            : text("系统通知被拒绝", "System notifications denied")
        case .notDetermined: return text("等待系统授权", "Waiting for permission")
        @unknown default: return text("通知状态未知", "Notification status unavailable")
        }
    }

    func text(_ chinese: String, _ english: String) -> String {
        language.text(chinese, english)
    }

    func applyQuota(_ update: QuotaMonitorService.Update) {
        quotaProviders = update.providers
        quotaLastUpdated = update.refreshedAt
        quotaRefreshing = false
    }

    func refreshQuota() {
        quotaRefreshing = true
        onRefreshQuota?()
    }

    func refreshSessions() {
        guard !sessionRefreshing else { return }
        sessionRefreshing = true
        monitorStatus = text("正在刷新", "Refreshing")
        onRefreshSessions?()
    }

    func quotaSnapshot(for provider: QuotaProvider) -> QuotaProviderSnapshot? {
        quotaProviders.first { $0.provider == provider }
    }

    func isQuotaProviderEnabled(_ provider: QuotaProvider) -> Bool {
        switch provider {
        case .codex: return codexEnergyEnabled
        case .claude: return claudeEnergyEnabled
        }
    }

    func setQuotaProvider(_ provider: QuotaProvider, enabled: Bool) {
        switch provider {
        case .codex: codexEnergyEnabled = enabled
        case .claude: claudeEnergyEnabled = enabled
        }
    }

    func isQuotaWindowEnabled(_ window: QuotaWindowSnapshot) -> Bool {
        !disabledQuotaWindowIDs.contains(window.id)
    }

    func setQuotaWindow(_ window: QuotaWindowSnapshot, enabled: Bool) {
        if enabled {
            disabledQuotaWindowIDs.remove(window.id)
        } else {
            disabledQuotaWindowIDs.insert(window.id)
        }
    }

    var notificationUnavailable: Bool {
        systemNotificationsEnabled && notificationAuthorization == .denied && !notifier.fallbackAvailable
    }

    func apply(_ update: MonitorService.Update) {
        // Idle short-circuit: adapter output is identical to the previous
        // round, so state, disk, and network can't have anything new. The
        // display fingerprint still gates the skip because buckets decay with
        // wall-clock time (15 min / 6 h / midnight); when a session crosses a
        // boundary, one full pass runs to refresh the UI.
        if update.unchangedSinceLastScan && !update.isManualRefresh {
            let now = Date()
            let fingerprint = DisplayFingerprint.compute(
                sessions: sessions,
                attentionStates: attentionStates,
                activeSnoozeIDs: inboxStore.activeSnoozes(now: now),
                policy: displayPolicy,
                now: now
            )
            if fingerprint == lastDisplayFingerprint { return }
        }

        sessions = update.sessions.sorted { $0.lastActivity > $1.lastActivity }
        lastScanDuration = update.scanDuration
        if parseErrorCount != update.errors.count {
            parseErrorCount = update.errors.count
        }
        if update.isManualRefresh {
            sessionRefreshing = false
            sessionLastRefreshed = Date()
            monitorStatus = update.errors.count > 10
                ? text("刷新完成，部分数据异常", "Refreshed · some data needs attention")
                : text("刷新完成", "Refreshed")
        } else {
            let status = update.errors.count > 10
                ? text("部分数据源异常", "Some sources need attention")
                : text("监控中", "Monitoring")
            if monitorStatus != status {
                monitorStatus = status
            }
        }

        let reconciliation = inboxStore.reconcile(sessions, at: Date())
        if attentionStates != reconciliation.attentionStates {
            attentionStates = reconciliation.attentionStates
        }
        // Reconcile above already cleared expired snoozes, so this set is the
        // authoritative "still pushed away" view for badge/list/snapshot.
        let activeSnoozes = inboxStore.activeSnoozes(now: Date())
        if snoozedSessionIDs != activeSnoozes {
            snoozedSessionIDs = activeSnoozes
        }
        for transition in reconciliation.transitions {
            activityStore.append(ActivityRecord(transition: transition))
            reportService.regenerateReportIfClosedDay(
                transition.timestamp,
                includeBackground: !hideBackgroundInReports
            )
            if transition.kind == .handled && Calendar.current.isDateInToday(transition.timestamp) {
                todayHandledCount += 1
            }
            let dispatchDelay = Date().timeIntervalSince(transition.timestamp)
            if transition.kind == .taskStarted,
               transition.session.origin == .interactive,
               noticeStyle == .chime,
               dispatchDelay >= 0,
               dispatchDelay < 15 {
                notifier.playDispatchSound()
            }
        }
        for event in reconciliation.completionEvents {
            AppLogger.shared.write("assistant_final_detected", fields: [
                "event_id": event.id,
                "session_id": event.session.id,
                "tool": event.session.tool.rawValue,
                "origin": event.session.origin.rawValue,
                "delay_seconds": max(0, event.detectedAt.timeIntervalSince(event.session.lastActivity))
            ])
            route(event)
        }
        let timeline = timelineBuilder.build(
            for: Date(),
            records: activityStore.records(),
            currentSessions: sessions,
            now: Date()
        )
        if todayTimeline != timeline {
            todayTimeline = timeline
        }
        onBadgeChanged?(unreadCount)
        publishSharedSnapshot()
        lastDisplayFingerprint = DisplayFingerprint.compute(
            sessions: sessions,
            attentionStates: attentionStates,
            activeSnoozeIDs: snoozedSessionIDs,
            policy: displayPolicy,
            now: Date()
        )
    }

    func attentionState(for session: SessionSnapshot) -> AttentionState {
        attentionStates[session.id] ?? (session.status == .running ? .running : .handled)
    }

    func markRead(_ session: SessionSnapshot) {
        guard performMarkRead(session, playSound: true) else { return }
        onBadgeChanged?(unreadCount)
        publishSharedSnapshot()
    }

    @discardableResult
    private func performMarkRead(_ session: SessionSnapshot, playSound: Bool = false) -> Bool {
        guard attentionState(for: session) == .unread, inboxStore.markRead(session) else { return false }
        if playSound && noticeStyle == .chime { notifier.playSwordChime() }
        attentionStates[session.id] = .pending
        AppLogger.shared.write("session_read", fields: [
            "session_id": session.id,
            "tool": session.tool.rawValue,
            "origin": session.origin.rawValue
        ])
        return true
    }

    func markHandled(_ session: SessionSnapshot) {
        guard performMarkHandled(session, playSound: true) else { return }
        onBadgeChanged?(unreadCount)
        publishSharedSnapshot()
    }

    @discardableResult
    private func performMarkHandled(_ session: SessionSnapshot, playSound: Bool) -> Bool {
        guard let transition = inboxStore.markHandled(session, at: Date()) else { return false }
        if playSound && sheathSoundEnabled { notifier.playSheathSound() }
        activityStore.append(ActivityRecord(transition: transition))
        attentionStates[session.id] = .handled
        todayHandledCount += 1
        AppLogger.shared.write("session_handled", fields: [
            "session_id": session.id,
            "tool": session.tool.rawValue,
            "origin": session.origin.rawValue
        ])
        return true
    }

    /// 「推」: hide the session until the option's fire date; it returns in
    /// its original attention state via the reconcile expiry, silently.
    func snooze(_ session: SessionSnapshot, option: SnoozeOption) {
        let now = Date()
        guard inboxStore.snooze(session, until: option.until(from: now), at: now) else { return }
        if sheathSoundEnabled { notifier.playSwordPushSound() }
        snoozedSessionIDs.insert(session.id)
        onBadgeChanged?(unreadCount)
        publishSharedSnapshot()
        AppLogger.shared.write("session_snoozed", fields: [
            "session_id": session.id,
            "tool": session.tool.rawValue,
            "until": ISO8601DateFormatter().string(from: option.until(from: now))
        ])
    }

    /// 「万剑归宗」: sheathe every finished session in a group at once.
    /// Running sessions stay — a sword still out can't be recalled — and the
    /// group sound plays once instead of per row.
    func sheatheAll(_ group: [SessionSnapshot], groupID: String) {
        let targets = group.filter { attentionState(for: $0).needsUserAttention }
        guard !targets.isEmpty else { return }
        var handled = 0
        for session in targets where performMarkHandled(session, playSound: false) {
            handled += 1
        }
        guard handled > 0 else { return }
        if sheathSoundEnabled { notifier.playSwordsReturnSound() }
        onBadgeChanged?(unreadCount)
        publishSharedSnapshot()
        AppLogger.shared.write("group_sheathed", fields: [
            "group": groupID,
            "count": handled
        ])
    }

    func open(_ session: SessionSnapshot) {
        let attention = attentionState(for: session)
        if attention == .running && noticeStyle == .chime { notifier.playSwordChime() }
        if attention == .unread { markRead(session) }
        notifier.open(session)
        onSessionOpened?()
    }

    func isExpanded(_ groupID: String) -> Bool {
        expandedGroupIDs.contains(groupID)
    }

    func setExpanded(_ expanded: Bool, groupID: String) {
        if expanded { expandedGroupIDs.insert(groupID) } else { expandedGroupIDs.remove(groupID) }
    }

    func previewDispatchSound() {
        notifier.playDispatchSound()
    }

    func previewSwordChime() {
        notifier.playSwordChime()
    }

    func previewSheathSound() {
        notifier.playSheathSound()
    }

    func previewSwordPushSound() {
        notifier.playSwordPushSound()
    }

    func previewSwordsReturnSound() {
        notifier.playSwordsReturnSound()
    }

    func sendTestNotification() {
        if !systemNotificationsEnabled { systemNotificationsEnabled = true }
        notifier.sendTest(playSound: false, language: language)
    }

    func openLog() {
        NSWorkspace.shared.activateFileViewerSelecting([AppLogger.shared.logURL])
    }

    func openDailyReport() {
        reportService.openTodayReport(
            currentSessions: sessions,
            includeBackground: !hideBackgroundInReports,
            language: language.usesEnglish ? .english : .chinese
        )
    }

    func processRemoteActions(_ actions: [JianlingRemoteAction]) {
        consumeSharedActions(actions)
        onBadgeChanged?(unreadCount)
        publishSharedSnapshot()
    }

    private var visibleSessions: [SessionSnapshot] {
        sessions.filter { displayBucket(for: $0) != .hidden && !isSnoozed($0) }
    }

    private func sorted(_ values: [SessionSnapshot]) -> [SessionSnapshot] {
        values.sorted { lhs, rhs in
            let lhsRank = sessionRank(lhs)
            let rhsRank = sessionRank(rhs)
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            return lhs.lastActivity > rhs.lastActivity
        }
    }

    private func sessionRank(_ session: SessionSnapshot) -> Int {
        switch attentionState(for: session) {
        case .unread: return 0
        case .pending: return 1
        case .running: return 2
        case .handled: return 3
        }
    }

    private func route(_ event: CompletionEvent) {
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == event.session.tool.bundleIdentifier {
            AppLogger.shared.write("attention_suppressed_frontmost", fields: ["event_id": event.id, "tool": event.session.tool.rawValue])
            return
        }

        if quietHoursEnabled && isQuietHour(Date()) {
            AppLogger.shared.write("attention_suppressed_quiet_hours", fields: ["event_id": event.id])
            return
        }

        if systemNotificationsEnabled {
            notifier.sendCompletion(event, playSound: false, language: language)
        } else {
            AppLogger.shared.write("attention_kept_in_inbox", fields: ["event_id": event.id])
        }
    }

    private func isQuietHour(_ date: Date) -> Bool {
        let hour = Calendar.current.component(.hour, from: date)
        return hour >= 23 || hour < 8
    }

    private static func handledCountToday(in records: [ActivityRecord]) -> Int {
        records.filter { $0.kind == .handled && Calendar.current.isDateInToday($0.timestamp) }.count
    }

    private func consumeSharedActions(_ actions: [JianlingRemoteAction], now: Date = Date()) {
        var badgeChanged = false
        for action in actions {
            do {
                if try sharedStore.hasProcessedAction(id: action.id) {
                    try? sharedStore.removeAction(id: action.id)
                    AppLogger.shared.write("shared_action_deduplicated", fields: [
                        "action": action.kind.rawValue,
                        "task_id": action.taskID
                    ])
                    continue
                }
            } catch {
                AppLogger.shared.write("shared_action_receipt_read_error", fields: [
                    "action_id": action.id.uuidString,
                    "error": error.localizedDescription
                ])
                continue
            }

            guard let session = sessions.first(where: { $0.id == action.taskID }) else {
                if now.timeIntervalSince(action.createdAt) > 24 * 60 * 60 {
                    do {
                        try sharedStore.markActionProcessed(id: action.id, at: now)
                        try sharedStore.removeAction(id: action.id)
                    } catch {
                        AppLogger.shared.write("shared_action_expire_error", fields: [
                            "action_id": action.id.uuidString,
                            "error": error.localizedDescription
                        ])
                    }
                }
                continue
            }

            if action.kind != .open,
               let targetFingerprint = action.turnFingerprint,
               session.completionFingerprint != targetFingerprint {
                do {
                    try sharedStore.markActionProcessed(id: action.id, at: now)
                    try sharedStore.removeAction(id: action.id)
                    AppLogger.shared.write("shared_action_stale_turn", fields: [
                        "action": action.kind.rawValue,
                        "task_id": action.taskID
                    ])
                } catch {
                    AppLogger.shared.write("shared_action_stale_turn_error", fields: [
                        "action_id": action.id.uuidString,
                        "error": error.localizedDescription
                    ])
                }
                continue
            }

            do {
                // Persist the receipt before performing a side effect such as opening an app.
                // This makes retries from LAN + iCloud at-most-once across app restarts.
                try sharedStore.markActionProcessed(id: action.id, at: now)
            } catch {
                AppLogger.shared.write("shared_action_receipt_write_error", fields: [
                    "action_id": action.id.uuidString,
                    "error": error.localizedDescription
                ])
                continue
            }

            switch action.kind {
            case .open:
                if performMarkRead(session) { badgeChanged = true }
                notifier.open(session)
            case .markRead:
                if performMarkRead(session) { badgeChanged = true }
            case .markHandled:
                if performMarkHandled(session, playSound: false) { badgeChanged = true }
            }
            do {
                try sharedStore.removeAction(id: action.id)
                AppLogger.shared.write("shared_action_consumed", fields: [
                    "action": action.kind.rawValue,
                    "task_id": action.taskID
                ])
            } catch {
                AppLogger.shared.write("shared_action_remove_error", fields: ["error": error.localizedDescription])
            }
        }
        if badgeChanged { onBadgeChanged?(unreadCount) }
    }

    private func publishSharedSnapshot(now: Date = Date()) {
        let tasks = sorted(sessions.filter {
            attentionState(for: $0) != .handled && displayBucket(for: $0, now: now) != .hidden && !isSnoozed($0)
        }).compactMap { session in
            sharedTask(from: session)
        }
        let candidate = JianlingInboxSnapshot(
            generatedAt: now,
            revision: sharedRevision,
            tasks: tasks,
            todayHandledCount: todayHandledCount,
            hideBackgroundTasks: hideBackgroundInReports
        )
        // Same content as the last published frame: skip the disk write, the
        // LAN broadcast, and the iCloud queue in one place. Newly paired
        // phones still get a frame because LocalPeerTransport re-sends the
        // on-disk snapshot on pairing.
        if let last = lastPublishedSnapshot, last.hasSameContent(as: candidate) { return }
        sharedRevision = max(sharedRevision + 1, Int64(now.timeIntervalSince1970 * 1_000))
        let snapshot = JianlingInboxSnapshot(
            generatedAt: now,
            revision: sharedRevision,
            tasks: tasks,
            todayHandledCount: todayHandledCount,
            hideBackgroundTasks: hideBackgroundInReports
        )
        do {
            try sharedStore.writeSnapshot(snapshot)
            lastPublishedSnapshot = snapshot
            if !didLogSharedSnapshot {
                didLogSharedSnapshot = true
                AppLogger.shared.write("shared_snapshot_ready", fields: [
                    "schema_version": snapshot.schemaVersion,
                    "task_count": snapshot.tasks.count,
                    "routine_count": snapshot.tasks.filter { $0.origin == .scheduled }.count,
                    "background_count": snapshot.tasks.filter(\.isBackground).count,
                    "path": sharedStore.snapshotURL.path
                ])
            }
            onSharedSnapshotChanged?(snapshot)
        } catch {
            AppLogger.shared.write("shared_snapshot_write_error", fields: ["error": error.localizedDescription])
        }
    }

    private func sharedTask(from session: SessionSnapshot) -> JianlingTaskSnapshot? {
        let state: JianlingTaskState
        switch attentionState(for: session) {
        case .running: state = .running
        case .unread: state = .unread
        case .pending: state = .pending
        case .handled: return nil
        }
        let tool: JianlingTool
        switch session.tool {
        case .craft: tool = .craft
        case .claudeCode: tool = .claudeCode
        case .codex: tool = .codex
        case .newMax: tool = .newMax
        case .workBuddy: tool = .workBuddy
        }
        let origin = JianlingTaskOrigin(rawValue: session.origin.rawValue) ?? .detached
        let projectName = session.projectPath.flatMap { path in
            let value = URL(fileURLWithPath: path).lastPathComponent
            return value.isEmpty ? nil : value
        }
        return JianlingTaskSnapshot(
            id: session.id,
            sessionID: session.sessionID,
            tool: tool,
            title: session.title,
            state: state,
            origin: origin,
            updatedAt: session.lastActivity,
            completedAt: session.turnCompletedAt,
            turnFingerprint: session.completionFingerprint,
            projectName: projectName,
            isHostVisible: session.isHostVisible
        )
    }
}
