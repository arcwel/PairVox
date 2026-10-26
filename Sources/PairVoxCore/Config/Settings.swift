// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Which speech-to-text engine to use.
public enum TranscriberChoice: String, Sendable, Codable, CaseIterable {
    /// WhisperKit when its model is ready, Apple speech otherwise.
    case automatic
    case whisperKit
    case apple
}

/// Which text-to-speech engine to use.
public enum SynthesizerChoice: String, Sendable, Codable, CaseIterable {
    /// Kokoro when its model is downloaded and loads, system voice otherwise.
    case automatic
    case kokoro
    case system
}

/// Per-project overrides.
public struct ProjectPreferences: Sendable, Codable, Equatable {
    public var speechMode: SpeechMode?
    public var conversationMode: ConversationMode?
    public var model: String?
    /// Extra words to bias speech recognition toward (names, acronyms).
    public var vocabulary: [String]
    /// Requests from this project are never announced aloud (they still show in the inbox and badges).
    public var muteAnnouncements: Bool

    public init(speechMode: SpeechMode? = nil, conversationMode: ConversationMode? = nil, model: String? = nil,
                vocabulary: [String] = [], muteAnnouncements: Bool = false) {
        self.muteAnnouncements = muteAnnouncements
        self.speechMode = speechMode
        self.conversationMode = conversationMode
        self.model = model
        self.vocabulary = vocabulary
    }
}

extension ProjectPreferences {
    enum CodingKeys: String, CodingKey { case speechMode, conversationMode, model, vocabulary, muteAnnouncements }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(speechMode: try? c.decode(SpeechMode.self, forKey: .speechMode),
                  conversationMode: try? c.decode(ConversationMode.self, forKey: .conversationMode),
                  model: try? c.decode(String.self, forKey: .model),
                  vocabulary: (try? c.decode([String].self, forKey: .vocabulary)) ?? [],
                  muteAnnouncements: (try? c.decode(Bool.self, forKey: .muteAnnouncements)) ?? false)
    }
}

/// User settings, persisted as JSON. Secrets (the API key) are NOT stored here;
/// the macOS app keeps them in the Keychain.
public struct AppSettings: Sendable, Codable, Equatable {
    // Session
    public var authKind: AuthKind = .subscription
    public var model: String? = nil
    public var claudePathOverride: String? = nil
    public var recentProjects: [String] = []
    public var lastProject: String? = nil
    public var projectPreferences: [String: ProjectPreferences] = [:]

    // Conversation
    public var speechMode: SpeechMode = .skipCode
    public var conversationMode: ConversationMode = .execute
    public var verbosity: Verbosity = .normal
    public var acknowledgements = true
    public var autoApproveLowRisk = false
    /// Whether the child may load the opened project's own Claude Code settings, hooks and MCP servers.
    /// Off by default: those files come with the repository and can act outside PairVox's approval prompts.
    public var trustProjectConfiguration = false
    /// Lets the user approve a high-risk request by saying "confirm high risk" instead of pressing the button.
    /// Off by default. PairVox's own prompt contains that phrase, so speech it plays and the microphone hears can
    /// satisfy it; turning this on accepts that.
    public var spokenHighRiskConfirmation = false
    /// Explain each permission request in plain words with a small separate Claude call.
    public var explainRequests = true
    /// Folders the user has let Claude work in without asking. Only PairVox itself writes this list.
    public var folderGrants: [FolderGrant] = []
    /// Folders where the user said no to the one-time offer, so it is not repeated.
    public var declinedGrantFolders: [String] = []
    /// Projects that were open when PairVox last quit, in order, so they come back.
    public var openProjects: [String] = []
    /// Hide the Dock icon and window; PairVox lives in the menu bar (and the small floating window).
    public var menuBarOnly = false
    /// Speak a request from another project at a break in the current conversation.
    public var announceOtherProjects = true
    public var announceQuietSeconds: Double = 2
    /// Say the project's name when announcing (off: "another project").
    public var speakProjectNames = true
    /// Voice may also confirm requests Claude Code says need the screen. Off until switched on (and confirmed twice).
    public var voiceApprovesNeedsScreen = false
    /// A spoken yes answers a request from its one-line summary (file name, first command step); the full command
    /// is on screen. On by default: a long path read aloud tells a listener nothing. Off, long commands need a click.
    public var approveByVoiceFromSummary = true
    /// Which kinds of command take one spoken yes, two, or a tap (Settings, Approval gates).
    public var approvalGates = ApprovalGates()
    /// Ask for Touch ID or the login password after the spoken high-risk phrase.
    public var macSecondConfirmation = false
    /// Lets paired phones connect over Tailscale. Off until the owner turns it on.
    public var phoneLinkEnabled = false
    public var phoneLinkPort = 47821
    /// A short sound when Claude starts working and when it finishes.
    public var earcons = false
    /// The key held with ⌃⌥ to talk, from `pushToTalkKeys`.
    public var pushToTalkKey = AppSettings.pushToTalkKeys[0]
    public static let pushToTalkKeys = ["space", "t", "v", "g", "b"]

