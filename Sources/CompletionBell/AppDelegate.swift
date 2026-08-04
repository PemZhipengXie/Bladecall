import AppKit
import CompletionBellCore
import JianlingCloudSync
import JianlingShared
import JianlingSync
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let notifier = NotificationService()
    private let activityStore = ActivityLogStore(url: RuntimePaths.activityLogURL)
    private let sharedStore = JianlingSharedStore()
    private lazy var cloudBridge = JianlingCloudBridge(store: sharedStore)
    private let pairingCode = JianlingPairingCode.generate()
    private lazy var inboxStore = InboxStateStore(url: RuntimePaths.inboxStateURL)
    private lazy var reportService = DailyReportService(store: activityStore)
    private lazy var state = AppState(
        notifier: notifier,
        inboxStore: inboxStore,
        activityStore: activityStore,
        reportService: reportService,
        sharedStore: sharedStore
    )
    private lazy var localServer = JianlingLocalServer(
        pairingCode: pairingCode,
        peer: JianlingPeerDescriptor(
            deviceID: Self.persistentDeviceID(),
            name: Host.current().localizedName ?? "Mac",
            platform: .macOS,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        ),
        snapshotProvider: { [sharedStore] in
            (try? sharedStore.readSnapshot()) ?? .empty
        },
        actionHandler: { [weak self] action in
            guard let self else { return }
            _ = try? self.sharedStore.enqueue(action)
            Task { @MainActor [weak self] in
                self?.state.processRemoteActions([action])
            }
        }
    )
    private let sharedActionReaderStore = JianlingSharedStore()
    private let sharedActionReadQueue = DispatchQueue(label: "completion-bell.shared-actions", qos: .utility)
    private lazy var foregroundTracker = ForegroundUsageTracker(store: activityStore)
    private let monitor = MonitorService()
    private let quotaMonitor = QuotaMonitorService()
    private let presentationRouter = PresentationRouter()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var floatingPanel: NSPanel?
    private var topNotchHost: TopNotchHost?
    private var rightEdgeHost: RightEdgeHost?
    private var settingsWindow: NSWindow?
    private var screenRosterObserver: NSObjectProtocol?
    private var restoreHostAfterSettings = false
    private let settingsNavigation = SettingsNavigation()
    private var maintenanceTimer: Timer?
    private var cloudSyncInFlight = false
    private var cloudAccountReady = false
    private var cloudSnapshotUploadInFlight = false
    private var sharedActionReadInFlight = false
    private var pendingCloudSnapshot: JianlingInboxSnapshot?
    private var lastCloudUploadedSnapshot: JianlingInboxSnapshot?
    private var resizeStartFrame: NSRect?
    private let floatingFrameName = "JianlingFloatingPanel"
    private var isApplyingPresentationRoute = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(state.dockIconVisible ? .regular : .accessory)
        notifier.activate()
        setupStatusItem()
        setupPopover()
        wireActions()
        setupPeerSync()
        configureCloudSync(enabled: state.iCloudSyncEnabled)

        if UserDefaults.standard.object(forKey: "hasShownWelcome") == nil {
            NSApp.activate(ignoringOtherApps: true)
        }
        notifier.refreshAuthorizationStatus()
        foregroundTracker.start()
        reportService.generateMissingReportsAsync(includeBackground: !state.hideBackgroundInReports)
        maintenanceTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.foregroundTracker.checkpoint()
                guard let self else { return }
                self.monitor.publishClockIfNeeded()
                self.reportService.generateMissingReportsAsync(includeBackground: !self.state.hideBackgroundInReports)
                self.syncCloudIfNeeded()
                self.flushCloudSnapshotIfNeeded()
                self.pollSharedActions()
            }
        }
        monitor.start()
        quotaMonitor.start()
        pollSharedActions()
        presentCurrentHost(trigger: .launch)

        if CommandLine.arguments.contains("--test-notification") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.state.sendTestNotification()
            }
        }

        if CommandLine.arguments.contains("--show-settings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.showSettings()
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            if UserDefaults.standard.object(forKey: "hasShownWelcome") == nil {
                self?.showPopover(nil)
                UserDefaults.standard.set(true, forKey: "hasShownWelcome")
            }
        }
        AppLogger.shared.write("app_launched", fields: ["version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"])
    }

    func applicationWillTerminate(_ notification: Notification) {
        maintenanceTimer?.invalidate()
        foregroundTracker.stop()
        reportService.generateMissingReports(includeBackground: !state.hideBackgroundInReports)
        monitor.stop()
        quotaMonitor.stop()
        localServer.stop()
        inboxStore.flush()
        topNotchHost?.stop()
        rightEdgeHost?.stop()
        floatingPanel?.saveFrame(usingName: floatingFrameName)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        presentCurrentHost(trigger: .dockReopen)
        AppLogger.shared.write("presentation_host_shown", fields: ["source": "application_reopen"])
        return true
    }

    private func setupStatusItem() {
        // AppKit persists the item's distance from the right screen edge. A
        // display-arrangement change can strand that offset beyond the current
        // menu bar's width (observed: 5582pt on a 1512pt built-in display),
        // which leaves the item entirely off screen. Drop a stale offset so
        // the item re-anchors at the default position.
        let positionKey = "NSStatusItem Preferred Position Item-0"
        let narrowestScreen = NSScreen.screens.map(\.frame.width).min() ?? 1280
        let existingPosition = UserDefaults.standard.object(forKey: positionKey) as? Double
        // New status items default to the LEFT end of the status area, which a
        // notch plus a crowded menu bar simply refuses to render. Seed (and
        // repair) a preferred slot near the right edge so the icon fits on the
        // built-in display too; the user can still drag it elsewhere.
        if existingPosition == nil || existingPosition! > narrowestScreen {
            UserDefaults.standard.set(300.0, forKey: positionKey)
            AppLogger.shared.write("status_item_position_seeded", fields: [
                "previous": existingPosition ?? -1,
                "seeded": 300
            ])
        }
        // Keep the recovery entry compact so it stays visible on crowded menu bars.
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.isVisible = true
        guard let button = statusItem.button else { return }
        if let image = AppAssets.statusBarIcon {
            button.image = image
        } else {
            button.image = NSImage(systemSymbolName: "seal", accessibilityDescription: state.language.productName)
        }
        button.imagePosition = .imageLeading
        button.target = self
        button.action = #selector(showPopover(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.toolTip = state.text("剑令 · AI 任务收件箱", "Bladecall · A calm inbox for AI work")

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, let item = self.statusItem else { return }
            let window = item.button?.window
            AppLogger.shared.write("status_item_diagnostics", fields: [
                "is_visible": item.isVisible,
                "length": item.length,
                "has_button": item.button != nil,
                "image_size": item.button?.image.map { "\($0.size)" } ?? "nil",
                "window_frame": window.map { "\($0.frame)" } ?? "nil",
                "window_screen": window?.screen.map { "\($0.frame)" } ?? "nil",
                "window_visible": window?.isVisible ?? false,
                "occlusion": window.map { "\($0.occlusionState.contains(.visible))" } ?? "nil"
            ])
        }
    }

    private func setupPopover() {
        // .environment(\.colorScheme) drives our palette but not AppKit chrome
        // (popover arrow/border, scrollers, context menus). Without this the
        // popover renders dark chrome behind light content in Dark Mode.
        popover.appearance = NSAppearance(named: .aqua)
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: PresentationLayout.menuWidth, height: PresentationLayout.menuHeight)
        popover.contentViewController = NSHostingController(
            rootView: PopoverView(
                state: state,
                surface: .menu,
                onClose: { [weak self] in self?.popover.performClose(nil) }
            )
                .environment(\.colorScheme, .light)
                .jianlingFontScale(state.fontScale)
        )
    }

    @discardableResult
    private func setupFloatingPanel() -> Bool {
        if floatingPanel != nil { return true }
        guard NSScreen.main != nil else { return false }
        let defaultSize = NSSize(
            width: PresentationLayout.floatingDefaultWidth,
            height: PresentationLayout.floatingDefaultHeight
        )
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: defaultSize),
            styleMask: [.nonactivatingPanel, .borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.level = state.floatingAlwaysOnTop ? .floating : .normal
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.contentMinSize = NSSize(width: PresentationLayout.floatingMinimumWidth, height: PresentationLayout.floatingMinimumHeight)
        panel.contentMaxSize = NSSize(width: PresentationLayout.floatingMaximumWidth, height: PresentationLayout.floatingMaximumHeight)
        // 菜单面板和浮窗复用同一个视图，避免状态、排序和操作能力发生漂移。
        panel.contentViewController = NSHostingController(
            rootView: FloatingPanelContent(
                state: state,
                onClose: { [weak self] in self?.destroyFloatingPanel() },
                onResize: { [weak self] translation, ended in
                    self?.resizeFloatingPanel(translation: translation, ended: ended)
                }
            )
            .environment(\.colorScheme, .light)
            .jianlingFontScale(state.fontScale)
        )

        let restored = panel.setFrameUsingName(floatingFrameName)
        _ = panel.setFrameAutosaveName(floatingFrameName)
        if !restored, let screen = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(
                x: screen.maxX - defaultSize.width - 20,
                y: screen.maxY - defaultSize.height - 20
            ))
        }
        // Same reason as the popover: the palette is light, so the window's
        // effective appearance must be too or AppKit chrome goes dark.
        panel.appearance = NSAppearance(named: .aqua)
        floatingPanel = panel
        return true
    }

    private func wireActions() {
        monitor.onUpdate = { [weak self] update in
            DispatchQueue.main.async { self?.state.apply(update) }
        }
        quotaMonitor.onUpdate = { [weak self] update in
            DispatchQueue.main.async { self?.state.applyQuota(update) }
        }
        notifier.onAuthorizationStatus = { [weak self] status in
            Task { @MainActor in
                self?.state.notificationAuthorization = status
            }
        }
        state.onOpenSettings = { [weak self] in self?.showSettings() }
        state.onQuit = { NSApp.terminate(nil) }
        state.onBadgeChanged = { [weak self] count in self?.updateBadge(count) }
        state.onCloudSyncChanged = { [weak self] enabled in
            self?.configureCloudSync(enabled: enabled)
        }
        state.onLanguageChanged = { [weak self] in self?.refreshLocalizedChrome() }
        state.onRefreshQuota = { [weak self] in self?.quotaMonitor.refreshNow() }
        state.onRefreshSessions = { [weak self] in
            self?.monitor.scanNow(reloadMetadata: true)
            self?.quotaMonitor.refreshNow()
        }
        state.onFloatingPinChanged = { [weak self] pinned in
            self?.floatingPanel?.level = pinned ? .floating : .normal
        }
        state.onDockIconChanged = { visible in
            NSApp.setActivationPolicy(visible ? .regular : .accessory)
            if visible { NSApp.activate(ignoringOtherApps: true) }
        }
        state.onPresentationModeChanged = { [weak self] old, new in
            guard let self, !self.isApplyingPresentationRoute else { return }
            self.applyPresentationRoute(self.presentationRouter.route(mode: new, trigger: .modeChanged(from: old, to: new)))
        }
        state.onNotchPinnedChanged = { [weak self] pinned in self?.topNotchHost?.setPinned(pinned) }
        state.onNotchScreenChanged = { [weak self] id in self?.topNotchHost?.moveToScreen(id) }
        state.onEdgePinnedChanged = { [weak self] pinned in self?.rightEdgeHost?.setPinned(pinned) }
        state.onEdgeScreenChanged = { [weak self] id in self?.rightEdgeHost?.moveToScreen(id) }
        state.onEdgeTagSizeChanged = { [weak self] in self?.rightEdgeHost?.resizeTag() }
        refreshEdgeScreenChoices()
        screenRosterObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshEdgeScreenChoices() }
        }
        state.onSessionOpened = { [weak self] in
            self?.topNotchHost?.contentActivated()
            self?.rightEdgeHost?.contentActivated()
        }
    }

    private func setupPeerSync() {
        state.pairingCodeText = pairingCode.rawValue
        state.onSharedSnapshotChanged = { [weak self] snapshot in
            self?.localServer.broadcast(snapshot)
            self?.queueCloudSnapshot(snapshot)
        }
        localServer.onStateChange = { [weak self] serverState in
            guard let self else { return }
            switch serverState {
            case .stopped:
                state.phoneConnectionStatus = state.text("同网连接已停止", "Local connection stopped")
            case .starting:
                state.phoneConnectionStatus = state.text("正在开启同网连接", "Starting local connection")
            case .ready:
                state.phoneConnectionStatus = state.text("等待 iPhone 输入配对码", "Waiting for the pairing code on iPhone")
            case .paired(let deviceName):
                state.phoneConnectionStatus = state.text("已连接 · \(deviceName)", "Connected · \(deviceName)")
            case .failed(let message):
                state.phoneConnectionStatus = state.text("连接异常 · \(message)", "Connection issue · \(message)")
            }
        }
        do {
            try localServer.start()
        } catch {
            state.phoneConnectionStatus = state.text("连接异常 · \(error.localizedDescription)", "Connection issue · \(error.localizedDescription)")
        }
    }

    private func configureCloudSync(enabled: Bool) {
        guard enabled else {
            cloudAccountReady = false
            pendingCloudSnapshot = nil
            state.iCloudSyncStatus = state.text("未开启，状态只在同网同步", "Off · syncing only on the same network")
            return
        }
        state.iCloudSyncStatus = state.text("正在连接你的 iCloud", "Connecting to your iCloud")
        cloudBridge.verifyAccount { [weak self] result in
            Task { @MainActor in
                guard let self, self.state.iCloudSyncEnabled else { return }
                switch result {
                case .failure(let error):
                    self.cloudAccountReady = false
                    self.state.iCloudSyncStatus = error.localizedDescription
                case .success:
                    self.cloudAccountReady = true
                    self.state.iCloudSyncStatus = self.state.text("私人 iCloud 已连接", "Private iCloud connected")
                    if let snapshot = try? self.sharedStore.readSnapshot(applyingPendingActions: false) {
                        self.queueCloudSnapshot(snapshot)
                    }
                    self.syncCloudIfNeeded()
                }
            }
        }
    }

    private func syncCloudIfNeeded() {
        guard state.iCloudSyncEnabled, cloudAccountReady, !cloudSyncInFlight else { return }
        cloudSyncInFlight = true
        state.iCloudSyncStatus = state.text("正在收取手机操作", "Checking for iPhone actions")
        cloudBridge.importRemoteActions { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.cloudSyncInFlight = false
                switch result {
                case .failure(let error):
                    self.state.iCloudSyncStatus = self.state.text("iCloud 暂时没有同步 · \(error.localizedDescription)", "iCloud is temporarily unavailable · \(error.localizedDescription)")
                case .success(let report):
                    if report.importedActions > 0 { self.pollSharedActions() }
                    self.state.iCloudSyncStatus = report.importedActions > 0
                        ? self.state.text("已收到 \(report.importedActions) 个手机操作", "Received \(report.importedActions) iPhone actions")
                        : self.state.text("私人 iCloud 已连接", "Private iCloud connected")
                }
            }
        }
    }

    /// Reading an App Group directory can block in macOS' container manager for
    /// an ad-hoc signed local build. Keep that work away from the main actor so
    /// the Mac inbox and snapshot publishing remain responsive.
    private func pollSharedActions() {
        guard !sharedActionReadInFlight else { return }
        sharedActionReadInFlight = true
        let reader = sharedActionReaderStore
        sharedActionReadQueue.async { [weak self] in
            let result = Result { try reader.pendingActions() }
            DispatchQueue.main.async {
                guard let self else { return }
                self.sharedActionReadInFlight = false
                switch result {
                case .success(let actions):
                    if !actions.isEmpty { self.state.processRemoteActions(actions) }
                case .failure(let error):
                    AppLogger.shared.write("shared_action_read_error", fields: ["error": error.localizedDescription])
                }
            }
        }
    }

    private func queueCloudSnapshot(_ snapshot: JianlingInboxSnapshot) {
        guard state.iCloudSyncEnabled, cloudAccountReady else { return }
        pendingCloudSnapshot = snapshot
        flushCloudSnapshotIfNeeded()
    }

    private func flushCloudSnapshotIfNeeded() {
        guard state.iCloudSyncEnabled,
              cloudAccountReady,
              !cloudSnapshotUploadInFlight,
              let snapshot = pendingCloudSnapshot else { return }
        if let last = lastCloudUploadedSnapshot, last.hasSameContent(as: snapshot) {
            pendingCloudSnapshot = nil
            return
        }
        pendingCloudSnapshot = nil
        cloudSnapshotUploadInFlight = true
        cloudBridge.publish(snapshot: snapshot) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.cloudSnapshotUploadInFlight = false
                var shouldContinue = false
                switch result {
                case .failure(let error):
                    if self.pendingCloudSnapshot == nil { self.pendingCloudSnapshot = snapshot }
                    self.state.iCloudSyncStatus = self.state.text("iCloud 暂时没有同步 · \(error.localizedDescription)", "iCloud is temporarily unavailable · \(error.localizedDescription)")
                case .success:
                    self.lastCloudUploadedSnapshot = snapshot
                    self.state.iCloudSyncStatus = self.state.text("私人 iCloud 已连接", "Private iCloud connected")
                    shouldContinue = self.pendingCloudSnapshot != nil
                }
                if shouldContinue { self.flushCloudSnapshotIfNeeded() }
            }
        }
    }

    @objc private func showPopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if let event = NSApp.currentEvent, event.type == .rightMouseUp {
            showStatusContextMenu(event: event, button: button)
            return
        }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func showStatusContextMenu(event: NSEvent, button: NSStatusBarButton) {
        popover.performClose(nil)
        let menu = NSMenu()
        menu.autoenablesItems = false

        let (showTitle, hideTitle, symbol): (String, String, String) = switch state.presentationMode {
        case .floating:
            (state.text("显示浮窗", "Show Floating Window"), state.text("关闭浮窗", "Close Floating Window"), "rectangle.on.rectangle")
        case .notch:
            (state.text("显示顶部剑令", "Show Top Entry"), state.text("关闭顶部剑令", "Close Top Entry"), "laptopcomputer")
        case .rightEdge:
            (state.text("显示右侧藏锋", "Show Edge Entry"), state.text("关闭右侧藏锋", "Close Edge Entry"), "sidebar.right")
        }
        let showFloating = statusMenuItem(
            showTitle,
            symbol: symbol,
            action: #selector(showFloatingPanelFromMenu(_:))
        )
        showFloating.isEnabled = !currentHostIsVisible
        menu.addItem(showFloating)

        let hideFloating = statusMenuItem(
            hideTitle,
            symbol: "xmark.rectangle",
            action: #selector(hideFloatingPanelFromMenu(_:))
        )
        hideFloating.isEnabled = currentHostIsVisible
        menu.addItem(hideFloating)

        menu.addItem(.separator())
        menu.addItem(statusMenuItem(
            state.text("刷新剑令", "Refresh Sessions"),
            symbol: "arrow.clockwise",
            action: #selector(refreshSessionsFromMenu(_:)),
            keyEquivalent: "r"
        ))
        menu.addItem(statusMenuItem(
            state.text("设置…", "Settings…"),
            symbol: "gearshape",
            action: #selector(openSettingsFromMenu(_:)),
            keyEquivalent: ","
        ))

        menu.addItem(.separator())
        menu.addItem(statusMenuItem(
            state.text("关于剑令", "About Bladecall"),
            symbol: "info.circle",
            action: #selector(openAboutFromMenu(_:))
        ))
        menu.addItem(statusMenuItem(
            state.text("更新剑令…", "Update Bladecall…"),
            symbol: "arrow.down.circle",
            action: #selector(showUpdateHelpFromMenu(_:))
        ))

        menu.addItem(.separator())
        menu.addItem(statusMenuItem(
            state.text("退出剑令…", "Quit Bladecall…"),
            symbol: "power",
            action: #selector(confirmQuitFromMenu(_:)),
            keyEquivalent: "q"
        ))

        NSMenu.popUpContextMenu(menu, with: event, for: button)
    }

    private func statusMenuItem(
        _ title: String,
        symbol: String,
        action: Selector,
        keyEquivalent: String = ""
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        return item
    }

    @objc private func showFloatingPanelFromMenu(_ sender: Any?) {
        presentCurrentHost(trigger: .statusMenuShow)
        AppLogger.shared.write("presentation_host_shown", fields: ["source": "status_menu"])
    }

    @objc private func hideFloatingPanelFromMenu(_ sender: Any?) {
        closeActiveHost()
        AppLogger.shared.write("presentation_host_hidden", fields: ["source": "status_menu"])
    }

    @objc private func refreshSessionsFromMenu(_ sender: Any?) {
        state.refreshSessions()
    }

    @objc private func openSettingsFromMenu(_ sender: Any?) {
        showSettings(section: .general)
    }

    @objc private func openAboutFromMenu(_ sender: Any?) {
        showSettings(section: .about)
    }

    @objc private func showUpdateHelpFromMenu(_ sender: Any?) {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "dev"
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = state.text("更新剑令", "Update Bladecall")
        alert.informativeText = state.text(
            "当前版本：\(version)（Build \(build)）。\n\n剑令目前通过新安装包更新；拿到新版后直接安装即可，设置和剑迹会保留。",
            "Current version: \(version) (Build \(build)).\n\nBladecall currently updates through a new installer. Install it over this version; your settings and activity history stay in place."
        )
        alert.addButton(withTitle: state.text("打开下载文件夹", "Open Downloads"))
        alert.addButton(withTitle: state.text("好", "Done"))
        if alert.runModal() == .alertFirstButtonReturn,
           let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first {
            NSWorkspace.shared.open(downloads)
        }
    }

    @objc private func confirmQuitFromMenu(_ sender: Any?) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = state.text("退出剑令？", "Quit Bladecall?")
        alert.informativeText = state.text(
            "退出后将停止会话监控，下次可从“应用程序”重新打开。",
            "Monitoring stops until you open Bladecall again from Applications."
        )
        alert.addButton(withTitle: state.text("退出", "Quit"))
        alert.addButton(withTitle: state.text("取消", "Cancel"))
        if alert.runModal() == .alertFirstButtonReturn {
            NSApp.terminate(nil)
        }
    }

    private var currentHostIsVisible: Bool {
        switch state.presentationMode {
        case .floating: return floatingPanel?.isVisible == true
        case .notch: return topNotchHost?.isVisible == true
        case .rightEdge: return rightEdgeHost?.isVisible == true
        }
    }

    private func toggleCurrentHost() {
        if currentHostIsVisible { closeActiveHost() } else { presentCurrentHost(trigger: .statusMenuShow) }
    }

    /// Keeps the Settings display picker populated regardless of which host is
    /// live, so the user can pre-select a screen before switching to edge mode.
    private func refreshEdgeScreenChoices() {
        let choices = RightEdgeHost.screenChoices(from: RightEdgeHost.screens())
        if state.notchScreenChoices.map(\.id) != choices.map(\.id) {
            state.notchScreenChoices = choices
        }
        let storedNotch = UserDefaults.standard.string(forKey: "jianlingNotchScreenID")
        let resolvedNotch = choices.contains { $0.id == storedNotch } ? storedNotch : nil
        if state.notchScreenID != resolvedNotch { state.notchScreenID = resolvedNotch }
        if state.edgeScreenChoices.map(\.id) != choices.map(\.id) {
            state.edgeScreenChoices = choices
        }
        let stored = UserDefaults.standard.string(forKey: "jianlingRightEdgeScreenID")
        let resolved = choices.contains { $0.id == stored } ? stored : nil
        if state.edgeScreenID != resolved { state.edgeScreenID = resolved }
    }

    private func presentCurrentHost(trigger: PresentationTrigger) {
        applyPresentationRoute(presentationRouter.route(mode: state.presentationMode, trigger: trigger))
    }

    private func applyPresentationRoute(_ route: PresentationRoute) {
        isApplyingPresentationRoute = true
        if route.destroy.contains(.floating) { destroyFloatingPanel() }
        if route.destroy.contains(.notch) { destroyTopNotchHost() }
        if route.destroy.contains(.rightEdge) { destroyRightEdgeHost() }
        if route.persistedMode != state.presentationMode { state.presentationMode = route.persistedMode }

        let succeeded: Bool
        switch route.present {
        case .floating:
            succeeded = setupFloatingPanel()
            if succeeded { presentFloatingPanel() }
        case .notch:
            if topNotchHost == nil { topNotchHost = TopNotchHost(state: state) }
            succeeded = topNotchHost?.show() == true
        case .rightEdge:
            if rightEdgeHost == nil { rightEdgeHost = RightEdgeHost(state: state) }
            succeeded = rightEdgeHost?.show() == true
        }
        if !succeeded && !route.didFallback {
            AppLogger.shared.write("presentation_host_creation_failed", fields: ["host": route.present.rawValue])
            isApplyingPresentationRoute = false
            applyPresentationRoute(presentationRouter.route(mode: state.presentationMode, trigger: .hostCreationFailed(route.present)))
            return
        }
        isApplyingPresentationRoute = false
    }

    private func destroyFloatingPanel() {
        guard let panel = floatingPanel else { return }
        panel.saveFrame(usingName: floatingFrameName)
        panel.orderOut(nil)
        panel.contentViewController = nil
        floatingPanel = nil
        resizeStartFrame = nil
    }

    private func destroyRightEdgeHost() {
        rightEdgeHost?.stop()
        rightEdgeHost = nil
    }

    private func destroyTopNotchHost() {
        topNotchHost?.stop()
        topNotchHost = nil
    }

    private func closeActiveHost() {
        restoreHostAfterSettings = false
        if popover.isShown { popover.performClose(nil) }
        switch state.presentationMode {
        case .floating: destroyFloatingPanel()
        case .notch: destroyTopNotchHost()
        case .rightEdge: destroyRightEdgeHost()
        }
        AppLogger.shared.write("window_closed", fields: ["mode": state.presentationMode.rawValue])
    }

    /// Show the panel with a short fade so it stops teleporting into view.
    /// Frequency is tens of times a day, so the fade stays near-imperceptible
    /// (120ms) and is skipped entirely when motion is off.
    private func presentFloatingPanel() {
        if floatingPanel == nil { _ = setupFloatingPanel() }
        guard let panel = floatingPanel else { return }
        guard state.motionEnabled, !panel.isVisible else {
            panel.orderFrontRegardless()
            return
        }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    private func showSettings(section: SettingsSection = .general) {
        settingsNavigation.section = section
        popover.performClose(nil)
        let hostWasVisible = topNotchHost?.isVisible == true || rightEdgeHost?.isVisible == true || floatingPanel?.isVisible == true
        closeActiveHost()
        restoreHostAfterSettings = restoreHostAfterSettings || hostWasVisible
        if settingsWindow == nil {
            let controller = NSHostingController(
                rootView: SettingsView(state: state, navigation: settingsNavigation)
                    .jianlingFontScale(state.fontScale)
            )
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = state.text("剑令设置", "Bladecall Settings")
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 560, height: 520)
            window.contentViewController = controller
            window.delegate = self
            // NSHostingController shrinks the window to the SwiftUI minimum
            // size on assignment, which lands below the sidebar breakpoint.
            // Restore the intended size so the sidebar is visible by default.
            let restored = window.setFrameUsingName("JianlingSettings")
            window.setFrameAutosaveName("JianlingSettings")
            if !restored {
                window.setContentSize(NSSize(width: 900, height: 640))
                window.center()
            }
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === settingsWindow else { return }
        let shouldRestore = restoreHostAfterSettings
        restoreHostAfterSettings = false
        if shouldRestore { presentCurrentHost(trigger: .statusMenuShow) }
    }

    private func refreshLocalizedChrome() {
        statusItem?.button?.toolTip = state.text(
            "剑令 · AI 任务收件箱",
            "Bladecall · A calm inbox for AI work"
        )
        settingsWindow?.title = state.text("剑令设置", "Bladecall Settings")
    }

    private func updateBadge(_ count: Int) {
        guard let button = statusItem.button else { return }
        button.title = ""
        button.toolTip = count > 0
            ? state.text("剑令 · \(count) 枚待处理", "Bladecall · \(count) items need attention")
            : state.text("剑令 · 暂无待处理", "Bladecall · Nothing needs attention")
    }

    private func resizeFloatingPanel(translation: CGSize, ended: Bool) {
        guard let panel = floatingPanel else { return }
        let start = resizeStartFrame ?? panel.frame
        if resizeStartFrame == nil { resizeStartFrame = start }
        let width = min(panel.contentMaxSize.width, max(panel.contentMinSize.width, start.width + translation.width))
        let height = min(panel.contentMaxSize.height, max(panel.contentMinSize.height, start.height + translation.height))
        let nextFrame = NSRect(
            x: start.minX,
            y: start.maxY - height,
            width: width,
            height: height
        )
        panel.setFrame(nextFrame, display: true)
        if ended {
            panel.saveFrame(usingName: floatingFrameName)
            resizeStartFrame = nil
        }
    }

    private static func persistentDeviceID() -> UUID {
        let key = "jianlingMacDeviceID"
        if let value = UserDefaults.standard.string(forKey: key), let id = UUID(uuidString: value) {
            return id
        }
        let id = UUID()
        UserDefaults.standard.set(id.uuidString, forKey: key)
        return id
    }
}

private struct FloatingPanelContent: View {
    @ObservedObject var state: AppState
    let onClose: () -> Void
    let onResize: (CGSize, Bool) -> Void

    var body: some View {
        PopoverView(state: state, surface: .floating, onClose: onClose)
            .overlay(alignment: .bottomTrailing) {
                ResizeGrip(onResize: onResize)
                    .padding(6)
            }
    }
}

private struct ResizeGrip: View {
    let onResize: (CGSize, Bool) -> Void

    var body: some View {
        Canvas { context, size in
            for inset in [CGFloat(3), 7, 11] {
                var path = Path()
                path.move(to: CGPoint(x: size.width - inset, y: size.height - 1))
                path.addLine(to: CGPoint(x: size.width - 1, y: size.height - inset))
                context.stroke(path, with: .color(.secondary.opacity(0.62)), lineWidth: 1)
            }
        }
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { onResize($0.translation, false) }
                    .onEnded { onResize($0.translation, true) }
            )
            .help("拖动调整浮窗大小")
    }
}
