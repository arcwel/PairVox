// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PairVoxCore

/// Approval gates (owner, 2026-10-26): Manual is a tap or click, Auto is a yes, a read-back and a second yes, Skip is
/// one yes. Kinds of command and named commands choose the gate; high risk and unreadable commands stay Manual.
final class ApprovalGatePolicyTests: XCTestCase {
    let root = "/Users/dev/app"

    func bash(_ command: String, _ gates: ApprovalGates = ApprovalGates()) -> PermissionAssessment {
        PermissionPolicy(projectRoot: root, gates: gates).assess(PermissionRequest(requestID: "r", toolName: "Bash", input: ["command": .string(command)]))
    }

    func gates(_ rules: [(String, ApprovalGate)], _ categories: [CommandCategory: ApprovalGate] = [:]) -> ApprovalGates {
        var g = ApprovalGates(rules: rules.map { CommandGateRule(command: $0.0, gate: $0.1) })
        for (k, v) in categories { g.categories[k] = v }
        return g
    }

    func testByDefaultGhIsManualByChoiceAndOrdinaryCommandsTakeOneYes() {
        let gh = bash("gh pr list --state open")
        XCTAssertEqual(gh.gate, .manual)
        XCTAssertFalse(gh.voiceApprovable)
        XCTAssertFalse(gh.gateLocked, "the owner's choice, not a safety rule")
        XCTAssertEqual(ApprovalGates().rules.map(\.command), ["gh"], "gh is named in the list so it can be changed")
        let build = bash("swift build")
        XCTAssertEqual(build.gate, .skip)
        XCTAssertTrue(build.voiceApprovable)
        XCTAssertEqual(bash("curl https://example.invalid").gate, .manual, "network commands are Manual by default")
        XCTAssertEqual(bash("npm install left-pad").gate, .manual, "installs too")
    }

    func testANamedCommandOverridesItsKindAndTheLongestMatchWins() {
        let g = gates([("gh", .manual), ("gh pr list", .skip), ("npm test", .auto)])
        XCTAssertEqual(bash("gh pr list --state open", g).gate, .skip)
        XCTAssertTrue(bash("gh pr list --state open", g).voiceApprovable)
        XCTAssertEqual(bash("gh pr view 7", g).gate, .manual, "only that subcommand was opened up")
        XCTAssertEqual(bash("/opt/homebrew/bin/gh pr list", g).gate, .skip, "the program is matched without its folder")
        XCTAssertEqual(bash("npm test", g).gate, .auto)
        XCTAssertEqual(bash("npm run build", g).gate, .skip, "the kind's gate when no rule matches")
    }

    func testAChainedCommandTakesItsStrictestStep() {
        let g = gates([("gh", .auto)])
        XCTAssertEqual(bash("swift build && gh pr list", g).gate, .auto)
        XCTAssertEqual(bash("cd \"\(root)\" && gh pr list --state open 2>&1 | head -20; git status -sb | head -5", g).gate, .auto)
        XCTAssertEqual(bash("ls && curl https://example.invalid", g).gate, .manual, "curl is still network, Manual")
    }

    func testHighRiskAndUnreadableCommandsStayManualWhateverTheRules() {
        let g = gates([("git push", .skip), ("rm", .skip), ("gh", .skip)], [.network: .skip, .otherCommands: .skip])
        for c in ["git push origin main", "rm -rf build", "gh pr merge 7", "gh pr list > open.txt", "echo $(gh pr list)"] {
            let a = bash(c, g)
            XCTAssertEqual(a.gate, .manual, c)
            XCTAssertFalse(a.voiceApprovable, c)
            XCTAssertTrue(a.gateLocked, "\(c): Manual for safety")
        }
    }

    func testEditsFollowTheirOwnGate() {
        var g = ApprovalGates()
        g.categories[.fileEdits] = .manual
        let edit = PermissionPolicy(projectRoot: root, gates: g).assess(PermissionRequest(requestID: "r", toolName: "Edit", input: ["file_path": .string(root + "/a.swift")]))
        XCTAssertEqual(edit.gate, .manual)
        XCTAssertFalse(edit.gateLocked)
        XCTAssertTrue(edit.reasons.contains { $0.contains("Settings, Approval gates") }, "\(edit.reasons)")
        g.categories[.fileEdits] = .auto
        XCTAssertEqual(PermissionPolicy(projectRoot: root, gates: g).assess(PermissionRequest(requestID: "r", toolName: "Edit", input: ["file_path": .string(root + "/a.swift")])).gate, .auto)
        let outside = PermissionPolicy(projectRoot: root, gates: gates([], [.fileEdits: .skip])).assess(PermissionRequest(requestID: "r", toolName: "Edit", input: ["file_path": "/etc/hosts"]))
        XCTAssertEqual(outside.gate, .manual, "outside the project is high risk")
    }

