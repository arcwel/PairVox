// SPDX-License-Identifier: Apache-2.0

import Foundation
import PairVoxLinkKit

/// What the host does to the engine on the phone's behalf. The real implementation wraps `ConversationEngine`;
/// tests use a fake.
public protocol LinkEngine: Sendable {
    func submit(_ text: String) async
    func approve(requestID: String) async
    func deny(requestID: String) async
    func interrupt() async
}

/// The Mac side of the phone link. It enforces every rule itself: the phone's messages are requests, never
/// decisions, and a request the Mac's policy would not let a voice approve cannot be approved by voice here.
public actor LinkHost {
    public static let staleAfter: TimeInterval = 300

    private let pairing: PairingManager
    private let engine: LinkEngine
    private let clock: @Sendable () -> Date
    private var latest: LinkSnapshot?
    private var firstSeen: [String: Date] = [:]
    private var connections: [UUID: Connection] = [:]
    public var log: @Sendable (String) -> Void = { _ in }
    private var connectionsChanged: @Sendable (Int) -> Void = { _ in }
    private var acceptPairing: @Sendable (String) async -> Bool = { _ in false }
    private var pairingEnded: @Sendable () -> Void = {}
    /// Called after every pairing attempt, so the screen can drop an offer that was used up or burned.
    public func setPairingObserver(_ f: @escaping @Sendable () -> Void) { pairingEnded = f }

    public init(pairing: PairingManager, engine: LinkEngine, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.pairing = pairing; self.engine = engine; self.clock = clock
    }

    /// Called with the number of connected phones whenever it changes.
    public func setConnectionObserver(_ f: @escaping @Sendable (Int) -> Void) { connectionsChanged = f }
    public func connectedCount() -> Int { connections.count }
    public func setLog(_ f: @escaping @Sendable (String) -> Void) { log = f }
    /// Asked on the Mac for every new pairing, with the phone's name. Nothing is granted unless this returns true.
    public func setPairingApproval(_ f: @escaping @Sendable (String) async -> Bool) { acceptPairing = f }

    final class Connection {
        var codec: FrameCodec
        let transport: LinkTransport
        let deviceID: String
        var presented: [String: Date] = [:]
        init(codec: FrameCodec, transport: LinkTransport, deviceID: String) { self.codec = codec; self.transport = transport; self.deviceID = deviceID }
    }

    // MARK: Engine -> phone

    /// Called by the app whenever the engine's state changes.
    public func publish(_ raw: LinkSnapshot) async {
        let snapshot = raw.bounded()
        let now = clock()
        if let r = snapshot.request { firstSeen[r.requestID] = firstSeen[r.requestID] ?? now }
        firstSeen = firstSeen.filter { id, _ in snapshot.request?.requestID == id }
        latest = snapshot
        for (id, c) in connections { await push(snapshot, to: c, id: id) }
    }

    public func speak(_ rawText: String) async {
        let text = LinkSnapshot.cut(rawText, 8192).text
        for (id, c) in connections {
            guard await pairing.activeDevice(c.deviceID) != nil else { await dropDevice(c.deviceID); continue }
            try? await send(.speak(text), on: c, id: id)
        }
    }

    private var closed = false
    private var preAuth = 0
    private var preAuthByPeer: [String: Int] = [:]
    public static let maxPreAuthPerPeer = 3
    public static let maxPreAuth = 8
    public static let maxConnectionsPerDevice = 3
    public static let preAuthTimeout: TimeInterval = 10

    /// Closes every connection and refuses new ones. Used when the link is switched off.
    public func shutdown() async {
        closed = true
        let all = Array(connections.values)
        connections.removeAll()
        for c in all { await c.transport.close() }
        connectionsChanged(0)
    }

    /// Closes every connection of a device, at once. Used when a phone is removed.
    public func dropDevice(_ deviceID: String) async {
        for (id, c) in connections where c.deviceID == deviceID {
            connections[id] = nil
            await c.transport.close()
        }
        connectionsChanged(connections.count)
    }

    private func push(_ snap: LinkSnapshot, to c: Connection, id: UUID) async {
        // Nothing is sent to a phone that has been removed, even if its connection is still open.
        guard await pairing.activeDevice(c.deviceID) != nil else { await dropDevice(c.deviceID); return }
        var out = snap
        if var r = out.request {
            let seen = firstSeen[r.requestID] ?? clock()
            r.ageSeconds = max(0, Int(clock().timeIntervalSince(seen)))
            out.request = r
        }
        guard (try? await send(.snapshot(out), on: c, id: id)) != nil else { return }
        // Only a request that really went out counts as shown on this phone.
        if let r = out.request { c.presented[r.requestID] = clock() }
    }

    private func send(_ m: HostMessage, on c: Connection, id: UUID) async throws {
        do { try await c.transport.send(try c.codec.seal(try JSONEncoder().encode(m))) }
        catch { connections[id] = nil; connectionsChanged(connections.count); await c.transport.close(); throw error }
    }

    // MARK: Phone -> engine

    /// Runs one connection until it ends. Unknown, revoked or unauthenticated devices are dropped without detail.
    public func serve(_ transport: LinkTransport) async {
        let peerKey = transport.peer ?? "unknown"
        guard !closed, preAuth < Self.maxPreAuth, (preAuthByPeer[peerKey] ?? 0) < Self.maxPreAuthPerPeer else { await transport.close(); return }
        preAuth += 1
        preAuthByPeer[peerKey, default: 0] += 1
        var counted = true
        func release() { preAuth -= 1; preAuthByPeer[peerKey, default: 1] -= 1; if preAuthByPeer[peerKey] == 0 { preAuthByPeer[peerKey] = nil } }
        defer { if counted { release() } }
        do {
            let first = try await Self.within(Self.preAuthTimeout, transport) { try await transport.receive() }
            switch try JSONDecoder().decode(Opening.self, from: first) {
            case .pair(let request): try await servePairing(request, on: transport)
            case .hello(let version, let deviceID, let clientNonce):
                try await serveSession(version, deviceID, clientNonce, on: transport) { if counted { release(); counted = false } }
            }
        } catch { log("link.ended \(error)") }
        await transport.close()
    }

    /// Runs `body`, closing the transport and throwing if it takes longer than `seconds`.
    static func within<T: Sendable>(_ seconds: TimeInterval, _ transport: LinkTransport,
                                    _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                await transport.close()
                throw LinkError.closed
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    private func servePairing(_ request: PairRequest, on transport: LinkTransport) async throws {
        guard !closed else { throw LinkError.closed }
        let accept = acceptPairing
        defer { pairingEnded() }
        do {
            let grant = try await pairing.redeem(request, peer: transport.peer ?? "unknown", now: clock(), accept: accept)
            try await transport.send(try JSONEncoder().encode(PairReply.grant(grant)))
            log("pairing.granted \(request.name)")
        } catch {
            try? await transport.send(try JSONEncoder().encode(PairReply.failed("Pairing was not accepted.")))
            log("pairing.refused \(error)")
        }
    }

    private func serveSession(_ version: Int, _ deviceID: String, _ cNonce: Data, on transport: LinkTransport,
                              authenticated: () -> Void) async throws {
        guard version == Handshake.version else { throw LinkError.versionMismatch }
        guard let device = await pairing.activeDevice(deviceID) else { log("link.unknownDevice"); throw LinkError.unknownDevice }
        let hNonce = Handshake.randomBytes(16)
        let challenge = Challenge(hostNonce: hNonce, proof: Handshake.proof(psk: device.psk, role: "host", first: cNonce, second: hNonce, deviceID: deviceID, version: version))
        try await transport.send(try JSONEncoder().encode(challenge))
        let auth = try JSONDecoder().decode(Auth.self, from: try await Self.within(Self.preAuthTimeout, transport) { try await transport.receive() })
        guard Handshake.constantTimeEqual(auth.proof, Handshake.proof(psk: device.psk, role: "client", first: hNonce, second: cNonce, deviceID: deviceID, version: version)) else {
            throw LinkError.authFailed
        }
        let keys = LinkKeys.derive(psk: device.psk, clientNonce: cNonce, hostNonce: hNonce, isHost: true)
        let connection = Connection(codec: FrameCodec(keys: keys), transport: transport, deviceID: deviceID)
        guard !closed else { throw LinkError.closed }
        guard connections.values.filter({ $0.deviceID == deviceID }).count < Self.maxConnectionsPerDevice else { throw LinkError.closed }
        authenticated()
        let id = UUID()
        connections[id] = connection
        connectionsChanged(connections.count)
        log("link.connected \(device.name)")
        if let latest { await push(latest, to: connection, id: id) }
        do {
            while true {
                // A device revoked while connected is cut off at its next message.
                let frame = try await transport.receive()
                guard await pairing.activeDevice(deviceID) != nil else { throw LinkError.revoked }
                let message = try JSONDecoder().decode(ClientMessage.self, from: try connection.codec.open(frame))
                await handle(message, from: connection, id: id)
            }
        } catch {
            connections[id] = nil
            connectionsChanged(connections.count)
            throw error
        }
    }

    private func handle(_ message: ClientMessage, from c: Connection, id: UUID) async {
        switch message {
        case .ping: break
        case .interrupt: await engine.interrupt()
        case .submit(let text):
            guard !text.isEmpty, text.count <= 4000 else { return }
            await engine.submit(text)
        case .deny(let requestID):
            guard latest?.request?.requestID == requestID else { return }
            await engine.deny(requestID: requestID)
        case .approve(let requestID, let method, let auth):
            if let reason = approvalRefusal(requestID, method, c) {
                log("link.approvalRefused \(reason)")
                try? await send(.refused(reason), on: c, id: id)
                if let latest { await push(latest, to: c, id: id) }
                return
            }
            log("link.approved \(requestID) via \(method.rawValue) \(auth.rawValue)")
            await engine.approve(requestID: requestID)
        }
    }

    /// The reason an approval from the phone is not accepted, or nil if it is.
    func approvalRefusal(_ requestID: String, _ method: ApprovalMethod, _ c: Connection) -> String? {
        guard let request = latest?.request, request.requestID == requestID else { return "That request is no longer waiting." }
        if request.truncated { return "This request is too long to read on the phone. Approve it on the Mac." }
        guard let shown = c.presented[requestID] else { return "That request has not been shown on this phone yet." }
        let age = clock().timeIntervalSince(firstSeen[requestID] ?? shown)
        if request.risk == "high" {
            guard method == .tap else { return "A high-risk request needs a tap, not a spoken yes." }
            return nil
        }
        guard request.voiceApprovable || method == .tap else { return "This request needs a tap, not a spoken yes." }
        if method == .voice, age > Self.staleAfter { return "This request is old. Check it and tap to allow." }
        return nil
    }
}
