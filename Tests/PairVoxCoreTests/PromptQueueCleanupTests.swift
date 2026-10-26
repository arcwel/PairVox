// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PairVoxCore

/// A question that is over before its prompt played is not asked afterwards, whichever way it ended. Audit run 8 did
/// this for an answered request; run 9 deferred the other ways (cancelled, the session gone, the offer replaced or
/// answered on screen).
final class PromptQueueCleanupTests: XCTestCase {
    var backend: FakeBackend!
    var output: FakeOutput!
    var engine: ConversationEngine!
    let root = FolderScope.resolved(NSTemporaryDirectory() + "pv-prompt-cleanup")

    override func setUp() async throws {
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        backend = FakeBackend(); output = FakeOutput()
        output.cancellable = true
        let b = backend!
        engine = ConversationEngine(configuration: EngineConfiguration(projectRoot: root, speechMode: .skipCode, acknowledgementDelay: 0.15),
                                    output: output, backendFactory: { _ in b })
        await engine.start()
    }

    override func tearDown() async throws {
        await engine.shutdown()
        try? FileManager.default.removeItem(atPath: root)
    }

    func settle(_ ms: UInt64 = 60) async { try? await Task.sleep(nanoseconds: ms * 1_000_000) }

    func edit(_ id: String, _ file: String) -> SessionEvent {
        .permissionRequested(PermissionRequest(requestID: id, toolName: "Edit", input: ["file_path": .string(root + "/" + file)]))
    }

    var queuedPrompts: [String] { output.queue.filter { $0.kind == .prompt }.map(\.text) }

    func testACancelledRequestsUnplayedPromptIsNotAsked() async {
        await engine.submit("Fix it")
        backend.emit(edit("A", "a.swift"))
        await settle()
        XCTAssertEqual(queuedPrompts.count, 1)
        let askA = queuedPrompts.first
        backend.emit(.permissionCancelled(requestID: "A"))
        backend.emit(edit("B", "b.swift"))
        await settle()
        XCTAssertEqual(queuedPrompts.count, 1, "only B's question is left: \(queuedPrompts)")
        XCTAssertNotEqual(queuedPrompts.first, askA, "\(queuedPrompts)")
    }

    func testARequestsUnplayedPromptGoesWithTheSession() async {
        await engine.submit("Fix it")
        backend.emit(edit("A", "a.swift"))
        await settle()
        backend.emit(.processExited(code: 1, stderrTail: ""))
        await settle()
        XCTAssertTrue(queuedPrompts.isEmpty, "\(queuedPrompts)")
        await engine.userStartedSpeaking()
        await engine.userStoppedSpeaking()
        await engine.submit("yes")
        XCTAssertTrue(backend.responses.isEmpty)
    }

    func testARequestOpenWhenTheTurnEndsTakesItsPromptWithIt() async {
        await engine.submit("Fix it")
        backend.emit(edit("A", "a.swift"))
        await settle()
        let askA = queuedPrompts.first
        XCTAssertNotNil(askA)
        backend.emit(.turnCompleted(TurnResult(outcome: .interrupted)))
        await settle()
        XCTAssertFalse(queuedPrompts.contains { $0 == askA }, "\(queuedPrompts)")
    }

    func testTheOffersUnplayedQuestionIsNotAskedAfterTheRequestThatReplacedIt() async {
        await engine.offerFolderGrant()
        await engine.submit("Fix it")   // says something else, which drops the offer
        await engine.offerFolderGrant()
        backend.emit(edit("A", "a.swift"))
        await settle()
        XCTAssertEqual(queuedPrompts.count, 1, "\(queuedPrompts)")
        XCTAssertFalse(queuedPrompts.first?.contains("without asking each time") ?? true, "the request's question, not the offer's")
    }

    func testTheOffersUnplayedQuestionGoesWhenItIsAnsweredOnScreen() async {
        await engine.offerFolderGrant()
        await engine.answerGrantOffer(yes: true)   // "Allow edits…" before the question played
        XCTAssertEqual(queuedPrompts.count, 1, "only the confirmation: \(queuedPrompts)")
        XCTAssertTrue(queuedPrompts.first?.hasPrefix("To confirm") ?? false)
        await engine.answerGrantOffer(yes: false)  // Cancel
        XCTAssertTrue(queuedPrompts.isEmpty, "\(queuedPrompts)")
        await engine.offerFolderGrant()
        await engine.dismissGrantOffer()           // Not now
        XCTAssertTrue(queuedPrompts.isEmpty, "\(queuedPrompts)")
    }

    func testAPromptAlreadyPlayingIsLeftToFinish() async {
        await engine.submit("Fix it")
        backend.emit(edit("A", "a.swift"))
        await settle()
        guard let prompt = output.queue.last(where: { $0.kind == .prompt }) else { return XCTFail("A's question") }
        output.continuation.yield(.started(prompt.id))
        await settle()
        backend.emit(.permissionCancelled(requestID: "A"))
        await settle()
        XCTAssertTrue(output.queue.contains { $0.id == prompt.id }, "only questions not yet started are taken out")
    }
}
