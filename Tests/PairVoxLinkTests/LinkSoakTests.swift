// SPDX-License-Identifier: Apache-2.0

import Darwin
import XCTest
@testable import PairVoxLink
@testable import PairVoxLinkKit

/// Link soak: the phone link under churn, hostile clients and a storm of snapshots, over real loopback sockets.
/// `PAIRVOX_SOAK_SECONDS` sets how long (default 8).
final class LinkSoakTests: XCTestCase {
    static func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? info.resident_size : 0
    }

    struct TimedOut: Error {}

    /// A client call that fails the test instead of hanging it.
    func timed<T: Sendable>(_ seconds: Double = 12, _ op: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await op() }
            group.addTask { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)); throw TimedOut() }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    struct Rig {
        let host: LinkHost
        let pairing: PairingManager
        let listener: TCPListener
        var port: UInt16 { listener.port }
    }

    func makeRig() async throws -> Rig {
        let pairing = PairingManager(storeURL: nil)
        let host = LinkHost(pairing: pairing, engine: FakeEngine())
        await host.setPairingApproval { _ in true }
        let listener = try TCPListener(port: 0) { transport in Task { await host.serve(transport) } }
        try await listener.start()
        return Rig(host: host, pairing: pairing, listener: listener)
    }

    func pair(_ rig: Rig, name: String = "Soak phone") async throws -> (deviceID: String, psk: Data) {
        let offer = await rig.pairing.createOffer()
        let port = rig.port
        let transport = TCPTransport.connect(host: "127.0.0.1", port: port)
        do {
            return try await timed { try await LinkClient.pair(over: transport, material: PairingClient.material(fromQR: offer.display)!, deviceName: name) }
        } catch { await transport.close(); throw error }
    }

    func connect(_ rig: Rig, _ creds: (deviceID: String, psk: Data)) async throws -> LinkClient {
        let transport = TCPTransport.connect(host: "127.0.0.1", port: rig.port)
        do { return try await timed { try await LinkClient.connect(over: transport, deviceID: creds.deviceID, psk: creds.psk) } }
        catch { await transport.close(); throw error }
    }

    func snapshot(_ n: Int, padding: Int = 0) -> LinkSnapshot {
        var tail = [LinkEntry(id: n, role: "assistant", text: "Update \(n)")]
        // Large entries fill a socket quickly, which is what makes a phone that never reads actually block.
        if padding > 0 { tail = (0..<4).map { LinkEntry(id: n * 10 + $0, role: "assistant", text: String(repeating: "x", count: padding)) } + [tail[0]] }
        return LinkSnapshot(phase: "working", project: "soak", transcriptTail: tail, request: nil, queuedRequests: 0)
    }

    func waitUntil(_ timeout: Double = 3, _ condition: () async -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if await condition() { return true }; try? await Task.sleep(nanoseconds: 25_000_000) }
        return await condition()
    }

    func testChurnAndHostileClientsLeaveNothingBehind() async throws {
        signal(SIGPIPE, SIG_IGN)
        let seconds = Double(ProcessInfo.processInfo.environment["PAIRVOX_SOAK_SECONDS"] ?? "8") ?? 8
        let rig = try await makeRig()
        defer { rig.listener.stop() }
        var counts = [String: Int]()
        var rng = UInt64(7)
        func pick(_ n: Int) -> Int { rng = rng &* 6364136223846793005 &+ 1442695040888963407; return Int((rng >> 33) % UInt64(n)) }
        let started = Date()
        var warmup: UInt64 = 0
        var cycle = 0
        while Date().timeIntervalSince(started) < seconds {
            cycle += 1
            let kind = pick(5)
            counts["kind\(kind)", default: 0] += 1
            switch kind {
            case 0:   // a good phone: pair, connect, receive a snapshot, leave politely
                // Under hostile load the host may refuse (it limits half-open connections per peer): that is allowed.
                guard let creds = try? await pair(rig), let client = try? await connect(rig, creds) else { counts["refusedUnderLoad", default: 0] += 1; break }
                await rig.host.publish(snapshot(cycle))
                _ = try? await timed(5) { try await client.receive() }
                await client.close()
            case 1:   // a phone that was never paired
                let t = TCPTransport.connect(host: "127.0.0.1", port: rig.port)
                _ = try? await timed(5) { try await LinkClient.connect(over: t, deviceID: UUID().uuidString, psk: Data(repeating: 1, count: 32)) }
                await t.close()
            case 2:   // garbage bytes
                let t = TCPTransport.connect(host: "127.0.0.1", port: rig.port)
                try? await t.send(Data((0..<(1 + pick(400))).map { _ in UInt8(pick(256)) }))
                await t.close()
            case 3:   // a paired phone that vanishes mid-session without a word
                guard let creds = try? await pair(rig) else { counts["refusedUnderLoad", default: 0] += 1; break }
                let t = TCPTransport.connect(host: "127.0.0.1", port: rig.port)
                _ = try? await timed { try await LinkClient.connect(over: t, deviceID: creds.deviceID, psk: creds.psk) }
                await t.close()
            default:  // connects and leaves at once
                let t = TCPTransport.connect(host: "127.0.0.1", port: rig.port)
                await t.close()
            }
            if cycle % 25 == 0 {
                let drained = await waitUntil { await rig.host.connectedCount() == 0 }
                XCTAssertTrue(drained, "after \(cycle) cycles connections were still counted as open")
                if warmup == 0, Date().timeIntervalSince(started) > 2 { warmup = Self.residentBytes() }
            }
        }
        let drained = await waitUntil(5) { await rig.host.connectedCount() == 0 }
        XCTAssertTrue(drained, "connections left open at the end")
        // The service still works after all of that. Half-open connections count against the per-peer limit until the
        // host notices they are gone, so allow it up to the pre-auth timeout to clear.
        var recovered: LinkClient?
        for _ in 0..<14 {
            if let creds = try? await pair(rig, name: "Last phone"), let c = try? await connect(rig, creds) { recovered = c; break }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        let client = try XCTUnwrap(recovered, "the link did not accept a good phone within 14 s of the churn ending")
        await rig.host.publish(snapshot(999_999))
        // A host sends a phone the state it already has the moment it connects, which can be the last snapshot of the
        // churn, so the first snapshot is not necessarily the one just published: read until the marker arrives.
        let sawMarker = try await timed { () async throws -> Bool in
            for _ in 0..<5 {
                if case .snapshot(let s) = try await client.receive(), s.transcriptTail.last?.id == 999_999 { return true }
            }
            return false
        }
        XCTAssertTrue(sawMarker, "the snapshot published after the churn reached the new phone")
        await client.close()
        let growthMB = warmup == 0 ? 0 : (Double(Self.residentBytes()) - Double(warmup)) / 1_048_576
        print("SOAK link churn: \(cycle) cycles in \(Int(seconds)) s \(counts.sorted { $0.key < $1.key }); memory growth after warm-up \(String(format: "%.1f", growthMB)) MB")
        XCTAssertLessThan(growthMB, 60)
        XCTAssertGreaterThan(cycle, 20)
    }

    func testASnapshotStormWithASlowPhoneDoesNotStarveTheOthers() async throws {
        signal(SIGPIPE, SIG_IGN)
        let rig = try await makeRig()
        defer { rig.listener.stop() }
        var clients: [LinkClient] = []
        for i in 0..<3 {
            let creds = try await pair(rig, name: "Phone \(i)")
            clients.append(try await connect(rig, creds))
        }
        let connected = await waitUntil { await rig.host.connectedCount() == 3 }
        XCTAssertTrue(connected)
        final class Count: @unchecked Sendable { private let l = NSLock(); private var n = 0, last = 0
            func note(_ id: Int) { l.lock(); n += 1; last = id; l.unlock() }
            var value: (Int, Int) { l.lock(); defer { l.unlock() }; return (n, last) } }
        let a = Count(), b = Count()
        let readers = [(clients[0], a), (clients[1], b)].map { client, count in
            Task { while let m = try? await client.receive() { if case .snapshot(let s) = m { count.note(s.transcriptTail.last?.id ?? 0) } } }
        }
        // clients[2] never reads: its socket buffers fill up.
        let before = Self.residentBytes()
        let storm = 3000
        for n in 1...storm { await rig.host.publish(snapshot(n, padding: 3000)) }
        let reached = await waitUntil(8) { a.value.1 == storm && b.value.1 == storm }
        let growthMB = (Double(Self.residentBytes()) - Double(before)) / 1_048_576
        print("SOAK link storm: \(storm) snapshots; phone 1 saw \(a.value.0) (last \(a.value.1)), phone 2 saw \(b.value.0) (last \(b.value.1)); growth \(String(format: "%.1f", growthMB)) MB")
        XCTAssertTrue(reached, "the readers must end on the newest snapshot, but ended at \(a.value.1) and \(b.value.1)")
        XCTAssertLessThan(growthMB, 80, "a phone that never reads must not make the Mac hold every snapshot")
        let droppedSlow = await waitUntil(LinkHost.sendTimeout + 5) { await rig.host.connectedCount() == 2 }
        XCTAssertTrue(droppedSlow, "the phone that never reads should be cut off after the send timeout, leaving the other two")
        for r in readers { r.cancel() }
        for c in clients { await c.close() }
    }
}

