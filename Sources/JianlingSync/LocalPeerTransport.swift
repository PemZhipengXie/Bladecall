import Foundation
import JianlingShared
import Network

public final class JianlingLocalServer: @unchecked Sendable {
    public enum State: Equatable, Sendable {
        case stopped
        case starting
        case ready
        case paired(deviceName: String)
        case failed(String)
    }

    public var onStateChange: ((State) -> Void)?

    private let pairingCode: JianlingPairingCode
    private let peer: JianlingPeerDescriptor
    private let snapshotProvider: () -> JianlingInboxSnapshot
    private let actionHandler: (JianlingRemoteAction) -> Void
    private let queue = DispatchQueue(label: "com.suifeng.jianling.local-server")
    private var listener: NWListener?
    private var channels: [UUID: JianlingConnectionChannel] = [:]
    private var authorizedChannelIDs: Set<UUID> = []

    public init(
        pairingCode: JianlingPairingCode,
        peer: JianlingPeerDescriptor,
        snapshotProvider: @escaping () -> JianlingInboxSnapshot,
        actionHandler: @escaping (JianlingRemoteAction) -> Void
    ) {
        self.pairingCode = pairingCode
        self.peer = peer
        self.snapshotProvider = snapshotProvider
        self.actionHandler = actionHandler
    }

    public var listeningPort: UInt16? {
        queue.sync { listener?.port?.rawValue }
    }

    public func start(port: NWEndpoint.Port = .any) throws {
        guard listener == nil else { return }
        emit(.starting)
        let listener = try NWListener(using: .tcp, on: port)
        listener.service = NWListener.Service(name: peer.name, type: "_jianling._tcp")
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready: self.emit(.ready)
            case .failed(let error): self.emit(.failed(error.localizedDescription))
            case .cancelled: self.emit(.stopped)
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    public func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            listener?.cancel()
            listener = nil
            channels.values.forEach { $0.cancel() }
            channels.removeAll()
            authorizedChannelIDs.removeAll()
            emit(.stopped)
        }
    }

    public func broadcast(_ snapshot: JianlingInboxSnapshot) {
        queue.async { [weak self] in
            guard let self else { return }
            let envelope = JianlingWireEnvelope(kind: .snapshot, snapshot: snapshot)
            for id in authorizedChannelIDs {
                channels[id]?.send(envelope)
            }
        }
    }

    private func accept(_ connection: NWConnection) {
        let id = UUID()
        let channel = JianlingConnectionChannel(connection: connection, queue: queue)
        channel.onEnvelope = { [weak self] envelope in self?.receive(envelope, from: id) }
        channel.onClosed = { [weak self] in
            guard let self else { return }
            channels[id] = nil
            authorizedChannelIDs.remove(id)
            if authorizedChannelIDs.isEmpty { emit(.ready) }
        }
        channels[id] = channel
        channel.start()
    }

    private func receive(_ envelope: JianlingWireEnvelope, from id: UUID) {
        guard let channel = channels[id] else { return }
        if !authorizedChannelIDs.contains(id) {
            guard envelope.kind == .pairRequest,
                  envelope.pairingCode == pairingCode,
                  let remotePeer = envelope.peer else {
                channel.cancel()
                return
            }
            authorizedChannelIDs.insert(id)
            channel.send(JianlingWireEnvelope(kind: .pairAccepted, peer: peer))
            channel.send(JianlingWireEnvelope(kind: .snapshot, snapshot: snapshotProvider()))
            emit(.paired(deviceName: remotePeer.name))
            return
        }

        switch envelope.kind {
        case .action:
            guard let action = envelope.action else { return }
            actionHandler(action)
            channel.send(JianlingWireEnvelope(
                kind: .acknowledgement,
                acknowledgedMessageID: envelope.messageID
            ))
            channel.send(JianlingWireEnvelope(kind: .snapshot, snapshot: snapshotProvider()))
        case .ping:
            channel.send(JianlingWireEnvelope(
                kind: .acknowledgement,
                acknowledgedMessageID: envelope.messageID
            ))
        default:
            break
        }
    }

    private func emit(_ state: State) {
        DispatchQueue.main.async { [weak self] in self?.onStateChange?(state) }
    }
}

public final class JianlingLocalClient: @unchecked Sendable {
    public enum State: Equatable, Sendable {
        case idle
        case searching
        case connecting
        case paired(macName: String)
        case failed(String)
    }

    public var onStateChange: ((State) -> Void)?
    public var onSnapshot: ((JianlingInboxSnapshot) -> Void)?

