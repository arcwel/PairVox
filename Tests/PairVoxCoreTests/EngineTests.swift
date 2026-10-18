// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PairVoxCore

// MARK: - Fakes

final class FakeBackend: SessionBackend, @unchecked Sendable {
    let events: AsyncStream<SessionEvent>
    let continuation: AsyncStream<SessionEvent>.Continuation
    private let lock = NSLock()
    private var _sent: [String] = []
    private var _interrupts = 0
    private var _responses: [(String, PermissionDecision)] = []
    private var _modes: [PermissionMode] = []

    init() {
        var c: AsyncStream<SessionEvent>.Continuation!
        events = AsyncStream { c = $0 }
        continuation = c
    }

    var sent: [String] { lock.lock(); defer { lock.unlock() }; return _sent }
    var interrupts: Int { lock.lock(); defer { lock.unlock() }; return _interrupts }
    var responses: [(String, PermissionDecision)] { lock.lock(); defer { lock.unlock() }; return _responses }
    var modes: [PermissionMode] { lock.lock(); defer { lock.unlock() }; return _modes }

    var isRunning: Bool { true }
    var sessionID: String? { "s1" }
    func start() throws {}
    func send(_ text: String) throws { lock.lock(); _sent.append(text); lock.unlock() }
    func interrupt() throws { lock.lock(); _interrupts += 1; lock.unlock() }
    func respond(to request: PermissionRequest, decision: PermissionDecision) throws {
        lock.lock(); _responses.append((request.requestID, decision)); lock.unlock()
    }
    func setPermissionMode(_ mode: PermissionMode) throws { lock.lock(); _modes.append(mode); lock.unlock() }
    func setModel(_ model: String?) throws {}
    func stop() {}
    func emit(_ e: SessionEvent) { continuation.yield(e) }
}

final class FakeOutput: SpeechOutput, @unchecked Sendable {
    let events: AsyncStream<SpeechOutputEvent>
    let continuation: AsyncStream<SpeechOutputEvent>.Continuation
    private let lock = NSLock()
    private var _queue: [Utterance] = []
    private var _played: [Utterance] = []
    private var _stops = 0
    private var _rate = 1.0
    private var _pauses = 0
    private var _resumes = 0
    var pausable = false

    var supportsPause: Bool { pausable }
    var cancellable = false
    @discardableResult func cancelQueued(_ ids: [Int]) -> [Int] {
        guard cancellable else { return [] }
        lock.lock(); defer { lock.unlock() }
        let removed = _queue.filter { ids.contains($0.id) }.map(\.id)
        _queue.removeAll { ids.contains($0.id) }
        return removed
    }
    func pause() { lock.lock(); _pauses += 1; lock.unlock() }
    func resume() { lock.lock(); _resumes += 1; lock.unlock() }
    var pauses: Int { lock.lock(); defer { lock.unlock() }; return _pauses }
    var resumes: Int { lock.lock(); defer { lock.unlock() }; return _resumes }

    init() {
        var c: AsyncStream<SpeechOutputEvent>.Continuation!
        events = AsyncStream { c = $0 }
        continuation = c
    }

    var queue: [Utterance] { lock.lock(); defer { lock.unlock() }; return _queue }
    var played: [Utterance] { lock.lock(); defer { lock.unlock() }; return _played }
    var stops: Int { lock.lock(); defer { lock.unlock() }; return _stops }
    var rate: Double { lock.lock(); defer { lock.unlock() }; return _rate }
    var allTexts: [String] { (played + queue).map(\.text) }

    func enqueue(_ u: Utterance) {
        lock.lock(); _queue.append(u); lock.unlock()
    }
    @discardableResult func stopAll() -> [Int] {
        lock.lock(); defer { lock.unlock() }
        _stops += 1
        let ids = _queue.map(\.id)
        _queue.removeAll()
        return ids
    }
    func setRate(_ rate: Double) { lock.lock(); _rate = rate; lock.unlock() }

