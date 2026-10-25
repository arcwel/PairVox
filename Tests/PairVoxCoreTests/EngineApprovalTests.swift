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

    // Security audit 2026-10-24: a spoken "sounds good" begun before the request's prompt played (a reply to Claude's
    // previous sentence) approved a request nobody had heard.
    func testASpokenYesBegunBeforeThePromptPlayedDoesNotCount() async {
        await engine.submit("Fix it")
        backend.emit(.textDelta("I will update the config. "))
        backend.emit(edit("A", "a.swift"))
        await settle()
        await engine.userStartedSpeaking()
        await engine.userStoppedSpeaking()
        await engine.submit("sounds good")
        await settle()
        XCTAssertTrue(backend.responses.isEmpty, "the prompt had not started, so the reply was to something else")
        guard let prompt = output.queue.last(where: { $0.kind == .prompt }) else { return XCTFail("the prompt is still to be played") }
        output.continuation.yield(.started(prompt.id))
        await settle()
        await engine.userStartedSpeaking()
        await engine.userStoppedSpeaking()
        await engine.submit("yes")
        await settle()
        guard case .allow? = backend.responses.first?.1 else { return XCTFail("a yes begun after the prompt started approves") }
    }

    // Audit run 7: the end of "…Allow?" heard back through the microphone is PairVox's own voice, not an answer.
    func testTheTailOfThePromptHeardBackIsNotAnApproval() async {
        await engine.submit("Fix it")
        backend.emit(edit("A", "a.swift"))
        await settle()
        guard let prompt = output.queue.last(where: { $0.kind == .prompt }) else { return XCTFail("prompt") }
        output.continuation.yield(.started(prompt.id))
        await settle()
        await engine.userStartedSpeaking()
        await engine.userStoppedSpeaking()
        await engine.submit("Allow")
        await settle()
        XCTAssertTrue(backend.responses.isEmpty, "\"allow\" while the prompt plays is its own last word")
        output.continuation.yield(.finished(prompt.id))
        await settle()
        await engine.userStartedSpeaking()
        await engine.userStoppedSpeaking()
        await engine.submit("yes")
        await settle()
        guard case .allow? = backend.responses.first?.1 else { return XCTFail("\"yes\" is never in a prompt, so it counts") }
    }

    // Review of run 7: a prompt that was cut off is not an echo source, and "confirm high risk" is never one.
    func testAnAllowAfterACutOffPromptCounts() async {
        await engine.submit("Fix it")
        backend.emit(edit("A", "a.swift"))
        await settle()
        guard let prompt = output.queue.last(where: { $0.kind == .prompt }) else { return XCTFail("prompt") }
        output.continuation.yield(.started(prompt.id))
        await settle()
        // A noise barges in on the prompt and cuts it off (which counts as its end), then nothing is said.
        await engine.userStartedSpeaking()
        await engine.userStoppedSpeaking()
        await engine.transcriptionFailed()
        await settle(700)             // past the echo window
        await engine.userStartedSpeaking()
        await engine.userStoppedSpeaking()
        await engine.submit("Allow")
        await settle()
        guard case .allow? = backend.responses.first?.1 else { return XCTFail("the prompt was no longer sounding") }
    }

    func testAlwaysAllowWithNoNarrowRuleIsAPlainAllow() async {
        await engine.submit("Fix it")
        backend.emit(.permissionRequested(PermissionRequest(requestID: "A", toolName: "Edit", input: ["file_path": .string("/Users/dev/app/a.swift")],
                                                            suggestions: [["type": "setMode", "mode": "acceptEdits", "destination": "session"]])))
        await settle()
        await engine.approvePending(always: true)
        await settle()
        XCTAssertEqual(backend.responses.first?.1, .allow, "a mode change is never applied, so this is an allow for this request")
    }

    // A spoken answer that does not count says why on the card.
    func testAnIgnoredAnswerSaysWhy() async {
        await engine.submit("Fix it")
        backend.emit(edit("A", "a.swift"))
        await settle()
        await engine.userStartedSpeaking()
        await engine.userStoppedSpeaking()
        await engine.submit("sounds good")
        await settle()
        var snap = await engine.snapshot
        XCTAssertEqual(snap.ignoredAnswer, IgnoredAnswer(requestID: "A", heard: "sounds good", reason: .beforePrompt))
        XCTAssertTrue(output.allTexts.contains("I heard that before I asked."))
        guard let prompt = output.queue.last(where: { $0.kind == .prompt }) else { return XCTFail("prompt") }
        output.continuation.yield(.started(prompt.id))
        await settle()
        await engine.userStartedSpeaking()
        await engine.userStoppedSpeaking()
        await engine.submit("yes")
        await settle()
        snap = await engine.snapshot
        XCTAssertNil(snap.ignoredAnswer, "an answered request leaves nothing behind")
    }

    // Audit run 8: the notice after an echo has no answer word in it, and its own echo is not an answer either.
    func testTheEchoNoticeCannotItselfApprove() async {
        await engine.submit("Fix it")
        backend.emit(edit("A", "a.swift"))
        await settle()
        guard let prompt = output.queue.last(where: { $0.kind == .prompt }) else { return XCTFail("prompt") }
        output.continuation.yield(.started(prompt.id))
        await settle()
        await engine.userStartedSpeaking()
        await engine.userStoppedSpeaking()
        await engine.submit("Allow")
        await settle()
        guard let notice = output.queue.last(where: { $0.kind == .notice }) else { return XCTFail("the echo notice") }
        XCTAssertNil(VoiceCommand.parse(notice.text, context: .init(awaitingPermission: true)), "\(notice.text) is not an answer")
        output.continuation.yield(.started(notice.id))
        await settle()
        await engine.userStartedSpeaking()
        await engine.userStoppedSpeaking()
        await engine.submit("answer again")
        await settle()
        XCTAssertTrue(backend.responses.isEmpty)
    }

    // Audit run 8: an earlier request's prompt left in the queue does not open the answer window for the next one.
    func testAStalePromptDoesNotCountAsTheNextRequestsQuestion() async {
        await engine.submit("Fix it")
        backend.emit(edit("A", "a.swift"))
        await settle()
        let promptA = output.queue.last(where: { $0.kind == .prompt })
        await engine.approvePending(requestID: "A")   // a click, before A's prompt played
        backend.emit(edit("B", "b.swift"))
        await settle()
        if let a = promptA { output.continuation.yield(.started(a.id)) }
        await settle()
        await engine.userStartedSpeaking()
        await engine.userStoppedSpeaking()
        await engine.submit("yes")
        await settle()
        XCTAssertEqual(backend.responses.map(\.0), ["A"], "B's own question had not started")
    }

    // Audit run 8: an announcement about another project heard back is not offered to the cross-project interceptor.
    func testAnAnnouncementHeardBackIsNotAnAnswerToIt() async {
        let seen = Recorder()
        await engine.setUtteranceInterceptor { text in seen.add(text); return true }
        await engine.announce("Second project wants to edit a dot swift. Say approve, deny, tell me more, or switch.")
        await settle()
        guard let notice = output.queue.last(where: { $0.kind == .notice }) else { return XCTFail("announcement") }
        output.continuation.yield(.started(notice.id))
        await settle()
        await engine.userStartedSpeaking()
        await engine.userStoppedSpeaking()
        await engine.submit("approve")
        await settle()
        XCTAssertEqual(seen.items, [], "the announcement's own word, heard while it played")
        output.continuation.yield(.finished(notice.id))
        await settle(700)
        await engine.userStartedSpeaking()
        await engine.userStoppedSpeaking()
        await engine.submit("approve")
        await settle()
        XCTAssertEqual(seen.items, ["approve"], "said after the announcement ended: an answer")
    }

    func testTypedAnswersAreNotHeldBackByThePrompt() async {
        await engine.submit("Fix it")
        backend.emit(edit("A", "a.swift"))
        await settle()
        // The app and the CLI announce typed text the way they announce speech (it barges in), but marked as typed.
        await engine.userStartedSpeaking(typed: true)
        await engine.userStoppedSpeaking()
        await engine.submit("yes")
        await settle()
        guard case .allow? = backend.responses.first?.1 else { return XCTFail("typed text has no speech start to compare") }
    }

    func testThePromptOfTheFirstRequestDoesNotCountForTheNext() async {
        await engine.submit("Fix it")
        backend.emit(edit("A", "a.swift"))
        backend.emit(edit("B", "b.swift"))
        await settle()
        guard let promptA = output.queue.last(where: { $0.kind == .prompt }) else { return XCTFail("prompt for A") }
        output.continuation.yield(.started(promptA.id))
        await settle()
        await engine.userStartedSpeaking()
        await engine.userStoppedSpeaking()
        await engine.submit("yes")
        await settle()
        XCTAssertEqual(backend.responses.map(\.0), ["A"], "A was heard, so its yes counts")
        // B is shown now; a yes begun before B's own prompt starts is not an answer to B.
        await engine.userStartedSpeaking()
        await engine.userStoppedSpeaking()
        await engine.submit("yes")
        await settle()
        XCTAssertEqual(backend.responses.map(\.0), ["A"], "B's prompt had not started")
    }

    // The voice goes cold between replies (first sentence 5.0 s on 2026-10-18), so it is told to get ready as soon as
    // a reply becomes likely: speech starts, typed text is sent, or a phone sends text.
    func testTheVoiceIsToldToGetReadyWhenAReplyIsLikely() async {
        await engine.userStartedSpeaking()
        XCTAssertEqual(output.prepares, 1)
        await engine.userStartedSpeaking(typed: true)
        XCTAssertEqual(output.prepares, 2)
        await engine.submitFromRemote("what changed")
        XCTAssertEqual(output.prepares, 3)
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
        XCTAssertTrue(output.allTexts.contains("Claude wants to edit b dot swift in the project folder. Allow?"))

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

    // MARK: Task 1.3: the summary setting reaches a running session

    let longCommand = "cd /Users/dev/app && swift build && swift test --filter LinkTests && git status --short && ls -la .build | head -40"

    func testTurningTheSummarySettingOffReachesTheRunningSession() async {
        await engine.submit("Build it")
        backend.emit(bash("s1", longCommand))
        await settle()
        XCTAssertTrue(output.allTexts.contains { $0.hasPrefix("Claude wants to run cd") && $0.contains("more steps shown on screen. Allow?") }, "\(output.allTexts)")
        await engine.submit("yes")
        XCTAssertEqual(backend.responses.map(\.0), ["s1"], "on by default: the summary line is what a yes answers")

        await engine.setApproveByVoiceFromSummary(false)
        backend.emit(bash("s2", longCommand))
        await settle()
        await engine.submit("yes")
        XCTAssertEqual(backend.responses.map(\.0), ["s1"], "turned off mid-session: the next long command needs a click")
        XCTAssertTrue(output.allTexts.last?.contains("needs a click") ?? false, "\(output.allTexts.last ?? "")")
        var snap = await engine.snapshot
        XCTAssertEqual(snap.pendingPermission?.request.requestID, "s2")
        XCTAssertFalse(snap.pendingPermission?.assessment.voiceApprovable ?? true)
        XCTAssertTrue(snap.pendingPermission?.assessment.spokenPrompt.hasSuffix("Please confirm on screen.") ?? false)
        await engine.approvePending(requestID: "s2")
        XCTAssertEqual(backend.responses.map(\.0), ["s1", "s2"], "a click still approves it")

        await engine.setApproveByVoiceFromSummary(true)
        backend.emit(bash("s3", longCommand))
        await settle()
        await engine.submit("yes")
        XCTAssertEqual(backend.responses.map(\.0), ["s1", "s2", "s3"], "turned back on: the summary answers again")
        snap = await engine.snapshot
        XCTAssertNil(snap.pendingPermission)
    }

    func testTurningTheSummarySettingOffReratesTheRequestAlreadyOnScreen() async {
        await engine.submit("Build it")
        backend.emit(bash("s1", longCommand))
        backend.emit(bash("s2", longCommand))
        await settle()
        var snap = await engine.snapshot
        XCTAssertTrue(snap.pendingPermission?.assessment.voiceApprovable ?? false)
        await engine.setApproveByVoiceFromSummary(false)
        snap = await engine.snapshot
        XCTAssertFalse(snap.pendingPermission?.assessment.voiceApprovable ?? true, "the request on screen follows the new rule")
        XCTAssertFalse(snap.queuedPermissions.first?.assessment.voiceApprovable ?? true, "so does the one waiting behind it")
        await engine.submit("yes")
        XCTAssertTrue(backend.responses.isEmpty, "a yes spoken after the change does not approve from the summary")
        XCTAssertFalse(output.allTexts.filter { $0.hasPrefix("Claude wants to run") }.count > 1, "the prompt is not spoken again")
    }

    func testASettingThatDidNotChangeLeavesTheRequestAlone() async {
        await engine.submit("Build it")
        backend.emit(bash("s1", longCommand))
        await settle()
        let before = await engine.snapshot.pendingPermission
        await engine.setApproveByVoiceFromSummary(true)
        let after = await engine.snapshot.pendingPermission
        XCTAssertEqual(before, after)
    }

    // MARK: Task 1.5: a spoken yes stops counting after the age limit

    final class FakeClock: @unchecked Sendable {
        private let lock = NSLock()
        private var t: Date
        init(_ start: Date = Date(timeIntervalSince1970: 2_000_000)) { t = start }
        var now: Date { lock.lock(); defer { lock.unlock() }; return t }
        func advance(_ seconds: TimeInterval) { lock.lock(); t.addTimeInterval(seconds); lock.unlock() }
    }

    func testASpokenYesIsRefusedForARequestLeftWaitingButAClickStillWorks() async {
        let clock = FakeClock()
        await engine.setClock { clock.now }
        await engine.submit("Fix it")
        backend.emit(edit("A", "a.swift"))
        await settle()
        let snap = await engine.snapshot
        XCTAssertEqual(snap.pendingPermission?.receivedAt, clock.now, "the request is stamped with the engine's clock")

        clock.advance(Announcer.staleAfter - 1)
        await engine.submit("yes")
        XCTAssertEqual(backend.responses.map(\.0), ["A"], "just inside the limit, a yes still answers")

        backend.emit(edit("B", "b.swift"))
        await settle()
        clock.advance(Announcer.staleAfter + 1)
        await engine.submit("yes")
        await engine.submit("sure")
        XCTAssertEqual(backend.responses.map(\.0), ["A"], "a prompt that waited an hour takes no stray yes from the room")
        XCTAssertTrue(output.allTexts.last?.contains("waiting a while") ?? false, "\(output.allTexts.last ?? "")")
        XCTAssertTrue(output.allTexts.last?.contains("confirm it on screen") ?? false)
        var after = await engine.snapshot
        XCTAssertEqual(after.pendingPermission?.request.requestID, "B", "the request still waits")
        await engine.approvePending(requestID: "B")
        XCTAssertEqual(backend.responses.map(\.0), ["A", "B"], "a click is not subject to the age limit")
        after = await engine.snapshot
        XCTAssertNil(after.pendingPermission)
    }

    func testTheAgeLimitAppliesToTheHighRiskPhraseAndToAllowAllToo() async {
        let clock = FakeClock()
        await engine.setClock { clock.now }
        await engine.setSpokenHighRiskConfirmation(true)
        await engine.submit("Clean up")
        backend.emit(bash("h1", "rm -rf build"))
        await settle()
        clock.advance(Announcer.staleAfter + 1)
        await engine.submit("confirm high risk")
        XCTAssertTrue(backend.responses.isEmpty, "the phrase is a spoken approval too")
        XCTAssertTrue(output.allTexts.last?.contains("waiting a while") ?? false)
        await engine.denyPending()

        backend.emit(edit("A", "a.swift"))
        backend.emit(edit("B", "b.swift"))
        await settle()
        clock.advance(Announcer.staleAfter + 1)
        await engine.submit("allow all")
        XCTAssertEqual(backend.responses.count, 1, "nothing stale is armed for allow all")
        XCTAssertTrue(output.allTexts.last?.contains("None of these can be allowed by voice") ?? false, "\(output.allTexts.last ?? "")")
    }

    func testTheSameAgeLimitAsTheAnnouncerAndTheLink() {
        XCTAssertEqual(Announcer.staleAfter, 300)
        let p = PendingPermission(request: PermissionRequest(requestID: "r", toolName: "Read", input: [:]),
                                  assessment: PermissionAssessment(risk: .low, voiceApprovable: true, spokenPrompt: "", summary: "", reasons: []),
                                  receivedAt: Date(timeIntervalSince1970: 0))
        XCTAssertFalse(p.isStale(now: Date(timeIntervalSince1970: Announcer.staleAfter)))
        XCTAssertTrue(p.isStale(now: Date(timeIntervalSince1970: Announcer.staleAfter + 0.5)))
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

final class VoiceForEverythingTests: XCTestCase {
    var backend: FakeBackend!, output: FakeOutput!, engine: ConversationEngine!

    func start(needsScreen: Bool = false) async {
        backend = FakeBackend(); output = FakeOutput()
        let b = backend!
        engine = ConversationEngine(configuration: EngineConfiguration(projectRoot: "/Users/dev/app", spokenHighRiskConfirmation: true,
                                                                       explainRequests: false, acknowledgementDelay: 0.15),
                                    output: output, backendFactory: { _ in b })
        await engine.start()
        await engine.submit("Do it")
        backend.emit(.permissionRequested(PermissionRequest(requestID: "H", toolName: "Bash", input: ["command": "git push origin main"],
                                                            requiresUserInteraction: needsScreen)))
        try? await Task.sleep(nanoseconds: 80_000_000)
    }

    func testHighRiskByVoiceUsesTheDeliberatePhraseNotAYes() async {
        await start()
        await engine.submit("yes")
        try? await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertTrue(backend.responses.isEmpty)
        await engine.submit("confirm high risk")
        try? await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(backend.responses.map(\.0), ["H"])
        await engine.shutdown()
    }

    func testRequestsClaudeCodeMarksAsNeedingTheScreenHaveTheirOwnSwitch() async {
        await start(needsScreen: true)
        await engine.submit("confirm high risk")
        try? await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertTrue(backend.responses.isEmpty, "off by default")
        await engine.setVoiceApprovesNeedsScreen(true)
        await engine.submit("confirm high risk")
        try? await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(backend.responses.map(\.0), ["H"])
        await engine.shutdown()
    }

    func testSecondConfirmationCanRefuseAfterTheSpokenPhrase() async {
        await start()
        await engine.setSecondConfirmation { false }
        await engine.submit("confirm high risk")
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(backend.responses.isEmpty, "the Touch ID or password check said no")
        let snap = await engine.snapshot
        XCTAssertEqual(snap.pendingPermission?.request.requestID, "H", "still waiting")
        await engine.setSecondConfirmation { true }
        await engine.submit("confirm high risk")
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(backend.responses.map(\.0), ["H"])
        await engine.shutdown()
    }

    func testTheAppCanInterceptAnUtteranceBeforeTheEngineReadsIt() async {
        await start()
        await engine.setUtteranceInterceptor { text in text == "approve" }
        await engine.submit("approve")
        try? await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertTrue(backend.responses.isEmpty, "the app took it")
        await engine.setUtteranceInterceptor(nil)
        await engine.shutdown()
    }
}

final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _items: [String] = []
    var items: [String] { lock.withLock { _items } }
    func add(_ s: String) { lock.withLock { _items.append(s) } }
}
