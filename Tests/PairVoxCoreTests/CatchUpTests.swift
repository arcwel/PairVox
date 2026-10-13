// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PairVoxCore

/// Working in several projects: a project the user left stays silent, remembers what Claude said, and offers a
/// catch-up when the user returns.
final class CatchUpTests: XCTestCase {
    var backend: FakeBackend!
    var output: FakeOutput!
    var engine: ConversationEngine!

    override func setUp() async throws {
        backend = FakeBackend(); output = FakeOutput()
        let b = backend!
        engine = ConversationEngine(configuration: EngineConfiguration(projectRoot: "/Users/dev/app", speechMode: .skipCode, acknowledgementDelay: 5),
                                    output: output, backendFactory: { _ in b })
        await engine.start()
    }

    override func tearDown() async throws { await engine.shutdown() }

    func settle(_ ms: UInt64 = 70) async { try? await Task.sleep(nanoseconds: ms * 1_000_000) }

    /// One full reply from Claude.
    func reply(_ text: String) async {
        backend.emit(.textDelta(text))
        backend.emit(.textBlockEnded)
        backend.emit(.turnCompleted(TurnResult(outcome: .success)))
        await settle()
    }

    func testRepliesWhileAwayAreListedAndTheUserChoosesWhatToHear() async {
        await engine.submit("Do the first thing")
        await reply("First answer.")
        output.playAll()
        var snap = await engine.snapshot
        XCTAssertTrue(snap.missedMessages.isEmpty, "heard while here")

        await engine.setActive(false)
        XCTAssertGreaterThan(output.stops, 0, "leaving cuts the voice")
        await engine.submit("Do the second thing")
        await reply("Second answer.")
        await engine.submit("Do the third thing")
        await reply("Third answer. With two sentences.")
        snap = await engine.snapshot
        XCTAssertFalse(snap.isActive)
        XCTAssertEqual(snap.missedMessages.map(\.sentences), [["Second answer."], ["Third answer.", "With two sentences."]])

        await engine.setActive(true)
        snap = await engine.snapshot
        XCTAssertTrue(snap.awaitingCatchUpChoice)
        XCTAssertEqual(snap.missedMessages.count, 2)

        let before = output.allTexts.count
        await engine.resolveCatchUp(.fromFirstMissed)
        XCTAssertEqual(Array(output.allTexts.dropFirst(before)), ["Second answer.", "Third answer.", "With two sentences."])
        snap = await engine.snapshot
        XCTAssertFalse(snap.awaitingCatchUpChoice)
        XCTAssertTrue(snap.missedMessages.isEmpty)
    }

    func testPlayLastMessageSpeaksOnlyTheLastReply() async {
        await engine.setActive(false)
        await engine.submit("A")
        await reply("Alpha.")
        await engine.submit("B")
        await reply("Bravo. Charlie.")
        await engine.setActive(true)
        let before = output.allTexts.count
        await engine.resolveCatchUp(.lastMessage)
        XCTAssertEqual(Array(output.allTexts.dropFirst(before)), ["Bravo.", "Charlie."])
    }

    func testSkipSpeaksNothingAndSpokenCommandsWork() async {
        await engine.setActive(false)
        await engine.submit("A")
        await reply("Alpha.")
        await engine.setActive(true)
        var before = output.allTexts.count
        await engine.submit("skip")
        XCTAssertEqual(output.allTexts.count, before)
        var snap = await engine.snapshot
        XCTAssertFalse(snap.awaitingCatchUpChoice)

        await engine.setActive(false)
        await engine.submit("B")
        await reply("Bravo.")
        await engine.setActive(true)
        before = output.allTexts.count
        await engine.submit("catch me up")
        XCTAssertEqual(Array(output.allTexts.dropFirst(before)), ["Bravo."])

        await engine.setActive(false)
        await engine.submit("C")
        await reply("Charlie.")
        await engine.setActive(true)
        before = output.allTexts.count
        await engine.submit("play the last one")
        XCTAssertEqual(Array(output.allTexts.dropFirst(before)), ["Charlie."])
        snap = await engine.snapshot
        XCTAssertTrue(snap.missedMessages.isEmpty)
    }

    func testAnythingElseSaidIsNotACatchUpAnswerAndCarriesOn() async {
        await engine.setActive(false)
        await engine.submit("A")
        await reply("Alpha.")
        await engine.setActive(true)
        let sentBefore = backend.sent.count
        await engine.submit("Now refactor the parser")
        XCTAssertEqual(backend.sent.count, sentBefore + 1, "goes to Claude as a normal message")
        let snap = await engine.snapshot
        XCTAssertFalse(snap.awaitingCatchUpChoice, "the offer is dropped")
    }