    /// Simulates playback: first item starts (and optionally finishes).
    func playNext(finish: Bool = true) {
        lock.lock()
        guard !_queue.isEmpty else { lock.unlock(); return }
        let u = finish ? _queue.removeFirst() : _queue[0]
        if finish { _played.append(u) }
        lock.unlock()
        continuation.yield(.started(u.id))
        if finish { continuation.yield(.finished(u.id)) }
        if finish && queue.isEmpty { continuation.yield(.idle) }
    }

    func playAll() { while !queue.isEmpty { playNext() } }
}

// MARK: - Tests

final class ConversationEngineTests: XCTestCase {
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

    override func tearDown() async throws {
        await engine.shutdown()
    }

    /// Lets the engine's event-loop tasks run.
    func settle(_ ms: UInt64 = 60) async {
        try? await Task.sleep(nanoseconds: ms * 1_000_000)
    }

    /// Waits until the acknowledgement is queued (or two seconds pass). A fixed 300 ms wait was not always enough on
    /// the Linux CI runner, so the test then started a sentence that did not exist yet.
    func waitForQueuedAcknowledgement() async {
        let deadline = Date().addingTimeInterval(2)
        while output.queue.first?.kind != .ack, Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
    }

    func testTurnStreamsSpeechAndRecordsTranscript() async {
        await engine.submit("What does the auth module do?")
        XCTAssertEqual(backend.sent, ["What does the auth module do?"])
        backend.emit(.textDelta("It validates tokens. "))
        backend.emit(.textDelta("It also refreshes them"))
        await settle()
        XCTAssertEqual(output.queue.map(\.text), ["It validates tokens."], "first sentence speaks before the reply ends")
        backend.emit(.textDelta(".\n\n```swift\nlet a = 1\n```\n"))
        backend.emit(.textBlockEnded)
        backend.emit(.turnCompleted(TurnResult(outcome: .success)))
        await settle()
        XCTAssertEqual(output.queue.map(\.text), ["It validates tokens.", "It also refreshes them.", "A one-line Swift snippet."])
        let snap = await engine.snapshot
        XCTAssertEqual(snap.transcript.map(\.role), [.user, .assistant])
        XCTAssertEqual(snap.transcript[1].status, .done)
        XCTAssertEqual(snap.transcript[1].skipped.first?.kind, .code)
        XCTAssertEqual(snap.usage.turns, 1)
        XCTAssertNotNil(snap.lastLatency?.firstUtterance)
        XCTAssertFalse(snap.isClaudeWorking)
    }

    func testAcknowledgementWhenSilent() async {
        await engine.submit("Refactor the parser")
        await settle(300)
        XCTAssertEqual(output.queue.first?.kind, .ack)
    }

    func testNoAcknowledgementWhenAnswerIsFast() async {
        await engine.submit("Hi")
        backend.emit(.textDelta("Hello there. "))
        await settle(300)
        XCTAssertFalse(output.queue.contains { $0.kind == .ack })
    }

    func testBargeInStopsSpeechAndNoiseResumesIt() async {
        await engine.submit("Explain")
        backend.emit(.textDelta("First point here. Second point here. Third point here. "))
        await settle()
        output.playNext(finish: false)
        await settle()
        await engine.userStartedSpeaking()
        XCTAssertEqual(output.stops, 1)
        XCTAssertEqual(output.queue, [])
        // More text arrives while the user is talking: it is held, not spoken over them.
        backend.emit(.textDelta("Fourth point. "))
        await settle()
        XCTAssertEqual(output.queue, [])
        // It was just a cough.
        await engine.userStoppedSpeaking()
        await engine.submit("")
        XCTAssertEqual(output.queue.map(\.text), ["First point here.", "Second point here.", "Third point here.", "Fourth point."])
    }

    // MARK: Pausing instead of stopping

    private func startSpeaking() async {
        output.pausable = true
        await engine.submit("Explain")
        backend.emit(.textDelta("First point here. Second point here. Third point here. "))
        await settle()
        output.playNext(finish: false)
        await settle()
    }