    // Voice
    public var transcriber: TranscriberChoice = .automatic
    public var whisperModel = "openai_whisper-small.en"
    public var synthesizer: SynthesizerChoice = .automatic
    public var kokoroVoice = "af_heart"
    public var systemVoiceIdentifier: String? = nil
    public var speechRate: Double = 1.0
    /// The most sentences read aloud in one reply; the rest is kept for "details". 0 reads everything.
    public var spokenReplyLimit = 15
    /// Cut the silence the voice puts before and after each sentence, so replies start sooner and sentences follow each
    /// other closely. On by default; turn it off if word endings sound clipped.
    public var trimSentenceSilence = true
    public var bargeInEnabled = true
    public var handsFree = true
    /// Seconds of silence that end a spoken turn. 1.5 since 2026-10-25: at 0.65 PairVox took a pause mid-sentence for
    /// the end, replied, and the rest of the sentence arrived as a second, partial request.
    public var endOfTurnSilence: Double = 1.5
    public static let endOfTurnSilenceRange: ClosedRange<Double> = 0.4...3.0
    /// Start transcribing after a short silence (0.3 s) instead of waiting for the whole end-of-turn silence, and discard
    /// the result if you keep talking. Saves up to about a third of a second per turn. Experimental.
    public var earlyTranscription = true
    public var pronunciation: [String: String] = [:]
    /// Voice processing (echo cancellation and noise suppression). Turn off to compare audio quality,
    /// or if a headset sounds distorted; barge-in on speakers then needs headphones or push to talk.
    public var echoCancellation = true
    /// Where PairVox plays. nil = automatic: the system's output, or the same headset as the microphone
    /// when that is a Bluetooth headset. Otherwise a Core Audio device UID.
    public var outputDeviceUID: String? = nil
    /// Off = playback only. A Bluetooth headset then stays in its high-quality music mode (an open
    /// microphone forces the narrow, fragile call mode). You can still type to Claude.
    public var microphoneEnabled = true
    /// Minutes without conversation before a hands-free microphone goes to sleep (muted until turned back on).
    /// 0 = never. One of `MicHibernation.minuteChoices`.
    public var micSleepMinutes = MicHibernation.defaultMinutes
    /// Experimental: capture and play on separate audio stacks so a Bluetooth headset's microphone and speaker
    /// are not joined into one fragile aggregate device. No echo cancellation in this mode.
    public var separateAudioEngines = false

    // Diagnostics (logs stay on this Mac until the user exports them)
    public var verboseLogging = false
    /// Put what you say and what Claude says into the log. Off by default: logs record lengths only.
    public var logConversationText = false
    /// Record the audio PairVox plays into the log folder, to diagnose crackle. Off by default.
    public var recordPlaybackAudio = false
    /// Keep the last seconds of microphone and playback audio in memory and save them to the log folder when the
    /// microphone hears a howl (acoustic feedback) while PairVox is speaking. On by default; nothing is written
    /// unless a howl is detected.
    public var captureFeedbackAudio = true

    public init() {}

    public struct ModelChoice: Identifiable, Hashable, Sendable {
        public var id: String { model ?? "default" }
        public let model: String?
        public let label: String
    }

    public static let modelChoices: [ModelChoice] = [
        ModelChoice(model: nil, label: "Default"),
        ModelChoice(model: "sonnet", label: "Sonnet"),
        ModelChoice(model: "opus", label: "Opus"),
        ModelChoice(model: "haiku", label: "Haiku (fastest)"),
    ]

    public func preferences(for project: String?) -> ProjectPreferences {
        guard let project else { return ProjectPreferences() }
        return projectPreferences[project] ?? ProjectPreferences()
    }

    public func effectiveSpeechMode(for project: String?) -> SpeechMode {
        preferences(for: project).speechMode ?? speechMode
    }

    public func effectiveConversationMode(for project: String?) -> ConversationMode {
        preferences(for: project).conversationMode ?? conversationMode
    }

    public func effectiveModel(for project: String?) -> String? {
        preferences(for: project).model ?? model
    }

