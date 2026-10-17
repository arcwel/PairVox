// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PairVoxCore

/// Scenarios with REAL engines for several projects: a request waits in a background project, PairVox speaks about it at
/// a break in the active conversation, and what the person says is routed to the project that owns the request. The rig
/// below does what the app's CrossProjectController does, using only the core's public pieces and real engines, so these
/// scenarios prove that the engines, the inbox, the announcer and the router agree with each other.
/// (The controller itself is app code and is not run here.)
final class TwoProjectScenarioTests: XCTestCase {
    final class Project {
        let id: String, name: String
        let backend = FakeBackend()
        let output = FakeOutput()
        let engine: ConversationEngine
        init(id: String, name: String) {
            self.id = id; self.name = name
            let b = backend
            engine = ConversationEngine(configuration: EngineConfiguration(projectRoot: "/Users/dev/\(name.lowercased())", speechMode: .skipCode,
                                                                           acknowledgements: false),
                                        output: output, backendFactory: { _ in b })
        }
    }

    final class Rig: @unchecked Sendable {
        let projects: [Project]
        let active: Project
        var inbox = ApprovalInbox()
        var announcer = Announcer()
        var settings = AnnouncementSettings()
        var now = Date(timeIntervalSince1970: 2_000_000)
        var lastActivity: Date
        var activeBusy = false
        var authenticationResult = true
        private(set) var authenticationCalls = 0
        private(set) var switchedTo: [String] = []
        private(set) var spoken: [String] = []
        private let lock = NSLock()
        private var announcement: Announcement?

        init(active: Project, others: [Project]) {
            self.active = active
            self.projects = [active] + others
            self.lastActivity = now
        }

        var names: [String] { projects.map(\.name) }

        func start() async {
            for p in projects { await p.engine.start() }
            let box = self
            await active.engine.setUtteranceInterceptor { text in box.intercept(text) }
        }

        func stop() async { for p in projects { await p.engine.shutdown() } }

        /// Pulls every project's waiting requests into the inbox, as the app does whenever a session changes.
        func sync() async {
            for p in projects {
                let snap = await p.engine.snapshot
                let pending = [snap.pendingPermission].compactMap { $0 } + snap.queuedPermissions
                inbox.sync(projectID: p.id, name: p.name, pending: pending, now: now)
                if p === active { activeBusy = snap.pendingPermission != nil || snap.grantOffer != nil }
            }
            publish()
        }

        /// One tick of the announcer; speaks through the active project's voice.
        @discardableResult func tick() async -> Announcement? {
            await sync()
            let phase = await active.engine.snapshot.phase
            let activity = ConversationActivity(activePhase: phase, userSpeaking: phase == .listening, lastActivity: lastActivity)
            let made = announcer.next(inbox: inbox, activeProjectID: active.id, activity: activity, settings: settings, now: now)
            if let made { await say(made.text); lastActivity = now }
            publish()
            return made
        }

        func say(_ text: String) async { spoken.append(text); await active.engine.announce(text) }

        private func publish() { lock.lock(); announcement = announcer.current; lock.unlock() }

        /// What the engine calls when the person speaks. True means the words were an answer to the announcement.
        func intercept(_ text: String) -> Bool {
            lock.lock(); let a = announcement; let busy = activeBusy; let box = (inbox, settings, names, now); lock.unlock()
            if busy { return false }
            let reply = AnnouncementReply.parse(text, projectNames: box.2)
            let decision = AnnouncementRouter.resolve(reply, announcement: a, inbox: box.0, settings: box.1, now: box.3)
            if decision == .notBound {
                if a != nil { announcer.clear(answeredAt: Date.distantPast); publish() }   // speaking of something else ends the binding
                return false
            }
            Task { await self.perform(decision) }
            return true
        }

        func perform(_ decision: AnnouncementDecision) async {
            switch decision {
            case .notBound: break
            case .say(let text): await say(text)
            case .switchTo(let item): switchedTo.append(item.projectID); finish()
            case .overview(let item):
                let p = projects.first { $0.id == item.projectID }!
                let snap = await p.engine.snapshot
                await say(CrossProjectOverview.text(item: item, transcript: snap.transcript, explanation: nil))
            case .deny(let item):
                await projects.first { $0.id == item.projectID }!.engine.denyPending(requestID: item.requestID)
                await say("Done. The request in \(item.projectName) was turned down."); finish()
            case .approve(let item, let second):
                if second {
                    authenticationCalls += 1
                    if !authenticationResult { await say("Not confirmed. It is still waiting."); return }
                }
                await projects.first { $0.id == item.projectID }!.engine.approvePending(always: false, requestID: item.requestID)
                await say("Done. \(item.projectName) is continuing."); finish()
            }
        }