    func testNoiseOverSpeechResumesInPlaceWithoutReplaying() async {
        await startSpeaking()
        let before = output.queue.map(\.text)
        await engine.userStartedSpeaking()
        XCTAssertEqual(output.pauses, 1)
        XCTAssertEqual(output.stops, 0, "nothing is discarded while we find out whether the user meant it")
        XCTAssertEqual(output.queue.map(\.text), before)
        backend.emit(.textDelta("Fourth point. "))
        await settle()
        XCTAssertEqual(output.queue.map(\.text), before, "new text waits while the user talks")
        await engine.userStoppedSpeaking()
        await engine.submit("")   // transcribed to nothing
        XCTAssertEqual(output.resumes, 1)
        XCTAssertEqual(output.stops, 0)
        XCTAssertEqual(output.queue.map(\.text), before + ["Fourth point."], "carries on where it was, then the held text")
    }

    func testBackchannelOverSpeechResumesInPlace() async {
        await startSpeaking()
        let before = output.queue.map(\.text)
        await engine.userStartedSpeaking()
        await engine.submit("okay")
        XCTAssertEqual(output.resumes, 1)
        XCTAssertEqual(output.stops, 0)
        XCTAssertEqual(output.queue.map(\.text), before)
        XCTAssertEqual(backend.interrupts, 0)
    }

    func testRealCommandOverPausedSpeechStopsIt() async {
        await startSpeaking()
        await engine.userStartedSpeaking()
        await engine.submit("stop")
        XCTAssertGreaterThanOrEqual(output.stops, 1)
        XCTAssertEqual(output.queue, [])
        XCTAssertEqual(output.resumes, 0)
    }

    func testNewInstructionOverPausedSpeechStopsItAndIsSent() async {
        await startSpeaking()
        await engine.userStartedSpeaking()
        await engine.submit("Actually use SQLite instead")
        XCTAssertEqual(output.stops, 1)
        XCTAssertEqual(output.queue, [])
        XCTAssertEqual(backend.sent.last, "Actually use SQLite instead")
    }

    func testStuckTranscriptionDoesNotLeaveSpeechPaused() async {
        await engine.setPauseWatchdog(seconds: 0.2)
        await startSpeaking()
        await engine.userStartedSpeaking()
        await engine.userStoppedSpeaking()
        try? await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertEqual(output.resumes, 1, "a decode that never answers must not silence the reply")
        let phase = await engine.snapshot.phase
        XCTAssertNotEqual(phase, .transcribing)
    }

    func testOutputsThatCannotPauseKeepTheOldBehaviour() async {
        await engine.submit("Explain")
        backend.emit(.textDelta("One here. Two here. "))
        await settle()
        output.playNext(finish: false)
        await engine.userStartedSpeaking()
        XCTAssertEqual(output.pauses, 0)
        XCTAssertEqual(output.stops, 1)
    }

    func testLongReplyIsReadInPartAndDetailsReadsTheRest() async {
        await engine.setSpokenReplyLimit(3)
        await engine.submit("Explain")
        backend.emit(.textDelta("One here. Two here. Three here. Four here. Five here. Six here. "))
        backend.emit(.turnCompleted(TurnResult(outcome: .success)))
        await settle()
        output.playAll()
        await settle()
        let first = output.played.map(\.text)
        XCTAssertTrue(first.contains("Three here."))
        XCTAssertFalse(first.contains("Four here."), "the reply was cut at the limit")
        XCTAssertTrue(first.contains { $0.contains("first part") })
        await engine.submit("details")
        await settle()
        output.playAll()
        XCTAssertTrue(output.played.map(\.text).contains("Six here."), "details reads what was held back")
    }

    // MARK: Courtesy lines never delay the answer

