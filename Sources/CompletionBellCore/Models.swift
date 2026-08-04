import Foundation

public enum ToolKind: String, Codable, CaseIterable, Hashable {
    case craft
    case claudeCode
    case codex
    case newMax
    case workBuddy

    public var displayName: String {
        switch self {
        case .craft: return "Craft Agents"
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        case .newMax: return "NewMax"
        case .workBuddy: return "WorkBuddy"
        }
    }

    public var bundleIdentifier: String {
        switch self {
        case .craft: return "com.lukilabs.craft-agent"
        case .claudeCode: return "com.anthropic.claudefordesktop"
        case .codex: return "com.openai.codex"
        case .newMax: return "cc.newmax.desktop"
        case .workBuddy: return "com.workbuddy.workbuddy"
        }
    }
}

public enum SessionStatus: String, Codable, Hashable {
    case running
    case completed
    case idle
    case unknown
}

public enum SessionOrigin: String, Codable, CaseIterable, Hashable {
    case interactive
    case scheduled
    case subagent
    case externalRuntime
    case detached

    /// A result that was intentionally produced on a schedule and should be
    /// reviewed in the dedicated routine inbox instead of hidden as runtime noise.
    public var isRoutine: Bool { self == .scheduled }

    /// Technical execution details that are useful for diagnostics but usually
    /// do not deserve the user's attention.
    public var isBackground: Bool {
        switch self {
        case .subagent, .externalRuntime, .detached: return true
        case .interactive, .scheduled: return false
        }
    }

    public var displayName: String {
        switch self {
        case .interactive: return "对话"
        case .scheduled: return "例行任务"
        case .subagent: return "子 Agent"
        case .externalRuntime: return "外部运行"
        case .detached: return "不可见 Session"
        }
    }
}

public enum AttentionState: String, Codable, Hashable {
    case running
    case unread
    case pending
    case handled

    public var needsUserAttention: Bool {
        self == .unread || self == .pending
    }
}

public enum SessionDisplayBucket: String, Hashable {
    case active
    case pending
    case routine
    case background
    case hidden
}

public struct SessionDisplayPolicy {
    public let activeWindow: TimeInterval
    public let backgroundWindow: TimeInterval

    public init(
        activeWindow: TimeInterval = 15 * 60,
        backgroundWindow: TimeInterval = 6 * 60 * 60
    ) {
        self.activeWindow = activeWindow
        self.backgroundWindow = backgroundWindow
    }

    public func bucket(
        for session: SessionSnapshot,
        attention: AttentionState,
        now: Date = Date()
    ) -> SessionDisplayBucket {
        switch attention {
        case .handled:
            return .hidden
        case .unread, .pending:
            if session.isRoutine { return .routine }
            return session.isBackground ? .background : .pending
        case .running:
            let age = max(0, now.timeIntervalSince(session.lastActivity))
            if session.isRoutine { return age <= backgroundWindow ? .routine : .hidden }
            if session.isBackground { return age <= backgroundWindow ? .background : .hidden }
            if age <= activeWindow { return .active }
            return age <= backgroundWindow ? .background : .hidden
        }
    }

    public func isStalled(
        _ session: SessionSnapshot,
        attention: AttentionState,
        now: Date = Date()
    ) -> Bool {
        attention == .running
            && !session.isBackground
            && bucket(for: session, attention: attention, now: now) == .background
    }
}

public struct SessionSnapshot: Identifiable, Codable, Hashable {
    public let id: String
    public let tool: ToolKind
    public let sessionID: String
    public let title: String
    public let status: SessionStatus
    public let lastActivity: Date
    public let completionFingerprint: String?
    public let sourceFile: String
    public let projectPath: String?
    public let hasUnread: Bool
    public let origin: SessionOrigin
    public let isHostVisible: Bool
    public let turnStartedAt: Date?
    public let turnCompletedAt: Date?

    public init(
        tool: ToolKind,
        sessionID: String,
        title: String,
        status: SessionStatus,
        lastActivity: Date,
        completionFingerprint: String?,
        sourceFile: String,
        projectPath: String? = nil,
        hasUnread: Bool = false,
        origin: SessionOrigin = .interactive,
        isHostVisible: Bool = true,
        turnStartedAt: Date? = nil,
        turnCompletedAt: Date? = nil
    ) {
        self.id = "\(tool.rawValue):\(sessionID)"
        self.tool = tool
        self.sessionID = sessionID
        self.title = title
        self.status = status
        self.lastActivity = lastActivity
        self.completionFingerprint = completionFingerprint
        self.sourceFile = sourceFile
        self.projectPath = projectPath
        self.hasUnread = hasUnread
        self.origin = origin
        self.isHostVisible = isHostVisible
        self.turnStartedAt = turnStartedAt
        self.turnCompletedAt = turnCompletedAt
    }