        private func finish() { announcer.clear(answeredAt: now); lastActivity = now; publish() }
    }

    func edit(_ id: String, project: String, _ file: String = "main.swift") -> SessionEvent {
        .permissionRequested(PermissionRequest(requestID: id, toolName: "Edit", input: ["file_path": .string("/Users/dev/\(project.lowercased())/\(file)")]))
    }
    func gitPush(_ id: String) -> SessionEvent {
        .permissionRequested(PermissionRequest(requestID: id, toolName: "Bash", input: ["command": .string("git push origin main")]))
    }
    func settle(_ ms: UInt64 = 80) async { try? await Task.sleep(nanoseconds: ms * 1_000_000) }

    func makeRig(others: [String] = ["Beta"]) async -> (Rig, Project, [Project]) {
        let alpha = Project(id: "A", name: "Alpha")
        let rest = others.enumerated().map { Project(id: ["B", "C", "D"][$0.offset], name: $0.element) }
        let rig = Rig(active: alpha, others: rest)
        await rig.start()
        return (rig, alpha, rest)
    }

    // MARK: Scenarios

    func testARequestInAnotherProjectIsAnnouncedAtABreakAndAYesApprovesOnlyThatOne() async throws {
        let (rig, alpha, others) = await makeRig()
        let beta = others[0]
        await beta.engine.submit("Rename the helper")
        beta.backend.emit(edit("R1", project: "Beta"))
        await settle()
        rig.now.addTimeInterval(5)
        let announcement = await rig.tick()
        XCTAssertNotNil(announcement)
        XCTAssertTrue(announcement?.text.hasPrefix("Quick one from Beta:") == true, announcement?.text ?? "")
        XCTAssertTrue(announcement?.text.contains("Say approve, deny, tell me more, or switch.") == true)
        await settle()
        XCTAssertTrue(alpha.output.allTexts.contains { $0.hasPrefix("Quick one from Beta") }, "spoken through the active project's voice")

        await alpha.engine.submit("yes")
        await settle(200)
        XCTAssertEqual(beta.backend.responses.map(\.0), ["R1"], "the yes reached Beta, bound to the announced request")
        if case .allow? = beta.backend.responses.first?.1 {} else { XCTFail("it must be an approval") }
        XCTAssertTrue(alpha.backend.sent.isEmpty, "the active project never saw the answer as an instruction")
        XCTAssertTrue(rig.spoken.last?.hasPrefix("Done. Beta is continuing") == true)
        await rig.stop()
    }

    func testANoRefusesOnlyTheAnnouncedRequest() async throws {
        let (rig, alpha, others) = await makeRig()
        let beta = others[0]
        await beta.engine.submit("Rename the helper")
        beta.backend.emit(edit("R1", project: "Beta"))
        await settle(); rig.now.addTimeInterval(5); await rig.tick(); await settle()
        await alpha.engine.submit("no")
        await settle(200)
        if case .deny? = beta.backend.responses.first?.1 {} else { XCTFail("a no must refuse the request") }
        XCTAssertTrue(alpha.backend.sent.isEmpty)
        await rig.stop()
    }

    func testStopAndWaitAreNotAnswersAndEndTheBinding() async throws {
        let (rig, alpha, others) = await makeRig()
        let beta = others[0]
        await beta.engine.submit("Rename the helper")
        beta.backend.emit(edit("R1", project: "Beta"))
        await settle(); rig.now.addTimeInterval(5); await rig.tick(); await settle()
        await alpha.engine.submit("wait")                  // not an answer: it belongs to the conversation the person is in
        await settle()
        await alpha.engine.submit("yes")                   // the binding ended, so this answers nothing in Beta
        await settle(200)
        XCTAssertTrue(beta.backend.responses.isEmpty, "after other talk, a late yes must not approve Beta's request")
        await rig.stop()
    }