/// Faults against the real stand-in host as a separate process: it is frozen (like a Mac that is asleep or stalled),
/// resumed, and killed (a crash), while a phone is connected.
final class LinkFaultTests: XCTestCase {
    final class HostProcess {
        let process = Process()
        let output = Pipe()
        private let lock = NSLock()
        private var text = ""
        init(port: UInt16) throws {
            process.executableURL = URL(fileURLWithPath: "\(FileManager.default.currentDirectoryPath)/.build/debug/pairvox-link-testhost")
            process.arguments = ["--port", "\(port)", "--tick", "0.25"]
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            output.fileHandleForReading.readabilityHandler = { [weak self] h in
                let chunk = String(decoding: h.availableData, as: UTF8.self)
                self?.lock.lock(); self?.text += chunk; self?.lock.unlock()
            }
            try process.run()
        }
        var log: String { lock.lock(); defer { lock.unlock() }; return text }
        /// The pairing link the stand-in host prints (`LINK: pairvox://pair?...`).
        var link: PairingPayload? {
            log.components(separatedBy: "LINK: ").dropFirst().first?.split(separator: "\n").first.flatMap { PairingPayload.parse(String($0)) }
        }
        func stop() { output.fileHandleForReading.readabilityHandler = nil; if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
    }

    final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private var ids: [(Date, Int)] = []
        private var ended: Date?
        func note(_ id: Int) { lock.lock(); ids.append((Date(), id)); lock.unlock() }
        func end() { lock.lock(); ended = Date(); lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return ids.count }
        var last: Int { lock.lock(); defer { lock.unlock() }; return ids.last?.1 ?? 0 }
        var endedAt: Date? { lock.lock(); defer { lock.unlock() }; return ended }
        func count(since t: Date) -> Int { lock.lock(); defer { lock.unlock() }; return ids.filter { $0.0 >= t }.count }
    }