    public var isRoutine: Bool { origin.isRoutine }

    public var isBackground: Bool {
        guard !isRoutine else { return false }
        return origin.isBackground || !isHostVisible
    }
}

public struct CompletionEvent: Identifiable, Codable, Hashable {
    public let id: String
    public let session: SessionSnapshot
    public let detectedAt: Date

    public init(session: SessionSnapshot, detectedAt: Date) {
        self.id = session.completionFingerprint ?? "\(session.id):\(detectedAt.timeIntervalSince1970)"
        self.session = session
        self.detectedAt = detectedAt
    }
}

public struct AdapterScanResult {
    public let tool: ToolKind
    public let sessions: [SessionSnapshot]
    public let errors: [String]
    public let diagnostics: AdapterScanDiagnostics

    public init(
        tool: ToolKind,
        sessions: [SessionSnapshot],
        errors: [String] = [],
        diagnostics: AdapterScanDiagnostics = .empty
    ) {
        self.tool = tool
        self.sessions = sessions
        self.errors = errors
        self.diagnostics = diagnostics
    }
}

/// Paths accumulated for one adapter between the first filesystem event and
/// the debounced scan. Content and metadata are deliberately separate: a
/// host-side rename must refresh titles without making us parse transcripts.
public struct AdapterChangeSet: Equatable, Sendable {
    public var contentPaths: Set<String>
    public var metadataPaths: Set<String>
    public var requiresFullScan: Bool
    public var fullScanReason: String?

    public init(
        contentPaths: Set<String> = [],
        metadataPaths: Set<String> = [],
        requiresFullScan: Bool = false,
        fullScanReason: String? = nil
    ) {
        self.contentPaths = contentPaths
        self.metadataPaths = metadataPaths
        self.requiresFullScan = requiresFullScan
        self.fullScanReason = fullScanReason
    }

    public var pathCount: Int { contentPaths.count + metadataPaths.count }

    public mutating func merge(_ other: AdapterChangeSet) {
        contentPaths.formUnion(other.contentPaths)
        metadataPaths.formUnion(other.metadataPaths)
        if other.requiresFullScan {
            requiresFullScan = true
            fullScanReason = fullScanReason ?? other.fullScanReason
        }
    }
}

public struct AdapterScanDiagnostics: Equatable, Sendable {
    public let didFullDiscovery: Bool
    public let changedPathCount: Int
    public let discoveryDuration: TimeInterval
    public let parseDuration: TimeInterval
    public let parsedFileCount: Int
    public let fullScanReason: String?

    public init(
        didFullDiscovery: Bool,
        changedPathCount: Int,
        discoveryDuration: TimeInterval,
        parseDuration: TimeInterval,
        parsedFileCount: Int,
        fullScanReason: String? = nil
    ) {
        self.didFullDiscovery = didFullDiscovery
        self.changedPathCount = changedPathCount
        self.discoveryDuration = discoveryDuration
        self.parseDuration = parseDuration
        self.parsedFileCount = parsedFileCount
        self.fullScanReason = fullScanReason
    }

    public static let empty = AdapterScanDiagnostics(
        didFullDiscovery: false,
        changedPathCount: 0,
        discoveryDuration: 0,
        parseDuration: 0,
        parsedFileCount: 0
    )
}

public protocol SessionAdapter {
    var tool: ToolKind { get }
    /// Directories containing session content.
    var watchRoots: [URL] { get }
    /// Directories containing host-side title / visibility metadata.
    var metadataWatchRoots: [URL] { get }
    /// Individual metadata files outside the watched roots (usually SQLite
    /// databases, WALs, or append-only rename indexes).
    var metadataWatchFiles: [URL] { get }
    func scan(now: Date) -> AdapterScanResult
    /// `changes == nil` is a full scan. Adapters that have not opted into
    /// incremental discovery retain the old behavior through the default.
    func scan(now: Date, changes: AdapterChangeSet?) -> AdapterScanResult
    func invalidateCache()
}

public extension SessionAdapter {
    var watchRoots: [URL] { [] }
    var metadataWatchRoots: [URL] { [] }
    var metadataWatchFiles: [URL] { [] }
    func scan(now: Date, changes: AdapterChangeSet?) -> AdapterScanResult { scan(now: now) }
    func invalidateCache() {}
}

public enum NotificationMode: String, Codable, CaseIterable, Identifiable {
    case batch
    case watchedOnly
    case instant

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .batch: return "30 分钟合并通知"
        case .watchedOnly: return "仅关注会话即时"
        case .instant: return "每个结果立即通知"
        }
    }
}
