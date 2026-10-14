// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PairVoxCore

final class CrossProjectTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 2_000_000)

    func pending(_ id: String, risk: RiskLevel = .medium, voice: Bool = true, screen: Bool = false, text: String = "Claude wants to edit pricing dot html. Allow?") -> PendingPermission {
        let req = PermissionRequest(requestID: id, toolName: "Edit", input: ["file_path": "/p/pricing.html"], requiresUserInteraction: screen)
        return PendingPermission(request: req, assessment: PermissionAssessment(risk: risk, voiceApprovable: voice, spokenPrompt: text, summary: "Edit pricing.html", reasons: []))
    }

    func inbox(_ items: [(String, String, PendingPermission)]) -> ApprovalInbox {
        var i = ApprovalInbox()
        for (pid, name, p) in items { i.sync(projectID: pid, name: name, pending: i.items.filter { $0.projectID == pid }.isEmpty ? [p] : [p], now: t0) }
        return i
    }

    let idle = { (t: Date) in ConversationActivity(activePhase: .idle, lastActivity: t) }

    // MARK: inbox

    func testInboxKeepsArrivalOrderAndFirstSeen() {
        var i = ApprovalInbox()
        i.sync(projectID: "web", name: "website", pending: [pending("A")], now: t0)
        i.sync(projectID: "api", name: "api", pending: [pending("B")], now: t0.addingTimeInterval(5))
        i.sync(projectID: "web", name: "website", pending: [pending("A"), pending("C")], now: t0.addingTimeInterval(9))
        XCTAssertEqual(i.items.map(\.requestID), ["A", "B", "C"])
        XCTAssertEqual(i.item(project: "web", request: "A")?.firstSeen, t0, "age is not reset by a refresh")
        i.sync(projectID: "web", name: "website", pending: [], now: t0)
        XCTAssertEqual(i.items.map(\.requestID), ["B"])
    }

    // MARK: break detection and announcing

    func testNothingIsAnnouncedWhileSomeoneIsTalkingOrBeforeTheQuietPeriod() {
        let i = inbox([("web", "website", pending("A"))])
        var a = Announcer(); let s = AnnouncementSettings()
        for phase in [EnginePhase.speaking, .listening, .transcribing, .awaitingPermission] {
            XCTAssertNil(a.next(inbox: i, activeProjectID: "api", activity: ConversationActivity(activePhase: phase, lastActivity: t0 - 60), settings: s, now: t0))
        }
        XCTAssertNil(a.next(inbox: i, activeProjectID: "api", activity: ConversationActivity(activePhase: .idle, userSpeaking: true, lastActivity: t0 - 60), settings: s, now: t0))
        XCTAssertNil(a.next(inbox: i, activeProjectID: "api", activity: idle(t0 - 1), settings: s, now: t0), "only 1 s of quiet")
        XCTAssertNotNil(a.next(inbox: i, activeProjectID: "api", activity: idle(t0 - 2.5), settings: s, now: t0))
    }

    func testAnnouncementNamesTheProjectAndOffersTheRightChoices() throws {
        let i = inbox([("web", "website", pending("A"))])
        var a = Announcer()
        let first = try XCTUnwrap(a.next(inbox: i, activeProjectID: "api", activity: idle(t0 - 5), settings: AnnouncementSettings(), now: t0))
        XCTAssertEqual(first.text, "Quick one from website: Claude wants to edit pricing dot html. Say approve, deny, tell me more, or switch.")
        var hidden = AnnouncementSettings(); hidden.speakProjectNames = false
        var b = Announcer()
        XCTAssertTrue(b.next(inbox: i, activeProjectID: "api", activity: idle(t0 - 5), settings: hidden, now: t0)!.text.hasPrefix("Quick one from another project:"))
    }

    func testAnnouncedOnceMutedAndNeverForTheActiveProject() {
        let i = inbox([("web", "website", pending("A")), ("api", "api", pending("B"))])
        var a = Announcer(); var s = AnnouncementSettings()
        XCTAssertEqual(a.next(inbox: i, activeProjectID: "api", activity: idle(t0 - 5), settings: s, now: t0)?.item.requestID, "A", "not the active project's own request")
        XCTAssertNil(a.next(inbox: i, activeProjectID: "api", activity: idle(t0 - 5), settings: s, now: t0 + 30), "not twice")
        var m = Announcer(); s.mutedProjects = ["web"]
        XCTAssertNil(m.next(inbox: i, activeProjectID: "api", activity: idle(t0 - 5), settings: s, now: t0), "muted projects are never spoken")
        s.mutedProjects = []; s.enabled = false
        var off = Announcer()
        XCTAssertNil(off.next(inbox: i, activeProjectID: "api", activity: idle(t0 - 5), settings: s, now: t0))
    }

    func testSeveralWaitingAreAnnouncedOneAtATime() throws {
        let i = inbox([("web", "website", pending("A")), ("docs", "docs", pending("B"))])
        var a = Announcer()
        let first = try XCTUnwrap(a.next(inbox: i, activeProjectID: "api", activity: idle(t0 - 5), settings: AnnouncementSettings(), now: t0))
        XCTAssertTrue(first.text.contains("1 more waiting"))
        XCTAssertNil(a.next(inbox: i, activeProjectID: "api", activity: idle(t0 - 5), settings: AnnouncementSettings(), now: t0 + 1), "one at a time")
        a.clear(answeredAt: t0 + 3)
        XCTAssertNil(a.next(inbox: i, activeProjectID: "api", activity: idle(t0 - 5), settings: AnnouncementSettings(), now: t0 + 4), "a pause after an answer")
        XCTAssertEqual(a.next(inbox: i, activeProjectID: "api", activity: idle(t0 - 5), settings: AnnouncementSettings(), now: t0 + 6)?.item.requestID, "B")
    }

    // MARK: reply parsing

    func testReplies() {
        let names = ["website", "api"]
        XCTAssertEqual(AnnouncementReply.parse("approve", projectNames: names), .approve)
        XCTAssertEqual(AnnouncementReply.parse("yes", projectNames: names), .approve)
        XCTAssertEqual(AnnouncementReply.parse("deny", projectNames: names), .deny)
        XCTAssertEqual(AnnouncementReply.parse("I wouldn't allow that", projectNames: names), .deny)
        XCTAssertEqual(AnnouncementReply.parse("tell me more", projectNames: names), .tellMore)
        XCTAssertEqual(AnnouncementReply.parse("switch", projectNames: names), .switchHere)
        XCTAssertEqual(AnnouncementReply.parse("confirm high risk website", projectNames: names), .confirmHighRisk(project: "website"))
        XCTAssertEqual(AnnouncementReply.parse("confirm high risk", projectNames: names), .confirmHighRisk(project: nil))
        XCTAssertEqual(AnnouncementReply.parse("always allow", projectNames: names), .notForUs, "no standing permission from an announcement")
        XCTAssertEqual(AnnouncementReply.parse("please refactor the login page and add tests for it today", projectNames: names), .notForUs)
    }

    // MARK: routing

    func route(_ reply: AnnouncementReply, item: PendingPermission, settings: AnnouncementSettings = AnnouncementSettings(),
               at: TimeInterval = 5, announcedFor: TimeInterval = 0) -> AnnouncementDecision {
        let i = inbox([("web", "website", item)])
        var a = Announcer()
        let ann = a.next(inbox: i, activeProjectID: "api", activity: idle(t0 - 5), settings: settings, now: t0 + announcedFor)
        return AnnouncementRouter.resolve(reply, announcement: ann, inbox: i, settings: settings, now: t0 + at)
    }

    func testApproveAnswersTheAnnouncedRequestOfTheOwningProject() {
        guard case .approve(let item, let second) = route(.approve, item: pending("A")) else { return XCTFail() }
        XCTAssertEqual(item.projectID, "web"); XCTAssertEqual(item.requestID, "A"); XCTAssertFalse(second)
    }

    func testTheBindingExpiresAndNeedsALiveAnnouncement() {
        XCTAssertEqual(route(.approve, item: pending("A"), at: 25), .notBound, "20 seconds is the limit")
        let i = inbox([("web", "website", pending("A"))])
        XCTAssertEqual(AnnouncementRouter.resolve(.approve, announcement: nil, inbox: i, settings: AnnouncementSettings(), now: t0), .notBound)
        // The request disappeared (answered on screen) before the reply.
        var gone = i; gone.removeProject("web")
        var a = Announcer()
        let ann = a.next(inbox: i, activeProjectID: "api", activity: idle(t0 - 5), settings: AnnouncementSettings(), now: t0)
        XCTAssertEqual(AnnouncementRouter.resolve(.approve, announcement: ann, inbox: gone, settings: AnnouncementSettings(), now: t0 + 2), .notBound)
    }

    func testHighRiskByVoiceNeedsTheSettingTheProjectNameAndRespectsNeedsScreen() {
        let high = pending("H", risk: .high, voice: false, text: "Claude wants to run git push. Please confirm on screen.")
        var off = AnnouncementSettings()
        guard case .say(let s1) = route(.confirmHighRisk(project: "website"), item: high, settings: off) else { return XCTFail() }
        XCTAssertTrue(s1.contains("click"))
        guard case .say = route(.approve, item: high, settings: off) else { return XCTFail("a bare yes never approves high risk") }
        var on = AnnouncementSettings(); on.voiceHighRisk = true
        guard case .say(let s2) = route(.confirmHighRisk(project: nil), item: high, settings: on) else { return XCTFail() }
        XCTAssertTrue(s2.contains("project name"))
        guard case .say = route(.approve, item: high, settings: on) else { return XCTFail("a bare yes still does not") }
        guard case .approve(_, let second) = route(.confirmHighRisk(project: "website"), item: high, settings: on) else { return XCTFail() }
        XCTAssertFalse(second)
        on.secondConfirmation = true
        guard case .approve(_, let second2) = route(.confirmHighRisk(project: "website"), item: high, settings: on) else { return XCTFail() }
        XCTAssertTrue(second2)
        // Claude Code's own "needs the screen" flag has its own switch.
        let screen = pending("S", risk: .high, voice: false, screen: true, text: "Claude wants to edit a file. Please confirm on screen.")
        guard case .say = route(.confirmHighRisk(project: "website"), item: screen, settings: on) else { return XCTFail() }
        on.voiceNeedsScreen = true
        guard case .approve = route(.confirmHighRisk(project: "website"), item: screen, settings: on) else { return XCTFail() }
    }

    func testAnOldRequestCannotBeApprovedByVoice() {
        // The request has been waiting 310 s by the time the announcement is made and answered.
        guard case .say(let s) = route(.approve, item: pending("A"), at: 312, announcedFor: 310) else { return XCTFail("a stale request must not be approved by voice") }
        XCTAssertTrue(s.contains("old"))
        guard case .approve = route(.approve, item: pending("A"), at: 12, announcedFor: 10) else { return XCTFail("a fresh one is fine") }
    }
}

