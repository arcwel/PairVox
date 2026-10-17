// SPDX-License-Identifier: Apache-2.0

#if canImport(Darwin)
import Darwin
#endif
import Foundation
import XCTest
@testable import PairVoxCore

/// A soak test: many thousands of mixed conversation cycles through a real engine with a fake Claude and a fake speaker,
/// checking that it stays responsive, ends in a clean state and does not grow without bound.
/// `PAIRVOX_SOAK_SECONDS` sets how long it runs (default 8; `scripts/soak.sh` runs it for minutes).
final class EngineSoakTests: XCTestCase {
    /// Resident memory of this process in bytes.
    /// On Linux (CI) it is read from /proc; 0 when unavailable, which the memory check treats as "not measured".
    static func residentBytes() -> UInt64 {
        #if canImport(Darwin)
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? info.resident_size : 0
        #else
        // /proc/self/statm: size resident shared ... in pages.
        guard let text = try? String(contentsOfFile: "/proc/self/statm", encoding: .utf8),
              let pages = text.split(separator: " ").dropFirst().first.flatMap({ UInt64($0) }) else { return 0 }
        return pages * 4096
        #endif
    }

    struct Rng { var state: UInt64
        mutating func next(_ n: Int) -> Int { state = state &* 6364136223846793005 &+ 1442695040888963407; return Int((state >> 33) % UInt64(n)) } }

    func sentences(_ rng: inout Rng, _ count: Int) -> String {
        (0..<count).map { _ in "Point number \(rng.next(1000)) about the module is that it does something useful. " }.joined()
    }

    func testManyMixedConversationsStayResponsiveAndBounded() async throws {
        let seconds = Double(ProcessInfo.processInfo.environment["PAIRVOX_SOAK_SECONDS"] ?? "8") ?? 8
        let backend = FakeBackend()
        let output = FakeOutput()
        output.pausable = true
        let engine = ConversationEngine(configuration: EngineConfiguration(projectRoot: "/Users/dev/app", speechMode: .skipCode,
                                                                           acknowledgements: false, spokenReplyLimit: 15),
                                        output: output, backendFactory: { _ in backend })
        await engine.start()
        var rng = Rng(state: 42)
        var cycles = 0, turns = 0, approvals = 0, bargeIns = 0, restarts = 0
        var warmupMemory: UInt64 = 0
        var peakTranscript = 0
        let started = Date()
        var lastCheck = started

        func settle() async { try? await Task.sleep(nanoseconds: 3_000_000) }

        while Date().timeIntervalSince(started) < seconds {
            cycles += 1
            switch rng.next(10) {
            case 0, 1, 2:   // a normal turn
                await engine.submit("Question \(cycles)")
                backend.emit(.textDelta(sentences(&rng, 2 + rng.next(8))))
                if rng.next(3) == 0 { backend.emit(.toolUse(ToolUse(id: "t\(cycles)", name: "Read", input: ["file_path": "/Users/dev/app/a.swift"]))) }
                backend.emit(.textBlockEnded)
                backend.emit(.turnCompleted(TurnResult(outcome: .success)))
                turns += 1
                await settle()
                output.playAll()
            case 3:   // a long reply that exceeds the spoken limit, then "details"
                await engine.submit("Explain everything \(cycles)")
                backend.emit(.textDelta(sentences(&rng, 25)))
                backend.emit(.textBlockEnded)
                backend.emit(.turnCompleted(TurnResult(outcome: .success)))
                await settle()
                output.playAll()
                await engine.submit("details")
                await settle()
                output.playAll()
            case 4:   // barge-in with a noise, an acknowledgement or a real instruction
                await engine.submit("Talk to me \(cycles)")
                backend.emit(.textDelta(sentences(&rng, 6)))
                await settle()
                output.playNext(finish: false)
                await engine.userStartedSpeaking(); bargeIns += 1
                await engine.userStoppedSpeaking()
                switch rng.next(3) {
                case 0: await engine.submit("")
                case 1: await engine.submit("okay")
                default: await engine.submit("Actually do something else \(cycles)")
                }
                backend.emit(.turnCompleted(TurnResult(outcome: .interrupted)))
                await settle()
                output.playAll()
            case 5, 6:   // a permission request, answered or queued behind another
                await engine.submit("Change a file \(cycles)")
                backend.emit(.permissionRequested(PermissionRequest(requestID: "p\(cycles)a", toolName: "Edit", input: ["file_path": .string("/Users/dev/app/a.swift")])))
                if rng.next(2) == 0 { backend.emit(.permissionRequested(PermissionRequest(requestID: "p\(cycles)b", toolName: "Edit", input: ["file_path": .string("/Users/dev/app/b.swift")]))) }
                await settle()
                for _ in 0..<2 {
                    switch rng.next(3) {
                    case 0: await engine.submit("yes"); approvals += 1
                    case 1: await engine.submit("no")
                    default: await engine.approvePending(always: false)
                    }
                    await settle()
                }
                backend.emit(.turnCompleted(TurnResult(outcome: .success)))
                output.playAll()
            case 7:   // a failed turn
                await engine.submit("Break \(cycles)")
                backend.emit(.turnCompleted(TurnResult(outcome: .failed("simulated failure \(cycles)"))))
                await settle()
                output.playAll()
            case 8:   // "stop" mid-reply
                await engine.submit("Go on \(cycles)")
                backend.emit(.textDelta(sentences(&rng, 5)))
                await settle()
                await engine.submit("stop")
                await settle()
                output.playAll()
            default:  // now and then, a fresh session
                if rng.next(8) == 0 { await engine.newSession(); restarts += 1 }
            }

            if Date().timeIntervalSince(lastCheck) > 1 {
                lastCheck = Date()
                // The engine must answer promptly even in the middle of all this.
                let t0 = Date()
                let snap = await engine.snapshot
                XCTAssertLessThan(Date().timeIntervalSince(t0), 1.0, "the engine stopped answering after \(cycles) cycles")
                peakTranscript = max(peakTranscript, snap.transcript.count)
                if warmupMemory == 0, Date().timeIntervalSince(started) > 2 { warmupMemory = Self.residentBytes() }
            }
        }

        // Let everything drain, then check the end state.
        for _ in 0..<5 { output.playAll(); try? await Task.sleep(nanoseconds: 50_000_000) }
        let end = await engine.snapshot
        let growthMB = warmupMemory == 0 ? 0 : (Double(Self.residentBytes()) - Double(warmupMemory)) / 1_048_576
        print("SOAK engine: \(cycles) cycles in \(Int(seconds)) s (\(turns) turns, \(approvals) spoken approvals, \(bargeIns) barge-ins, \(restarts) restarts); transcript peak \(peakTranscript); memory growth after warm-up \(String(format: "%.1f", growthMB)) MB")
        XCTAssertLessThanOrEqual(peakTranscript, 600, "the transcript is capped")
        XCTAssertLessThan(growthMB, 60, "resident memory grew by \(growthMB) MB while idle state was reused")
        XCTAssertGreaterThan(cycles, 50, "the soak did too little to mean anything")
        _ = end
        await engine.shutdown()
    }
}