    private let peer: JianlingPeerDescriptor
    private let queue = DispatchQueue(label: "com.suifeng.jianling.local-client")
    private var pairingCode: JianlingPairingCode?
    private var browser: NWBrowser?
    private var channel: JianlingConnectionChannel?
    private var paired = false
    private var acknowledgementHandlers: [UUID: (Bool) -> Void] = [:]

    public init(peer: JianlingPeerDescriptor) {
        self.peer = peer
    }

    public func connect(pairingCode: JianlingPairingCode) {
        disconnect()
        self.pairingCode = pairingCode
        emit(.searching)
        let browser = NWBrowser(for: .bonjour(type: "_jianling._tcp", domain: nil), using: .tcp)
        browser.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state { self?.emit(.failed(error.localizedDescription)) }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self, channel == nil, let endpoint = results.first?.endpoint else { return }
            connect(to: endpoint)
        }
        self.browser = browser
        browser.start(queue: queue)
    }

    public func connect(host: String, port: UInt16, pairingCode: JianlingPairingCode) {
        guard let networkPort = NWEndpoint.Port(rawValue: port) else {
            emit(.failed("无效端口"))
            return
        }
        disconnect()
        self.pairingCode = pairingCode
        connect(to: .hostPort(host: NWEndpoint.Host(host), port: networkPort))
    }

    public func disconnect() {
        browser?.cancel()
        browser = nil
        channel?.cancel()
        channel = nil
        paired = false
        acknowledgementHandlers.values.forEach { $0(false) }
        acknowledgementHandlers.removeAll()
        emit(.idle)
    }

    public func send(_ action: JianlingRemoteAction, completion: ((Bool) -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self, paired, let channel else {
                DispatchQueue.main.async { completion?(false) }
                return
            }
            let envelope = JianlingWireEnvelope(kind: .action, action: action)
            if let completion { acknowledgementHandlers[envelope.messageID] = completion }
            channel.send(envelope)
        }
    }

    private func connect(to endpoint: NWEndpoint) {
        emit(.connecting)
        browser?.cancel()
        browser = nil
        let channel = JianlingConnectionChannel(
            connection: NWConnection(to: endpoint, using: .tcp),
            queue: queue
        )
        channel.onReady = { [weak self, weak channel] in
            guard let self, let channel, let pairingCode else { return }
            channel.send(JianlingWireEnvelope(
                kind: .pairRequest,
                peer: peer,
                pairingCode: pairingCode
            ))
        }
        channel.onEnvelope = { [weak self] in self?.receive($0) }
        channel.onClosed = { [weak self] in
            guard let self else { return }
            paired = false
            self.channel = nil
            emit(.failed("与 Mac 的连接已断开"))
        }
        self.channel = channel
        channel.start()
    }

    private func receive(_ envelope: JianlingWireEnvelope) {
        switch envelope.kind {
        case .pairAccepted:
            guard let mac = envelope.peer else { return }
            paired = true
            emit(.paired(macName: mac.name))
        case .snapshot:
            guard let snapshot = envelope.snapshot else { return }
            DispatchQueue.main.async { [weak self] in self?.onSnapshot?(snapshot) }
        case .acknowledgement:
            guard let id = envelope.acknowledgedMessageID,
                  let completion = acknowledgementHandlers.removeValue(forKey: id) else { return }
            DispatchQueue.main.async { completion(true) }
        default:
            break
        }
    }

    private func emit(_ state: State) {
        DispatchQueue.main.async { [weak self] in self?.onStateChange?(state) }
    }
}

private final class JianlingConnectionChannel: @unchecked Sendable {
    var onReady: (() -> Void)?
    var onEnvelope: ((JianlingWireEnvelope) -> Void)?
    var onClosed: (() -> Void)?

    private let connection: NWConnection
    private let queue: DispatchQueue
    private var buffer = Data()
    private var closed = false

    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                onReady?()
                receiveNext()
            case .failed, .cancelled:
                closeOnce()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    func send(_ envelope: JianlingWireEnvelope) {
        do {
            let data = try JianlingWireCodec.encode(envelope)
            connection.send(content: data, completion: .contentProcessed { [weak self] error in
                if error != nil { self?.closeOnce() }
            })
        } catch {
            closeOnce()
        }
    }

    func cancel() {
        connection.cancel()
        closeOnce()
    }

    private func receiveNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data { buffer.append(data) }
            do {
                for envelope in try JianlingWireCodec.decodeAvailable(from: &buffer) {
                    onEnvelope?(envelope)
                }
            } catch {
                cancel()
                return
            }
            if complete || error != nil {
                closeOnce()
            } else {
                receiveNext()
            }
        }
    }

    private func closeOnce() {
        guard !closed else { return }
        closed = true
        onClosed?()
    }
}
