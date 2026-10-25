// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PairVoxCore

final class FolderScopeTests: XCTestCase {
    var root: URL!
    var outside: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("pv-grant-\(UUID().uuidString)")
        root = base.appendingPathComponent("project")
        outside = base.appendingPathComponent("elsewhere")
        for d in [root!, outside!, root.appendingPathComponent("src")] {
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
        try "x".write(to: outside.appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link-out"), withDestinationURL: outside)
        root = URL(fileURLWithPath: FolderScope.resolved(root.path))   // /var vs /private/var
        outside = URL(fileURLWithPath: FolderScope.resolved(outside.path))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }

    func testInsideOutsideAndTraversal() {
        XCTAssertTrue(FolderScope.contains(folder: root.path, path: root.path + "/src/a.swift"))
        XCTAssertTrue(FolderScope.contains(folder: root.path, path: "src/new-file.swift", relativeTo: root.path), "a file that does not exist yet")
        XCTAssertFalse(FolderScope.contains(folder: root.path, path: root.path + "-evil/x"), "prefix trick")
        XCTAssertFalse(FolderScope.contains(folder: root.path, path: root.path + "/src/../../elsewhere/secret.txt"))
        XCTAssertFalse(FolderScope.contains(folder: root.path, path: "../elsewhere/secret.txt", relativeTo: root.path))
        XCTAssertFalse(FolderScope.contains(folder: root.path, path: "~/Documents/x"))
    }

    func testASymlinkInsideTheFolderDoesNotCarryTheGrantOutside() {
        XCTAssertFalse(FolderScope.contains(folder: root.path, path: root.path + "/link-out/secret.txt"))
        XCTAssertFalse(FolderScope.contains(folder: root.path, path: root.path + "/link-out/brand-new.txt"), "even for a new file through the link")
    }

    func grants(shell: Bool = false) -> [FolderGrant] { [FolderGrant(path: root.path, allowShell: shell)] }

    func assess(_ tool: String, _ input: JSONValue, shell: Bool = false, grants g: [FolderGrant]? = nil,
                _ extra: (inout PermissionRequest) -> Void = { _ in }) -> PermissionAssessment {
        var r = PermissionRequest(requestID: "r", toolName: tool, input: input)
        extra(&r)
        return PermissionPolicy(projectRoot: root.path, grants: g ?? grants(shell: shell)).assess(r)
    }

    func testEditsInsideAGrantedFolderAreCoveredButNothingElse() {
        XCTAssertTrue(assess("Edit", ["file_path": .string(root.path + "/src/a.swift")]).coveredByFolderGrant)
        XCTAssertTrue(assess("Write", ["file_path": "src/new.swift"]).coveredByFolderGrant)
        XCTAssertFalse(assess("Edit", ["file_path": .string(root.path + "/src/a.swift")], grants: []).coveredByFolderGrant, "no grant")
        XCTAssertFalse(assess("Edit", ["file_path": .string(outside.path + "/secret.txt")]).coveredByFolderGrant)
        XCTAssertFalse(assess("Edit", ["file_path": .string(root.path + "/link-out/secret.txt")]).coveredByFolderGrant)
        XCTAssertFalse(assess("Edit", ["file_path": .string(root.path + "/.env")]).coveredByFolderGrant, "sensitive files stay high risk")
        XCTAssertFalse(assess("Edit", ["file_path": .string(root.path + "/src/a.swift")]) { $0.decisionReasonType = "safetyCheck" }.coveredByFolderGrant)
        XCTAssertFalse(assess("Edit", ["file_path": .string(root.path + "/src/a.swift")]) { $0.requiresUserInteraction = true }.coveredByFolderGrant)
        XCTAssertFalse(assess("WebFetch", ["url": "https://example.invalid"]).coveredByFolderGrant)
        XCTAssertFalse(assess("Read", ["file_path": .string(root.path + "/src/a.swift")]).coveredByFolderGrant, "reads are not what the grant is about")
    }

    func testShellCommandsNeedTheSeparateShellGrant() {
        XCTAssertFalse(assess("Bash", ["command": "swift build"], shell: false).coveredByFolderGrant, "edit grant alone never covers shell")
        for ok in ["swift build", "npm test", "make", "ls src", "python3 script.py", "rm build.log", "mv a.txt src/a.txt", "cat src/a.swift | wc -l"] {
            XCTAssertTrue(assess("Bash", ["command": .string(ok)], shell: true).coveredByFolderGrant, ok)
        }
        let escapes = ["cat ../elsewhere/secret.txt", "cd .. && ls", "ls /etc", "cp a.txt /tmp/a.txt", "cat ~/notes.txt", "cat $HOME/x",
                       "echo hi > ../out.txt", "cat \(outside.path)/secret.txt", "cat link-out/secret.txt",
                       "curl https://example.invalid/x", "npm install lodash", "git push origin main", "rm -rf build", "sudo make install",
                       "python3 -c 'print(1)'", "node -e 'x()'", "sh -c 'ls'", "ssh host ls", "open .", "cat .env", "ls `pwd`/..", "ls $(pwd)"]
        for bad in escapes {
            XCTAssertFalse(assess("Bash", ["command": .string(bad)], shell: true).coveredByFolderGrant, bad)
        }
        XCTAssertFalse(assess("Bash", ["command": "swift build"], shell: true) { $0.requiresUserInteraction = true }.coveredByFolderGrant)
    }
}

final class FolderGrantEngineTests: XCTestCase {
    var backend: FakeBackend!
    var output: FakeOutput!
    var engine: ConversationEngine!
    var changes: Changes!
    let root = FolderScope.resolved(NSTemporaryDirectory() + "pv-engine-grant")

