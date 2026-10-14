// SPDX-License-Identifier: Apache-2.0

import Foundation

/// One request waiting for a decision in some open project.
public struct InboxItem: Sendable, Equatable, Identifiable {
    public var id: String { "\(projectID)/\(requestID)" }
    public var projectID: String
    public var projectName: String
    public var requestID: String
    public var summary: String
    public var spokenPrompt: String
    public var risk: RiskLevel
    public var voiceApprovable: Bool
    /// Claude Code itself says this one needs the person at the screen.
    public var needsScreen: Bool
    public var firstSeen: Date
    public var arrival: Int
    /// Short enough, and with few enough reasons, to approve from a small surface without opening the project.
    public var fitsCompactSurface = false
}

/// Every pending request across all open projects, in the order they arrived.
public struct ApprovalInbox: Sendable, Equatable {
    public private(set) var items: [InboxItem] = []
    private var counter = 0

    public init() {}

    /// Replaces one project's entries with what its engine reports (the request on screen, then the queue).
    public mutating func sync(projectID: String, name: String, pending: [PendingPermission], now: Date) {
        let existing = Dictionary(items.filter { $0.projectID == projectID }.map { ($0.requestID, $0) }, uniquingKeysWith: { first, _ in first })
        items.removeAll { $0.projectID == projectID }
        for p in pending {
            let id = p.request.requestID
            if var kept = existing[id] {
                kept.projectName = name
                kept.summary = p.assessment.summary; kept.spokenPrompt = p.assessment.spokenPrompt
                kept.risk = p.assessment.risk; kept.voiceApprovable = p.assessment.voiceApprovable
                kept.fitsCompactSurface = p.assessment.fitsCompactSurface
                items.append(kept)
            } else {
                counter += 1
                items.append(InboxItem(projectID: projectID, projectName: name, requestID: id, summary: p.assessment.summary,
                                       spokenPrompt: p.assessment.spokenPrompt, risk: p.assessment.risk,
                                       voiceApprovable: p.assessment.voiceApprovable,
                                       needsScreen: p.request.needsPersonAtScreen,
                                       firstSeen: now, arrival: counter, fitsCompactSurface: p.assessment.fitsCompactSurface))
            }
        }
        items.sort { $0.arrival < $1.arrival }
    }

    public mutating func removeProject(_ projectID: String) { items.removeAll { $0.projectID == projectID } }

    public func item(project: String, request: String) -> InboxItem? { items.first { $0.projectID == project && $0.requestID == request } }
    public func others(than activeProjectID: String?) -> [InboxItem] { items.filter { $0.projectID != activeProjectID } }
}

/// What the active conversation is doing right now.
public struct ConversationActivity: Sendable, Equatable {
    public var activePhase: EnginePhase
    public var userSpeaking: Bool
    /// The last moment anything was said, heard or spoken in the active conversation.
    public var lastActivity: Date
    public init(activePhase: EnginePhase, userSpeaking: Bool = false, lastActivity: Date) {
        self.activePhase = activePhase; self.userSpeaking = userSpeaking; self.lastActivity = lastActivity
    }
}

public struct AnnouncementSettings: Sendable, Equatable {
    public var enabled = true
    public var quietSeconds: TimeInterval = 2
    public var speakProjectNames = true
    /// Spoken confirmation of high-risk requests is switched on.
    public var voiceHighRisk = false
    /// Requests Claude Code says need the screen may also be confirmed by voice.
    public var voiceNeedsScreen = false
    /// Touch ID or the login password is asked after the spoken phrase on this Mac.
    public var secondConfirmation = false
    /// Projects that are never announced (their requests still show in the inbox).
    public var mutedProjects: Set<String> = []
    public init() {}
}

public struct Announcement: Sendable, Equatable {
    public var item: InboxItem
    public var text: String
    public var announcedAt: Date
    public var expiresAt: Date
}

/// Decides when a request from another project is worth interrupting for, and what is said.
public struct Announcer: Sendable {
    public static let bindingSeconds: TimeInterval = 20
    /// A request older than this cannot be approved by voice (the rule that applies everywhere).
    public static let staleAfter: TimeInterval = 300

