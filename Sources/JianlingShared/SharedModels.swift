import Foundation

public enum JianlingTool: String, Codable, CaseIterable, Hashable, Sendable {
    case craft
    case claudeCode
    case codex
    case newMax
    case workBuddy

    public var displayName: String {
        switch self {
        case .craft: return "Craft"
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        case .newMax: return "NewMax"
        case .workBuddy: return "WorkBuddy"
        }
    }
}

public enum JianlingTaskState: String, Codable, CaseIterable, Hashable, Sendable {
    case running
    case unread
    case pending
}

public enum JianlingTaskOrigin: String, Codable, CaseIterable, Hashable, Sendable {
    case interactive
    case scheduled
    case subagent
    case externalRuntime
    case detached

    public var isRoutine: Bool { self == .scheduled }

    public var isBackground: Bool {
        switch self {
        case .subagent, .externalRuntime, .detached: return true
        case .interactive, .scheduled: return false
        }
    }
}

public struct JianlingTaskSnapshot: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let sessionID: String
    public let tool: JianlingTool
    public let title: String
    public let state: JianlingTaskState
    public let origin: JianlingTaskOrigin
    public let updatedAt: Date
    public let completedAt: Date?
    public let turnFingerprint: String?
    public let projectName: String?
    public let isHostVisible: Bool

    public init(
        id: String,
        sessionID: String,
        tool: JianlingTool,
        title: String,
        state: JianlingTaskState,
        origin: JianlingTaskOrigin,
        updatedAt: Date,
        completedAt: Date? = nil,
        turnFingerprint: String? = nil,
        projectName: String? = nil,
        isHostVisible: Bool
    ) {
        self.id = id
        self.sessionID = sessionID
        self.tool = tool
        self.title = title
        self.state = state
        self.origin = origin
        self.updatedAt = updatedAt
        self.completedAt = completedAt
        self.turnFingerprint = turnFingerprint
        self.projectName = projectName
        self.isHostVisible = isHostVisible
    }

    public var isRoutine: Bool { origin.isRoutine }

    public var isBackground: Bool {
        guard !isRoutine else { return false }
        return origin.isBackground || !isHostVisible
    }
}

public struct JianlingInboxSnapshot: Codable, Hashable, Sendable {
    /// v5 adds WorkBuddy while preserving the v3 routine/background split on
    /// companion devices.
    public static let currentSchemaVersion = 5

    public let schemaVersion: Int
    public let generatedAt: Date
    public let revision: Int64
    public let tasks: [JianlingTaskSnapshot]
    public let todayHandledCount: Int
    public let hideBackgroundTasks: Bool

    public init(
        schemaVersion: Int = JianlingInboxSnapshot.currentSchemaVersion,
        generatedAt: Date,
        revision: Int64,
        tasks: [JianlingTaskSnapshot],
        todayHandledCount: Int,
        hideBackgroundTasks: Bool
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.revision = revision
        self.tasks = tasks
        self.todayHandledCount = todayHandledCount
        self.hideBackgroundTasks = hideBackgroundTasks
    }

    public static var empty: JianlingInboxSnapshot {
        JianlingInboxSnapshot(
            generatedAt: .distantPast,
            revision: 0,
            tasks: [],
            todayHandledCount: 0,
            hideBackgroundTasks: true
        )
    }

    public var visibleTasks: [JianlingTaskSnapshot] {
        hideBackgroundTasks ? tasks.filter { !$0.isBackground } : tasks
    }

    public var runningCount: Int { visibleTasks.filter { $0.state == .running }.count }
    public var unreadCount: Int { visibleTasks.filter { $0.state == .unread }.count }
    public var pendingCount: Int { visibleTasks.filter { $0.state == .pending }.count }
    public var routineCount: Int { visibleTasks.filter(\.isRoutine).count }

    /// Content-level equality for change detection. Ignores `generatedAt`,
    /// `revision`, and `schemaVersion`, which advance on every publish even
    /// when nothing the companion devices care about has changed.
    public func hasSameContent(as other: JianlingInboxSnapshot) -> Bool {
        tasks == other.tasks
            && todayHandledCount == other.todayHandledCount
            && hideBackgroundTasks == other.hideBackgroundTasks
    }
}

public struct JianlingRemoteAction: Identifiable, Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable {
        case open
        case markRead
        case markHandled
    }

    public let id: UUID
    public let kind: Kind
    public let taskID: String
    public let turnFingerprint: String?
    public let createdAt: Date
    public let sourceDeviceName: String?

    public init(
        id: UUID = UUID(),
        kind: Kind,
        taskID: String,
        turnFingerprint: String? = nil,
        createdAt: Date = Date(),
        sourceDeviceName: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.taskID = taskID
        self.turnFingerprint = turnFingerprint
        self.createdAt = createdAt
        self.sourceDeviceName = sourceDeviceName
    }
}
