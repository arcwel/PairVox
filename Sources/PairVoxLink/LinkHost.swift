// SPDX-License-Identifier: Apache-2.0

import Foundation
import PairVoxCore
import PairVoxLinkKit

/// What the host does to the engine on the phone's behalf. The real implementation wraps `ConversationEngine`;
/// tests use a fake.
public protocol LinkEngine: Sendable {
    func submit(_ text: String) async
    func approve(requestID: String, projectID: String?) async
    func deny(requestID: String, projectID: String?) async
    func interrupt() async
    /// False when there is nothing to send text to (the Mac has no project open). The phone is told, instead of its
    /// message going nowhere without a word.
    func canSubmit() async -> Bool
    /// Makes the project with this id the active one. False when there is no such open project.
    func switchProject(_ projectID: String) async -> Bool
}

public extension LinkEngine {
    func canSubmit() async -> Bool { true }
    func switchProject(_ projectID: String) async -> Bool { false }
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
        /// What is waiting to go to this phone, and whether a writer is already sending it. A phone that stops reading
        /// must only ever hold up itself, never `publish` and never the other phones.
        var outbox: [Outgoing] = []
        var writing = false
        /// When anything last arrived from, and went to, this phone.
        var lastHeard: Date
        var lastSent: Date
        /// True once the phone has pinged: only a phone that does has to keep talking. An older phone app that never
        /// pings is not cut off for being quiet.
        var keepAlive = false
        init(codec: FrameCodec, transport: LinkTransport, deviceID: String, now: Date) {
            self.codec = codec; self.transport = transport; self.deviceID = deviceID; lastHeard = now; lastSent = now
        }
    }

    struct Outgoing { var message: HostMessage; var presentedKeys: [String] }

    // MARK: Engine -> phone

    /// Called by the app whenever the engine's state changes.
    public func publish(_ raw: LinkSnapshot) async {
        let snapshot = raw.bounded()
        let now = clock()
        let live = ([snapshot.request].compactMap { $0 } + snapshot.others).map { key($0.projectID, $0.requestID, active: snapshot.activeProjectID) }
        for k in live { firstSeen[k] = firstSeen[k] ?? now }
        firstSeen = firstSeen.filter { live.contains($0.key) }
        latest = snapshot
        for (id, c) in connections { await push(snapshot, to: c, id: id) }
    }

    /// The paired devices that have a live connection right now.
    public func connectedDeviceIDs() -> Set<String> { Set(connections.values.map(\.deviceID)) }

    /// Largest audio sent in one message; bigger sentences go as text. Base64 inside JSON grows it by a third, and a
    /// frame may be at most 1 MiB.
    public static let maxSpeakAudioBytes = 512 * 1024

    /// Plays a sentence of the Mac's voice on every connected phone; too large or empty audio goes as its text.
    public func speakAudio(format: String, data: Data, text rawText: String) async {
        let text = LinkSnapshot.cut(rawText, 8192).text
        guard !data.isEmpty, data.count <= Self.maxSpeakAudioBytes else { await speak(text); return }
        for (id, c) in connections {
            guard await pairing.activeDevice(c.deviceID) != nil else { await dropDevice(c.deviceID); continue }
            enqueue(.speakAudio(format: format, data: data, text: text), to: c, id: id)
        }
    }

    /// Tells every connected phone the Mac stopped speaking.
    public func stopSpeaking() async {
        for (id, c) in connections { enqueue(.stopSpeaking, to: c, id: id) }
    }

    public func speak(_ rawText: String) async {
        let text = LinkSnapshot.cut(rawText, 8192).text
        for (id, c) in connections {
            guard await pairing.activeDevice(c.deviceID) != nil else { await dropDevice(c.deviceID); continue }
            enqueue(.speak(text), to: c, id: id)
        }
    }

    private var closed = false
    private var preAuth = 0
    private var preAuthByPeer: [String: Int] = [:]
    public static let maxPreAuthPerPeer = 3
    public static let maxPreAuth = 8
    public static let maxConnectionsPerDevice = 3
    public static let preAuthTimeout: TimeInterval = 10
    /// How long the Mac waits for a phone to confirm that it received its key.
    public static let ackTimeout: TimeInterval = 10

    /// How the link notices a phone that has silently gone: while idle the Mac re-sends its latest state every
    /// `heartbeat` seconds, and a phone that pings but then stays quiet for `idle` seconds is dropped.
    public struct Timing: Sendable {
        public var heartbeat: TimeInterval = 10
        public var idle: TimeInterval = 35
        public var tick: TimeInterval = 5
        public init(heartbeat: TimeInterval = 10, idle: TimeInterval = 35, tick: TimeInterval = 5) { self.heartbeat = heartbeat; self.idle = idle; self.tick = tick }
    }
    private var timing = Timing()
    /// What a phone is sent while the Mac has published nothing yet.
    static let idleSnapshot = LinkSnapshot(phase: "idle", project: "", transcriptTail: [], request: nil, queuedRequests: 0)
    private var watchdog: Task<Void, Never>?
    public func setTiming(_ t: Timing) { timing = t }

    private func startWatchdogIfNeeded() {
        guard watchdog == nil else { return }
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let tick = await self.timing.tick
                try? await Task.sleep(nanoseconds: UInt64(tick * 1_000_000_000))
                if Task.isCancelled { return }
                await self.watchdogTick()
            }
        }
    }

    private func watchdogTick() async {
        let now = clock()
        for (id, c) in connections {
            if c.keepAlive, now.timeIntervalSince(c.lastHeard) > timing.idle {
                connections[id] = nil
                connectionsChanged(connections.count)
                log("link.idleDropped")
                await c.transport.close()
            } else if now.timeIntervalSince(c.lastSent) >= timing.heartbeat, !c.writing {
                // With no state yet (the Mac has no project open) a bare idle state still goes out, so a phone that
                // pings is not dropped by its own silence timer for a link that is perfectly healthy.
                await push(latest ?? Self.idleSnapshot, to: c, id: id)
            }
        }
    }

    /// Closes every connection and refuses new ones. Used when the link is switched off.
    public func shutdown() async {
        closed = true
        watchdog?.cancel()
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

    /// One identity per request: the request on the Mac's screen is keyed by the project it belongs to, the same as
    /// when it later shows up under "other projects", so switching projects never resets its age.
    func key(_ projectID: String?, _ requestID: String, active: String? = nil) -> String { (projectID ?? active ?? latest?.activeProjectID ?? "") + "/" + requestID }

    private func push(_ snap: LinkSnapshot, to c: Connection, id: UUID) async {
        // Nothing is sent to a phone that has been removed, even if its connection is still open.
        guard await pairing.activeDevice(c.deviceID) != nil else { await dropDevice(c.deviceID); return }
        var out = snap
        func aged(_ request: LinkRequest) -> LinkRequest {
            var r = request
            let seen = firstSeen[key(r.projectID, r.requestID)] ?? clock()
            r.ageSeconds = max(0, Int(clock().timeIntervalSince(seen)))
            return r
        }
        out.request = out.request.map(aged)
        out.others = out.others.map(aged)
        // Only a request that really went out counts as shown on this phone: the writer marks it after the send.
        let keys = ([out.request].compactMap { $0 } + out.others).map { key($0.projectID, $0.requestID) }
        enqueue(.snapshot(out), presented: keys, to: c, id: id)
    }

    /// How long one send to a phone may take before the phone is considered gone.
    public static let sendTimeout: TimeInterval = 10
    static let maxOutbox = 32

    /// Queues a message for a phone and returns at once. A newer snapshot replaces an older one that has not gone out
    /// yet, so a slow phone sees the latest state instead of a backlog.
    private func enqueue(_ m: HostMessage, presented: [String] = [], to c: Connection, id: UUID) {
        if case .snapshot = m { c.outbox.removeAll { if case .snapshot = $0.message { return true }; return false } }
        c.outbox.append(Outgoing(message: m, presentedKeys: presented))
        if c.outbox.count > Self.maxOutbox { c.outbox.removeFirst(c.outbox.count - Self.maxOutbox) }
        guard !c.writing else { return }
        c.writing = true
        Task { await self.drain(c, id: id) }
    }

    /// The one writer for a phone: sends in order, and cuts a phone off that cannot take data.
    private func drain(_ c: Connection, id: UUID) async {
        while !c.outbox.isEmpty {
            let item = c.outbox.removeFirst()
            do {
                let frame = try c.codec.seal(try JSONEncoder().encode(item.message))
                let transport = c.transport
                // Marked before the send, not after it. The send is an await, and while this actor waits there the
                // phone can already have the card and answer it; marking afterwards refused that answer as "not shown
                // on this phone yet" (seen on CI with the in-memory transport). A send that fails closes the
                // connection below, so nothing can be approved on the strength of a card that did not go out.
                for k in item.presentedKeys { c.presented[k] = clock() }
                try await Self.within(Self.sendTimeout, transport) { try await transport.send(frame) }
            } catch {
                c.outbox.removeAll()
                c.writing = false
                if connections[id] != nil { connections[id] = nil; connectionsChanged(connections.count) }
                log("link.slowPhoneDropped")
                await c.transport.close()
                return
            }
            c.lastSent = clock()
        }
        c.writing = false
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
            let before = Set(await pairing.pairedDevices().map(\.id))
            let grant = try await pairing.redeem(request, peer: transport.peer ?? "unknown", now: clock(), accept: accept)
            do {
                try await transport.send(try JSONEncoder().encode(PairReply.grant(grant)))
                let reply = try await Self.within(Self.ackTimeout, transport) { try await transport.receive() }
                guard (try? JSONDecoder().decode(PairAck.self, from: reply))?.ack == true else { throw LinkError.authFailed }
            } catch {
                // The phone is gone (it gave up waiting for the click) or never confirmed: a phone that did not
                // receive its key must not stay on the list as paired.
                for added in await pairing.pairedDevices() where !before.contains(added.id) { try? await pairing.revoke(added.id) }
                log("pairing.undelivered \(sanitizedDeviceName(request.name))")
                throw error
            }
            // The cleaned name, as shown in the Pair dialog: the raw one can carry control and bidi characters.
            log("pairing.granted \(sanitizedDeviceName(request.name))")
        } catch {
            try? await transport.send(try JSONEncoder().encode(PairReply.failed("Pairing was not accepted.")))
            log("pairing.refused \(error)")
        }
    }

    private func serveSession(_ version: Int, _ deviceID: String, _ cNonce: Data, on transport: LinkTransport,
                              authenticated: () -> Void) async throws {
        // Same rule as pairing: a 16-byte nonce. An empty one leaves only the host's randomness in the key salt, and
        // a huge one makes an unauthenticated peer cost an HMAC over it. Ends like a wrong key would.
        guard cNonce.count == Handshake.nonceLength else { throw LinkError.authFailed }
        // A phone the Mac will not talk to is told why before the close, so it can stop retrying and say so.
        func refuse(_ reason: HandshakeRefusal.Reason) async throws -> Never {
            try? await transport.send(try JSONEncoder().encode(HandshakeRefusal(reason)))
            log("link.\(reason.rawValue)")
            throw HandshakeRefusal(reason).error
        }
        guard version == Handshake.version else { try await refuse(.versionMismatch) }
        guard let device = await pairing.activeDevice(deviceID) else {
            let known = await pairing.pairedDevices().contains { $0.id == deviceID }
            try await refuse(known ? .revoked : .unknownDevice)
        }
        let hNonce = Handshake.randomBytes(16)
        let challenge = Challenge(hostNonce: hNonce, proof: Handshake.proof(psk: device.psk, role: "host", first: cNonce, second: hNonce, deviceID: deviceID, version: version))
        try await transport.send(try JSONEncoder().encode(challenge))
        let auth = try JSONDecoder().decode(Auth.self, from: try await Self.within(Self.preAuthTimeout, transport) { try await transport.receive() })
        guard Handshake.constantTimeEqual(auth.proof, Handshake.proof(psk: device.psk, role: "client", first: hNonce, second: cNonce, deviceID: deviceID, version: version)) else {
            throw LinkError.authFailed
        }
        let keys = LinkKeys.derive(psk: device.psk, clientNonce: cNonce, hostNonce: hNonce, isHost: true)
        let connection = Connection(codec: FrameCodec(keys: keys), transport: transport, deviceID: deviceID, now: clock())
        guard !closed else { throw LinkError.closed }
        guard connections.values.filter({ $0.deviceID == deviceID }).count < Self.maxConnectionsPerDevice else { throw LinkError.closed }
        authenticated()
        let id = UUID()
        connections[id] = connection
        connectionsChanged(connections.count)
        log("link.connected \(device.name)")
        await pairing.markSeen(deviceID, now: clock())
        startWatchdogIfNeeded()
        if let latest { await push(latest, to: connection, id: id) }
        do {
            while true {
                // A device revoked while connected is cut off at its next message.
                let frame = try await transport.receive()
                guard await pairing.activeDevice(deviceID) != nil else { throw LinkError.revoked }
                let message = try JSONDecoder().decode(ClientMessage.self, from: try connection.codec.open(frame))
                connection.lastHeard = clock()
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
        case .ping: c.keepAlive = true
        case .interrupt: await engine.interrupt()
        case .submit(let text):
            guard !text.isEmpty, text.count <= 4000 else { return }
            guard await engine.canSubmit() else {
                log("link.submit.refused no project open")
                enqueue(.notice("Your Mac has no project open, so that was not sent. Open a project in PairVox on the Mac."), to: c, id: id)
                return
            }
            log("link.submit \(text.count) chars")   // the length only; the text itself is the person's
            await engine.submit(text)
        case .spokenAnswer(let requestID, let text, let projectID):
            guard text.count <= 4000 else { return }
            let target = projectID ?? latest?.activeProjectID
            switch VoiceCommand.spokenAnswer(text) {
            case .approve, .approveAlways:
                // "Always allow" from a phone is a plain allow: the session-wide rule needs the Mac.
                if let reason = approvalRefusal(requestID, projectID, .voice, .none, c) {
                    log("link.approvalRefused \(reason)")
                    enqueue(.refused(reason), to: c, id: id)
                    if let latest { await push(latest, to: c, id: id) }
                    return
                }
                log("link.approved \(requestID) via voice none\(projectID == nil ? "" : " (other project)")")
                await engine.approve(requestID: requestID, projectID: target)
            case .deny:
                guard find(requestID, projectID) != nil else { return }
                log("link.denied \(requestID) via voice")
                await engine.deny(requestID: requestID, projectID: target)
            case .unclear:
                log("link.spokenAnswer.unclear")
                enqueue(.speak("Sorry, was that a yes or a no?"), to: c, id: id)
            case .notAnAnswer:
                // Something else entirely: the same as saying it to the Mac ("no, do this instead").
                guard text.count <= 4000, await engine.canSubmit() else { return }
                log("link.submit \(text.count) chars")
                await engine.submit(text)
            }
        case .switchProject(let projectID):
            // Only a project the phone was shown: the id is the Mac's own, from its last snapshot.
            guard latest?.projects?.contains(where: { $0.id == projectID }) == true else {
                log("link.switch.unknown")
                enqueue(.notice("That project is no longer open on the Mac."), to: c, id: id)
                return
            }
            let switched = await engine.switchProject(projectID)
            log("link.switch \(switched ? "done" : "refused")")
            if !switched { enqueue(.notice("The Mac could not switch to that project."), to: c, id: id) }
        case .deny(let requestID, let projectID):
            guard find(requestID, projectID) != nil else { return }
            await engine.deny(requestID: requestID, projectID: projectID ?? latest?.activeProjectID)
        case .approve(let requestID, let method, let auth, let projectID):
            if let reason = approvalRefusal(requestID, projectID, method, auth, c) {
                log("link.approvalRefused \(reason)")
                enqueue(.refused(reason), to: c, id: id)
                if let latest { await push(latest, to: c, id: id) }
                return
            }
            log("link.approved \(requestID) via \(method.rawValue) \(auth.rawValue)\(projectID == nil ? "" : " (other project)")")
            // To the project the phone was shown, not whichever is active by the time this arrives: a switch on the
            // Mac between the last snapshot and this message would otherwise send it to the new project's engine.
            await engine.approve(requestID: requestID, projectID: projectID ?? latest?.activeProjectID)
        }
    }

    func find(_ requestID: String, _ projectID: String?) -> LinkRequest? {
        guard let latest else { return nil }
        if let projectID, projectID != latest.activeProjectID { return latest.others.first { $0.projectID == projectID && $0.requestID == requestID } }
        return latest.request?.requestID == requestID ? latest.request : nil
    }

    /// The reason an approval from the phone is not accepted, or nil if it is. The same rules cover the request on
    /// the Mac's screen and requests in other projects.
    func approvalRefusal(_ requestID: String, _ projectID: String?, _ method: ApprovalMethod, _ auth: DeviceAuth, _ c: Connection) -> String? {
        guard let request = find(requestID, projectID), let latest else { return "That request is no longer waiting." }
        if request.truncated { return "This request is too long to read on the phone. Approve it on the Mac." }
        let key = key(projectID, requestID)
        guard let shown = c.presented[key] else { return "That request has not been shown on this phone yet." }
        let age = clock().timeIntervalSince(firstSeen[key] ?? shown)
        if method == .tap {
            // A deliberate tap is the click: the phone asked for Face ID, Touch ID or the passcode first. A phone with
            // none of those set up says so, and a high-risk request then waits for the Mac (audit run 7). The claim is
            // the phone's own; this keeps an ordinary phone honest, not a modified one (backlog 3.3).
            if request.risk == "high", auth == .none { return "This phone has no passcode, so a high-risk request is approved on the Mac." }
            return nil
        }
        // Voice from here on.
        if !request.voiceApprovable {
            // High risk, or too long to read out: only the spoken phrase, only if the Mac has that switched on, and
            // only with the phone's own second confirmation (Face ID, Touch ID or the passcode).
            guard latest.voiceHighRisk else { return "This request needs a tap, not a spoken yes." }
            guard !request.needsScreen || latest.voiceNeedsScreen else { return "Claude Code says this needs you at the screen. Tap to allow." }
            guard auth != .none else { return "Confirm with Face ID, Touch ID or your passcode as well." }
        }
        if age > Self.staleAfter { return "This request is old. Check it and tap to allow." }
        return nil
    }
}
