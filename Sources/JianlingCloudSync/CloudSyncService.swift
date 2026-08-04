import CloudKit
import Foundation
import JianlingShared

public enum JianlingCloudConfiguration {
    public static let containerIdentifier = "iCloud.com.suifeng.jianling"
}

public enum JianlingCloudCodec {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(type, from: data)
    }
}

public final class JianlingCloudSyncService: @unchecked Sendable {
    public enum SyncError: Error {
        case missingPayload
        case accountUnavailable(CKAccountStatus)
    }

    private enum RecordType {
        static let snapshot = "JianlingInboxSnapshot"
        static let action = "JianlingRemoteAction"
    }

    private enum Field {
        static let payload = "payload"
        static let revision = "revision"
        static let createdAt = "createdAt"
    }

    private let container: CKContainer
    private let database: CKDatabase
    private let snapshotRecordID = CKRecord.ID(recordName: "current-inbox")

    public init(containerIdentifier: String = JianlingCloudConfiguration.containerIdentifier) {
        self.container = CKContainer(identifier: containerIdentifier)
        self.database = container.privateCloudDatabase
    }

    public func accountStatus(completion: @escaping (Result<CKAccountStatus, Error>) -> Void) {
        container.accountStatus { status, error in
            if let error { completion(.failure(error)) } else { completion(.success(status)) }
        }
    }

    public func upload(
        snapshot: JianlingInboxSnapshot,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        do {
            let record = CKRecord(recordType: RecordType.snapshot, recordID: snapshotRecordID)
            record[Field.payload] = try JianlingCloudCodec.encode(snapshot) as NSData
            record[Field.revision] = NSNumber(value: snapshot.revision)
            record[Field.createdAt] = snapshot.generatedAt as NSDate
            database.save(record) { _, error in
                if let error { completion(.failure(error)) } else { completion(.success(())) }
            }
        } catch {
            completion(.failure(error))
        }
    }

    public func fetchSnapshot(
        completion: @escaping (Result<JianlingInboxSnapshot?, Error>) -> Void
    ) {
        database.fetch(withRecordID: snapshotRecordID) { record, error in
            if let cloudError = error as? CKError, cloudError.code == .unknownItem {
                completion(.success(nil))
                return
            }
            if let error {
                completion(.failure(error))
                return
            }
            guard let data = record?[Field.payload] as? Data else {
                completion(.failure(SyncError.missingPayload))
                return
            }
            do {
                completion(.success(try JianlingCloudCodec.decode(JianlingInboxSnapshot.self, from: data)))
            } catch {
                completion(.failure(error))
            }
        }
    }

    public func upload(
        action: JianlingRemoteAction,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        do {
            let recordID = CKRecord.ID(recordName: action.id.uuidString)
            let record = CKRecord(recordType: RecordType.action, recordID: recordID)
            record[Field.payload] = try JianlingCloudCodec.encode(action) as NSData
            record[Field.createdAt] = action.createdAt as NSDate
            database.save(record) { _, error in
                if let error { completion(.failure(error)) } else { completion(.success(())) }
            }
        } catch {
            completion(.failure(error))
        }
    }

    public func fetchActions(
        completion: @escaping (Result<[JianlingRemoteAction], Error>) -> Void
    ) {
        let query = CKQuery(recordType: RecordType.action, predicate: NSPredicate(value: true))
        query.sortDescriptors = [NSSortDescriptor(key: Field.createdAt, ascending: true)]
        database.fetch(
            withQuery: query,
            inZoneWith: nil,
            desiredKeys: [Field.payload, Field.createdAt],
            resultsLimit: 200
        ) { result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let response):
                let values = response.matchResults.compactMap { _, recordResult -> JianlingRemoteAction? in
                    guard let record = try? recordResult.get(),
                          let data = record[Field.payload] as? Data else { return nil }
                    return try? JianlingCloudCodec.decode(JianlingRemoteAction.self, from: data)
                }
                completion(.success(values))
            }
        }
    }

    public func removeAction(id: UUID, completion: @escaping (Result<Void, Error>) -> Void) {
        database.delete(withRecordID: CKRecord.ID(recordName: id.uuidString)) { _, error in
            if let cloudError = error as? CKError, cloudError.code == .unknownItem {
                completion(.success(()))
            } else if let error {
                completion(.failure(error))
            } else {
                completion(.success(()))
            }
        }
    }
}
