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
        XCTAssertEqual(output.queue.last?.text, "Claude wants to edit a dot swift. Allow?")
        await engine.submit("yeah go ahead")
        XCTAssertEqual(backend.responses.map(\.0), ["p1"])
        XCTAssertEqual(backend.responses.first?.1, .allow)
        snap = await engine.snapshot
        XCTAssertNil(snap.pendingPermission)
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