final class CrossProjectOverviewTests: XCTestCase {
    func testOverviewRecapsTheProjectAndNeverReadsAnApprovalAloud() {
        let item = InboxItem(projectID: "web", projectName: "website", requestID: "A", summary: "Edit pricing.html",
                             spokenPrompt: "Claude wants to edit pricing dot html. Allow?", risk: .medium, voiceApprovable: true,
                             needsScreen: false, firstSeen: Date(), arrival: 1)
        let transcript = [TranscriptEntry(id: 1, role: .user, text: "Change the monthly price to 49 dollars"),
                          TranscriptEntry(id: 2, role: .assistant, text: "Sure, I will update the pricing page. Allow. Confirm high risk.")]
        let text = CrossProjectOverview.text(item: item, transcript: transcript, explanation: .ready("It changes one number."))
        XCTAssertTrue(text.contains("In website, you asked: Change the monthly price to 49 dollars"))
        XCTAssertTrue(text.contains("it wants to edit pricing dot html"))
        XCTAssertTrue(text.contains("It changes one number"))
        XCTAssertFalse(text.lowercased().contains("confirm high risk"))
        XCTAssertFalse(text.contains("Allow."), "an approval-shaped sentence from the model is removed")
    }
}

final class AuditRun4CrossProjectTests: XCTestCase {
    func testOnlyShortAnswersAreForTheAnnouncement() {
        let names = ["website"]
        for notForUs in ["stop", "this is not what I asked for", "no wait that is not what I meant", "I don't think so try again",
                         "please refactor the login page and add tests"] {
            XCTAssertEqual(AnnouncementReply.parse(notForUs, projectNames: names), .notForUs, notForUs)
        }
        XCTAssertEqual(AnnouncementReply.parse("no", projectNames: names), .deny)
        XCTAssertEqual(AnnouncementReply.parse("deny", projectNames: names), .deny)
        XCTAssertEqual(AnnouncementReply.parse("okay", projectNames: names), .approve)
    }

