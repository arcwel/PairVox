// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import PairVoxCore
import PairVoxVoice
import SwiftUI

/// Everything the UI binds to. Owns the voice stack and, per open project,
/// one Claude Code session + conversation engine.
@MainActor
final class AppModel: ObservableObject {
    struct SetupState: Equatable {
        var checking = true
        var claudePath: String?
        var cliVersion: String?
        var microphone: VoicePermissions.Status = VoicePermissions.microphone
        var speechRecognition: VoicePermissions.Status = VoicePermissions.speechRecognition
        var audioError: String?

        var claudeFound: Bool { claudePath != nil }
    }

    @Published var settings: AppSettings {
        didSet { settingsChanged(from: oldValue) }
    }
    @Published private(set) var snapshot = EngineSnapshot()
    @Published private(set) var project: URL?
    @Published private(set) var setup = SetupState()
    @Published private(set) var whisperState: TranscriberState = .notLoaded
    @Published private(set) var kokoroStatus: ModelStore.Status = .missing
    @Published private(set) var inputLevel: Float = -90
    @Published private(set) var listeningMode: VoiceInputController.ListeningMode = .handsFree
    @Published private(set) var pushToTalkActive = false
    @Published private(set) var hasAPIKey = KeychainStore.readAPIKey() != nil
    @Published var showSetup = false
    @Published var errorMessage: String?

    let voice: VoiceStack
    private let store = SettingsStore()
    private var engine: ConversationEngine?
    private var input: VoiceInputController?
    private var output: VoiceSpeechOutput?
    private var snapshotTask: Task<Void, Never>?
    private var loginEnvironment: [String: String] = ProcessInfo.processInfo.environment
    private let hotKeys = HotKeyCenter()
    private let notifier = Notifier()
    private var notifiedPermissionID: String?
    private var turnsAtDeactivation = 0
    private var receivedFirstSnapshot = false
    /// True while copying engine-originated values into settings (don't echo them back).
    private var syncingFromEngine = false

    init() {
        let loaded = store.load()
        settings = loaded
        voice = VoiceStack(settings: loaded)
        listeningMode = loaded.handsFree ? .handsFree : .pushToTalk
        voice.onWhisperState = { [weak self] s in Task { @MainActor in self?.whisperState = s } }
        voice.onKokoroStatus = { [weak self] s in Task { @MainActor in self?.kokoroStatus = s } }
        Task { await bootstrap() }
    }

    // MARK: Startup

    private func bootstrap() async {
        loginEnvironment = await ShellEnvironment.loginShellEnvironment()
        await refreshSetup()

        if VoicePermissions.microphone == .notDetermined { _ = await VoicePermissions.requestMicrophone() }
        if VoicePermissions.speechRecognition == .notDetermined { _ = await VoicePermissions.requestSpeechRecognition() }
        setup.microphone = VoicePermissions.microphone
        setup.speechRecognition = VoicePermissions.speechRecognition
        notifier.requestAuthorization()

        hotKeys.onPress = { [weak self] in self?.pushToTalk(down: true) }
        hotKeys.onRelease = { [weak self] in self?.pushToTalk(down: false) }
        hotKeys.register()

        let whisperModel = settings.whisperModel
        let stack = voice
        Task.detached(priority: .utility) { await stack.prepareRecognition(model: whisperModel) }
        Task.detached(priority: .utility) { await stack.prepareKokoro() }

        if !setup.claudeFound || setup.microphone != .granted {
            showSetup = true
        } else if let last = settings.lastProject, FileManager.default.fileExists(atPath: last) {
            openProject(URL(fileURLWithPath: last))
        }
    }

    func refreshSetup() async {
        setup.checking = true
        let exe = ClaudeLocator.locate(override: settings.claudePathOverride, pathVariable: loginEnvironment["PATH"])
        setup.claudePath = exe?.path
        setup.cliVersion = nil
        if let exe { setup.cliVersion = await ClaudeLocator.version(of: exe, environment: loginEnvironment) }
        setup.microphone = VoicePermissions.microphone
        setup.speechRecognition = VoicePermissions.speechRecognition
        setup.checking = false
    }

    // MARK: Projects / sessions

