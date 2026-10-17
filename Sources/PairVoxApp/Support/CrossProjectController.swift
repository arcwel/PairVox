// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import LocalAuthentication
import PairVoxCore

/// Lets the person answer a request from another project without leaving the conversation they are in.
/// It keeps one inbox of every waiting request, speaks about one at a break, and routes the spoken answer to
/// the project that owns the request. The permission rules are the engine's and the policy's; this only routes.
@MainActor
final class CrossProjectController: ObservableObject {
    @Published private(set) var inbox = ApprovalInbox()
    @Published private(set) var announcement: Announcement?

    /// Read by the engines' utterance interceptors, which run on the engine's executor, not the main actor.
    final class Shared: @unchecked Sendable {
        private let lock = NSLock()
        private var _announcement: Announcement?
        private var _inbox = ApprovalInbox()
        private var _settings = AnnouncementSettings()
        private var _names: [String] = []
        private var _activeBusy = false
        func set(announcement: Announcement?, inbox: ApprovalInbox, settings: AnnouncementSettings, names: [String], activeBusy: Bool) {
            lock.lock(); _announcement = announcement; _inbox = inbox; _settings = settings; _names = names; _activeBusy = activeBusy; lock.unlock()
        }
        func read() -> (Announcement?, ApprovalInbox, AnnouncementSettings, [String], Bool) {
            lock.lock(); defer { lock.unlock() }; return (_announcement, _inbox, _settings, _names, _activeBusy)
        }
    }

    let shared = Shared()
    private var announcer = Announcer()
    private var lastActivity = Date()
    private var activeBusy = false
    private var timer: Timer?
    private unowned let model: AppModel

    init(model: AppModel) {
        self.model = model
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    // MARK: Inputs

    func sessionChanged(_ session: ProjectSession, isActive: Bool) {
        let pending = [session.snapshot.pendingPermission].compactMap { $0 } + session.snapshot.queuedPermissions
        inbox.sync(projectID: session.id.uuidString, name: session.name, pending: pending, now: Date())
        if isActive {
            activeBusy = session.snapshot.pendingPermission != nil || session.snapshot.grantOffer != nil
                || session.snapshot.awaitingCatchUpChoice || session.snapshot.hasHeldBack
            switch session.snapshot.phase {
            case .speaking, .listening, .transcribing: lastActivity = Date()
            default: break
            }
        }
        publishShared()
    }

    func sessionClosed(_ id: UUID) {
        inbox.removeProject(id.uuidString)
        if announcement?.item.projectID == id.uuidString { announcement = nil }
        publishShared()
    }

    func activeProjectChanged() { lastActivity = Date(); publishShared() }

    func settingsChanged() { publishShared() }

    private func currentSettings() -> AnnouncementSettings {
        var s = AnnouncementSettings()
        let app = model.settings
        s.enabled = app.announceOtherProjects
        s.quietSeconds = app.announceQuietSeconds
        s.speakProjectNames = app.speakProjectNames
        s.voiceHighRisk = app.spokenHighRiskConfirmation
        s.voiceNeedsScreen = app.voiceApprovesNeedsScreen
        s.secondConfirmation = app.macSecondConfirmation
        s.mutedProjects = Set(model.sessions.filter { app.preferences(for: $0.path).muteAnnouncements }.map { $0.id.uuidString })
        return s
    }

    private func publishShared() {
        // While the active project has its own request or folder question open, "yes" and "no" are for that one.
        let busy = activeBusy
        shared.set(announcement: announcer.current, inbox: inbox, settings: currentSettings(), names: model.sessions.map(\.name), activeBusy: busy)
    }

    // MARK: Announcing

    private func tick() {
        let now = Date()
        let active = model.activeSessionID?.uuidString
        let phase = model.snapshot.phase
        let activity = ConversationActivity(activePhase: phase, userSpeaking: phase == .listening, lastActivity: lastActivity)
        if let a = announcer.next(inbox: inbox, activeProjectID: active, activity: activity, settings: currentSettings(), now: now) {
            announcement = a
            say(a.text)
            lastActivity = now
        } else if announcement != announcer.current {
            announcement = announcer.current
        }
        publishShared()
    }

    // MARK: Answers

    /// Called from an engine when the person speaks; returns true when the words were an answer to the announcement.
    nonisolated func intercept(_ text: String) -> Bool {
        let (announcement, inbox, settings, names, activeBusy) = shared.read()
        if activeBusy { return false }
        let reply = AnnouncementReply.parse(text, projectNames: names)
        let decision = AnnouncementRouter.resolve(reply, announcement: announcement, inbox: inbox, settings: settings, now: Date())
        if decision == .notBound {
            // Speaking about something else ends the binding: a later "yes" answers nothing here.
            if announcement != nil { Task { @MainActor in self.dropBinding() } }
            return false
        }
        Task { @MainActor in await self.perform(decision) }
        return true
    }

    func perform(_ decision: AnnouncementDecision) async {
        switch decision {
        case .notBound: break
        case .say(let text): say(text)
        case .switchTo(let item):
            if let id = UUID(uuidString: item.projectID) { model.switchTo(id) }
            finishAnnouncement()
        case .overview(let item):
            guard let session = session(for: item) else { return }
            let explanation = ([session.snapshot.pendingPermission].compactMap { $0 } + session.snapshot.queuedPermissions)
                .first { $0.request.requestID == item.requestID }?.explanation
            say(CrossProjectOverview.text(item: item, transcript: session.snapshot.transcript, explanation: explanation, speakName: model.settings.speakProjectNames))
        case .deny(let item):
            guard let session = session(for: item) else { return }
            await session.engine.denyPending(requestID: item.requestID)
            say("Done. The request in \(speakName(item)) was turned down.")
            finishAnnouncement()
        case .approve(let item, let second):
            guard let session = session(for: item) else { return }
            if second, !(await Self.authenticate(reason: "Allow a high-risk action in \(item.projectName)")) {
                say("Not confirmed. It is still waiting.")
                return
            }
            await session.engine.approvePending(always: false, requestID: item.requestID)
            say("Done. \(speakName(item)) is continuing.")
            finishAnnouncement()
        }
    }

    private func say(_ text: String) {
        let engine = model.activeEngine
        Task { await engine?.announce(text) }
    }

    func dropBinding() { announcer.clear(answeredAt: Date.distantPast); announcement = nil; publishShared() }

    private func finishAnnouncement() {
        announcer.clear(answeredAt: Date()); announcement = nil; lastActivity = Date(); publishShared()
    }

    private func speakName(_ item: InboxItem) -> String { model.settings.speakProjectNames ? item.projectName : "the other project" }

    private func session(for item: InboxItem) -> ProjectSession? { UUID(uuidString: item.projectID).flatMap { model.session(withID: $0) } }

    // MARK: Clicks

    func approve(_ item: InboxItem) {
        Task {
            guard let s = session(for: item) else { return }
            await s.engine.approvePending(always: false, requestID: item.requestID)
        }
    }

    func deny(_ item: InboxItem) {
        Task { if let s = session(for: item) { await s.engine.denyPending(requestID: item.requestID) } }
    }

    func open(_ item: InboxItem) { if let id = UUID(uuidString: item.projectID) { model.switchTo(id) } }

    /// Touch ID or the login password through the system dialog.
    static func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return false }
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }
}