    func testAHighRiskRequestIsNotVoiceApprovableByDefault() async throws {
        let (rig, alpha, others) = await makeRig()
        let beta = others[0]
        await beta.engine.submit("Ship it")
        beta.backend.emit(gitPush("P1"))
        await settle(); rig.now.addTimeInterval(5)
        let a = await rig.tick(); await settle()
        XCTAssertTrue(a?.text.contains("needs a click") == true, "voice for high risk is off by default: \(a?.text ?? "")")
        await alpha.engine.submit("approve"); await settle(150)
        XCTAssertTrue(beta.backend.responses.isEmpty, "a plain approve must not pass a high-risk request")
        await rig.stop()
        let (rig2, alpha2, others2) = await makeRig()
        let beta2 = others2[0]
        await beta2.engine.submit("Ship it")
        beta2.backend.emit(gitPush("P1"))
        await settle(); rig2.now.addTimeInterval(5)
        _ = await rig2.tick(); await settle()
        await alpha2.engine.submit("confirm high risk beta"); await settle(150)
        XCTAssertTrue(beta2.backend.responses.isEmpty, "with the spoken high-risk switch off, even the phrase does not pass")
        await rig2.stop()
    }

    func testAHighRiskRequestWithTheSwitchOnNeedsThePhraseTheNameAndOptionallyASecondConfirmation() async throws {
        let (rig, alpha, others) = await makeRig()
        let beta = others[0]
        rig.settings.voiceHighRisk = true
        await beta.engine.submit("Ship it")
        beta.backend.emit(gitPush("P1"))
        await settle(); rig.now.addTimeInterval(5)
        let a = await rig.tick(); await settle()
        XCTAssertTrue(a?.text.contains("confirm high risk Beta") == true, a?.text ?? "nothing announced")
        await alpha.engine.submit("approve"); await settle(150)
        XCTAssertTrue(beta.backend.responses.isEmpty, "a plain approve still does not pass")
        await alpha.engine.submit("confirm high risk"); await settle(150)
        XCTAssertTrue(beta.backend.responses.isEmpty, "the project name is part of the phrase")

        // Each failed try above spoke a prompt and kept the binding; now require Touch ID / password as well.
        rig.settings.secondConfirmation = true
        rig.authenticationResult = false
        await alpha.engine.submit("confirm high risk beta"); await settle(200)
        XCTAssertEqual(rig.authenticationCalls, 1)
        XCTAssertTrue(beta.backend.responses.isEmpty, "a failed Touch ID or password check must leave it waiting")

        rig.authenticationResult = true
        await alpha.engine.submit("confirm high risk beta"); await settle(200)
        XCTAssertEqual(rig.authenticationCalls, 2)
        XCTAssertEqual(beta.backend.responses.map(\.0), ["P1"])
        await rig.stop()
    }

    func testARequestThatWaitedOverFiveMinutesCannotBeApprovedByVoice() async throws {
        let (rig, alpha, others) = await makeRig()
        let beta = others[0]
        await beta.engine.submit("Rename")
        beta.backend.emit(edit("R1", project: "Beta"))
        await settle()
        await rig.sync()                                   // the inbox first sees it now
        rig.now.addTimeInterval(Announcer.staleAfter + 1)  // it waits (the person was busy), then there is a break
        let a = await rig.tick(); await settle()
        XCTAssertNotNil(a)
        await alpha.engine.submit("yes"); await settle(200)
        XCTAssertTrue(beta.backend.responses.isEmpty, "a request older than five minutes is never approved by a spoken yes")
        XCTAssertTrue(rig.spoken.contains { $0.contains("old") }, "and the person is told why: \(rig.spoken)")
        await rig.stop()
    }

    func testTheAnswerWindowIsTwentySeconds() async throws {
        let (rig, alpha, others) = await makeRig()
        let beta = others[0]
        await beta.engine.submit("Rename")
        beta.backend.emit(edit("R1", project: "Beta"))
        await settle(); rig.now.addTimeInterval(5); await rig.tick(); await settle()
        rig.now.addTimeInterval(Announcer.bindingSeconds + 1)
        await alpha.engine.submit("yes"); await settle(200)
        XCTAssertTrue(beta.backend.responses.isEmpty, "a yes after the window answers nothing")
        XCTAssertEqual(alpha.backend.sent, ["yes"], "it is just something said in the active conversation")
        await rig.stop()
    }