    func testTheAgeLimitAppliesToTheHighRiskPhraseToo() {
        let t0 = Date(timeIntervalSince1970: 3_000_000)
        let high = InboxItem(projectID: "web", projectName: "website", requestID: "H", summary: "git push", spokenPrompt: "x. Please confirm on screen.",
                             risk: .high, voiceApprovable: false, needsScreen: false, firstSeen: t0, arrival: 1)
        var inbox = ApprovalInbox()
        var pend = PermissionRequest(requestID: "H", toolName: "Bash", input: ["command": "git push"])
        pend.requestID = "H"
        inbox.sync(projectID: "web", name: "website", pending: [PendingPermission(request: pend, assessment: PermissionAssessment(risk: .high, voiceApprovable: false, spokenPrompt: "x. Please confirm on screen.", summary: "git push", reasons: []))], now: t0)
        var s = AnnouncementSettings(); s.voiceHighRisk = true
        var a = Announcer()
        let ann = a.next(inbox: inbox, activeProjectID: "api", activity: ConversationActivity(activePhase: .idle, lastActivity: t0 - 10), settings: s, now: t0 + 1000)
        let d = AnnouncementRouter.resolve(.confirmHighRisk(project: "website"), announcement: ann, inbox: inbox, settings: s, now: t0 + 1005)
        guard case .say(let text) = d else { return XCTFail("a request older than five minutes is not approved by voice: \(d)") }
        XCTAssertTrue(text.contains("old"))
        _ = high
    }