    func testAQueuedAcknowledgementIsDroppedWhenTheAnswerIsReady() async {
        output.cancellable = true
        await engine.submit("Refactor the parser")
        await waitForQueuedAcknowledgement()                // the acknowledgement is queued, not started
        XCTAssertEqual(output.queue.first?.kind, .ack)
        backend.emit(.textDelta("The parser has three stages. "))
        await settle()
        XCTAssertEqual(output.queue.map(\.text), ["The parser has three stages."], "the answer must not wait behind \"On it.\"")
    }

    func testAnAcknowledgementAlreadyBeingSpokenFinishes() async {
        output.cancellable = true
        await engine.submit("Refactor the parser")
        await waitForQueuedAcknowledgement()
        XCTAssertEqual(output.queue.first?.kind, .ack)
        output.playNext(finish: false)                      // it has started
        // "Started" reaches the engine through an async stream; the answer must not overtake it, or the engine still
        // sees the acknowledgement as only queued and rightly drops it (the race behind the CI failures).
        let deadline = Date().addingTimeInterval(2)
        while await !engine.snapshot.isSpeaking, Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
        backend.emit(.textDelta("The parser has three stages. "))
        await settle()
        XCTAssertEqual(output.queue.map(\.kind), [.ack, .prose], "what is already out loud is not cut off")
    }

    func testTheAcknowledgementIsTheFirstSoundAndItsTimeIsRecorded() async {
        // The default acknowledgement comes at 0.8 s, because Claude's first token is rarely sooner than about 1.1 s.
        XCTAssertEqual(EngineConfiguration().acknowledgementDelay, 0.8)
        await engine.submit("Refactor the parser")
        await settle(300)
        output.playNext(finish: false)                       // the acknowledgement starts
        await settle()
        backend.emit(.textDelta("The parser has three stages. "))
        backend.emit(.textBlockEnded)
        output.playNext(finish: true)
        await settle()
        output.playAll()
        backend.emit(.turnCompleted(TurnResult(outcome: .success)))
        await settle()
        let snap = await engine.snapshot
        let sound = snap.lastLatency?.firstSound
        XCTAssertNotNil(sound, "the first sound of the turn, an acknowledgement included, must be measured")
        if let sound, let audio = snap.lastLatency?.firstAudio { XCTAssertLessThanOrEqual(sound, audio) }
    }

    func testBackchannelWhileWorkingDoesNotInterrupt() async {
        await engine.submit("Refactor the parser")
        backend.emit(.textDelta("Starting with the tokenizer. Then the AST. "))
        await settle()
        output.playNext(finish: false)
        await engine.userStartedSpeaking()
        await engine.submit("okay")
        XCTAssertEqual(backend.interrupts, 0)
        XCTAssertEqual(backend.sent, ["Refactor the parser"])
        XCTAssertEqual(output.queue.map(\.text), ["Starting with the tokenizer.", "Then the AST."], "speech resumes")
    }

    func testStopCommandSilencesRestOfTurn() async {
        await engine.submit("Explain")
        backend.emit(.textDelta("One. Two. "))
        await settle()
        await engine.userStartedSpeaking()
        await engine.submit("stop")
        backend.emit(.textDelta("Three. "))
        await settle()
        XCTAssertEqual(output.queue, [])
        XCTAssertEqual(backend.interrupts, 0, "stop only silences speech; Claude keeps working")
    }

    func testRedirectInterruptsClaudeAndSendsNewInstruction() async {
        await engine.submit("Write the migration")
        backend.emit(.toolUse(ToolUse(id: "t1", name: "Read", input: ["file_path": "/Users/dev/app/db.swift"])))
        await settle()
        await engine.userStartedSpeaking()
        await engine.submit("Actually use SQLite instead of Postgres")
        XCTAssertEqual(backend.interrupts, 1)
        XCTAssertEqual(backend.sent, ["Write the migration", "Actually use SQLite instead of Postgres"])
        // Old turn ends interrupted; its trailing text stays silent; new turn speaks.
        backend.emit(.textDelta("Old text. "))
        backend.emit(.turnCompleted(TurnResult(outcome: .interrupted)))
        backend.emit(.textDelta("Switching to SQLite. "))
        await settle()
        let texts = output.queue.map(\.text)
        XCTAssertFalse(texts.contains("Old text."))
        XCTAssertTrue(texts.contains("Switching to SQLite."))
    }

