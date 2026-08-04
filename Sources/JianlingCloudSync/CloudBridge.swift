import CloudKit
import Foundation
import JianlingShared

public protocol JianlingCloudTransport: AnyObject {
    func accountStatus(completion: @escaping (Result<CKAccountStatus, Error>) -> Void)
    func upload(
        snapshot: JianlingInboxSnapshot,
        completion: @escaping (Result<Void, Error>) -> Void
    )
    func fetchSnapshot(
        completion: @escaping (Result<JianlingInboxSnapshot?, Error>) -> Void
    )
    func upload(
        action: JianlingRemoteAction,
        completion: @escaping (Result<Void, Error>) -> Void
    )
    func fetchActions(
        completion: @escaping (Result<[JianlingRemoteAction], Error>) -> Void
    )
    func removeAction(id: UUID, completion: @escaping (Result<Void, Error>) -> Void)
}

extension JianlingCloudSyncService: JianlingCloudTransport {}

public enum JianlingSnapshotConflictResolver {
    public static func shouldAcceptRemote(
        _ remote: JianlingInboxSnapshot,
        over local: JianlingInboxSnapshot
    ) -> Bool {
        if remote.revision != local.revision { return remote.revision > local.revision }
        return remote.generatedAt > local.generatedAt
    }
}

public struct JianlingCloudSyncReport: Equatable, Sendable {
    public let uploadedActions: Int
    public let importedActions: Int
    public let receivedSnapshotRevision: Int64?

    public init(
        uploadedActions: Int = 0,
        importedActions: Int = 0,
        receivedSnapshotRevision: Int64? = nil
    ) {
        self.uploadedActions = uploadedActions
        self.importedActions = importedActions
        self.receivedSnapshotRevision = receivedSnapshotRevision
    }
}

public final class JianlingCloudBridge: @unchecked Sendable {
    public enum BridgeError: LocalizedError {
        case accountUnavailable(CKAccountStatus)

        public var errorDescription: String? {
            switch self {
            case .accountUnavailable(.noAccount): return "这台设备还没有登录 iCloud"
            case .accountUnavailable(.restricted): return "这台设备限制了 iCloud 使用"
            case .accountUnavailable(.couldNotDetermine): return "暂时无法确认 iCloud 状态"
            case .accountUnavailable(.temporarilyUnavailable): return "iCloud 暂时不可用"
            case .accountUnavailable(.available): return nil
            @unknown default: return "iCloud 当前不可用"
            }
        }
    }

    private let transport: JianlingCloudTransport
    private let store: JianlingSharedStore

    public init(
        transport: JianlingCloudTransport = JianlingCloudSyncService(),
        store: JianlingSharedStore = JianlingSharedStore()
    ) {
        self.transport = transport
        self.store = store
    }

    public func verifyAccount(completion: @escaping (Result<Void, Error>) -> Void) {
        transport.accountStatus { result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(.available):
                completion(.success(()))
            case .success(let status):
                completion(.failure(BridgeError.accountUnavailable(status)))
            }
        }
    }

    public func publish(
        snapshot: JianlingInboxSnapshot,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        transport.upload(snapshot: snapshot, completion: completion)
    }

    public func fetchNewerSnapshot(
        completion: @escaping (Result<JianlingInboxSnapshot?, Error>) -> Void
    ) {
        let local: JianlingInboxSnapshot
        do {
            local = try store.readSnapshot(applyingPendingActions: false)
        } catch {
            completion(.failure(error))
            return
        }
        transport.fetchSnapshot { [store] result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(nil):
                completion(.success(nil))
            case .success(let remote?):
                guard JianlingSnapshotConflictResolver.shouldAcceptRemote(remote, over: local) else {
                    completion(.success(nil))
                    return
                }
                do {
                    try store.writeSnapshot(remote)
                    try store.reconcilePendingActions(with: remote)
                    completion(.success(remote))
                } catch {
                    completion(.failure(error))
                }
            }
        }
    }

    public func uploadPendingActions(
        completion: @escaping (Result<JianlingCloudSyncReport, Error>) -> Void
    ) {
        let actions: [JianlingRemoteAction]
        do {
            actions = try store.pendingActions()
        } catch {
            completion(.failure(error))
            return
        }
        upload(actions: actions, index: 0, uploaded: 0, completion: completion)
    }

    public func importRemoteActions(
        completion: @escaping (Result<JianlingCloudSyncReport, Error>) -> Void
    ) {
        transport.fetchActions { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let actions):
                importActions(
                    actions.sorted { $0.createdAt < $1.createdAt },
                    index: 0,
                    imported: 0,
                    completion: completion
                )
            }
        }
    }

    private func upload(
        actions: [JianlingRemoteAction],
        index: Int,
        uploaded: Int,
        completion: @escaping (Result<JianlingCloudSyncReport, Error>) -> Void
    ) {
        guard index < actions.count else {
            completion(.success(JianlingCloudSyncReport(uploadedActions: uploaded)))
            return
        }
        let action = actions[index]
        transport.upload(action: action) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success:
                do {
                    if action.kind == .open { try store.removeAction(id: action.id) }
                    upload(
                        actions: actions,
                        index: index + 1,
                        uploaded: uploaded + 1,
                        completion: completion
                    )
                } catch {
                    completion(.failure(error))
                }
            }
        }
    }

    private func importActions(
        _ actions: [JianlingRemoteAction],
        index: Int,
        imported: Int,
        completion: @escaping (Result<JianlingCloudSyncReport, Error>) -> Void
    ) {
        guard index < actions.count else {
            completion(.success(JianlingCloudSyncReport(importedActions: imported)))
            return
        }
        let action = actions[index]
        do {
            let alreadyProcessed = try store.hasProcessedAction(id: action.id)
            if !alreadyProcessed { try store.enqueue(action) }
            transport.removeAction(id: action.id) { [weak self] result in
                guard let self else { return }
                switch result {
                case .failure(let error):
                    completion(.failure(error))
                case .success:
                    importActions(
                        actions,
                        index: index + 1,
                        imported: imported + (alreadyProcessed ? 0 : 1),
                        completion: completion
                    )
                }
            }
        } catch {
            completion(.failure(error))
        }
    }
}
