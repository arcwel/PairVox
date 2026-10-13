// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PairVoxCore

/// The approval gate: one request is shown and spoken at a time, an approval only ever applies to the request
/// the user was shown, and the auto-approve setting reaches a running session.
final class EngineApprovalTests: XCTestCase {
    var backend: FakeBackend!
    var output: FakeOutput!
    var engine: ConversationEngine!

    override func setUp() async throws {
        backend = FakeBackend()
        output = FakeOutput()
        let b = backend!
        engine = ConversationEngine(configuration: EngineConfiguration(projectRoot: "/Users/dev/app", speechMode: .skipCode,
                                                                       acknowledgementDelay: 0.15),
                                    output: output, backendFactory: { _ in b })
        await engine.start()
    }

    override func tearDown() async throws { await engine.shutdown() }

    func settle(_ ms: UInt64 = 60) async { try? await Task.sleep(nanoseconds: ms * 1_000_000) }

    func edit(_ id: String, _ file: String) -> SessionEvent {
        .permissionRequested(PermissionRequest(requestID: id, toolName: "Edit", input: ["file_path": .string("/Users/dev/app/\(file)")]))
    }

    func testSecondRequestQueuesInsteadOfReplacingTheFirst() async {
        await engine.submit("Fix it")
        backend.emit(edit("A", "a.swift"))
        backend.emit(edit("B", "b.swift"))
        await settle()
        var snap = await engine.snapshot
        XCTAssertEqual(snap.pendingPermission?.request.requestID, "A", "the request the user heard stays on screen")
        XCTAssertEqual(snap.queuedPermissionCount, 1)
        XCTAssertEqual(output.allTexts.filter { $0.hasSuffix("Allow?") }.count, 1, "only the shown request is spoken")

        await engine.submit("yes")
        XCTAssertEqual(backend.responses.map(\.0), ["A"], "the spoken yes answers A, never B")
        await settle()
        snap = await engine.snapshot
        XCTAssertEqual(snap.pendingPermission?.request.requestID, "B", "B is shown once A is answered")
        XCTAssertEqual(snap.queuedPermissionCount, 0)
        XCTAssertTrue(output.allTexts.contains("Claude wants to edit b dot swift. Allow?"))

        await engine.denyPending()
        XCTAssertEqual(backend.responses.map(\.0), ["A", "B"])
    }

    func testApprovalBoundToAStaleRequestIDDoesNothing() async {
        await engine.submit("Fix it")
        backend.emit(edit("A", "a.swift"))
        backend.emit(edit("B", "b.swift"))
        await settle()
        await engine.approvePending(requestID: "B")
        XCTAssertTrue(backend.responses.isEmpty, "B is not the request on screen")
        await engine.approvePending(requestID: "A")
        XCTAssertEqual(backend.responses.map(\.0), ["A"])
        await engine.denyPending(requestID: "A")
        XCTAssertEqual(backend.responses.map(\.0), ["A"], "A is already answered")
    }

    func testCancellingTheShownRequestPromotesTheNext() async {
        await engine.submit("Fix it")
        backend.emit(edit("A", "a.swift"))
        backend.emit(edit("B", "b.swift"))
        await settle()
        backend.emit(.permissionCancelled(requestID: "A"))
        await settle()
        let snap = await engine.snapshot
        XCTAssertEqual(snap.pendingPermission?.request.requestID, "B")
        XCTAssertEqual(snap.queuedPermissionCount, 0)
    }

    func testAutoApproveAppliesToReadOnlyToolsOnlyAndFollowsTheSetting() async {
        await engine.setAutoApproveLowRisk(true)
        await engine.submit("Look around")
        backend.emit(.permissionRequested(PermissionRequest(requestID: "r1", toolName: "Read", input: ["file_path": "/Users/dev/app/a.swift"])))
        backend.emit(.permissionRequested(PermissionRequest(requestID: "r2", toolName: "Bash", input: ["command": "python3 evil.py"])))
        await settle()
        XCTAssertEqual(backend.responses.map(\.0), ["r1"], "only the plain read is answered silently")
        var snap = await engine.snapshot
        XCTAssertEqual(snap.pendingPermission?.request.requestID, "r2")
        await engine.denyPending()

        await engine.setAutoApproveLowRisk(false)
        backend.emit(.permissionRequested(PermissionRequest(requestID: "r3", toolName: "Read", input: ["file_path": "/Users/dev/app/b.swift"])))
        await settle()
        snap = await engine.snapshot
        XCTAssertEqual(snap.pendingPermission?.request.requestID, "r3", "turning the setting off takes effect on the running session")
    }

    func testExitPlanModeIsNeverAutoApproved() async {
        await engine.setAutoApproveLowRisk(true)
        await engine.submit("Plan it")
        backend.emit(.permissionRequested(PermissionRequest(requestID: "x", toolName: "ExitPlanMode", input: [:])))
        await settle()
        let snap = await engine.snapshot
        XCTAssertEqual(snap.pendingPermission?.request.requestID, "x")
        XCTAssertTrue(backend.responses.isEmpty)
    }

    func testNewSessionKeepsTheModeTheUserSwitchedTo() async {
        let first = FakeBackend(), second = FakeBackend()
        let sessions = [first, second]
        let counter = Counter()
        let engine2 = ConversationEngine(configuration: EngineConfiguration(projectRoot: "/Users/dev/app", conversationMode: .execute),
                                         output: FakeOutput(), backendFactory: { _ in sessions[min(counter.next(), 1)] })
        await engine2.start()
        await engine2.setConversationMode(.brainstorm)
        XCTAssertEqual(first.modes, [.plan])
        await engine2.newSession()
        XCTAssertEqual(second.modes, [.plan], "the new child must not start in the mode the project opened in")
        await engine2.shutdown()
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = -1
    func next() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
}