    func testVoiceApprovalForMediumRisk() async {
        await engine.submit("Fix it")
        let req = PermissionRequest(requestID: "p1", toolName: "Edit", input: ["file_path": "/Users/dev/app/a.swift"])
        backend.emit(.permissionRequested(req))
        await settle()
        var snap = await engine.snapshot
        XCTAssertEqual(snap.phase, .awaitingPermission)
        XCTAssertEqual(output.queue.last?.text, "Claude wants to edit a dot swift in the project folder. Allow?")
        await engine.submit("yeah go ahead")
        XCTAssertEqual(backend.responses.map(\.0), ["p1"])
        XCTAssertEqual(backend.responses.first?.1, .allow)
        snap = await engine.snapshot
        XCTAssertNil(snap.pendingPermission)
    }

    /// Owner report, 2026-10-17: a spoken answer the recognizer got wrong denied the request twice. One or two words
    /// that are neither yes nor no now ask again; a real redirect ("no, edit b instead") still refuses with feedback.
    func testAnUnclearShortAnswerAsksAgainInsteadOfDenying() async {
        await engine.submit("Fix it")
        backend.emit(.permissionRequested(PermissionRequest(requestID: "p1", toolName: "Edit",
                                                            input: ["file_path": "/Users/dev/app/a.swift"])))
        await settle()
        await engine.submit("Yasp.")
        await settle()
        XCTAssertTrue(backend.responses.isEmpty, "a misheard word must not answer the request")
        XCTAssertEqual(output.queue.last?.text, "Sorry, was that a yes or a no?")
        var snap = await engine.snapshot
        XCTAssertEqual(snap.pendingPermission?.request.requestID, "p1", "still waiting")
        await engine.submit("yes")
        XCTAssertEqual(backend.responses.first?.1, .allow)

        backend.emit(.permissionRequested(PermissionRequest(requestID: "p2", toolName: "Edit",
                                                            input: ["file_path": "/Users/dev/app/b.swift"])))
        await settle()
        await engine.submit("Edit the other file instead")
        await settle()
        snap = await engine.snapshot
        XCTAssertNil(snap.pendingPermission)
        XCTAssertEqual(backend.responses.last?.0, "p2")
        if case .deny = backend.responses.last?.1 {} else { XCTFail("a longer redirect still refuses with feedback") }
    }

    func testRepliesAfterSpokenApprovalAreNotSwallowed() async {
        await engine.submit("Fix it")
        backend.emit(.permissionRequested(PermissionRequest(requestID: "p9", toolName: "Edit",
                                                            input: ["file_path": "/Users/dev/app/a.swift"])))
        await settle()
        output.playNext(finish: false)        // prompt is playing
        await settle()
        await engine.userStartedSpeaking()   // user talks over it
        await engine.userStoppedSpeaking()
        await engine.submit("yes")
        XCTAssertEqual(backend.responses.first?.1, .allow)
        backend.emit(.textDelta("Done, the file is fixed. "))
        backend.emit(.textBlockEnded)
        await settle()
        XCTAssertEqual(output.queue.map(\.text), ["Done, the file is fixed."])
    }

    func testDetailsDuringStreamingReadsDetailAtEnd() async {
        await engine.setSpeechMode(.summary)
        await engine.submit("Review it")
        backend.emit(.textDelta("Two issues found.\n\nThe cache key ignores locale. "))
        await settle()
        output.playNext(finish: false)
        await engine.userStartedSpeaking()
        await engine.submit("details")
        backend.emit(.textDelta("A test is flaky.\n"))
        backend.emit(.textBlockEnded)
        backend.emit(.turnCompleted(TurnResult(outcome: .success)))
        await settle()
        XCTAssertEqual(output.queue.map(\.text), ["Two issues found.", "The cache key ignores locale.", "A test is flaky."])
    }