    public mutating func noteProjectOpened(_ path: String) {
        lastProject = path
        recentProjects.removeAll { $0 == path }
        recentProjects.insert(path, at: 0)
        if recentProjects.count > 12 { recentProjects.removeLast(recentProjects.count - 12) }
    }

    // Decode leniently so new fields never wipe old settings.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        authKind = (try? c.decode(AuthKind.self, forKey: .authKind)) ?? d.authKind
        model = try? c.decode(String.self, forKey: .model)
        claudePathOverride = try? c.decode(String.self, forKey: .claudePathOverride)
        recentProjects = (try? c.decode([String].self, forKey: .recentProjects)) ?? d.recentProjects
        lastProject = try? c.decode(String.self, forKey: .lastProject)
        projectPreferences = (try? c.decode([String: ProjectPreferences].self, forKey: .projectPreferences)) ?? [:]
        speechMode = (try? c.decode(SpeechMode.self, forKey: .speechMode)) ?? d.speechMode
        conversationMode = (try? c.decode(ConversationMode.self, forKey: .conversationMode)) ?? d.conversationMode
        verbosity = (try? c.decode(Verbosity.self, forKey: .verbosity)) ?? d.verbosity
        acknowledgements = (try? c.decode(Bool.self, forKey: .acknowledgements)) ?? d.acknowledgements
        autoApproveLowRisk = (try? c.decode(Bool.self, forKey: .autoApproveLowRisk)) ?? d.autoApproveLowRisk
        trustProjectConfiguration = (try? c.decode(Bool.self, forKey: .trustProjectConfiguration)) ?? d.trustProjectConfiguration
        spokenHighRiskConfirmation = (try? c.decode(Bool.self, forKey: .spokenHighRiskConfirmation)) ?? d.spokenHighRiskConfirmation
        explainRequests = (try? c.decode(Bool.self, forKey: .explainRequests)) ?? d.explainRequests
        folderGrants = (try? c.decode([FolderGrant].self, forKey: .folderGrants)) ?? d.folderGrants
        declinedGrantFolders = (try? c.decode([String].self, forKey: .declinedGrantFolders)) ?? d.declinedGrantFolders
        openProjects = (try? c.decode([String].self, forKey: .openProjects)) ?? d.openProjects
        menuBarOnly = (try? c.decode(Bool.self, forKey: .menuBarOnly)) ?? d.menuBarOnly
        announceOtherProjects = (try? c.decode(Bool.self, forKey: .announceOtherProjects)) ?? d.announceOtherProjects
        let quiet = (try? c.decode(Double.self, forKey: .announceQuietSeconds)) ?? d.announceQuietSeconds
        announceQuietSeconds = min(max(quiet, 0.5), 30)
        speakProjectNames = (try? c.decode(Bool.self, forKey: .speakProjectNames)) ?? d.speakProjectNames
        voiceApprovesNeedsScreen = (try? c.decode(Bool.self, forKey: .voiceApprovesNeedsScreen)) ?? d.voiceApprovesNeedsScreen
        approveByVoiceFromSummary = (try? c.decode(Bool.self, forKey: .approveByVoiceFromSummary)) ?? d.approveByVoiceFromSummary
        approvalGates = (try? c.decode(ApprovalGates.self, forKey: .approvalGates)) ?? d.approvalGates
        macSecondConfirmation = (try? c.decode(Bool.self, forKey: .macSecondConfirmation)) ?? d.macSecondConfirmation
        phoneLinkEnabled = (try? c.decode(Bool.self, forKey: .phoneLinkEnabled)) ?? d.phoneLinkEnabled
        let decodedPort = (try? c.decode(Int.self, forKey: .phoneLinkPort)) ?? d.phoneLinkPort
        phoneLinkPort = (1024...65535).contains(decodedPort) ? decodedPort : d.phoneLinkPort
        earcons = (try? c.decode(Bool.self, forKey: .earcons)) ?? d.earcons
        let decodedKey = (try? c.decode(String.self, forKey: .pushToTalkKey)) ?? d.pushToTalkKey
        pushToTalkKey = AppSettings.pushToTalkKeys.contains(decodedKey) ? decodedKey : d.pushToTalkKey
        transcriber = (try? c.decode(TranscriberChoice.self, forKey: .transcriber)) ?? d.transcriber
        let decodedWhisper = (try? c.decode(String.self, forKey: .whisperModel)) ?? d.whisperModel
        whisperModel = VoiceCatalog.whisperModelIDs.contains(decodedWhisper) ? decodedWhisper : VoiceCatalog.defaultWhisperModel
        synthesizer = (try? c.decode(SynthesizerChoice.self, forKey: .synthesizer)) ?? d.synthesizer
        kokoroVoice = (try? c.decode(String.self, forKey: .kokoroVoice)) ?? d.kokoroVoice
        systemVoiceIdentifier = try? c.decode(String.self, forKey: .systemVoiceIdentifier)
        speechRate = (try? c.decode(Double.self, forKey: .speechRate)) ?? d.speechRate
        spokenReplyLimit = max(0, (try? c.decode(Int.self, forKey: .spokenReplyLimit)) ?? d.spokenReplyLimit)
        trimSentenceSilence = (try? c.decode(Bool.self, forKey: .trimSentenceSilence)) ?? d.trimSentenceSilence
        bargeInEnabled = (try? c.decode(Bool.self, forKey: .bargeInEnabled)) ?? d.bargeInEnabled
        handsFree = (try? c.decode(Bool.self, forKey: .handsFree)) ?? d.handsFree
        // A saved value below one second is the old 0.65 default or close to it; it cut people off, so it moves to the
        // new default once. Longer values were chosen on purpose and are kept.
        let silence = (try? c.decode(Double.self, forKey: .endOfTurnSilence)) ?? d.endOfTurnSilence
        endOfTurnSilence = silence < 1.0 ? d.endOfTurnSilence : min(silence, Self.endOfTurnSilenceRange.upperBound)
        earlyTranscription = (try? c.decode(Bool.self, forKey: .earlyTranscription)) ?? d.earlyTranscription
        pronunciation = (try? c.decode([String: String].self, forKey: .pronunciation)) ?? [:]
        echoCancellation = (try? c.decode(Bool.self, forKey: .echoCancellation)) ?? d.echoCancellation
        outputDeviceUID = try? c.decode(String.self, forKey: .outputDeviceUID)
        microphoneEnabled = (try? c.decode(Bool.self, forKey: .microphoneEnabled)) ?? d.microphoneEnabled
        let decodedSleep = (try? c.decode(Int.self, forKey: .micSleepMinutes)) ?? d.micSleepMinutes
        micSleepMinutes = MicHibernation.minuteChoices.contains(decodedSleep) ? decodedSleep : d.micSleepMinutes
        separateAudioEngines = (try? c.decode(Bool.self, forKey: .separateAudioEngines)) ?? d.separateAudioEngines
        verboseLogging = (try? c.decode(Bool.self, forKey: .verboseLogging)) ?? d.verboseLogging
        logConversationText = (try? c.decode(Bool.self, forKey: .logConversationText)) ?? d.logConversationText
        recordPlaybackAudio = (try? c.decode(Bool.self, forKey: .recordPlaybackAudio)) ?? d.recordPlaybackAudio
        captureFeedbackAudio = (try? c.decode(Bool.self, forKey: .captureFeedbackAudio)) ?? d.captureFeedbackAudio
    }
}