    public private(set) var current: Announcement?
    private var announced: Set<String> = []
    private var lastAnswered: Date?

    public init() {}

    static func isBreak(_ a: ConversationActivity, now: Date, quiet: TimeInterval) -> Bool {
        guard !a.userSpeaking else { return false }
        switch a.activePhase {
        case .listening, .transcribing, .speaking, .awaitingPermission, .starting, .needsSetup: return false
        case .idle, .thinking, .working: break
        }
        return now.timeIntervalSince(a.lastActivity) >= quiet
    }

    /// Call on a timer and whenever the inbox changes. Returns a new announcement to speak, if there is one.
    public mutating func next(inbox: ApprovalInbox, activeProjectID: String?, activity: ConversationActivity,
                              settings: AnnouncementSettings, now: Date) -> Announcement? {
        if let c = current, now >= c.expiresAt || inbox.item(project: c.item.projectID, request: c.item.requestID) == nil { current = nil }
        guard settings.enabled, current == nil else { return nil }
        guard Self.isBreak(activity, now: now, quiet: settings.quietSeconds) else { return nil }
        if let last = lastAnswered, now.timeIntervalSince(last) < settings.quietSeconds { return nil }
        let candidates = inbox.others(than: activeProjectID).filter { !settings.mutedProjects.contains($0.projectID) && !announced.contains($0.id) }
        guard let item = candidates.first else { return nil }
        announced.insert(item.id)
        let a = Announcement(item: item, text: Self.text(for: item, waiting: candidates.count, settings: settings),
                             announcedAt: now, expiresAt: now.addingTimeInterval(Self.bindingSeconds))
        current = a
        return a
    }

    public mutating func clear(answeredAt now: Date) { current = nil; lastAnswered = now }

    static func text(for item: InboxItem, waiting: Int, settings: AnnouncementSettings) -> String {
        let who = settings.speakProjectNames ? item.projectName : "another project"
        var what = item.spokenPrompt
        for tail in [" Allow?", ". Please confirm on screen."] where what.hasSuffix(tail) { what.removeLast(tail.count) }
        while what.hasSuffix(".") { what.removeLast() }
        var body = "Quick one from \(who): \(what)."
        if waiting > 1 { body += " \(waiting - 1) more waiting." }
        if item.voiceApprovable { return body + " Say approve, deny, tell me more, or switch." }
        let canByVoice = settings.voiceHighRisk && (!item.needsScreen || settings.voiceNeedsScreen)
        let name = settings.speakProjectNames ? " \(item.projectName)" : ""
        return body + (canByVoice ? " This needs care. Say tell me more, switch, or confirm high risk\(name)."
                                  : " This one needs a click. Say switch, or use the card.")
    }
}

public enum AnnouncementReply: Equatable, Sendable {
    case approve, deny, tellMore, switchHere
    case confirmHighRisk(project: String?)
    case notForUs

    /// Reads a short spoken answer to an announcement. Anything longer or unclear is not for the announcement.
    public static func parse(_ text: String, projectNames: [String]) -> AnnouncementReply {
        let words = VoiceCommand.normalize(text)
        let core = words.joined(separator: " ")
        guard !words.isEmpty, words.count <= 8 else { return .notForUs }
        // "stop" interrupts the active conversation, and a long sentence that happens to hold a refusal word is
        // an instruction for the active project, so neither is an answer to an announcement.
        if ["stop", "stop it", "stop that", "wait", "hold on"].contains(core) { return .notForUs }
        if ["tell me more", "more", "what is that about", "what's that about", "whats that about", "what is it", "explain", "what is that",
            "tell me more about it", "give me the overview"].contains(core) { return .tellMore }
        if ["switch", "go there", "take me there", "switch there", "switch to it", "go to it"].contains(core) { return .switchHere }
        if core.contains("confirm high risk") {
            let rest = core.replacingOccurrences(of: "confirm high risk", with: "").trimmingCharacters(in: .whitespaces)
            let match = projectNames.first { !rest.isEmpty && VoiceCommand.normalize($0).joined(separator: " ") == rest }
            return .confirmHighRisk(project: match)
        }
        guard words.count <= 4 else { return .notForUs }
        switch VoiceCommand.parse(text, context: VoiceCommand.Context(awaitingPermission: true)) {
        case .approve?: return .approve
        case .deny?: return .deny
        default: return .notForUs
        }
    }
}