    func testAFrozenThenResumedThenKilledHostIsHandledByAConnectedPhone() async throws {
        signal(SIGPIPE, SIG_IGN)
        guard FileManager.default.isExecutableFile(atPath: ".build/debug/pairvox-link-testhost") else { throw XCTSkip("build pairvox-link-testhost first") }
        let port = UInt16(47_900 + Int.random(in: 0..<80))
        let host = try HostProcess(port: port)
        defer { host.stop() }
        let ready = await waitFor(8) { host.link != nil }
        XCTAssertTrue(ready, "the stand-in host did not start: \(host.log)")
        let link = try XCTUnwrap(host.link)
        let transport = TCPTransport.connect(host: "127.0.0.1", port: port)
        let creds = try await LinkClient.pair(over: transport, material: link.material, deviceName: "Fault phone")
        let client = try await LinkClient.connect(over: TCPTransport.connect(host: "127.0.0.1", port: port), deviceID: creds.deviceID, psk: creds.psk)
        let seen = Seen()
        let reader = Task {
            while let m = try? await client.receive() { if case .snapshot(let s) = m, let id = s.transcriptTail.last?.id { seen.note(id) } }
            seen.end()
        }
        let flowing = await waitFor(6) { seen.count >= 4 }
        XCTAssertTrue(flowing, "snapshots never flowed before any fault")

        // 1. The host stalls for six seconds, like a Mac that is busy or on its way to sleep.
        kill(host.process.processIdentifier, SIGSTOP)
        let frozenAt = Date()
        try await Task.sleep(nanoseconds: 6_000_000_000)
        XCTAssertNil(seen.endedAt, "a six-second stall must not end the connection by itself")
        let before = seen.last
        kill(host.process.processIdentifier, SIGCONT)
        let resumed = await waitFor(6) { seen.last > before + 2 }
        XCTAssertTrue(resumed, "after the host woke up, updates should flow again on the same connection (last \(before) -> \(seen.last), \(Int(Date().timeIntervalSince(frozenAt))) s)")

        // 2. The host crashes: the phone must find out promptly, so it can reconnect.
        let killedAt = Date()
        kill(host.process.processIdentifier, SIGKILL)
        let noticed = await waitFor(8) { seen.endedAt != nil }
        XCTAssertTrue(noticed, "the phone never noticed that the host was gone")
        if let ended = seen.endedAt { XCTAssertLessThan(ended.timeIntervalSince(killedAt), 5, "it took too long to notice the crash") }
        print("FAULT host freeze 6 s: connection survived and resumed; crash noticed in \(seen.endedAt.map { String(format: "%.2f", $0.timeIntervalSince(killedAt)) } ?? "never") s")
        reader.cancel()
        await client.close()
    }

    func waitFor(_ timeout: Double, _ condition: @escaping () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if condition() { return true }; try? await Task.sleep(nanoseconds: 50_000_000) }
        return condition()
    }
}