    final class Changes: @unchecked Sendable {
        private let lock = NSLock(); private var _all: [FolderGrantChange] = []
        var all: [FolderGrantChange] { lock.withLock { _all } }
        func add(_ c: FolderGrantChange) { lock.withLock { _all.append(c) } }
    }

    override func setUp() async throws {
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        backend = FakeBackend(); output = FakeOutput(); changes = Changes()
        let b = backend!
        engine = ConversationEngine(configuration: EngineConfiguration(projectRoot: root, speechMode: .skipCode, acknowledgementDelay: 0.15),
                                    output: output, backendFactory: { _ in b })
        let c = changes!
        await engine.setGrantHandler { c.add($0) }
        await engine.start()
    }

    override func tearDown() async throws {
        await engine.shutdown()
        try? FileManager.default.removeItem(atPath: root)
    }

    func settle(_ ms: UInt64 = 60) async { try? await Task.sleep(nanoseconds: ms * 1_000_000) }

    func edit(_ id: String) -> SessionEvent {
        .permissionRequested(PermissionRequest(requestID: id, toolName: "Edit", input: ["file_path": .string(root + "/a.swift")]))
    }

    func testGrantNeedsTwoYesAnswersAndThenEditsSkipThePrompt() async {
        await engine.setSpokenHighRiskConfirmation(true)
        await engine.offerFolderGrant()
        var snap = await engine.snapshot
        XCTAssertEqual(snap.grantOffer?.stage, .asking)
        XCTAssertTrue(snap.grantOffer?.text.contains("allow Claude to edit all files inside it") ?? false)
        await engine.submit("yes")
        snap = await engine.snapshot
        XCTAssertEqual(snap.grantOffer?.stage, .confirming, "one yes is not enough")
        XCTAssertTrue(changes.all.isEmpty)
        XCTAssertTrue(output.allTexts.contains { $0.hasPrefix("To confirm: Claude will be able to edit every file inside") })
        await engine.submit("yes")
        snap = await engine.snapshot
        XCTAssertEqual(snap.grantOffer?.stage, .confirming, "the second step needs the word confirm, not another yes")
        await engine.submit("say confirm")
        snap = await engine.snapshot
        XCTAssertNotNil(snap.grantOffer, "a sentence that starts with say could be PairVox's own prompt heard back")
        XCTAssertTrue(changes.all.isEmpty)
        await engine.submit("confirm")
        snap = await engine.snapshot
        XCTAssertNil(snap.grantOffer)
        XCTAssertEqual(changes.all, [.granted(path: root, shell: false)])

        await engine.submit("Fix it")
        backend.emit(edit("A"))
        await settle()
        XCTAssertEqual(backend.responses.map(\.0), ["A"], "answered without asking")
        snap = await engine.snapshot
        XCTAssertNil(snap.pendingPermission)
        XCTAssertTrue(snap.transcript.contains { $0.text.hasPrefix("Allowed by your folder access") })
    }

    func testNoAtEitherStageDeclinesAndNothingIsGranted() async {
        await engine.setSpokenHighRiskConfirmation(true)
        await engine.offerFolderGrant()
        await engine.submit("no")
        var snap = await engine.snapshot
        XCTAssertNil(snap.grantOffer)
        XCTAssertEqual(changes.all, [.declined(path: root)])
        await engine.offerFolderGrant()
        await engine.submit("yes")
        await engine.submit("no thanks")
        snap = await engine.snapshot
        XCTAssertNil(snap.grantOffer)
        XCTAssertFalse(changes.all.contains(.granted(path: root, shell: false)))
        await engine.submit("Fix it")
        backend.emit(edit("A"))
        await settle()
        snap = await engine.snapshot
        XCTAssertEqual(snap.pendingPermission?.request.requestID, "A", "still asks")
    }

    func testSayingSomethingElseDropsTheOfferWithoutGranting() async {
        await engine.offerFolderGrant()
        await engine.submit("Please refactor the parser")
        let snap = await engine.snapshot
        XCTAssertNil(snap.grantOffer)
        XCTAssertTrue(changes.all.isEmpty)
    }