    func chooseProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open Project"
        panel.message = "Choose the folder Claude Code should work in."
        if panel.runModal() == .OK, let url = panel.url {
            openProject(url)
        }
    }

    func openProject(_ url: URL) {
        closeSession()
        guard let path = setup.claudePath else {
            showSetup = true
            return
        }
        project = url
        settings.noteProjectOpened(url.path)

        let auth: AuthMode
        if settings.authKind == .apiKey {
            guard let key = KeychainStore.readAPIKey() else {
                errorMessage = "API-key mode is selected but no key is saved. Add one in Settings → Account."
                return
            }
            auth = .apiKey(key)
        } else {
            auth = .subscription
        }

        let projectPath = url.path
        let conversationMode = settings.effectiveConversationMode(for: projectPath)
        let launch = LaunchConfiguration(
            executable: URL(fileURLWithPath: path), workingDirectory: url, auth: auth,
            model: settings.effectiveModel(for: projectPath), permissionMode: conversationMode.permissionMode,
            appendSystemPrompt: SystemPrompts.voice, baseEnvironment: loginEnvironment)

        let output = VoiceSpeechOutput(audio: voice.audio, synthesizer: voice.synthesizer)
        let engine = ConversationEngine(configuration: EngineConfiguration(settings: settings, project: projectPath),
                                        authKind: auth.kind, output: output) { resume in
            var cfg = launch
            cfg.resumeSessionID = resume
            return ClaudeCLISession(configuration: cfg)
        }
        let input = VoiceInputController(audio: voice.audio, transcriber: voice.transcriber, engine: engine,
                                         endSilence: settings.endOfTurnSilence)
        input.setBargeInEnabled(settings.bargeInEnabled)
        input.setMode(listeningMode)
        input.onLevel = { [weak self] level in Task { @MainActor in self?.inputLevel = level } }
        input.onError = { [weak self] msg in Task { @MainActor in self?.errorMessage = msg } }
        output.onPlaybackActiveChange = { [weak input] active in input?.setPlaybackActive(active) }

        self.output = output
        self.engine = engine
        self.input = input

        do {
            try voice.audio.start()
            setup.audioError = nil
        } catch {
            setup.audioError = error.localizedDescription
            errorMessage = "Microphone unavailable: \(error.localizedDescription)"
        }

        snapshotTask = Task { [weak self] in
            for await snap in engine.snapshots {
                self?.receive(snap)
            }
        }
        Task { await engine.start() }

        // Bias speech recognition toward this project's names.
        let extra = settings.preferences(for: projectPath).vocabulary
        Task.detached(priority: .utility) { [weak input] in
            let words = extra + RepoVocabulary.scan(root: url)
            input?.setVocabulary(words)
        }
    }

    func closeSession() {
        snapshotTask?.cancel()
        snapshotTask = nil
        // Stop this session's audio now, not later from a background task that
        // could cut off the next session's speech on the shared audio engine.
        output?.stopAll()
        if let engine { Task { await engine.shutdown() } }
        input?.setMode(.muted)
        engine = nil
        input = nil
        output = nil
        snapshot = EngineSnapshot()
        receivedFirstSnapshot = false
    }

    func restartSession() {
        if let project { openProject(project) }
    }

    // MARK: Conversation actions

    func sendTyped(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let engine else { return }
        Task {
            await engine.userStartedSpeaking()
            await engine.userStoppedSpeaking()
            await engine.submit(t)
        }
    }

    func approve(always: Bool = false) { Task { await engine?.approvePending(always: always) } }
    func deny() { Task { await engine?.denyPending() } }
    func interrupt() { Task { await engine?.interruptClaude() } }
    func stopSpeaking() { Task { await engine?.stopSpeaking() } }
    func newSession() { Task { await engine?.newSession() } }
    func perform(_ command: VoiceCommand) { Task { await engine?.perform(command) } }

    func setSpeechMode(_ mode: SpeechMode) {
        settings.speechMode = mode // settingsChanged pushes it to the engine
    }

    func setConversationMode(_ mode: ConversationMode) {
        settings.conversationMode = mode
        Task { await engine?.setConversationMode(mode) }
    }

    func setModel(_ model: String?) {
        settings.model = model
        Task { await engine?.setModel(model) }
    }

    // MARK: Listening

    func pushToTalk(down: Bool) {
        guard let input else { return }
        if down {
            guard !pushToTalkActive else { return }
            pushToTalkActive = true
            if listeningMode == .muted { input.setMode(.pushToTalk) }
            input.pushToTalkBegan()
        } else {
            guard pushToTalkActive else { return }
            pushToTalkActive = false
            input.pushToTalkEnded()
            if listeningMode == .muted { input.setMode(.muted) }
        }
    }

    func setListeningMode(_ mode: VoiceInputController.ListeningMode) {
        listeningMode = mode
        input?.setMode(mode)
        if mode != .muted { settings.handsFree = mode == .handsFree }
    }

    func toggleMute() {
        setListeningMode(listeningMode == .muted ? (settings.handsFree ? .handsFree : .pushToTalk) : .muted)
    }

    // MARK: Account

    func saveAPIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        hasAPIKey = KeychainStore.saveAPIKey(trimmed)
        if settings.authKind == .apiKey { restartSession() }
    }

    func removeAPIKey() {
        KeychainStore.deleteAPIKey()
        hasAPIKey = false
        if settings.authKind == .apiKey { settings.authKind = .subscription }
    }

    /// Opens Terminal running `claude` so the user can sign in through Anthropic's own flow.
    func openTerminalForLogin() {
        let command = (setup.claudePath ?? "claude").replacingOccurrences(of: "\"", with: "\\\"")
        let script = "tell application \"Terminal\" to do script \"\(command)\"\ntell application \"Terminal\" to activate"
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
        if error != nil, let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
            NSWorkspace.shared.openApplication(at: terminal, configuration: .init())
        }
    }

    func downloadKokoroNow() {
        let stack = voice
        Task.detached(priority: .userInitiated) { await stack.prepareKokoro() }
    }

    func reloadWhisper() {
        let stack = voice
        let model = settings.whisperModel
        Task.detached(priority: .userInitiated) { await stack.prepareRecognition(model: model) }
    }

    // MARK: Internals

    private func receive(_ snap: EngineSnapshot) {
        let previous = snapshot
        snapshot = snap
        // Voice commands ("faster", "summary mode") change these inside the engine;
        // mirror them into settings (but not the engine's initial per-project values).
        if receivedFirstSnapshot {
            syncingFromEngine = true
            if abs(snap.speechRate - settings.speechRate) > 0.001 { settings.speechRate = snap.speechRate }
            if snap.speechMode != settings.speechMode { settings.speechMode = snap.speechMode }
            syncingFromEngine = false
        }
        receivedFirstSnapshot = true
        if snap.phase == .needsSetup && previous.phase != .needsSetup { showSetup = true }

        // Background notifications.
        if !NSApp.isActive {
            if let p = snap.pendingPermission, p.request.requestID != notifiedPermissionID {
                notifiedPermissionID = p.request.requestID
                notifier.post(title: "Claude needs your OK", body: p.assessment.summary, id: p.request.requestID)
            }
            if previous.isClaudeWorking && !snap.isClaudeWorking && snap.usage.turns > turnsAtDeactivation {
                let last = snap.transcript.last { $0.role == .assistant }?.text ?? "Done."
                notifier.post(title: "Claude finished", body: String(last.prefix(140)))
            }
        } else {
            turnsAtDeactivation = snap.usage.turns
        }
    }

    private func settingsChanged(from old: AppSettings) {
        try? store.save(settings)
        voice.apply(settings)
        input?.setBargeInEnabled(settings.bargeInEnabled)
        input?.setEndSilence(settings.endOfTurnSilence)
        if !syncingFromEngine, old.speechRate != settings.speechRate {
            let rate = settings.speechRate
            Task { await engine?.setSpeechRate(rate) }
        }
        if !syncingFromEngine, old.speechMode != settings.speechMode {
            let mode = settings.speechMode
            Task { await engine?.setSpeechMode(mode) }
        }
        if old.verbosity != settings.verbosity {
            let v = settings.verbosity
            Task { await engine?.setVerbosity(v) }
        }
        if old.pronunciation != settings.pronunciation {
            let dict = settings.pronunciation
            Task { await engine?.setPronunciation(dict) }
        }
        if old.whisperModel != settings.whisperModel || (old.transcriber == .apple && settings.transcriber != .apple) {
            reloadWhisper()
        }
        if old.synthesizer == .system && settings.synthesizer != .system { downloadKokoroNow() }
        if old.claudePathOverride != settings.claudePathOverride {
            Task { await refreshSetup() }
        }
        // Auth changes need a fresh process.
        if old.authKind != settings.authKind { restartSession() }
    }

    var statusLine: String {
        switch snapshot.phase {
        case .starting: return "Starting…"
        case .idle: return listeningMode == .muted ? "Muted" : (listeningMode == .pushToTalk ? "Hold ⌃⌥Space to talk" : "Listening")
        case .listening: return "Hearing you…"
        case .transcribing: return "Transcribing…"
        case .thinking: return "Thinking…"
        case .working: return "Working…"
        case .speaking: return "Speaking"
        case .awaitingPermission: return "Needs your OK"
        case .needsSetup: return "Setup needed"
        }
    }
}