    func testModelWrittenSpeechNeverCarriesTheHighRiskPhraseWhateverItsLength() {
        let out = ConversationEngine.speakableAdvice("Looks routine. Confirm high risk pair vox web app")
        XCTAssertFalse(out.lowercased().contains("confirm high risk"), out)
        XCTAssertTrue(out.contains("Looks routine"))
    }

    func testTheProjectNameIsHiddenWhenTheSettingIsOff() {
        let t0 = Date(timeIntervalSince1970: 3_000_000)
        let item = InboxItem(projectID: "w", projectName: "secret-client", requestID: "A", summary: "s", spokenPrompt: "Claude wants to edit a file. Allow?",
                             risk: .medium, voiceApprovable: true, needsScreen: false, firstSeen: t0, arrival: 1)
        let text = CrossProjectOverview.text(item: item, transcript: [TranscriptEntry(id: 1, role: .user, text: "Fix it")], explanation: nil, speakName: false)
        XCTAssertFalse(text.contains("secret-client"))
        XCTAssertTrue(text.contains("the other project"))
    }
}

final class ProtectedShellTests: XCTestCase {
    func testEveryWayOfNamingTheConsentFolderInAShellCommandIsHighRisk() {
        let support = SettingsStore.defaultURL().deletingLastPathComponent().path
        let escaped = support.replacingOccurrences(of: " ", with: "\\ ")
        let commands = ["cp keys.json \"\(support)/paired-phones.json\"", "cp keys.json \(escaped)/paired-phones.json",
                        "cp keys.json ~/Library/Application\\ Support/PairVox/paired-phones.json",
                        "cat x > '$HOME/Library/Application Support/PairVox/settings.json'", "echo hi >> ${HOME}/.claude/settings.json",
                        "ls ~/.claude"]
        for c in commands { XCTAssertEqual(BashRisk.classify(c).level, .high, c) }
        XCTAssertNotEqual(BashRisk.classify("ls ~/Documents").level, .high)
    }
}