    // Security review 2026-10-26: a Manual rule matched only in command position, and only in the same case.
    func testANamedCommandAnywhereInAStepMakesItStricterButLoosensOnlyWhereItRuns() {
        let g = gates([("gh", .manual), ("aws", .manual), ("make deploy", .manual)], [.network: .skip, .otherCommands: .skip])
        for c in ["if true; then gh pr list; fi", "for i in 1; do make deploy; done", "! gh pr list", "sh -c 'gh pr list'",
                  "bash -c 'make deploy'", "eval gh pr list", "find . -exec aws s3 ls {} +", "watch gh pr list",
                  "arch -arm64 gh pr list", "GH pr list", "/opt/homebrew/bin/GH pr list"] {
            XCTAssertEqual(bash(c, g).gate, .manual, c)
        }
        // A rule that loosens counts only where its program runs: "npm test" on another machine is still network.
        let loose = gates([("npm test", .skip)])
        XCTAssertEqual(bash("npm test", loose).gate, .skip)
        XCTAssertEqual(bash("ssh build-box npm test", loose).gate, .manual)
        XCTAssertEqual(bash("CURL https://example.invalid").gate, .manual, "the Mac's disk runs CURL as curl")
        XCTAssertEqual(bash("echo gh", g).gate, .manual, "a named command anywhere errs toward asking")
    }

    func testOfTwoRulesAsLongTheStricterWins() {
        XCTAssertEqual(bash("npm test", gates([("npm test", .skip), ("npm test", .manual)])).gate, .manual)
        XCTAssertEqual(bash("npm test", gates([("NPM test", .auto), ("npm test", .skip)])).gate, .auto, "case does not matter")
    }

    func testAFolderGrantDoesNotCoverWhatTheOwnerSetToManual() {
        let grants = [FolderGrant(path: root, allowShell: true)]
        func assess(_ r: PermissionRequest, _ g: ApprovalGates) -> PermissionAssessment {
            PermissionPolicy(projectRoot: root, grants: grants, gates: g).assess(r)
        }
        let edit = PermissionRequest(requestID: "r", toolName: "Edit", input: ["file_path": .string(root + "/a.swift")])
        XCTAssertTrue(assess(edit, ApprovalGates()).coveredByFolderGrant)
        XCTAssertFalse(assess(edit, gates([], [.fileEdits: .manual])).coveredByFolderGrant, "edits set to Manual take a click")
        let build = PermissionRequest(requestID: "r", toolName: "Bash", input: ["command": "make deploy"])
        XCTAssertTrue(assess(build, ApprovalGates()).coveredByFolderGrant)
        XCTAssertFalse(assess(build, gates([("make deploy", .manual)])).coveredByFolderGrant)
        XCTAssertTrue(assess(build, gates([("make deploy", .auto)])).coveredByFolderGrant, "the grant is standing consent short of Manual")
    }

    // 2026-10-26: "--state open" read as the open command, and "2>&1" counted as extra steps.
    func testTheWordOpenAsAnArgumentDoesNotOpenAnything() {
        XCTAssertFalse(BashRisk.classify("gh pr list --state open 2>&1 | head -20").reasons.contains("Opens a file or URL with another app."))
        XCTAssertTrue(BashRisk.classify("open Package.swift").reasons.contains("Opens a file or URL with another app."))
        XCTAssertTrue(BashRisk.classify("nohup open Package.swift").reasons.contains("Opens a file or URL with another app."))
        XCTAssertTrue(BashRisk.classify("ls; open .").reasons.contains("Opens a file or URL with another app."))
    }

