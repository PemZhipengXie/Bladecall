import Foundation

public enum JianlingLanguage: String, CaseIterable, Codable, Identifiable, Sendable {
    case system
    case chinese
    case english

    public var id: String { rawValue }

    public var usesEnglish: Bool {
        switch self {
        case .chinese:
            return false
        case .english:
            return true
        case .system:
            let preferred = Locale.preferredLanguages.first?.lowercased() ?? "en"
            return !preferred.hasPrefix("zh")
        }
    }

    public var locale: Locale {
        Locale(identifier: usesEnglish ? "en" : "zh-Hans")
    }

    public var displayName: String {
        displayName(in: self)
    }

    public func displayName(in interfaceLanguage: JianlingLanguage) -> String {
        switch self {
        case .system: return interfaceLanguage.text("跟随系统", "System")
        case .chinese: return "中文"
        case .english: return "English"
        }
    }

    public var productName: String { usesEnglish ? "Bladecall" : "剑令" }

    public func text(_ chinese: String, _ english: String) -> String {
        usesEnglish ? english : chinese
    }
}

public enum JianlingSharedPreferences {
    private enum Key {
        static let iCloudSyncEnabled = "jianlingICloudSyncEnabled"
        static let showBackgroundTasks = "jianlingShowBackgroundTasks"
        static let appLanguage = "jianlingAppLanguage"
    }

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: JianlingSharedConfiguration.appGroupIdentifier) ?? .standard
    }

    public static var iCloudSyncEnabled: Bool {
        get { defaults.bool(forKey: Key.iCloudSyncEnabled) }
        set { defaults.set(newValue, forKey: Key.iCloudSyncEnabled) }
    }

    public static var showBackgroundTasks: Bool {
        get { defaults.bool(forKey: Key.showBackgroundTasks) }
        set { defaults.set(newValue, forKey: Key.showBackgroundTasks) }
    }

    public static var appLanguage: JianlingLanguage {
        get {
            guard let rawValue = defaults.string(forKey: Key.appLanguage) else { return .system }
            return JianlingLanguage(rawValue: rawValue) ?? .system
        }
        set { defaults.set(newValue.rawValue, forKey: Key.appLanguage) }
    }
}

public extension JianlingInboxSnapshot {
    func applyingBackgroundVisibility(showBackground: Bool) -> JianlingInboxSnapshot {
        JianlingInboxSnapshot(
            schemaVersion: schemaVersion,
            generatedAt: generatedAt,
            revision: revision,
            tasks: tasks,
            todayHandledCount: todayHandledCount,
            hideBackgroundTasks: !showBackground
        )
    }
}
