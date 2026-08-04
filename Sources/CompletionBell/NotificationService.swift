import AppKit
import AVFoundation
import CompletionBellCore
import Foundation
import JianlingShared
import UserNotifications

final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    var onAuthorizationStatus: ((UNAuthorizationStatus) -> Void)?
    private var authorizationStatus: UNAuthorizationStatus = .notDetermined
    private let soundPlayer = ResourceSoundPlayer()

    var fallbackAvailable: Bool { terminalNotifierURL != nil }

    private var terminalNotifierURL: URL? {
        ["/opt/homebrew/bin/terminal-notifier", "/usr/local/bin/terminal-notifier"]
            .map(URL.init(fileURLWithPath:))
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    func activate() {
        // Accessing UNUserNotificationCenter while AppDelegate itself is still
        // being initialized aborts on newer macOS releases. Wait until
        // applicationDidFinishLaunching, when the process is registered as an
        // application, before installing the delegate.
        UNUserNotificationCenter.current().delegate = self
    }

    func requestAuthorization() {
        let center = UNUserNotificationCenter.current()
        refreshAuthorizationStatus()
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            AppLogger.shared.write("notification_permission", fields: [
                "granted": granted,
                "error": error?.localizedDescription ?? ""
            ])
            self.refreshAuthorizationStatus()
        }
    }

    func refreshAuthorizationStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            self.authorizationStatus = settings.authorizationStatus
            DispatchQueue.main.async {
                self.onAuthorizationStatus?(settings.authorizationStatus)
            }
        }
    }

    func sendCompletion(_ event: CompletionEvent, playSound: Bool, language: JianlingLanguage) {
        let content = UNMutableNotificationContent()
        content.title = event.session.title
        content.subtitle = event.session.tool.displayName
        content.body = language.text("AI 已复命，等你有空再看。", "Your AI result is ready whenever you are.")
        content.sound = playSound ? .default : nil
        content.userInfo = [
            "bundleIdentifier": event.session.tool.bundleIdentifier,
            "eventID": event.id,
            "deepLink": SessionDeepLink.url(for: event.session)?.absoluteString ?? ""
        ]
        send(identifier: "completion-\(event.id)", content: content, eventName: "notification_sent")
    }

    func sendSummary(_ events: [CompletionEvent], language: JianlingLanguage) {
        guard !events.isEmpty else { return }
        let tools = Set(events.map { $0.session.tool.displayName }).sorted().joined(separator: "、")
        let content = UNMutableNotificationContent()
        content.title = language.text("\(events.count) 个 AI 回合已完成", "\(events.count) AI turns are ready")
        content.subtitle = tools
        content.body = language.text("打开剑令查看未阅复命。", "Open Bladecall to review them.")
        content.sound = nil
        send(identifier: "summary-\(Int(Date().timeIntervalSince1970))", content: content, eventName: "batch_notification_sent")
    }

    func sendTest(playSound: Bool = false, language: JianlingLanguage) {
        let content = UNMutableNotificationContent()
        content.title = language.text("剑令已复命", "Bladecall result ready")
        content.subtitle = language.text("轻提醒测试", "Quiet notification test")
        content.body = language.text("默认只留下未读光点，等你有空再看。", "By default, Bladecall leaves a quiet unread signal for later.")
        content.sound = playSound ? .default : nil
        content.userInfo = ["bundleIdentifier": ToolKind.craft.bundleIdentifier, "eventID": "test"]
        send(identifier: "test-\(UUID().uuidString)", content: content, eventName: "test_notification_sent")
    }

    func playDispatchSound() {
        soundPlayer.play(relativePath: "Sounds/sword-draw.mp3", volume: 0.52)
    }

    func playSwordChime() {
        soundPlayer.play(relativePath: "Sounds/sword-ring.m4a", volume: 0.56)
    }

    func playSheathSound() {
        soundPlayer.play(relativePath: "Sounds/sword-sheath.mp3", volume: 0.50)
    }

    func playSwordPushSound() {
        soundPlayer.play(relativePath: "Sounds/sword-push.m4a", volume: 0.52)
    }

    func playSwordsReturnSound() {
        soundPlayer.play(relativePath: "Sounds/swords-return.m4a", volume: 0.50)
    }

    private func send(identifier: String, content: UNMutableNotificationContent, eventName: String) {
        if !usesNativeNotifications, let terminalNotifierURL {
            sendWithTerminalNotifier(
                executableURL: terminalNotifierURL,
                identifier: identifier,
                content: content,
                eventName: eventName
            )
            return
        }
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            AppLogger.shared.write(error == nil ? eventName : "notify_error", fields: [
                "notification_id": identifier,
                "error": error?.localizedDescription ?? ""
            ])
        }
    }

    private var usesNativeNotifications: Bool {
        switch authorizationStatus {
        case .authorized, .provisional, .ephemeral: return true
        case .denied, .notDetermined: return false
        @unknown default: return false
        }
    }

    private func sendWithTerminalNotifier(
        executableURL: URL,
        identifier: String,
        content: UNMutableNotificationContent,
        eventName: String
    ) {
        let bundleIdentifier = content.userInfo["bundleIdentifier"] as? String
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = executableURL
            var arguments = ["-title", content.title, "-message", content.body, "-group", identifier]
            if !content.subtitle.isEmpty {
                arguments.append(contentsOf: ["-subtitle", content.subtitle])
            }
            if let bundleIdentifier, !bundleIdentifier.isEmpty {
                arguments.append(contentsOf: ["-activate", bundleIdentifier])
            }
            process.arguments = arguments
            let errorPipe = Pipe()
            process.standardOutput = Pipe()
            process.standardError = errorPipe

            do {
                try process.run()
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let errorText = String(data: errorData, encoding: .utf8) ?? ""
                AppLogger.shared.write(process.terminationStatus == 0 ? "\(eventName)_compat" : "notify_error", fields: [
                    "notification_id": identifier,
                    "channel": "terminal-notifier",
                    "exit_code": process.terminationStatus,
                    "error": errorText
                ])
            } catch {
                AppLogger.shared.write("notify_error", fields: [
                    "notification_id": identifier,
                    "channel": "terminal-notifier",
                    "error": error.localizedDescription
                ])
            }
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        let bundleIdentifier = info["bundleIdentifier"] as? String
        let deepLink = (info["deepLink"] as? String).flatMap(URL.init(string:))
        let eventID = info["eventID"] as? String ?? ""
        AppLogger.shared.write("notification_clicked", fields: ["event_id": eventID, "bundle_id": bundleIdentifier ?? ""])
        if let deepLink {
            openURL(deepLink, fallbackBundleIdentifier: bundleIdentifier)
        } else if let bundleIdentifier {
            openApplication(bundleIdentifier: bundleIdentifier)
        }
        completionHandler()
    }

    func open(_ session: SessionSnapshot) {
        guard let deepLink = SessionDeepLink.url(for: session) else {
            openApplication(bundleIdentifier: session.tool.bundleIdentifier)
            return
        }
        openURL(deepLink, fallbackBundleIdentifier: session.tool.bundleIdentifier)
    }

    func openApplication(bundleIdentifier: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            AppLogger.shared.write("activate_error", fields: ["bundle_id": bundleIdentifier, "reason": "app_not_found"])
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            AppLogger.shared.write(error == nil ? "app_activated" : "activate_error", fields: [
                "bundle_id": bundleIdentifier,
                "error": error?.localizedDescription ?? ""
            ])
        }
    }

    private func openURL(_ url: URL, fallbackBundleIdentifier: String?) {
        if NSWorkspace.shared.open(url) {
            AppLogger.shared.write("conversation_opened", fields: ["scheme": url.scheme ?? ""])
        } else if let fallbackBundleIdentifier {
            AppLogger.shared.write("conversation_open_error", fields: ["scheme": url.scheme ?? ""])
            openApplication(bundleIdentifier: fallbackBundleIdentifier)
        }
    }

}

private final class ResourceSoundPlayer: NSObject, AVAudioPlayerDelegate {
    private var players: [AVAudioPlayer] = []

    func play(relativePath: String, volume: Float) {
        guard let url = AppAssets.resourceURL(relativePath: relativePath) else {
            AppLogger.shared.write("sound_error", fields: ["resource": relativePath, "reason": "missing"])
            return
        }
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            player.volume = volume
            player.prepareToPlay()
            players.append(player)
            player.play()
        } catch {
            AppLogger.shared.write("sound_error", fields: ["resource": relativePath, "error": error.localizedDescription])
        }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        players.removeAll { $0 === player }
    }
}
