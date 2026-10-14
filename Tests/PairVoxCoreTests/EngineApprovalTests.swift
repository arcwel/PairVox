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

    func testTextFromAPairedPhoneNeverAnswersAWaitingRequest() async {
        await engine.submit("Fix it")
        backend.emit(edit("A", "a.swift"))
        await settle()
        await engine.submitFromRemote("yes")
        await settle()
        XCTAssertTrue(backend.responses.isEmpty, "a yes typed on the phone is not an approval")
        var snap = await engine.snapshot
        XCTAssertEqual(snap.pendingPermission?.request.requestID, "A", "the request still waits for an ID-bound answer")
        await engine.submitFromRemote("do something else instead")
        await settle()
        snap = await engine.snapshot
        if case .deny? = backend.responses.first?.1 {} else { XCTFail("an instruction while a request waits refuses it, as speech does") }
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

    func bash(_ id: String, _ command: String, _ extra: (inout PermissionRequest) -> Void = { _ in }) -> SessionEvent {
        var r = PermissionRequest(requestID: id, toolName: "Bash", input: ["command": .string(command)])
        extra(&r)
        return .permissionRequested(r)
    }

    func testHighRiskCannotBeConfirmedByVoiceWhileTheToggleIsOff() async {
        await engine.submit("Clean up")
        backend.emit(bash("h1", "rm -rf build"))
        await settle()
        await engine.submit("confirm high risk")
        await engine.submit("yes")
        XCTAssertTrue(backend.responses.isEmpty, "off by default: only the button approves a high-risk request")
        XCTAssertTrue(output.allTexts.last?.contains("needs a click") ?? false)
        XCTAssertFalse(output.allTexts.contains { $0.contains("confirm high risk") && $0.hasPrefix("Claude wants") })
    }

    func testHighRiskCanBeConfirmedByTheDeliberatePhraseWhenTheToggleIsOn() async {
        await engine.setSpokenHighRiskConfirmation(true)
        await engine.submit("Clean up")
        backend.emit(bash("h1", "rm -rf build"))
        await settle()
        XCTAssertTrue(output.allTexts.contains { $0.hasPrefix("Claude wants to run") && $0.hasSuffix("Say confirm high risk to allow it, or use the button.") },
                      "the prompt tells the user the phrase")
        await engine.submit("yes")
        await engine.submit("allow")
        XCTAssertTrue(backend.responses.isEmpty, "a casual yes never approves a high-risk request")
        XCTAssertTrue(output.allTexts.contains("That one is high risk. Say confirm high risk to allow it, or use the button."))
        await engine.submit("don't confirm high risk")
        XCTAssertEqual(backend.responses.map(\.0), ["h1"], "a refusal wins and denies")
        guard case .deny? = backend.responses.first?.1 else { return XCTFail("expected a denial") }
    }

    func testTheSpokenPhraseApproves() async {
        await engine.setSpokenHighRiskConfirmation(true)
        await engine.submit("Clean up")
        backend.emit(bash("h2", "git push --force origin main"))
        await settle()
        await engine.submit("Confirm high risk.")
        XCTAssertEqual(backend.responses.map(\.0), ["h2"])
        XCTAssertEqual(backend.responses.first?.1, .allow)
    }

    func testSpeechFromTheSpeakersCanSatisfyItWhenTheToggleIsOn() async {
        // Accepted tradeoff, stated in Settings: the engine does not tell PairVox's own voice from the user's.
        await engine.setSpokenHighRiskConfirmation(true)
        await engine.submit("Clean up")
        backend.emit(bash("h3", "rm -rf build"))
        await settle()
        output.playNext(finish: false)         // PairVox is speaking
        await engine.submit("confirm high risk")  // and the microphone hears the phrase
        XCTAssertEqual(backend.responses.map(\.0), ["h3"])
    }

    func testRequestsThatNeedTheScreenStayAClickEvenWhenTheToggleIsOn() async {
        await engine.setSpokenHighRiskConfirmation(true)
        await engine.submit("Fix it")
        backend.emit(bash("h4", "rm -rf build") { $0.requiresUserInteraction = true })
        await settle()
        await engine.submit("confirm high risk")
        XCTAssertTrue(backend.responses.isEmpty)
        backend.emit(bash("h5", "ls") { $0.decisionReasonType = "safetyCheck"; $0.requiresUserInteraction = true })
        await settle()
        await engine.denyPending()
        await engine.submit("confirm high risk")
        XCTAssertEqual(backend.responses.count, 1, "only the first denial")
    }

    func testTheToggleAppliesToARunningSession() async {
        await engine.setSpokenHighRiskConfirmation(true)
        await engine.setSpokenHighRiskConfirmation(false)
        await engine.submit("Clean up")
        backend.emit(bash("h6", "rm -rf build"))
        await settle()
        await engine.submit("confirm high risk")
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

final class AllowAllByVoiceTests: XCTestCase {
    var backend: FakeBackend!
    var output: FakeOutput!
    var engine: ConversationEngine!

    override func setUp() async throws {
        backend = FakeBackend(); output = FakeOutput()
        let b = backend!
        engine = ConversationEngine(configuration: EngineConfiguration(projectRoot: "/Users/dev/app", acknowledgementDelay: 5),
                                    output: output, backendFactory: { _ in b })
        await engine.start()
    }

    override func tearDown() async throws { await engine.shutdown() }

    func settle(_ ms: UInt64 = 70) async { try? await Task.sleep(nanoseconds: ms * 1_000_000) }

    func edit(_ id: String, _ f: String) -> SessionEvent {
        .permissionRequested(PermissionRequest(requestID: id, toolName: "Edit", input: ["file_path": .string("/Users/dev/app/\(f)")]))
    }

    func testAllowAllReadsTheListFirstAndNeedsASecondAllowAll() async {
        await engine.submit("Do the work")
        backend.emit(edit("A", "a.swift")); backend.emit(edit("B", "b.swift"))
        backend.emit(.permissionRequested(PermissionRequest(requestID: "H", toolName: "Bash", input: ["command": "rm -rf build"])))
        await settle()
        await engine.submit("allow all")
        XCTAssertTrue(backend.responses.isEmpty, "the first one only reads the list")
        let reading = output.allTexts.last ?? ""
        XCTAssertTrue(reading.contains("2 requests can be allowed together"), reading)
        XCTAssertTrue(reading.contains("edit a dot swift") && reading.contains("edit b dot swift"))
        XCTAssertTrue(reading.contains("1 high-risk one will still ask"))
        await engine.submit("allow all")
        await settle()
        XCTAssertEqual(Set(backend.responses.map(\.0)), ["A", "B"])
        let snap = await engine.snapshot
        XCTAssertEqual(snap.pendingPermission?.request.requestID, "H", "the high-risk one is still waiting for its own decision")
    }

    func testARequestThatArrivesAfterTheListWasReadIsNotAllowed() async {
        await engine.submit("Do the work")
        backend.emit(edit("A", "a.swift")); backend.emit(edit("B", "b.swift"))
        await settle()
        await engine.submit("allow all")
        backend.emit(edit("C", "c.swift"))      // new, never read out
        await settle()
        await engine.submit("allow all")
        await settle()
        XCTAssertEqual(Set(backend.responses.map(\.0)), ["A", "B"])
        let snap = await engine.snapshot
        XCTAssertEqual(snap.pendingPermission?.request.requestID, "C")
    }

    func testAnythingElseInBetweenDisarmsIt() async {
        await engine.submit("Do the work")
        backend.emit(edit("A", "a.swift")); backend.emit(edit("B", "b.swift"))
        await settle()
        await engine.submit("allow all")           // reads the list and arms
        await engine.submit("repeat that")         // something else in between
        await engine.submit("allow all")           // so this reads the list again instead of allowing
        XCTAssertTrue(backend.responses.isEmpty, "a stale arming must not carry over")
        await engine.submit("allow all")
        await settle()
        XCTAssertEqual(Set(backend.responses.map(\.0)), ["A", "B"])
    }

    func testAllowAllWithNothingQueuedIsAnOrdinaryYes() async {
        await engine.submit("Do the work")
        backend.emit(edit("A", "a.swift"))
        await settle()
        await engine.submit("allow all")
        XCTAssertEqual(backend.responses.map(\.0), ["A"])
    }
}

final class RemoteTextCommandTests: XCTestCase {
    func testTextFromAPhoneCannotChangeModesOrRestartTheSession() async throws {
        let backend = FakeBackend(), output = FakeOutput()
        let engine = ConversationEngine(configuration: EngineConfiguration(projectRoot: "/Users/dev/app", speechMode: .skipCode,
                                                                           conversationMode: .brainstorm, acknowledgementDelay: 0.15),
                                        output: output, backendFactory: { _ in backend })
        await engine.start()
        defer { Task { await engine.shutdown() } }
        for text in ["execute mode", "new session", "summary mode", "faster"] {
            await engine.submitFromRemote(text)
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        let snap = await engine.snapshot
        XCTAssertEqual(snap.conversationMode, .brainstorm)
        XCTAssertEqual(snap.speechMode, .skipCode)
        XCTAssertFalse(snap.transcript.contains { $0.text == "New session started." })
    }
}
