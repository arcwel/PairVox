// SPDX-License-Identifier: Apache-2.0

import Foundation

// MARK: - Speech output abstraction

/// Text-to-speech + playback. The macOS app implements this with Kokoro or the
/// system voice; the CLI prints (or uses `say`); tests use a fake.
public protocol SpeechOutput: AnyObject, Sendable {
    var events: AsyncStream<SpeechOutputEvent> { get }
    /// Queues an utterance; utterances play in order.
    func enqueue(_ utterance: Utterance)
    /// Stops playback immediately and clears the queue. Returns the IDs that did
    /// not finish (the one playing first), so speech can resume later.
    @discardableResult func stopAll() -> [Int]
    func setRate(_ rate: Double)
    /// True when `pause()` holds playback in place and `resume()` carries on from the same spot. An output that cannot
    /// do this keeps the default (false) and the engine stops speech at a barge-in instead.
    var supportsPause: Bool { get }
    func pause()
    func resume()
    /// Removes utterances that are queued but have not started playing. Returns the ids that were removed; one that is
    /// already playing stays. An output that cannot do this returns nothing and the engine leaves the queue alone.
    @discardableResult func cancelQueued(_ ids: [Int]) -> [Int]
    /// A reply is probably on its way (the user started talking, or a phone sent text): get the voice ready so the
    /// first sentence is not slow. Cheap when nothing needs doing.
    func prepare()
}

public extension SpeechOutput {
    func prepare() {}
    var supportsPause: Bool { false }
    func pause() {}
    func resume() {}
    func cancelQueued(_ ids: [Int]) -> [Int] { [] }
}

public enum SpeechOutputEvent: Sendable, Equatable {
    case started(Int)
    case finished(Int)
    case failed(Int, String)
    /// Queue drained and nothing is playing.
    case idle
}

// MARK: - Snapshot published to the UI

public enum EnginePhase: String, Sendable, Equatable {
    case starting
    case idle
    case listening
    case transcribing
    case thinking
    case working
    case speaking
    case awaitingPermission
    case needsSetup
}

public struct TranscriptEntry: Sendable, Equatable, Identifiable {
    public enum Role: String, Sendable { case user, assistant, tool, system }
    public enum Status: String, Sendable { case streaming, done, interrupted, failed }

    public let id: Int
    public var role: Role
    public var text: String
    public var spoken: [String]
    public var skipped: [SkippedSegment]
    public var status: Status
    public var date: Date

    public init(id: Int, role: Role, text: String, spoken: [String] = [], skipped: [SkippedSegment] = [],
                status: Status = .done, date: Date = Date()) {
        self.id = id
        self.role = role
        self.text = text
        self.spoken = spoken
        self.skipped = skipped
        self.status = status
        self.date = date
    }
}

/// A plain-words explanation of a pending request, written by a separate read-only Claude call.
public enum Explanation: Sendable, Equatable {
    case none
    case loading
    case ready(String)
    case unavailable
}

/// One assistant reply that arrived while the user was in another project.
public struct MissedMessage: Sendable, Equatable, Identifiable {
    public let entryID: Int
    public var id: Int { entryID }
    /// What was (or would have been) spoken, as sentences.
    public var sentences: [String]
    public var date: Date
}

/// What to do about replies that arrived while the user was in another project.
public enum CatchUpChoice: Sendable, Equatable {
    case fromFirstMissed
    case lastMessage
    case skip
}

/// A question to the user about giving Claude standing access to the project folder.
public struct GrantOffer: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case edit, shell }
    public enum Stage: Sendable, Equatable { case asking, confirming }
    public var folder: String
    public var kind: Kind
    public var stage: Stage
    /// The words PairVox says (and the banner shows) at this stage.
    public var text: String
}

/// What the engine reports back so the app can save or forget a grant.
public enum FolderGrantChange: Sendable, Equatable {
    case granted(path: String, shell: Bool)
    case declined(path: String)
}

public struct PendingPermission: Sendable, Equatable {
    public var request: PermissionRequest
    public var assessment: PermissionAssessment
    public var explanation: Explanation = .none
    /// Questions the user asked about this request before deciding, and the answers.
    public var questions: [AdvisorTurn] = []
    /// When the request arrived. A spoken yes stops counting after `Announcer.staleAfter`; a click still works.
    public var receivedAt: Date

    public init(request: PermissionRequest, assessment: PermissionAssessment, receivedAt: Date = Date()) {
        self.request = request
        self.assessment = assessment
        self.receivedAt = receivedAt
    }

    /// Older than the age limit every voice path shares (the announcer's and the phone link's).
    public func isStale(now: Date) -> Bool { now.timeIntervalSince(receivedAt) > Announcer.staleAfter }
}

public struct UsageSnapshot: Sendable, Equatable {
    public var turns = 0
    /// Only meaningful with an API key; subscription usage is shown as utilization.
    public var costUSD: Double = 0
    public var fiveHourUtilization: Double?
    public var sevenDayUtilization: Double?
    public var limitResetsAt: Date?
    public var limitStatus: String?
    public var sessionStarted = Date()
    public init() {}
}