    func testVoiceCannotApproveHighRisk() async {
        await engine.submit("Clean up")
        let req = PermissionRequest(requestID: "p2", toolName: "Bash", input: ["command": "rm -rf build"])
        backend.emit(.permissionRequested(req))
        await settle()
        XCTAssertTrue(output.queue.last?.text.hasSuffix("Please confirm on screen.") ?? false)
        await engine.submit("yes")
        XCTAssertTrue(backend.responses.isEmpty)
        XCTAssertEqual(output.queue.last?.text, "That one needs a click. Please confirm it on screen.")
        // The on-screen button works.
        await engine.approvePending()
        XCTAssertEqual(backend.responses.first?.1, .allow)
    }

    func testFeedbackInsteadOfYesNoDeniesWithMessage() async {
        await engine.submit("Fix it")
        backend.emit(.permissionRequested(PermissionRequest(requestID: "p3", toolName: "Edit",
                                                            input: ["file_path": "/Users/dev/app/a.swift"])))
        await settle()
        await engine.submit("No, change the b file first and keep a as it is")
        guard case .deny(let message, let interrupt)? = backend.responses.first?.1 else { return XCTFail() }
        XCTAssertTrue(message.contains("change the b file first"))
        XCTAssertFalse(interrupt)
    }

    func testSummaryModeAndDetails() async {
        await engine.setSpeechMode(.summary)
        await engine.submit("Review the PR")
        backend.emit(.textDelta("Looks good overall, two small issues.\n\nFirst, the cache key ignores locale. Second, a test is flaky.\n"))
        backend.emit(.textBlockEnded)
        backend.emit(.turnCompleted(TurnResult(outcome: .success)))
        await settle()
        XCTAssertEqual(output.queue.map(\.text), ["Looks good overall, two small issues.",
                                                  "There's more detail. Say “details” to hear it."])
        output.playAll()
        await settle()
        await engine.submit("details")
        XCTAssertEqual(output.queue.map(\.text), ["First, the cache key ignores locale.", "Second, a test is flaky."])
    }

    func testModeCommands() async {
        await engine.submit("brainstorm mode")
        XCTAssertEqual(backend.modes, [.plan])
        var snap = await engine.snapshot
        XCTAssertEqual(snap.conversationMode, .brainstorm)
        XCTAssertEqual(backend.sent, [], "commands are not sent to Claude")
        await engine.submit("speak faster")
        XCTAssertEqual(output.rate, 1.1, accuracy: 0.001)
        snap = await engine.snapshot
        XCTAssertEqual(snap.speechRate, 1.1, accuracy: 0.001)
    }

    func testRepeatLast() async {
        await engine.submit("Hi")
        backend.emit(.textDelta("Hello. How can I help?"))
        backend.emit(.textBlockEnded)
        backend.emit(.turnCompleted(TurnResult(outcome: .success)))
        await settle()
        output.playAll()
        await settle()
        await engine.submit("repeat that")
        XCTAssertEqual(output.queue.map(\.text), ["Hello.", "How can I help?"])
    }

    func testAuthProblemIsSpokenOnceAndShown() async {
        backend.emit(.authProblem("authentication_failed"))
        backend.emit(.authProblem("authentication_failed"))
        await settle()
        let snap = await engine.snapshot
        XCTAssertEqual(snap.phase, .needsSetup)
        XCTAssertEqual(output.queue.filter { $0.kind == .notice }.count, 1)
        XCTAssertTrue(output.queue.first?.text.contains("isn't signed in") ?? false)
    }

    func testProcessCrashMidTurnIsReported() async {
        await engine.submit("Do work")
        backend.emit(.processExited(code: 1, stderrTail: "boom"))
        await settle()
        let snap = await engine.snapshot
        XCTAssertFalse(snap.isClaudeWorking)
        XCTAssertTrue(output.queue.contains { $0.text.contains("stopped unexpectedly") })
    }
}