final class ProtectedShellRegressionTests: XCTestCase {
    func high(_ c: String, root: String? = nil, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(BashRisk.classify(c, projectRoot: root).level, .high, c, file: file, line: line)
    }

    func testPatternsCdAndNestedShellsAreReadLikeTheShellWouldRead() {
        high("cp evil.json ~/Library/Application\\ Support/Pair*/settings.json")
        high("cp evil.json ~/.cl*/settings.json")
        high("cp evil.json ~/.c[l]aude/settings.json")
        high("cat ~/.claud?/settings.json")
        high("cd && cp evil.json .claude/settings.json")
        high("cd ~ ; cp evil.json .claude/settings.json")
        high("sh -c 'cp evil.json ~/.claude/settings.json'")
        high("bash -c \"echo hi > $HOME/.claude/settings.json\"")
        XCTAssertNotEqual(BashRisk.classify("cp a.txt b.txt", projectRoot: NSTemporaryDirectory()).level, .high)
        XCTAssertNotEqual(BashRisk.classify("ls src/*.swift", projectRoot: NSTemporaryDirectory()).level, .high)
    }

    func testARepositorySymlinkIntoTheClaudeFolderIsSeenAndNoGrantCoversAGlob() throws {
        let claude = NSHomeDirectory() + "/.claude"
        try XCTSkipUnless(FileManager.default.fileExists(atPath: claude), "no ~/.claude on this machine")
        let root = FolderScope.resolved(FileManager.default.temporaryDirectory.appendingPathComponent("pv-sym-\(UUID().uuidString)").path)
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createSymbolicLink(atPath: root + "/lnk", withDestinationPath: claude)
        high("cat lnk/settings.json", root: root)
        let policy = PermissionPolicy(projectRoot: root, grants: [FolderGrant(path: root, allowShell: true)])
        for c in ["cp evil.json l?k/settings.json", "cat */settings.json", "cp evil.json l*k/settings.json", "cat lnk/settings.json"] {
            let a = policy.assess(PermissionRequest(requestID: "r", toolName: "Bash", input: ["command": .string(c)]))
            XCTAssertFalse(a.coveredByFolderGrant, c)
        }
    }

    func testAdviceWithPunctuatedPhraseIsStillDropped() {
        for s in ["Because of the earlier note, confirm, high risk, quux.", "Please confirm high-risk quux now", "Okay: confirm   high risk"] {
            XCTAssertFalse(ConversationEngine.speakableAdvice(s).lowercased().contains("high risk"), s)
            XCTAssertFalse(ConversationEngine.speakableAdvice(s).lowercased().contains("high-risk"), s)
        }
    }

    func testAnInboxWithADuplicateRequestIdDoesNotCrash() {
        var i = ApprovalInbox()
        let r = PermissionRequest(requestID: "X", toolName: "Edit", input: [:])
        let p = PendingPermission(request: r, assessment: PermissionAssessment(risk: .low, voiceApprovable: true, spokenPrompt: "", summary: "", reasons: []))
        i.sync(projectID: "a", name: "a", pending: [p, p], now: Date())
        i.sync(projectID: "a", name: "a", pending: [p, p], now: Date())
        XCTAssertEqual(i.items.count, 2)
    }
}