    func testTwoWaitingRequestsAreAnnouncedOneAtATimeInArrivalOrder() async throws {
        let (rig, alpha, others) = await makeRig(others: ["Beta", "Gamma"])
        let beta = others[0], gamma = others[1]
        await gamma.engine.submit("Gamma work"); await beta.engine.submit("Beta work")
        gamma.backend.emit(edit("G1", project: "Gamma"))
        await settle(); await rig.sync()                   // the app syncs whenever a session changes
        beta.backend.emit(edit("B1", project: "Beta"))
        await settle(); rig.now.addTimeInterval(5)
        let first = await rig.tick(); await settle()
        XCTAssertTrue(first?.text.hasPrefix("Quick one from Gamma:") == true, "the one that arrived first: \(first?.text ?? "")")
        XCTAssertTrue(first?.text.contains("1 more waiting.") == true)
        let noSecond = await rig.tick()
        XCTAssertNil(noSecond, "one announcement at a time")

        await alpha.engine.submit("yes"); await settle(200)
        XCTAssertEqual(gamma.backend.responses.map(\.0), ["G1"])
        XCTAssertTrue(beta.backend.responses.isEmpty, "the second request is untouched by the first answer")
        alpha.output.playAll(); await settle()             // the spoken "Done" finishes playing, so the conversation is quiet again
        rig.now.addTimeInterval(5)
        let second = await rig.tick()
        XCTAssertTrue(second?.text.hasPrefix("Quick one from Beta:") == true, second?.text ?? "nothing")
        await rig.stop()
    }

    func testWhileTheActiveProjectHasItsOwnRequestAYesAnswersThatOne() async throws {
        let (rig, alpha, others) = await makeRig()
        let beta = others[0]
        await alpha.engine.submit("Fix the bug")
        alpha.backend.emit(edit("A1", project: "Alpha"))
        await beta.engine.submit("Rename")
        beta.backend.emit(edit("R1", project: "Beta"))
        await settle(); rig.now.addTimeInterval(5)
        let a = await rig.tick()
        XCTAssertNil(a, "nothing is announced while the active project is waiting on the person itself")
        await alpha.engine.submit("yes"); await settle(200)
        XCTAssertEqual(alpha.backend.responses.map(\.0), ["A1"], "the yes belongs to the request on screen")
        XCTAssertTrue(beta.backend.responses.isEmpty)
        await rig.stop()
    }

    func testMutedProjectsAndTheMasterSwitchStaySilent() async throws {
        let (rig, _, others) = await makeRig()
        let beta = others[0]
        await beta.engine.submit("Rename")
        beta.backend.emit(edit("R1", project: "Beta"))
        await settle(); rig.now.addTimeInterval(5)
        rig.settings.mutedProjects = ["B"]
        let muted = await rig.tick()
        XCTAssertNil(muted, "a muted project is never announced")
        rig.settings.mutedProjects = []
        rig.settings.enabled = false
        let off = await rig.tick()
        XCTAssertNil(off, "with announcements off nothing is spoken")
        rig.settings.enabled = true
        let on = await rig.tick()
        XCTAssertNotNil(on)
        await rig.stop()
    }

    func testNothingIsAnnouncedBeforeTheConversationHasBeenQuiet() async throws {
        let (rig, _, others) = await makeRig()
        let beta = others[0]
        await beta.engine.submit("Rename")
        beta.backend.emit(edit("R1", project: "Beta"))
        await settle()
        rig.settings.quietSeconds = 2
        rig.now.addTimeInterval(0.5)
        let early = await rig.tick()
        XCTAssertNil(early, "not mid-conversation")
        rig.now.addTimeInterval(2)
        let later = await rig.tick()
        XCTAssertNotNil(later)
        await rig.stop()
    }

    func testTellMeMoreSpeaksARecapAndApprovesNothing() async throws {
        let (rig, alpha, others) = await makeRig()
        let beta = others[0]
        await beta.engine.submit("Rename the helper function")
        beta.backend.emit(.textDelta("I found three call sites. "))
        beta.backend.emit(edit("R1", project: "Beta"))
        await settle(); rig.now.addTimeInterval(5); await rig.tick(); await settle()
        await alpha.engine.submit("tell me more"); await settle(200)
        XCTAssertTrue(beta.backend.responses.isEmpty, "a recap is not an approval")
        XCTAssertTrue(rig.spoken.contains { $0.contains("Rename the helper function") || $0.contains("Beta") }, "the recap mentions the project's own conversation: \(rig.spoken)")
        await rig.stop()
    }

    func testSwitchTakesThePersonToTheProjectAndApprovesNothing() async throws {
        let (rig, alpha, others) = await makeRig()
        let beta = others[0]
        await beta.engine.submit("Rename")
        beta.backend.emit(edit("R1", project: "Beta"))
        await settle(); rig.now.addTimeInterval(5); await rig.tick(); await settle()
        await alpha.engine.submit("switch"); await settle(200)
        XCTAssertEqual(rig.switchedTo, ["B"])
        XCTAssertTrue(beta.backend.responses.isEmpty)
        await rig.stop()
    }
}