    func testARealPermissionRequestOutranksTheOffer() async {
        await engine.submit("Fix it")
        await engine.offerFolderGrant()
        backend.emit(edit("A"))
        await settle()
        var snap = await engine.snapshot
        XCTAssertNil(snap.grantOffer)
        await engine.submit("yes")
        XCTAssertEqual(backend.responses.map(\.0), ["A"], "the yes answers the request, not a grant")
        XCTAssertTrue(changes.all.isEmpty)
        snap = await engine.snapshot
        XCTAssertNil(snap.grantOffer)
    }

    func testShellGrantIsItsOwnTwoStepQuestionAndNeedsTheEditGrant() async {
        await engine.setSpokenHighRiskConfirmation(true)
        await engine.offerFolderGrant(shell: true)
        var snap = await engine.snapshot
        XCTAssertNil(snap.grantOffer, "no edit grant yet")
        await engine.setFolderGrants([FolderGrant(path: root)])
        await engine.offerFolderGrant(shell: true)
        snap = await engine.snapshot
        XCTAssertEqual(snap.grantOffer?.kind, .shell)
        await engine.submit("yes")
        XCTAssertTrue(output.allTexts.contains { $0.contains("run commands inside") && $0.hasPrefix("To confirm") })
        await engine.submit("confirm")
        XCTAssertEqual(changes.all, [.granted(path: root, shell: true)])
        await engine.submit("Build it")
        backend.emit(.permissionRequested(PermissionRequest(requestID: "S", toolName: "Bash", input: ["command": "swift build"])))
        backend.emit(.permissionRequested(PermissionRequest(requestID: "T", toolName: "Bash", input: ["command": "curl https://example.invalid"])))
        await settle()
        XCTAssertEqual(backend.responses.map(\.0), ["S"])
        snap = await engine.snapshot
        XCTAssertEqual(snap.pendingPermission?.request.requestID, "T", "a command that reaches the network still asks")
    }

    func testRemovingAGrantTakesEffectOnTheRunningSession() async {
        await engine.setFolderGrants([FolderGrant(path: root)])
        await engine.submit("Fix it")
        backend.emit(edit("A"))
        await settle()
        XCTAssertEqual(backend.responses.map(\.0), ["A"])
        await engine.setFolderGrants([])
        backend.emit(edit("B"))
        await settle()
        let snap = await engine.snapshot
        XCTAssertEqual(snap.pendingPermission?.request.requestID, "B")
    }

    // MARK: - Spoken answers to the offer (2026-10-25: hands-free PairVox in a room where people were talking)

    /// Plays the newest prompt to its end, then moves the clock past the echo window.
    func playLatestPrompt(_ clock: EngineApprovalTests.FakeClock) async {
        guard let prompt = output.queue.last(where: { $0.kind == .prompt }) else { return XCTFail("a prompt to play") }
        output.continuation.yield(.started(prompt.id))
        output.continuation.yield(.finished(prompt.id))
        await settle()
        clock.advance(1)
    }

    /// Speech the microphone heard: it starts and ends, then its words arrive.
    func say(_ text: String) async {
        await engine.userStartedSpeaking()
        await engine.userStoppedSpeaking()
        await engine.submit(text)
        await settle()
    }

    func withClock() async -> EngineApprovalTests.FakeClock {
        let clock = EngineApprovalTests.FakeClock()
        await engine.setClock { clock.now }
        return clock
    }

    func testByDefaultOnlyTheButtonsGrantAndASpokenNoStillDeclines() async {
        let clock = await withClock()
        await engine.offerFolderGrant()
        var snap = await engine.snapshot
        XCTAssertEqual(snap.grantOffer?.text.hasSuffix("without asking each time? Answer on screen, or say no."), true,
                       "the question does not invite a spoken yes: \(snap.grantOffer?.text ?? "")")
        await playLatestPrompt(clock)
        await say("yes")
        snap = await engine.snapshot
        XCTAssertEqual(snap.grantOffer?.stage, .asking, "a spoken yes does not even open the confirmation")
        XCTAssertTrue(output.allTexts.contains("Folder access needs a click. Please use the buttons on screen."))
        await engine.answerGrantOffer(yes: true)   // the first button
        await playLatestPrompt(clock)
        await say("confirm")
        await engine.submit("confirm")             // typed, too
        snap = await engine.snapshot
        XCTAssertEqual(snap.grantOffer?.stage, .confirming)
        XCTAssertTrue(changes.all.isEmpty)
        await engine.answerGrantOffer(yes: true)   // the second button
        XCTAssertEqual(changes.all, [.granted(path: root, shell: false)])

        await engine.setFolderGrants([])
        await engine.offerFolderGrant()
        await playLatestPrompt(clock)
        await say("no")
        snap = await engine.snapshot
        XCTAssertNil(snap.grantOffer)
        XCTAssertEqual(changes.all.last, .declined(path: root), "no by voice still works")
    }