/// Latency of the last turn, for the debug HUD and the CLI `--metrics` flag.
public struct TurnLatency: Sendable, Equatable {
    /// Send → first streamed token.
    public var firstToken: TimeInterval?
    /// Send → first utterance handed to TTS.
    public var firstUtterance: TimeInterval?
    /// Send → first audio actually playing.
    public var firstAudio: TimeInterval?
    /// Send → the first sound of any kind, an acknowledgement included: what the person actually waits for.
    public var firstSound: TimeInterval?
}

public struct EngineSnapshot: Sendable, Equatable {
    public var phase: EnginePhase = .starting
    public var transcript: [TranscriptEntry] = []
    public var pendingPermission: PendingPermission?
    public var grantOffer: GrantOffer?
    /// False while the user is working in a different project: this one stays silent.
    public var isActive = true
    /// Replies spoken-or-not that the user has not heard because they were elsewhere.
    public var missedMessages: [MissedMessage] = []
    /// The user has come back to a project with missed replies and has not yet chosen what to hear.
    public var awaitingCatchUpChoice = false
    /// Requests waiting behind the one shown; each is shown and spoken in turn once the current one is answered.
    public var queuedPermissions: [PendingPermission] = []
    public var queuedPermissionCount: Int { queuedPermissions.count }
    public var session: SessionInfo?
    public var usage = UsageSnapshot()
    public var speechMode: SpeechMode = .skipCode
    public var conversationMode: ConversationMode = .execute
    public var verbosity: Verbosity = .normal
    public var isClaudeWorking = false
    public var isSpeaking = false
    public var hasHeldBack = false
    public var authProblem: String?
    public var lastNotice: String?
    public var lastLatency: TurnLatency?
    public var speechRate: Double = 1.0
    public init() {}
}

/// Engine configuration (a subset of `AppSettings`, resolved for one project).
public struct EngineConfiguration: Sendable {
    public var projectRoot: String?
    public var speechMode: SpeechMode
    public var conversationMode: ConversationMode
    public var verbosity: Verbosity
    public var acknowledgements: Bool
    public var autoApproveLowRisk: Bool
    public var spokenHighRiskConfirmation: Bool
    /// Voice may also confirm requests Claude Code says need the screen (only with spoken confirmation on).
    public var voiceApprovesNeedsScreen: Bool
    /// A spoken yes answers a request from its one-line summary; the full command stays on screen.
    public var approveByVoiceFromSummary: Bool
    /// Ask a separate read-only Claude call to explain each request in plain words (uses a small amount of usage).
    public var explainRequests: Bool
    public var folderGrants: [FolderGrant]
    public var pronunciation: [String: String]
    public var speechRate: Double
    /// The most sentences read aloud per reply; the rest waits for "details". 0 means everything.
    public var spokenReplyLimit: Int
    /// Delay before a filler acknowledgement if nothing has been said yet.
    public var acknowledgementDelay: TimeInterval

    public init(projectRoot: String? = nil, speechMode: SpeechMode = .skipCode,
                conversationMode: ConversationMode = .execute, verbosity: Verbosity = .normal,
                acknowledgements: Bool = true, autoApproveLowRisk: Bool = false,
                spokenHighRiskConfirmation: Bool = false, voiceApprovesNeedsScreen: Bool = false,
                approveByVoiceFromSummary: Bool = true, explainRequests: Bool = true,
                folderGrants: [FolderGrant] = [], pronunciation: [String: String] = [:],
                speechRate: Double = 1.0, spokenReplyLimit: Int = 0, acknowledgementDelay: TimeInterval = 0.8) {
        self.projectRoot = projectRoot
        self.speechMode = speechMode
        self.conversationMode = conversationMode
        self.verbosity = verbosity
        self.acknowledgements = acknowledgements
        self.autoApproveLowRisk = autoApproveLowRisk
        self.spokenHighRiskConfirmation = spokenHighRiskConfirmation
        self.voiceApprovesNeedsScreen = voiceApprovesNeedsScreen
        self.approveByVoiceFromSummary = approveByVoiceFromSummary
        self.explainRequests = explainRequests
        self.folderGrants = folderGrants
        self.pronunciation = pronunciation
        self.speechRate = speechRate
        self.spokenReplyLimit = spokenReplyLimit
        self.acknowledgementDelay = acknowledgementDelay
    }

    public init(settings: AppSettings, project: String?) {
        self.init(projectRoot: project,
                  speechMode: settings.effectiveSpeechMode(for: project),
                  conversationMode: settings.effectiveConversationMode(for: project),
                  verbosity: settings.verbosity,
                  acknowledgements: settings.acknowledgements,
                  autoApproveLowRisk: settings.autoApproveLowRisk,
                  spokenHighRiskConfirmation: settings.spokenHighRiskConfirmation,
                  voiceApprovesNeedsScreen: settings.voiceApprovesNeedsScreen,
                  approveByVoiceFromSummary: settings.approveByVoiceFromSummary,
                  explainRequests: settings.explainRequests,
                  folderGrants: settings.folderGrants,
                  pronunciation: settings.pronunciation,
                  speechRate: settings.speechRate,
                  spokenReplyLimit: settings.spokenReplyLimit)
    }
}