public enum AnnouncementDecision: Equatable, Sendable {
    case approve(InboxItem, needsSecondConfirmation: Bool)
    case deny(InboxItem)
    case overview(InboxItem)
    case switchTo(InboxItem)
    case say(String)
    case notBound
}

public enum AnnouncementRouter {
    /// What a spoken reply does. Only the announced request can be answered, only while the announcement is live,
    /// and every rule that applies to a request in the active project applies here too.
    public static func resolve(_ reply: AnnouncementReply, announcement: Announcement?, inbox: ApprovalInbox,
                               settings: AnnouncementSettings, now: Date) -> AnnouncementDecision {
        guard reply != .notForUs, let a = announcement, now < a.expiresAt,
              let item = inbox.item(project: a.item.projectID, request: a.item.requestID) else { return .notBound }
        let who = settings.speakProjectNames ? item.projectName : "the other project"
        // The age limit applies to every way of approving by voice.
        let stale = now.timeIntervalSince(item.firstSeen) > Announcer.staleAfter
        switch reply {
        case .notForUs: return .notBound
        case .tellMore: return .overview(item)
        case .switchHere: return .switchTo(item)
        case .deny: return .deny(item)
        case .approve:
            if !item.voiceApprovable {
                return .say(settings.voiceHighRisk ? "That one needs care. Say confirm high risk \(who), or use the card."
                                                   : "That one needs a click. Use the card, or say switch.")
            }
            if stale { return .say("That request is old. Use the card, or say switch.") }
            return .approve(item, needsSecondConfirmation: false)
        case .confirmHighRisk(let project):
            guard settings.voiceHighRisk, !item.voiceApprovable else {
                return .say("That one needs a click. Use the card, or say switch.")
            }
            guard !item.needsScreen || settings.voiceNeedsScreen else {
                return .say("Claude Code says that one needs you at the screen. Use the card, or say switch.")
            }
            if stale { return .say("That request is old. Use the card, or say switch.") }
            guard project?.lowercased() == item.projectName.lowercased() else {
                return .say("Say confirm high risk, then the project name, \(who).")
            }
            return .approve(item, needsSecondConfirmation: settings.secondConfirmation)
        }
    }
}

/// The short recap spoken for "tell me more": what was asked in that project, what Claude last said, and what the
/// request is. Built from the project's own transcript, so it needs no extra model call; an explanation of the
/// request is added when the advisor already produced one.
public enum CrossProjectOverview {
    public static func text(item: InboxItem, transcript: [TranscriptEntry], explanation: Explanation?, speakName: Bool = true) -> String {
        let who = speakName ? item.projectName : "the other project"
        func clip(_ s: String, _ n: Int) -> String {
            let one = s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            return one.count > n ? String(one.prefix(n)) + "…" : one
        }
        var parts: [String] = []
        if let asked = transcript.last(where: { $0.role == .user })?.text, !asked.isEmpty {
            parts.append("In \(who), you asked: \(clip(asked, 120)).")
        } else {
            parts.append("In \(who).")
        }
        if let said = transcript.last(where: { $0.role == .assistant })?.text, !said.isEmpty {
            parts.append("Claude last said: \(clip(said, 140)).")
        }
        var what = item.spokenPrompt
        for tail in [" Allow?", ". Please confirm on screen."] where what.hasSuffix(tail) { what.removeLast(tail.count) }
        while what.hasSuffix(".") { what.removeLast() }
        parts.append("Now \(what.replacingOccurrences(of: "Claude wants to", with: "it wants to")).")
        if case .ready(let why)? = explanation { parts.append(clip(why, 200)) }
        // The recap quotes text a model wrote, so a sentence that would work as an approval is dropped.
        return ConversationEngine.speakableAdvice(parts.joined(separator: " "))
    }
}
