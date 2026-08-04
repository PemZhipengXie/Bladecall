import Darwin
import Foundation
import Security

public enum JianlingSharedConfiguration {
    public static let appGroupIdentifier = "group.com.suifeng.jianling"

    public static func containerURL(fileManager: FileManager = .default) -> URL {
        if hasAppGroupEntitlement,
           let groupURL = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) {
            return groupURL.appendingPathComponent("Jianling", isDirectory: true)
        }
        return fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CompletionBell/Shared", isDirectory: true)
    }

    private static var hasAppGroupEntitlement: Bool {
        guard let task = SecTaskCreateFromSelf(nil),
              let rawValue = SecTaskCopyValueForEntitlement(
                task,
                "com.apple.security.application-groups" as CFString,
                nil
              ),
              let groups = rawValue as? [String] else { return false }
        return groups.contains(appGroupIdentifier)
    }
}

public final class JianlingSharedStore: @unchecked Sendable {
    public let directoryURL: URL
    public let snapshotURL: URL
    public let actionsDirectoryURL: URL
    public let actionReceiptsURL: URL

    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let lock = NSLock()

    public init(directoryURL: URL, fileManager: FileManager = .default) {
        self.directoryURL = directoryURL
        self.snapshotURL = directoryURL.appendingPathComponent("inbox.json")
        self.actionsDirectoryURL = directoryURL.appendingPathComponent("Actions", isDirectory: true)
        self.actionReceiptsURL = directoryURL.appendingPathComponent("action-receipts.json")
        self.fileManager = fileManager
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder.dateDecodingStrategy = .millisecondsSince1970
    }

    public convenience init() {
        self.init(directoryURL: JianlingSharedConfiguration.containerURL())
    }

    public func readSnapshot(applyingPendingActions: Bool = true) throws -> JianlingInboxSnapshot {
        try lock.withLock {
            guard fileManager.fileExists(atPath: snapshotURL.path) else { return .empty }
            let snapshot = try decoder.decode(JianlingInboxSnapshot.self, from: Data(contentsOf: snapshotURL))
            guard applyingPendingActions else { return snapshot }
            let hiddenTaskIDs = Set(
                try pendingActionsUnlocked()
                    .filter { $0.kind == .markHandled }
                    .map(\.taskID)
            )
            guard !hiddenTaskIDs.isEmpty else { return snapshot }
            return JianlingInboxSnapshot(
                schemaVersion: snapshot.schemaVersion,
                generatedAt: snapshot.generatedAt,
                revision: snapshot.revision,
                tasks: snapshot.tasks.filter { !hiddenTaskIDs.contains($0.id) },
                todayHandledCount: snapshot.todayHandledCount + hiddenTaskIDs.count,
                hideBackgroundTasks: snapshot.hideBackgroundTasks
            )
        }
    }

    public func writeSnapshot(_ snapshot: JianlingInboxSnapshot) throws {
        try lock.withLock {
            try prepareDirectoriesUnlocked()
            try encoder.encode(snapshot).write(to: snapshotURL, options: .atomic)
        }
    }

    @discardableResult
    public func reconcilePendingActions(with snapshot: JianlingInboxSnapshot) throws -> Int {
        try lock.withLock {
            let actions = try pendingActionsUnlocked()
            var removed = 0
            for action in actions where isAcknowledged(action, by: snapshot) {
                let url = actionsDirectoryURL.appendingPathComponent("\(action.id.uuidString).json")
                if fileManager.fileExists(atPath: url.path) {
                    try fileManager.removeItem(at: url)
                    removed += 1
                }
            }
            return removed
        }
    }

    @discardableResult
    public func enqueue(_ action: JianlingRemoteAction) throws -> URL {
        try lock.withLock {
            try prepareDirectoriesUnlocked()
            let url = actionsDirectoryURL.appendingPathComponent("\(action.id.uuidString).json")
            try encoder.encode(action).write(to: url, options: .atomic)
            return url
        }
    }

    public func pendingActions() throws -> [JianlingRemoteAction] {
        try lock.withLock { try pendingActionsUnlocked() }
    }

    public func removeAction(id: UUID) throws {
        try lock.withLock {
            let url = actionsDirectoryURL.appendingPathComponent("\(id.uuidString).json")
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
        }
    }

    public func hasProcessedAction(id: UUID) throws -> Bool {
        try lock.withLock {
            try actionReceiptsUnlocked()[id.uuidString] != nil
        }
    }

    public func markActionProcessed(
        id: UUID,
        at date: Date = Date(),
        retention: TimeInterval = 30 * 24 * 60 * 60
    ) throws {
        try lock.withLock {
            try prepareDirectoriesUnlocked()
            let cutoff = date.addingTimeInterval(-retention)
            var receipts = try actionReceiptsUnlocked()
                .filter { $0.value >= cutoff }
            receipts[id.uuidString] = date
            try encoder.encode(receipts).write(to: actionReceiptsURL, options: .atomic)
        }
    }

    private func prepareDirectoriesUnlocked() throws {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: actionsDirectoryURL, withIntermediateDirectories: true)
    }

    private func pendingActionsUnlocked() throws -> [JianlingRemoteAction] {
        guard fileManager.fileExists(atPath: actionsDirectoryURL.path) else { return [] }
        // Foundation's directory APIs enter the CoreServices URL enumerator and
        // can stall indefinitely for an App Group directory in an ad-hoc signed
        // macOS build. The queue only needs filenames, so enumerate it via POSIX.
        let names = try directoryEntryNames(atPath: actionsDirectoryURL.path)
        return names
            .filter { !$0.hasPrefix(".") && $0.hasSuffix(".json") }
            .map { actionsDirectoryURL.appendingPathComponent($0) }
            .compactMap { try? decoder.decode(JianlingRemoteAction.self, from: Data(contentsOf: $0)) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    private func directoryEntryNames(atPath path: String) throws -> [String] {
        guard let directory = opendir(path) else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSFilePathErrorKey: path]
            )
        }
        defer { closedir(directory) }

        var names: [String] = []
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) {
                    String(cString: $0)
                }
            }
            if name != "." && name != ".." { names.append(name) }
        }
        return names
    }

    private func actionReceiptsUnlocked() throws -> [String: Date] {
        guard fileManager.fileExists(atPath: actionReceiptsURL.path) else { return [:] }
        return try decoder.decode([String: Date].self, from: Data(contentsOf: actionReceiptsURL))
    }

    private func isAcknowledged(
        _ action: JianlingRemoteAction,
        by snapshot: JianlingInboxSnapshot
    ) -> Bool {
        guard action.kind != .open else { return false }
        guard let task = snapshot.tasks.first(where: { $0.id == action.taskID }) else {
            return true
        }
        if let targetFingerprint = action.turnFingerprint,
           task.turnFingerprint != targetFingerprint {
            // The original turn is gone and a later turn now occupies the same session.
            return true
        }
        switch action.kind {
        case .open: return false
        case .markRead: return task.state != .unread
        case .markHandled: return false
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