    func testGatesSurviveOldAndForeignSettingsFiles() throws {
        let old = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"handsFree": true}"#.utf8))
        XCTAssertEqual(old.approvalGates, ApprovalGates())
        let foreign = try JSONDecoder().decode(ApprovalGates.self, from: Data(#"{"categories": {"network": "skip", "teleport": "skip"}, "rules": [{"command": "npm test", "gate": "auto"}, {"command": "  ", "gate": "skip"}, {"command": "make", "gate": "warp"}]}"#.utf8))
        XCTAssertEqual(foreign.gate(for: .network), .skip)
        XCTAssertEqual(foreign.gate(for: .install), .manual, "a category the file does not name keeps its default")
        XCTAssertEqual(foreign.rules.map(\.command), ["npm test", "make"], "an empty rule is dropped")
        XCTAssertEqual(foreign.rules.last?.gate, .manual, "an unreadable gate errs toward asking")
        let oneBad = try JSONDecoder().decode(ApprovalGates.self, from: Data(#"{"categories": {"network": "skip", "install": "warp"}}"#.utf8))
        XCTAssertEqual(oneBad.gate(for: .network), .skip, "one bad value does not reset the others")
        XCTAssertEqual(oneBad.gate(for: .install), .manual)
        XCTAssertTrue(CommandCategory.allCases.allSatisfy { ApprovalGates.strictest.gate(for: $0) == .manual })
        XCTAssertTrue(ApprovalGates.strictest.rules.isEmpty, "a file others could write falls back to asking for everything")
        let round = try JSONDecoder().decode(ApprovalGates.self, from: JSONEncoder().encode(foreign))
        XCTAssertEqual(round, foreign)
    }
}

final class ApprovalGateEngineTests: XCTestCase {
    var backend: FakeBackend!
    var output: FakeOutput!
    var engine: ConversationEngine!

    func start(_ gates: ApprovalGates, highRiskPhrase: Bool = false) async {
        backend = FakeBackend(); output = FakeOutput()
        let b = backend!
        engine = ConversationEngine(configuration: EngineConfiguration(projectRoot: "/Users/dev/app", speechMode: .skipCode,
                                                                       spokenHighRiskConfirmation: highRiskPhrase,
                                                                       approvalGates: gates, acknowledgementDelay: 0.15),
                                    output: output, backendFactory: { _ in b })
        await engine.start()
        await engine.submit("Do it")
    }

    override func tearDown() async throws { await engine?.shutdown() }

    func settle(_ ms: UInt64 = 60) async { try? await Task.sleep(nanoseconds: ms * 1_000_000) }

    func run(_ id: String, _ command: String) -> SessionEvent {
        .permissionRequested(PermissionRequest(requestID: id, toolName: "Bash", input: ["command": .string(command)]))
    }

    func play(_ u: Utterance?) async {
        guard let u else { return XCTFail("a prompt to play") }
        output.continuation.yield(.started(u.id))
        output.continuation.yield(.finished(u.id))
        await settle(700)   // past the echo window
    }

    func say(_ text: String) async {
        await engine.userStartedSpeaking()
        await engine.userStoppedSpeaking()
        await engine.submit(text)
        await settle()
    }

    func testAutoReadsBackWhatWillHappenAndTheSecondYesApproves() async {
        await start(ApprovalGates(rules: [CommandGateRule(command: "swift build", gate: .auto)]))
        backend.emit(run("A", "swift build"))
        await settle()
        await play(output.queue.last { $0.kind == .prompt })
        await say("yes")
        XCTAssertTrue(backend.responses.isEmpty, "one yes is not enough")
        var snap = await engine.snapshot
        XCTAssertEqual(snap.pendingPermission?.awaitingSecondYes, true)
        let readBack = output.queue.last { $0.kind == .prompt }
        XCTAssertEqual(readBack?.text, "Before it runs: Claude wants to run swift build. Answer a second time to proceed.")
        XCTAssertNil(VoiceCommand.parse(readBack?.text ?? "", context: .init(awaitingPermission: true)), "heard back, it answers nothing")
        await say("yes")
        XCTAssertTrue(backend.responses.isEmpty, "a yes begun before the read-back played does not count")
        await play(output.queue.last { $0.kind == .prompt })
        await say("yes")
        guard case .allow? = backend.responses.first?.1 else { return XCTFail("the second yes approves") }
        snap = await engine.snapshot
        XCTAssertNil(snap.pendingPermission)
    }

    // Security review 2026-10-26: "to confirm" and "go ahead" in the read-back were answers. No run of its words may be.
    func testNoRunOfWordsInTheReadBackOrNoticesIsAnAnswer() {
        let p = PendingPermission(request: PermissionRequest(requestID: "r", toolName: "Bash", input: ["command": "swift build"]),
                                  assessment: PermissionPolicy(projectRoot: "/Users/dev/app").assess(PermissionRequest(requestID: "r", toolName: "Bash", input: ["command": "swift build"])))
        let contexts = [VoiceCommand.Context(awaitingPermission: true), VoiceCommand.Context(awaitingPermission: true, awaitingHighRiskConfirmation: true)]
        for text in [ConversationEngine.secondYesPrompt(p), "Let me finish first.", "That one is set to Manual. Please tap or click to continue.",
                     "That one takes two answers. Answer on the phone, or tap."] {
            let w = VoiceCommand.normalize(text)
            for i in w.indices { for j in i..<w.count {
                let run = w[i...j].joined(separator: " ")
                for c in contexts { XCTAssertNil(VoiceCommand.parse(run, context: c), "\(text): \(run)") }
                XCTAssertTrue([.notAnAnswer, .unclear].contains(VoiceCommand.spokenAnswer(run)), "\(text): \(run)")
            } }
        }
    }

    func testAYesSaidOverTheReadBackOrAMinuteLaterIsNotTheSecond() async {
        await start(ApprovalGates(rules: [CommandGateRule(command: "swift build", gate: .auto)]))
        backend.emit(run("A", "swift build"))
        await settle()
        await play(output.queue.last { $0.kind == .prompt })
        await say("yes")
        guard let readBack = output.queue.last(where: { $0.kind == .prompt }) else { return XCTFail("read-back") }
        output.continuation.yield(.started(readBack.id))
        await settle()
        await say("yes")   // over the read-back: the person had not heard what it does
        XCTAssertTrue(backend.responses.isEmpty)
        XCTAssertTrue(output.allTexts.contains("Let me finish first."))
        let clock = EngineApprovalTests.FakeClock(Date())
        await engine.setClock { clock.now }
        await play(output.queue.last { $0.kind == .prompt })
        clock.advance(ConversationEngine.secondYesWindow + 1)
        await say("yes")
        XCTAssertTrue(backend.responses.isEmpty, "a minute later the first yes has lapsed")
        let snap = await engine.snapshot
        XCTAssertEqual(snap.pendingPermission?.awaitingSecondYes, true, "asked again")
    }

    func testTheSummaryIsNotReadAfterTheReadBack() async {
        backend = FakeBackend(); output = FakeOutput()
        let b = backend!
        let advisor = FakeAdvisor()
        advisor.delayNanoseconds = 400_000_000
        engine = ConversationEngine(configuration: EngineConfiguration(projectRoot: "/Users/dev/app", speechMode: .skipCode,
                                                                       approvalGates: ApprovalGates(rules: [CommandGateRule(command: "swift build", gate: .auto)]),
                                                                       acknowledgementDelay: 0.15),
                                    output: output, advisor: advisor, backendFactory: { _ in b })
        await engine.start()
        await engine.submit("Do it", typed: true)
        backend.emit(run("A", "swift build"))
        await settle()
        await engine.submit("yes", typed: true)
        await settle(600)   // the summary arrives after the first yes
        let prompts = output.queue.filter { $0.kind == .prompt }.map(\.text)
        XCTAssertEqual(prompts.last?.hasPrefix("Before it runs:"), true, "\(prompts)")
        XCTAssertFalse(prompts.contains { $0.hasSuffix("Allow?") && $0.contains("tests") })
    }

    func testAClickNeedsNoSecondYes() async {
        await start(ApprovalGates(rules: [CommandGateRule(command: "swift build", gate: .auto)]))
        backend.emit(run("A", "swift build"))
        await settle()
        await engine.approvePending(requestID: "A")
        XCTAssertEqual(backend.responses.map(\.0), ["A"])
    }

    func testManualByChoiceTakesNoSpokenAnswerNotEvenTheHighRiskPhrase() async {
        await start(ApprovalGates(), highRiskPhrase: true)
        backend.emit(run("A", "gh pr list"))
        await settle()
        await play(output.queue.last { $0.kind == .prompt })
        await say("yes")
        await say("confirm high risk")
        XCTAssertTrue(backend.responses.isEmpty)
        let snap = await engine.snapshot
        XCTAssertEqual(snap.ignoredAnswer?.reason, .manualGate)
        XCTAssertTrue(output.allTexts.contains("That one is set to Manual. Please tap or click to continue."))
        await engine.approvePending(requestID: "A")
        XCTAssertEqual(backend.responses.map(\.0), ["A"], "a click works")
    }

    func testAllowAllLeavesAutoRequestsForTheirOwnTwoAnswers() async {
        await start(ApprovalGates(rules: [CommandGateRule(command: "swift test", gate: .auto)]))
        backend.emit(run("A", "swift build"))
        backend.emit(run("B", "swift test"))
        backend.emit(run("C", "make"))
        await settle()
        await play(output.queue.last { $0.kind == .prompt })
        await say("allow all")
        await play(output.queue.last { $0.kind == .prompt })
        await say("allow all")
        XCTAssertEqual(Set(backend.responses.map(\.0)), ["A", "C"])
        let snap = await engine.snapshot
        XCTAssertEqual(snap.pendingPermission?.request.requestID, "B")
    }

    func testChangingTheGatesRatesTheWaitingRequestAgain() async {
        await start(ApprovalGates(rules: [CommandGateRule(command: "swift build", gate: .auto)]))
        backend.emit(run("A", "swift build"))
        await settle()
        await play(output.queue.last { $0.kind == .prompt })
        await say("yes")
        await engine.setApprovalGates(ApprovalGates(rules: [CommandGateRule(command: "swift build", gate: .manual)]))
        var snap = await engine.snapshot
        XCTAssertEqual(snap.pendingPermission?.assessment.gate, .manual)
        XCTAssertEqual(snap.pendingPermission?.awaitingSecondYes, false, "a half-given confirmation starts over")
        await play(output.queue.last { $0.kind == .prompt })
        await say("yes")
        XCTAssertTrue(backend.responses.isEmpty, "the stricter gate holds")
        await engine.setApprovalGates(ApprovalGates(rules: [CommandGateRule(command: "swift build", gate: .skip)]))
        snap = await engine.snapshot
        XCTAssertEqual(snap.pendingPermission?.assessment.gate, .skip)
    }
}

final class ApprovalGateAnnouncerTests: XCTestCase {
    /// The other project's request, rated with these gates, as the inbox holds it.
    func item(_ gates: ApprovalGates) -> InboxItem {
        let request = PermissionRequest(requestID: "r", toolName: "Bash", input: ["command": "gh pr list"])
        let pending = PendingPermission(request: request, assessment: PermissionPolicy(projectRoot: "/Users/dev/web", gates: gates).assess(request))
        var inbox = ApprovalInbox()
        inbox.sync(projectID: "p", name: "web", pending: [pending], now: Date())
        return inbox.items[0]
    }

    func resolve(_ gates: ApprovalGates, _ reply: AnnouncementReply) -> AnnouncementDecision {
        var settings = AnnouncementSettings()
        settings.voiceHighRisk = true
        let i = item(gates)
        var inbox = ApprovalInbox()
        let request = PermissionRequest(requestID: "r", toolName: "Bash", input: ["command": "gh pr list"])
        inbox.sync(projectID: "p", name: "web", pending: [PendingPermission(request: request, assessment: PermissionPolicy(projectRoot: "/Users/dev/web", gates: gates).assess(request))], now: Date())
        return AnnouncementRouter.resolve(reply, announcement: Announcement(item: i, text: "", announcedAt: Date(), expiresAt: Date().addingTimeInterval(60)),
                                         inbox: inbox, settings: settings, now: Date())
    }

    func testAnAnnouncementTakesOneApproveOnlyForASkipRequest() {
        let auto = ApprovalGates(rules: [CommandGateRule(command: "gh", gate: .auto)])
        XCTAssertEqual(resolve(auto, .approve), .say("That one takes two answers. Use the card, or say switch."))
        XCTAssertEqual(resolve(ApprovalGates(), .approve), .say("That one is set to Manual. Use the card, or say switch."))
        XCTAssertEqual(resolve(ApprovalGates(), .confirmHighRisk(project: "web")), .say("That one needs a click. Use the card, or say switch."),
                       "the high-risk phrase does not open up the owner's Manual")
        guard case .approve = resolve(ApprovalGates(rules: [CommandGateRule(command: "gh", gate: .skip)]), .approve) else {
            return XCTFail("a Skip request takes one approve")
        }
        var settings = AnnouncementSettings()
        settings.voiceHighRisk = true
        XCTAssertTrue(Announcer.text(for: item(auto), waiting: 1, settings: settings).hasSuffix("That one takes two answers. Say tell me more, switch, or use the card."))
        XCTAssertTrue(Announcer.text(for: item(ApprovalGates()), waiting: 1, settings: settings).hasSuffix("That one is set to Manual. Say switch, or use the card."))
    }
}
