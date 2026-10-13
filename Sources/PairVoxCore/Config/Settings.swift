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

    public init(speechMode: SpeechMode? = nil, conversationMode: ConversationMode? = nil, model: String? = nil,
                vocabulary: [String] = []) {
        self.speechMode = speechMode
        self.conversationMode = conversationMode
        self.model = model
        self.vocabulary = vocabulary
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

    // Voice
    public var transcriber: TranscriberChoice = .automatic
    public var whisperModel = "openai_whisper-small.en"
    public var synthesizer: SynthesizerChoice = .automatic
    public var kokoroVoice = "af_heart"
    public var systemVoiceIdentifier: String? = nil
    public var speechRate: Double = 1.0
    public var bargeInEnabled = true
    public var handsFree = true
    public var endOfTurnSilence: Double = 0.65
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
    /// Experimental: capture and play on separate audio stacks so a Bluetooth headset's microphone and speaker
    /// are not joined into one fragile aggregate device. No echo cancellation in this mode.
    public var separateAudioEngines = false

    // Diagnostics (logs stay on this Mac until the user exports them)
    public var verboseLogging = false
    /// Put what you say and what Claude says into the log. Off by default: logs record lengths only.
    public var logConversationText = false
    /// Record the audio PairVox plays into the log folder, to diagnose crackle. Off by default.
    public var recordPlaybackAudio = false

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
        transcriber = (try? c.decode(TranscriberChoice.self, forKey: .transcriber)) ?? d.transcriber
        let decodedWhisper = (try? c.decode(String.self, forKey: .whisperModel)) ?? d.whisperModel
        whisperModel = VoiceCatalog.whisperModelIDs.contains(decodedWhisper) ? decodedWhisper : VoiceCatalog.defaultWhisperModel
        synthesizer = (try? c.decode(SynthesizerChoice.self, forKey: .synthesizer)) ?? d.synthesizer
        kokoroVoice = (try? c.decode(String.self, forKey: .kokoroVoice)) ?? d.kokoroVoice
        systemVoiceIdentifier = try? c.decode(String.self, forKey: .systemVoiceIdentifier)
        speechRate = (try? c.decode(Double.self, forKey: .speechRate)) ?? d.speechRate
        bargeInEnabled = (try? c.decode(Bool.self, forKey: .bargeInEnabled)) ?? d.bargeInEnabled
        handsFree = (try? c.decode(Bool.self, forKey: .handsFree)) ?? d.handsFree
        endOfTurnSilence = (try? c.decode(Double.self, forKey: .endOfTurnSilence)) ?? d.endOfTurnSilence
        pronunciation = (try? c.decode([String: String].self, forKey: .pronunciation)) ?? [:]
        echoCancellation = (try? c.decode(Bool.self, forKey: .echoCancellation)) ?? d.echoCancellation
        outputDeviceUID = try? c.decode(String.self, forKey: .outputDeviceUID)
        microphoneEnabled = (try? c.decode(Bool.self, forKey: .microphoneEnabled)) ?? d.microphoneEnabled
        separateAudioEngines = (try? c.decode(Bool.self, forKey: .separateAudioEngines)) ?? d.separateAudioEngines
        verboseLogging = (try? c.decode(Bool.self, forKey: .verboseLogging)) ?? d.verboseLogging
        logConversationText = (try? c.decode(Bool.self, forKey: .logConversationText)) ?? d.logConversationText
        recordPlaybackAudio = (try? c.decode(Bool.self, forKey: .recordPlaybackAudio)) ?? d.recordPlaybackAudio
    }
}

/// Loads and saves `AppSettings` as JSON in Application Support.
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
        if !isPrivateToUser(url) { s.claudePathOverride = nil }
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
