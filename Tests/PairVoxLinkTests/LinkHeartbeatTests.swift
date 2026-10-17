// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PairVoxLink
@testable import PairVoxLinkKit

/// A link that dies silently (Tailscale dropping, a phone out of range) sends no reset. These tests cover how each side
/// notices, and that a healthy or older phone is never cut off for no reason.
extension LinkTests {
    /// A host on the real clock: these tests are about elapsed time, which the shared fake clock never advances.
    private func realRig() async -> (LinkHost, PairingManager) {
        let pairing = PairingManager(storeURL: nil)
        let host = LinkHost(pairing: pairing, engine: FakeEngine())
        await host.setPairingApproval { _ in true }
        return (host, pairing)
    }

    private func pairReal(_ host: LinkHost, _ pairing: PairingManager) async throws -> (String, Data) {
        let offer = await pairing.createOffer()
        let (a, b) = MemoryTransport.pair()
        Task { await host.serve(b) }
        let creds = try await LinkClient.pair(over: a, material: PairingClient.material(fromQR: offer.display)!, deviceName: "Heartbeat phone")
        return (creds.deviceID, creds.psk)
    }

    private func fast(_ host: LinkHost) async { await host.setTiming(.init(heartbeat: 0.2, idle: 0.7, tick: 0.1)) }

    private func connected(_ host: LinkHost, _ n: Int, within seconds: Double = 2) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { if await host.connectedCount() == n { return true }; try? await Task.sleep(nanoseconds: 30_000_000) }
        return await host.connectedCount() == n
    }

    func testAPhoneThatPingedAndThenWentSilentIsDroppedByTheMac() async throws {
        let (host, pairing) = await realRig()
        await fast(host)
        let (id, psk) = try await pairReal(host, pairing)
        let client = try await connect(host, id, psk)
        try await client.send(.ping)                       // it opts in to being kept alive, then the link dies
        let up = await connected(host, 1)
        XCTAssertTrue(up)
        let gone = await connected(host, 0, within: 3)
        XCTAssertTrue(gone, "a ghost phone must not stay counted as connected")
        await client.close()
    }

    func testAPhoneThatKeepsPingingStaysConnected() async throws {
        let (host, pairing) = await realRig()
        await fast(host)
        let (id, psk) = try await pairReal(host, pairing)
        let client = try await connect(host, id, psk)
        await client.startKeepAlive(every: 0.2, idleAfter: 5)
        try await Task.sleep(nanoseconds: 2_000_000_000)   // nearly three times the idle limit
        let still = await host.connectedCount()
        XCTAssertEqual(still, 1)
        await client.close()
    }

    func testAnOlderPhoneThatNeverPingsIsNotCutOffForBeingQuiet() async throws {
        let (host, pairing) = await realRig()
        await fast(host)
        let (id, psk) = try await pairReal(host, pairing)
        let client = try await connect(host, id, psk)
        try await Task.sleep(nanoseconds: 2_000_000_000)
        let still = await host.connectedCount()
        XCTAssertEqual(still, 1, "only phones that opted in by pinging are held to the idle limit")
        await client.close()
    }

    func testAnIdleMacKeepsSendingItsLatestStateSoASilentLinkCanBeTold() async throws {
        let (host, pairing) = await realRig()
        await fast(host)
        let (id, psk) = try await pairReal(host, pairing)
        let client = try await connect(host, id, psk)
        final class Count: @unchecked Sendable { private let l = NSLock(); private var n = 0
            func bump() { l.lock(); n += 1; l.unlock() }; var value: Int { l.lock(); defer { l.unlock() }; return n } }
        let count = Count()
        let reader = Task { while let m = try? await client.receive() { if case .snapshot = m { count.bump() } } }
        await host.publish(snapshot(id: "R1"))
        try await Task.sleep(nanoseconds: 1_500_000_000)
        reader.cancel()
        XCTAssertGreaterThanOrEqual(count.value, 4, "one publish, then a heartbeat roughly every 0.2 s: got \(count.value)")
        await client.close()
    }

    func testAMacWithNothingPublishedYetStillSendsHeartbeatsSoAHealthyLinkIsNotDropped() async throws {
        // A Mac with no project open has published no state. Before this was fixed it sent nothing at all, so a
        // phone that pings dropped the perfectly healthy link at its own silence limit, again and again.
        let (host, pairing) = await realRig()
        await fast(host)
        let (id, psk) = try await pairReal(host, pairing)
        let client = try await connect(host, id, psk)
        await client.startKeepAlive(every: 0.1, idleAfter: 0.8)
        final class Count: @unchecked Sendable { private let l = NSLock(); private var n = 0
            func bump() { l.lock(); n += 1; l.unlock() }; var value: Int { l.lock(); defer { l.unlock() }; return n } }
        let count = Count()
        let reader = Task { while let m = try? await client.receive() { if case .snapshot(let s) = m { XCTAssertEqual(s.phase, "idle"); count.bump() } } }
        try await Task.sleep(nanoseconds: 2_000_000_000)          // well over twice the phone's idle limit
        reader.cancel()
        let still = await host.connectedCount()
        XCTAssertEqual(still, 1, "the link is still up")
        XCTAssertGreaterThanOrEqual(count.value, 4, "idle heartbeats arrived: \(count.value)")
        await client.close()
    }

    func testAPhoneThatHearsNothingFromTheMacClosesTheLinkItself() async throws {
        let (host, pairing) = await realRig()
        await host.setTiming(.init(heartbeat: 3600, idle: 3600, tick: 3600))   // a Mac that goes quiet
        let (id, psk) = try await pairReal(host, pairing)
        let client = try await connect(host, id, psk)
        await client.startKeepAlive(every: 0.2, idleAfter: 0.7)
        let began = Date()
        do {
            while true { _ = try await client.receive() }
        } catch {
            XCTAssertLessThan(Date().timeIntervalSince(began), 3, "the phone should notice a silent link within the idle limit and let its owner reconnect")
            return
        }
    }
}