    func testASpokenYesBegunBeforeTheOfferPlayedDoesNotCount() async {
        await engine.setSpokenHighRiskConfirmation(true)
        let clock = await withClock()
        await engine.offerFolderGrant()
        await say("yes")   // begun before the question started: a reply to something else
        var snap = await engine.snapshot
        XCTAssertEqual(snap.grantOffer?.stage, .asking)
        XCTAssertTrue(output.allTexts.contains("I heard that before I asked."))
        await playLatestPrompt(clock)
        await say("yes")
        snap = await engine.snapshot
        XCTAssertEqual(snap.grantOffer?.stage, .confirming, "said after the question played, it opens the confirmation")
        await say("confirm")   // the confirmation has not started playing yet
        snap = await engine.snapshot
        XCTAssertEqual(snap.grantOffer?.stage, .confirming)
        XCTAssertTrue(changes.all.isEmpty, "a confirm begun before the confirmation played grants nothing")
        await playLatestPrompt(clock)
        await say("confirm")
        XCTAssertEqual(changes.all, [.granted(path: root, shell: false)])
    }

    func testTheOffersOwnWordsHeardBackAreNotAnAnswer() async {
        await engine.setSpokenHighRiskConfirmation(true)
        let clock = await withClock()
        await engine.offerFolderGrant()
        guard let ask = output.queue.last(where: { $0.kind == .prompt }) else { return XCTFail("the question") }
        output.continuation.yield(.started(ask.id))
        await settle()
        await say("yes")   // "…Say yes or no." from the speakers, while it plays
        var snap = await engine.snapshot
        XCTAssertEqual(snap.grantOffer?.stage, .asking)
        XCTAssertTrue(output.allTexts.contains("That sounded like my own voice. If it was you, answer again."))
        clock.advance(1)
        await say("yes")
        snap = await engine.snapshot
        XCTAssertEqual(snap.grantOffer?.stage, .confirming)
        guard let confirm = output.queue.last(where: { $0.kind == .prompt }) else { return XCTFail("the confirmation") }
        output.continuation.yield(.started(confirm.id))
        await settle()
        await say("confirm to allow it")   // the confirmation's own tail
        await say("confirm")
        snap = await engine.snapshot
        XCTAssertEqual(snap.grantOffer?.stage, .confirming)
        XCTAssertTrue(changes.all.isEmpty, "PairVox's own voice grants nothing")
    }

    func testAnOfferLeftWaitingTakesNoSpokenAnswerButTheButtonsStillWork() async {
        await engine.setSpokenHighRiskConfirmation(true)
        let clock = await withClock()
        await engine.offerFolderGrant()
        var snap = await engine.snapshot
        XCTAssertEqual(snap.grantOffer?.askedAt, clock.now, "the question is stamped with the engine's clock")
        await playLatestPrompt(clock)
        clock.advance(Announcer.staleAfter + 1)
        await say("yes")
        snap = await engine.snapshot
        XCTAssertEqual(snap.grantOffer?.stage, .asking, "a question left waiting takes no stray yes from the room")
        XCTAssertTrue(output.allTexts.contains("That question has been waiting a while. Please use the buttons on screen."))
        await engine.answerGrantOffer(yes: true)
        await playLatestPrompt(clock)
        clock.advance(Announcer.staleAfter + 1)
        await say("confirm")
        snap = await engine.snapshot
        XCTAssertEqual(snap.grantOffer?.stage, .confirming)
        XCTAssertTrue(changes.all.isEmpty, "nor a stray confirm")
        await engine.answerGrantOffer(yes: true)
        XCTAssertEqual(changes.all, [.granted(path: root, shell: false)], "the buttons are not subject to the age limit")
    }

    func testAVoiceGrantAlsoAsksForTouchIDWhenThatIsOn() async {
        await engine.setSpokenHighRiskConfirmation(true)
        await engine.setSecondConfirmation { false }
        await engine.offerFolderGrant()
        await engine.submit("yes")
        await engine.submit("confirm")
        await settle()
        var snap = await engine.snapshot
        XCTAssertEqual(snap.grantOffer?.stage, .confirming)
        XCTAssertTrue(changes.all.isEmpty, "Touch ID was refused")
        XCTAssertTrue(output.allTexts.contains("Not confirmed. Nothing has changed."))
        await engine.setSecondConfirmation { true }
        await engine.submit("confirm")
        await settle()
        snap = await engine.snapshot
        XCTAssertNil(snap.grantOffer)
        XCTAssertEqual(changes.all, [.granted(path: root, shell: false)])
    }
}
