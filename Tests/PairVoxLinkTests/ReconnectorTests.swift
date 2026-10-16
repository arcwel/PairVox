// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PairVoxLink
@testable import PairVoxLinkKit

/// The phone's reconnect loop: it waits longer after each failure, starts over after a success, and a nudge (the app
/// coming to the front, the network returning) ends a wait at once or checks a live session.
final class ReconnectorTests: XCTestCase {
    /// A session that lasts until the test ends it.
    final class Session: @unchecked Sendable {
        let id: Int
        private let lock = NSLock()
        private var ended: CheckedContinuation<Void, Never>?
        private var done = false
        init(_ id: Int) { self.id = id }
        func end() { lock.lock(); done = true; let c = ended; ended = nil; lock.unlock(); c?.resume() }
        func untilEnded() async {
            await withCheckedContinuation { c in
                lock.lock(); if done { lock.unlock(); c.resume(); return }; ended = c; lock.unlock()
            }
        }
    }

    struct Boom: Error {}

    /// Records every state change, with the time it happened.
    final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var states: [(Date, Reconnector<Session>.State)] = []
        func add(_ s: Reconnector<Session>.State) { lock.lock(); states.append((Date(), s)); lock.unlock() }
        var all: [(Date, Reconnector<Session>.State)] { lock.lock(); defer { lock.unlock() }; return states }
        var waits: [TimeInterval] { all.compactMap { if case .waiting(let d, _) = $0.1 { return d } else { return nil } } }
        var connects: [Date] { all.compactMap { if case .connecting = $0.1 { return $0.0 } else { return nil } } }
        var connectedCount: Int { all.filter { if case .connected = $0.1 { return true } else { return false } }.count }
    }

    /// A connect that fails `failures` times, then hands out sessions in order.
    final class Dial: @unchecked Sendable {
        private let lock = NSLock()
        var failures: Int
        private(set) var attempts = 0
        private(set) var sessions: [Session] = []
        private(set) var closed: [Int] = []
        private(set) var checked: [Int] = []
        init(failures: Int) { self.failures = failures }
        func connect() throws -> Session {
            lock.lock(); defer { lock.unlock() }
            attempts += 1
            if failures > 0 { failures -= 1; throw Boom() }
            let s = Session(attempts); sessions.append(s); return s
        }
        func didClose(_ s: Session) { lock.lock(); closed.append(s.id); lock.unlock() }
        func didCheck(_ s: Session) { lock.lock(); checked.append(s.id); lock.unlock() }
        var last: Session? { lock.lock(); defer { lock.unlock() }; return sessions.last }
    }

    func make(_ dial: Dial, _ log: Log, policy: Reconnector<Session>.Policy, checkEnds: Bool = false) -> Reconnector<Session> {
        Reconnector<Session>(policy: policy,
                             connect: { try dial.connect() },
                             run: { s in await s.untilEnded() },
                             check: { s in dial.didCheck(s); if checkEnds { s.end() } },
                             close: { s in dial.didClose(s) },
                             onState: { log.add($0) })
    }

    func eventually(_ what: String, within seconds: Double = 2, _ condition: @escaping () -> Bool) async {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end, !condition() { try? await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(condition(), what)
    }

    func testTheWaitDoublesUpToTheCapAndStartsOverAfterASession() async throws {
        let dial = Dial(failures: 4), log = Log()
        let r = make(dial, log, policy: .init(firstDelay: 0.05, maxDelay: 0.2))
        await r.start()
        await eventually("four failures then a session") { dial.last != nil }
        XCTAssertEqual(log.waits, [0.05, 0.1, 0.2, 0.2], "each failure waits twice as long, up to the cap")
        XCTAssertEqual(log.connectedCount, 1)
        let first = dial.last!
        XCTAssertEqual(first.id, 5, "the fifth attempt was the first to connect")
        first.end()
        await eventually("a new session after the first ended") { dial.sessions.count == 2 }
        XCTAssertEqual(log.waits.last, 0.05, "after a session the wait starts over at the first delay")
        XCTAssertEqual(dial.closed, [5], "the ended session was closed")
        await r.stop()
    }

    func testANudgeEndsALongWaitAtOnce() async throws {
        let dial = Dial(failures: 1), log = Log()
        let r = make(dial, log, policy: .init(firstDelay: 8, maxDelay: 8))
        await r.start()
        await eventually("the first attempt failed and the loop is waiting") { !log.waits.isEmpty }
        let nudgedAt = Date()
        await r.nudge()
        await eventually("a second attempt right after the nudge", within: 1) { dial.attempts == 2 }
        XCTAssertLessThan(Date().timeIntervalSince(nudgedAt), 1, "the 8 s wait did not run its course")
        XCTAssertNotNil(dial.last)
        await r.stop()
    }

    func testANudgeWhileConnectedRunsTheCheckAndADeadSessionIsReplaced() async throws {
        let dial = Dial(failures: 0), log = Log()
        let r = make(dial, log, policy: .init(firstDelay: 0.05, maxDelay: 0.05), checkEnds: true)
        await r.start()
        await eventually("connected") { dial.last != nil }
        await r.nudge()
        XCTAssertEqual(dial.checked, [1], "the live session was checked, not replaced blindly")
        await eventually("the check ended the session and a new one followed") { dial.sessions.count == 2 }
        XCTAssertEqual(dial.closed, [1])
        await r.stop()
    }

    func testANudgeWhileConnectedLeavesAHealthySessionAlone() async throws {
        let dial = Dial(failures: 0), log = Log()
        let r = make(dial, log, policy: .init(firstDelay: 0.05, maxDelay: 0.05))
        await r.start()
        await eventually("connected") { dial.last != nil }
        await r.nudge(); await r.nudge()
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(dial.sessions.count, 1, "a healthy session is kept")
        XCTAssertEqual(dial.checked, [1, 1])
        await r.stop()
    }

    func testStopClosesTheSessionAndEndsTheLoop() async throws {
        let dial = Dial(failures: 0), log = Log()
        let r = make(dial, log, policy: .init(firstDelay: 0.02, maxDelay: 0.02))
        await r.start()
        await eventually("connected") { dial.last != nil }
        await r.stop()
        XCTAssertEqual(dial.closed, [1])
        if case .stopped = log.all.last!.1 {} else { XCTFail("the last state is stopped") }
        dial.last!.end()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(dial.attempts, 1, "nothing reconnects after stop")
    }

    struct Refused: Error {}

    func testARefusalStopsTheRetriesUntilANudge() async throws {
        let dial = Dial(failures: 0), log = Log()
        let refusals = Counter(2)
        let r = Reconnector<Session>(policy: .init(firstDelay: 0.02, maxDelay: 0.02),
                                     connect: { if refusals.take() { throw Refused() }; return try dial.connect() },
                                     run: { s in await s.untilEnded() },
                                     close: { s in dial.didClose(s) },
                                     isPermanent: { $0 is Refused },
                                     onState: { log.add($0) })
        await r.start()
        await eventually("gave up") { if case .gaveUp = log.all.last?.1 { return true } else { return false } }
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(dial.attempts, 0, "a refused phone does not keep knocking")
        XCTAssertEqual(log.waits, [], "a refusal is not a wait")
        await r.nudge()                                      // the app came to the front: one more try, refused again
        await eventually("gave up again") { log.all.filter { if case .gaveUp = $0.1 { return true } else { return false } }.count == 2 }
        await r.nudge()                                      // this time the Mac knows the phone
        await eventually("connected after the Mac accepted") { dial.last != nil }
        await r.stop()
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock(); private var left: Int
        init(_ n: Int) { left = n }
        func take() -> Bool { lock.lock(); defer { lock.unlock() }; if left > 0 { left -= 1; return true }; return false }
    }

    func testStartAgainDropsTheOldLoop() async throws {
        let dial = Dial(failures: 0), log = Log()
        let r = make(dial, log, policy: .init(firstDelay: 0.02, maxDelay: 0.02))
        await r.start()
        await eventually("connected") { dial.last != nil }
        await r.start()
        await eventually("a second session from the new loop") { dial.sessions.count == 2 }
        dial.sessions[0].end()
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(dial.sessions.count, 2, "the old session ending does not make the old loop reconnect")
        await r.stop()
    }
}

/// A phone that comes back to the front after iOS suspended it closes a link the Mac has been silent on.
extension LinkTests {
    func testAClientClosesALinkTheMacHasBeenQuietOnWhenAsked() async throws {
        let (host, _, pairing, _) = await makeHost()
        let (id, psk) = try await pairPhone(host, pairing)
        let client = try await connect(host, id, psk)
        await host.publish(snapshot())
        _ = try await nextSnapshot(client)
        try await Task.sleep(nanoseconds: 120_000_000)
        let fresh = await client.closeIfSilent(longerThan: 5)
        XCTAssertFalse(fresh, "a link that was heard from recently is kept")
        let stale = await client.closeIfSilent(longerThan: 0.1)
        XCTAssertTrue(stale, "a link the Mac has been quiet on is closed")
        do { _ = try await client.receive(); XCTFail("receive ends on a closed link") } catch {}
    }
}
