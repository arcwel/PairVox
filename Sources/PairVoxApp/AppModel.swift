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
    @Published private(set) var previewingVoice: String?
    /// False when no microphone is being captured (none plugged in, or permission not granted yet).
    /// PairVox still speaks, and typed messages still work.
    @Published private(set) var microphoneAvailable = true
    @Published var showSetup = false
    /// Bumped by the "Type Instead of Talking" shortcut; the control bar focuses its text field.
    @Published private(set) var focusInputTick = 0
    @Published var errorMessage: String?

    let voice: VoiceStack
    private let store = SettingsStore()
    private var engine: ConversationEngine?
    private var input: VoiceInputController?
    private var output: VoiceSpeechOutput?
    private var snapshotTask: Task<Void, Never>?
    private var loginEnvironment: [String: String] = ProcessInfo.processInfo.environment
    private let hotKeys = HotKeyCenter()
    private let log = DiagnosticLog.shared
    private var audioTestOutput: VoiceSpeechOutput?
    private let notifier = Notifier()
    private var notifiedPermissionID: String?
    private var turnsAtDeactivation = 0
    private var receivedFirstSnapshot = false
    /// True while copying engine-originated values into settings (don't echo them back).
    private var syncingFromEngine = false

    init() {
        let loaded = store.load()
        settings = loaded
        let stack = VoiceStack(settings: loaded)
        stack.audio.outputDeviceUID = loaded.outputDeviceUID
        stack.audio.voiceProcessingEnabled = loaded.echoCancellation
        stack.audio.recordPlayback = loaded.recordPlaybackAudio
        voice = stack
        Self.configureDiagnostics(loaded)
        listeningMode = loaded.handsFree ? .handsFree : .pushToTalk
        voice.onWhisperState = { [weak self] s in Task { @MainActor in self?.whisperState = s } }
        voice.onKokoroStatus = { [weak self] s in Task { @MainActor in self?.kokoroStatus = s } }
        Task { await bootstrap() }
    }

    // MARK: Startup

    private func bootstrap() async {
        logLaunch()
        // Model loads don't need any permission, so they must not wait behind the prompts below.
        let whisperModel = settings.whisperModel
        let stack = voice
        Task.detached(priority: .utility) { await stack.prepareRecognition(model: whisperModel) }
        Task.detached(priority: .utility) { await stack.prepareKokoro() }

        loginEnvironment = await ShellEnvironment.loginShellEnvironment()
        await refreshSetup()

        if VoicePermissions.microphone == .notDetermined { _ = await VoicePermissions.requestMicrophone() }
        if VoicePermissions.speechRecognition == .notDetermined { _ = await VoicePermissions.requestSpeechRecognition() }
        setup.microphone = VoicePermissions.microphone
        setup.speechRecognition = VoicePermissions.speechRecognition
        notifier.requestAuthorization()

        hotKeys.onPress = { [weak self] id in self?.globalHotKey(id, down: true) }
        hotKeys.onRelease = { [weak self] id in self?.globalHotKey(id, down: false) }
        for key in Shortcuts.global {
            let ok = hotKeys.register(id: key.id.rawValue, keyCode: UInt32(key.keyCode), modifiers: key.carbonModifiers)
            log.log(ok ? .info : .warning, .hotkey, "register", ["key": .string(key.display), "action": .string(key.title), "ok": .bool(ok)])
        }

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

        voice.audio.onCaptureAvailabilityChange = { [weak self] captured in
            Task { @MainActor in
                guard let self else { return }
                self.microphoneAvailable = captured
                if captured {
                    self.setup.audioError = nil
                } else if VoicePermissions.microphone == .granted, self.settings.microphoneEnabled {
                    self.setup.audioError = "No microphone found. Plug in a microphone or headset to talk; typing and spoken replies still work."
                }
            }
        }
        voice.audio.onVoiceProcessingAutoDisabled = { [weak self] in
            Task { @MainActor in
                self?.errorMessage = "This audio device kept restarting, so PairVox turned echo cancellation off for this session. Use headphones, or push to talk."
            }
        }
        voice.audio.onPlaybackDropped = { [weak self] in
            Task { @MainActor in
                guard let self, self.errorMessage == nil else { return }
                self.errorMessage = "PairVox can't play sound: the audio engine isn't running. Check the output device, then reopen the project."
            }
        }
        startAudio()

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

    /// Starts audio. Playback always starts so replies are spoken; capture starts only with microphone
    /// permission and a microphone. Without permission the engine's own error (a bare CoreAudio code)
    /// says nothing useful, so ask or explain first.
    private func startAudio() {
        switch VoicePermissions.microphone {
        case .denied:
            let msg = "Microphone access is off for PairVox. Turn it on in System Settings → Privacy & Security → Microphone, then reopen the project."
            setup.microphone = .denied
            setup.audioError = msg
            errorMessage = msg
            showSetup = true
            startAudioEngine(capture: false)
        case .notDetermined:
            startAudioEngine(capture: false)
            Task {
                _ = await VoicePermissions.requestMicrophone()
                await refreshSetup()
                startAudio()
            }
        case .granted:
            startAudioEngine(capture: settings.microphoneEnabled)
        }
    }

    private func startAudioEngine(capture: Bool) {
        let audio = voice.audio
        audio.voiceProcessingEnabled = settings.echoCancellation
        audio.outputDeviceUID = settings.outputDeviceUID
        do {
            if audio.isRunning, capture != audio.captureAvailable {
                try audio.restart(captureWanted: capture)   // keeps any speech queued meanwhile
            } else {
                try audio.start(captureWanted: capture)
            }
            if capture, audio.captureAvailable {
                setup.audioError = nil
                // A headset needs no echo cancellation, so only a real failure is worth a message.
                if settings.echoCancellation, !audio.echoCancellationActive, audio.voiceProcessingSkipReason == nil {
                    errorMessage = "Echo cancellation is unavailable on this audio route, so PairVox can hear itself on speakers. Use headphones, or turn off barge-in in Settings."
                }
            }
        } catch {
            setup.audioError = error.localizedDescription
            errorMessage = "Audio unavailable: \(error.localizedDescription)"
        }
    }

    // MARK: Shortcuts

    /// Global hotkeys (⌃⌥ + key) work while another app is in front.
    private func globalHotKey(_ raw: UInt32, down: Bool) {
        guard let id = GlobalHotKey.ID(rawValue: raw) else { return }
        log.log(.info, .hotkey, "global", ["id": "\(id)", "down": .bool(down)])
        switch id {
        case .pushToTalk: pushToTalk(down: down)
        case .stopSpeaking: if down { stopSpeaking() }
        case .toggleMute: if down { toggleMute() }
        case .interrupt: if down { interrupt() }
        }
    }

    func focusInputField() { focusInputTick += 1 }

    /// Keyboard approval is never offered for high-risk requests: those need a click on the card.
    var canApproveWithKeyboard: Bool {
        guard let pending = snapshot.pendingPermission else { return false }
        return pending.assessment.risk != .high
    }

    func changeSpeechRate(faster: Bool) { perform(faster ? .faster : .slower) }

    // MARK: Diagnostics

    private static func configureDiagnostics(_ settings: AppSettings) {
        DiagnosticLog.shared.configure(.init(directory: DiagnosticsExporter.logDirectory,
                                             minLevel: settings.verboseLogging ? .debug : .info,
                                             includeContent: settings.logConversationText))
    }

    private func logLaunch() {
        let info = Bundle.main.infoDictionary ?? [:]
        log.log(.info, .app, "app.launch",
                ["version": .string("\(info["CFBundleShortVersionString"] ?? "?") (\(info["CFBundleVersion"] ?? "?"))"),
                 "macOS": .string(ProcessInfo.processInfo.operatingSystemVersionString),
                 "verbose": .bool(settings.verboseLogging), "conversationText": .bool(settings.logConversationText),
                 "recordPlayback": .bool(settings.recordPlaybackAudio), "echoCancellation": .bool(settings.echoCancellation)])
    }

    /// Setting names and values, minus anything that names a place or a person.
    private func logSettingChanges(from old: AppSettings) {
        let skip: Set<String> = ["recentProjects", "lastProject", "projectPreferences", "pronunciation", "claudePathOverride"]
        func dict(_ s: AppSettings) -> [String: Any] {
            (try? JSONEncoder().encode(s)).flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } ?? [:]
        }
        let a = dict(old), b = dict(settings)
        var changed: [String: LogValue] = [:]
        for (key, value) in b where !skip.contains(key) && "\(a[key] ?? "")" != "\(value)" {
            changed[key] = .string("\(value)")
        }
        if !changed.isEmpty { log.log(.info, .app, "settings.changed", changed) }
    }

    func exportDiagnostics() {
        let s = DiagnosticsExporter.Snapshot(
            settings: settings, claudePath: setup.claudePath, claudeVersion: setup.cliVersion,
            microphone: "\(setup.microphone)", speechRecognition: "\(setup.speechRecognition)",
            whisperState: "\(whisperState)", kokoroStatus: "\(kokoroStatus)", project: project?.path)
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let zip = try DiagnosticsExporter.export(s)
                await MainActor.run { NSWorkspace.shared.activateFileViewerSelecting([zip]) }
            } catch {
                await MainActor.run { self?.errorMessage = error.localizedDescription }
            }
        }
    }

    /// Speaks about a minute of fixed text through the real synthesis and playback path, with no model call.
    /// Used to reproduce and measure audio problems (noise, dropouts) on demand: read the log afterwards.
    func playAudioTest() {
        if !voice.audio.isRunning { startAudio() }
        let lines = [
            "This is the PairVox audio test. I will read a few sentences so we can check the sound.",
            "The quick brown fox jumps over the lazy dog, and then it sits quietly by the river.",
            "She sells seashells by the seashore, and the thick fog fizzled before the sun came up.",
            "Numbers matter too: one, two, three, four, five, six, seven, eight, nine, ten.",
            "If you hear crackling, static, or sudden loud noise, note roughly how many seconds in it happened.",
            "A steady voice should sound the same from the first word to the last, with no hiss between sentences.",
            "Now a longer sentence that keeps going for a while, so any dropout in the middle of a phrase would be easy to notice, because nothing should interrupt it.",
            "Peter Piper picked a peck of pickled peppers, and the sixth sick sheikh's sixth sheep is sick.",
            "Almost done. A few more sentences remain, then the test ends with a short goodbye.",
            "The audio engine is running, the voice is synthesized on this Mac, and nothing leaves the machine.",
            "Thank you for listening. This is the end of the PairVox audio test.",
        ]
        log.log(.info, .app, "audio.test.start", ["sentences": .int(lines.count)])
        let out = VoiceSpeechOutput(audio: voice.audio, synthesizer: voice.synthesizer)
        out.setRate(settings.speechRate)
        for (i, text) in lines.enumerated() { out.enqueue(Utterance(id: 9_000 + i, text: text, kind: .prose)) }
        audioTestOutput = out
    }

    func revealLogs() {
        try? FileManager.default.createDirectory(at: DiagnosticsExporter.logDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(DiagnosticsExporter.logDirectory)
    }

    /// Restarts capture and playback (used when a setting changes how the audio engine is built).
    private func restartAudioEngine() {
        let audio = voice.audio
        guard audio.isRunning else { return }
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try audio.restart()
                await MainActor.run { self?.setup.audioError = nil }
            } catch {
                await MainActor.run { self?.errorMessage = "Microphone unavailable: \(error.localizedDescription)" }
            }
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

    /// Plays a sample of a Kokoro voice. Tapping the voice that is already playing stops it.
    func previewVoice(_ id: String) {
        if previewingVoice == id { stopVoicePreview(); return }
        guard voice.kokoro.isReady else {
            errorMessage = "The Kokoro voice is still downloading. Previews work once it is ready."
            return
        }
        previewingVoice = id
        let stack = voice
        let rate = settings.speechRate
        let line = VoiceCatalog.sampleLine(for: id)
        Task {
            do {
                try await stack.previewKokoroVoice(id, text: line, rate: rate) { [weak self] in
                    Task { @MainActor in if self?.previewingVoice == id { self?.previewingVoice = nil } }
                }
            } catch {
                if previewingVoice == id { previewingVoice = nil }
                errorMessage = "Couldn't play the sample: \(error.localizedDescription)"
            }
        }
    }

    func stopVoicePreview() {
        voice.stopPreview()
        previewingVoice = nil
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
        logSettingChanges(from: old)
        voice.apply(settings)
        if old.verboseLogging != settings.verboseLogging || old.logConversationText != settings.logConversationText {
            Self.configureDiagnostics(settings)
        }
        voice.audio.recordPlayback = settings.recordPlaybackAudio
        if old.echoCancellation != settings.echoCancellation {
            voice.audio.voiceProcessingEnabled = settings.echoCancellation
            restartAudioEngine()
        }
        if old.microphoneEnabled != settings.microphoneEnabled, VoicePermissions.microphone == .granted {
            startAudioEngine(capture: settings.microphoneEnabled)
        }
        if old.outputDeviceUID != settings.outputDeviceUID {
            voice.audio.outputDeviceUID = settings.outputDeviceUID
            restartAudioEngine()
        }
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
        case .idle:
            if !settings.microphoneEnabled { return "Microphone off" }
            if !microphoneAvailable { return "No microphone" }
            return listeningMode == .muted ? "Muted" : (listeningMode == .pushToTalk ? "Hold \(Shortcuts.global[0].display) to talk" : "Listening")
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
