import Foundation
import JianlingShared

public struct JianlingPairingCode: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init?(rawValue: String) {
        guard rawValue.count == 6, rawValue.allSatisfy(\.isNumber) else { return nil }
        self.rawValue = rawValue
    }

    public static func generate() -> JianlingPairingCode {
        var generator = SystemRandomNumberGenerator()
        let value = Int.random(in: 0...999_999, using: &generator)
        return JianlingPairingCode(rawValue: String(format: "%06d", value))!
    }
}

public struct JianlingPeerDescriptor: Codable, Hashable, Sendable {
    public enum Platform: String, Codable, Hashable, Sendable {
        case macOS
        case iOS
    }

    public let deviceID: UUID
    public let name: String
    public let platform: Platform
    public let appVersion: String

    public init(deviceID: UUID, name: String, platform: Platform, appVersion: String) {
        self.deviceID = deviceID
        self.name = name
        self.platform = platform
        self.appVersion = appVersion
    }
}

public struct JianlingWireEnvelope: Codable, Hashable, Sendable {
    public static let currentProtocolVersion = 1

    public enum Kind: String, Codable, Hashable, Sendable {
        case pairRequest
        case pairAccepted
        case snapshot
        case action
        case acknowledgement
        case ping
    }

    public let protocolVersion: Int
    public let messageID: UUID
    public let kind: Kind
    public let sentAt: Date
    public let peer: JianlingPeerDescriptor?
    public let pairingCode: JianlingPairingCode?
    public let snapshot: JianlingInboxSnapshot?
    public let action: JianlingRemoteAction?
    public let acknowledgedMessageID: UUID?

    public init(
        protocolVersion: Int = JianlingWireEnvelope.currentProtocolVersion,
        messageID: UUID = UUID(),
        kind: Kind,
        sentAt: Date = Date(),
        peer: JianlingPeerDescriptor? = nil,
        pairingCode: JianlingPairingCode? = nil,
        snapshot: JianlingInboxSnapshot? = nil,
        action: JianlingRemoteAction? = nil,
        acknowledgedMessageID: UUID? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.messageID = messageID
        self.kind = kind
        self.sentAt = sentAt
        self.peer = peer
        self.pairingCode = pairingCode
        self.snapshot = snapshot
        self.action = action
        self.acknowledgedMessageID = acknowledgedMessageID
    }

    public var isStructurallyValid: Bool {
        guard protocolVersion == Self.currentProtocolVersion else { return false }
        switch kind {
        case .pairRequest: return peer != nil && pairingCode != nil
        case .pairAccepted: return peer != nil
        case .snapshot: return snapshot != nil
        case .action: return action != nil
        case .acknowledgement: return acknowledgedMessageID != nil
        case .ping: return true
        }
    }
}

public enum JianlingWireCodec {
    public static let maximumPayloadSize = 4 * 1024 * 1024

    public static func encode(_ envelope: JianlingWireEnvelope) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        let payload = try encoder.encode(envelope)
        guard payload.count <= maximumPayloadSize else { throw CodecError.payloadTooLarge }
        var length = UInt32(payload.count).bigEndian
        var framed = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
        framed.append(payload)
        return framed
    }

    public static func decodeAvailable(from buffer: inout Data) throws -> [JianlingWireEnvelope] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        var values: [JianlingWireEnvelope] = []
        while buffer.count >= 4 {
            let length = Int(buffer.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
            guard length <= maximumPayloadSize else { throw CodecError.payloadTooLarge }
            guard buffer.count >= 4 + length else { break }
            let payload = buffer.subdata(in: 4..<(4 + length))
            let envelope = try decoder.decode(JianlingWireEnvelope.self, from: payload)
            guard envelope.isStructurallyValid else { throw CodecError.invalidEnvelope }
            values.append(envelope)
            buffer.removeSubrange(0..<(4 + length))
        }
        return values
    }

    public enum CodecError: Error, Equatable {
        case payloadTooLarge
        case invalidEnvelope
    }
}