/// Loads and saves `AppSettings` as JSON in Application Support.
extension AppSettings {
    /// Settings keys whose values name a folder, a project or a person. Kept out of diagnostics and logs.
    public static let pathBearingKeys: Set<String> = ["recentProjects", "lastProject", "projectPreferences", "pronunciation",
                                                      "claudePathOverride", "folderGrants", "declinedGrantFolders", "openProjects"]
}

public struct SettingsStore: Sendable {
    public let url: URL

    public init(url: URL = SettingsStore.defaultURL()) {
        self.url = url
    }

    public static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config")
        return base.appendingPathComponent("PairVox", isDirectory: true).appendingPathComponent("settings.json")
    }

    public func load() -> AppSettings {
        guard let data = try? Data(contentsOf: url),
              var s = try? JSONDecoder().decode(AppSettings.self, from: data) else { return AppSettings() }
        // A settings file that other users or groups can write, or that another user owns, is not trusted to name
        // the program that receives the API key.
        // The same goes for every standing consent: a file someone else could write cannot grant access.
        if !isPrivateToUser(url) {
            s.claudePathOverride = nil
            s.folderGrants = []
            s.trustProjectConfiguration = false
            s.autoApproveLowRisk = false
            s.spokenHighRiskConfirmation = false
            s.phoneLinkEnabled = false
            s.voiceApprovesNeedsScreen = false
            s.approveByVoiceFromSummary = false
            s.approvalGates = .strictest
        }
        return s
    }

    public func save(_ settings: AppSettings) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(settings).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func isPrivateToUser(_ file: URL) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: file.path) else { return false }
        let uid = (attrs[.ownerAccountID] as? NSNumber)?.uint32Value ?? .max
        let mode = (attrs[.posixPermissions] as? NSNumber)?.uint16Value ?? 0o777
        return uid == getuid() && mode & 0o022 == 0
    }
}