    func testAReplyThatWasStreamingWhenTheUserLeftCountsAsMissed() async {
        await engine.submit("Explain it")
        backend.emit(.textDelta("Part one. "))
        await settle()
        await engine.setActive(false)
        backend.emit(.textDelta("Part two."))
        backend.emit(.textBlockEnded)
        backend.emit(.turnCompleted(TurnResult(outcome: .success)))
        await settle()
        let snap = await engine.snapshot
        XCTAssertEqual(snap.missedMessages.count, 1)
        XCTAssertEqual(snap.missedMessages.first?.sentences, ["Part one.", "Part two."])
    }

    func testNothingMissedMeansNoQuestionAndAWaitingRequestIsAskedAgain() async {
        await engine.submit("Fix it")
        backend.emit(.permissionRequested(PermissionRequest(requestID: "A", toolName: "Edit", input: ["file_path": "/Users/dev/app/a.swift"])))
        await settle()
        output.playAll()                       // the user heard the question, then switched away
        await engine.setActive(false)
        await engine.setActive(true)
        let snap = await engine.snapshot
        XCTAssertFalse(snap.awaitingCatchUpChoice)
        XCTAssertEqual(output.allTexts.filter { $0 == "Claude wants to edit a dot swift. Allow?" }.count, 2,
                       "the waiting question is asked again on return")
    }

    func testARequestThatArrivedWhileAwayIsAskedAfterTheCatchUp() async {
        await engine.setActive(false)
        await engine.submit("Fix it")
        await reply("I'll change a file.")
        backend.emit(.permissionRequested(PermissionRequest(requestID: "A", toolName: "Edit", input: ["file_path": "/Users/dev/app/a.swift"])))
        await settle()
        await engine.setActive(true)
        await engine.resolveCatchUp(.skip)
        XCTAssertEqual(output.allTexts.last, "Claude wants to edit a dot swift. Allow?")
    }
}

final class ProjectSwitchTests: XCTestCase {
    func testSpokenNamesMatchLooselyButOnlyWhenUnambiguous() {
        let names = ["PairVox", "HazzMate", "WebDeck", "web-deck-docs", "lumora"]
        XCTAssertEqual(ProjectMatcher.match("pair vox", in: names), 0)
        XCTAssertEqual(ProjectMatcher.match("hazz mate", in: names), 1)
        XCTAssertEqual(ProjectMatcher.match("lumora", in: names), 4)
        XCTAssertEqual(ProjectMatcher.match("web deck", in: names), 2, "an exact match beats the longer name containing it")
        XCTAssertNil(ProjectMatcher.match("web", in: names), "two projects fit")
        XCTAssertNil(ProjectMatcher.match("zzz", in: names))
        XCTAssertNil(ProjectMatcher.match("a", in: names))
        XCTAssertEqual(ProjectMatcher.match("hazz", in: names), 1, "a clear prefix is enough")
    }

    func testSwitchPhrasesParse() {
        XCTAssertEqual(VoiceCommand.parse("switch to project hazz mate"), .switchProject("hazz mate"))
        XCTAssertEqual(VoiceCommand.parse("Switch to PairVox."), .switchProject("pairvox"))
        XCTAssertEqual(VoiceCommand.parse("go to project web deck"), .switchProject("web deck"))
        XCTAssertNil(VoiceCommand.parse("go to the config file and fix it"))
    }

    func testAnUnmatchedSwitchGoesToClaudeAsAnOrdinaryInstruction() async {
        let backend = FakeBackend(), output = FakeOutput()
        let engine = ConversationEngine(configuration: EngineConfiguration(projectRoot: "/Users/dev/app"), output: output, backendFactory: { _ in backend })
        await engine.setProjectSwitchHandler { _ in false }
        await engine.start()
        await engine.submit("switch to the other branch")
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(backend.sent, ["switch to the other branch"])
        await engine.shutdown()
    }

    func testAMatchedSwitchIsHandledAndNotSentToClaude() async {
        let backend = FakeBackend(), output = FakeOutput()
        let engine = ConversationEngine(configuration: EngineConfiguration(projectRoot: "/Users/dev/app"), output: output, backendFactory: { _ in backend })
        let asked = NameBox()
        await engine.setProjectSwitchHandler { name in asked.set(name); return true }
        await engine.start()
        await engine.submit("switch to hazz mate")
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(asked.value, "hazz mate")
        XCTAssertTrue(backend.sent.isEmpty)
        await engine.shutdown()
    }

    final class NameBox: @unchecked Sendable {
        private let lock = NSLock(); private var _v: String?
        var value: String? { lock.withLock { _v } }
        func set(_ v: String) { lock.withLock { _v = v } }
    }
}
