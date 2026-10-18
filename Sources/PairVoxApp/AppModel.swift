// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import PairVoxCore
import PairVoxLink
import PairVoxLinkKit
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
    /// The snapshot of the project the user is in.
    @Published private(set) var snapshot = EngineSnapshot() { didSet { UITrace.tick("set.snapshot") } }
    /// Every open project, in the order they were opened.
    @Published private(set) var sessions: [SessionSummary] = [] { didSet { UITrace.tick("set.sessions") } }
    @Published private(set) var activeSessionID: UUID?
    @Published private(set) var setup = SetupState() { didSet { UITrace.tick("set.setup") } }
    @Published private(set) var whisperState: TranscriberState = .notLoaded
    @Published private(set) var kokoroStatus: ModelStore.Status = .missing
    @Published private(set) var inputLevel: Float = -90 { didSet { UITrace.tick("set.inputLevel") } }
    @Published private(set) var listeningMode: VoiceInputController.ListeningMode = .handsFree
    @Published private(set) var pushToTalkActive = false
    /// A request explainer exists for the open project (questions about a request can be asked).
    @Published private(set) var advisorAvailable = false
    @Published private(set) var hasAPIKey = KeychainStore.hasAPIKey()
    @Published private(set) var previewingVoice: String?
    /// False when no microphone is being captured (none plugged in, or permission not granted yet).
    /// PairVox still speaks, and typed messages still work.
    @Published private(set) var microphoneAvailable = true
    @Published var showSetup = false
    private var microphoneRequestInFlight = false
    /// Bumped by the "Type Instead of Talking" shortcut; the control bar focuses its text field.
    @Published private(set) var focusInputTick = 0
    @Published var errorMessage: String?

    let voice: VoiceStack
    private let store = SettingsStore()
    static let maxOpenProjects = 8
    private var liveSessions: [UUID: ProjectSession] = [:]
    private var sessionOrder: [UUID] = []
    private let inputBox = InputBox()
    private var input: VoiceInputController? {
        get { inputBox.input }
        set { inputBox.input = newValue }
    }
    private var activeSession: ProjectSession? { activeSessionID.flatMap { liveSessions[$0] } }
    private var engine: ConversationEngine? { activeSession?.engine }
    var activeEngine: ConversationEngine? { activeSession?.engine }
    func session(withID id: UUID) -> ProjectSession? { liveSessions[id] }
    /// The folder of the project the user is in.
    var project: URL? { activeSession?.url }
    private var loginEnvironment: [String: String] = ProcessInfo.processInfo.environment
    private let hotKeys = HotKeyCenter()
    private let log = DiagnosticLog.shared
    private var audioTestOutput: VoiceSpeechOutput?
    private let notifier = Notifier()
    /// True while copying engine-originated values into settings (don't echo them back).
    private var syncingFromEngine = false
    /// Paired phones: the listener, pairing screen and list.
    let phone: PhoneLinkModel
    /// Requests from other projects: the inbox, announcements and spoken answers.
    private(set) lazy var crossProject: CrossProjectController = {
        let c = CrossProjectController(model: self)
        Self.sharedCross = c
        return c
    }()
    /// The views that build before they can reach the model read the controller from here.
    static var sharedCross: CrossProjectController!
    /// The settings window builds before it can reach the model, so it reads the one phone model from here.
    static var sharedPhone: PhoneLinkModel = PhoneLinkModel()

    init() {
        phone = Self.sharedPhone
        let loaded = store.load()
        settings = loaded
        let stack = VoiceStack(settings: loaded)
        stack.audio.outputDeviceUID = loaded.outputDeviceUID
        stack.audio.separateEngines = loaded.separateAudioEngines
        stack.audio.voiceProcessingEnabled = loaded.echoCancellation
        stack.audio.recordPlayback = loaded.recordPlaybackAudio
        stack.audio.captureFeedbackEvidence = loaded.captureFeedbackAudio
        VoiceSpeechOutput.setTrimSilenceByDefault(loaded.trimSentenceSilence)
        voice = stack
        Self.configureDiagnostics(loaded)
        listeningMode = loaded.handsFree ? .handsFree : .pushToTalk
        voice.onWhisperState = { [weak self] s in Task { @MainActor in self?.whisperState = s } }
        voice.onKokoroStatus = { [weak self] s in Task { @MainActor in self?.kokoroStatus = s } }
        _ = crossProject
        phone.startControl()
        phone.engineBox.setSwitcher { [weak self] projectID in
            await MainActor.run { self?.switchFromPhone(projectID) ?? false }
        }
        phone.apply(enabled: loaded.phoneLinkEnabled, port: loaded.phoneLinkPort)
        Task { await bootstrap() }
        watchMainWindowClosing()
        // A quit is written down: twice today the process ended with no crash report and no line in the log,
        // and nothing said whether someone quit it or it died.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            DiagnosticLog.shared.log(.info, .app, "app.quit", ["reason": "terminate"])
        }
        if loaded.menuBarOnly { DispatchQueue.main.async { [weak self] in self?.applyActivationPolicy() } }
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
        setup.microphone = VoicePermissions.microphone
        setup.speechRecognition = VoicePermissions.speechRecognition
        notifier.requestAuthorization()

        hotKeys.onPress = { [weak self] id in self?.globalHotKey(id, down: true) }
        hotKeys.onRelease = { [weak self] id in self?.globalHotKey(id, down: false) }
        for key in [Shortcuts.pushToTalk(settings.pushToTalkKey)] + Shortcuts.global.dropFirst() {
            let ok = hotKeys.register(id: key.id.rawValue, keyCode: UInt32(key.keyCode), modifiers: key.carbonModifiers)
            log.log(ok ? .info : .warning, .hotkey, "register", ["key": .string(key.display), "action": .string(key.title), "ok": .bool(ok)])
        }

        // A microphone that has not been asked for yet is asked by `startAudio`, after playback is up. Waiting for
        // the answer here kept replies, hotkeys, the projects and the phone link behind a dialog nobody was at the
        // Mac to click (measured: 31 s in one launch, three hours in another).
        if !setup.claudeFound || setup.microphone == .denied {
            showSetup = true
        } else {
            // Bring back the projects that were open, with the one the user was in last.
            let last = settings.lastProject
            let others = settings.openProjects.filter { $0 != last && FileManager.default.fileExists(atPath: $0) }
            for path in others.prefix(Self.maxOpenProjects - 1) { openProject(URL(fileURLWithPath: path)) }
            if let last, FileManager.default.fileExists(atPath: last) { openProject(URL(fileURLWithPath: last)) }
        }
        if VoicePermissions.speechRecognition == .notDetermined {
            _ = await VoicePermissions.requestSpeechRecognition()
            setup.speechRecognition = VoicePermissions.speechRecognition
        }
    }

    func refreshSetup() async {
        setup.checking = true
        let exe = ClaudeLocator.locate(override: settings.claudePathOverride, pathVariable: loginEnvironment["PATH"])
        setup.claudePath = exe?.path
        if exe == nil, let o = settings.claudePathOverride, !o.isEmpty,
           let why = ClaudeLocator.overrideProblem((o as NSString).expandingTildeInPath) {
            errorMessage = "The Claude path set in Settings was not used. \(why)"
        }
        setup.cliVersion = nil
        if let exe { setup.cliVersion = await ClaudeLocator.version(of: exe, environment: ChildEnvironment.filter(loginEnvironment)) }
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
        let resolved = FolderScope.resolved(url.path)
        if let existing = sessionOrder.compactMap({ liveSessions[$0] }).first(where: { FolderScope.resolved($0.url.path) == resolved }) {
            switchTo(existing.id)
            return
        }
        guard sessionOrder.count < Self.maxOpenProjects else {
            errorMessage = "Eight projects are open. Close one from the project list before opening another."
            return
        }
        guard let path = setup.claudePath else {
            showSetup = true
            return
        }
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
            appendSystemPrompt: SystemPrompts.voice, baseEnvironment: loginEnvironment,
            trustProjectConfiguration: settings.trustProjectConfiguration)

        let advisor = ClaudeAdvisor(executable: URL(fileURLWithPath: path), workingDirectory: url, auth: auth,
                                    baseEnvironment: loginEnvironment)
        advisorAvailable = true
        let voiceOutput = VoiceSpeechOutput(audio: voice.audio, synthesizer: voice.synthesizer)
        // Silent until the user is in this project: only the active project may use the speakers.
        let gate = GatedSpeechOutput(inner: voiceOutput, active: false)
        // What this project says aloud is played on a connected phone too, as the same audio (the Mac's voice, not
        // the phone's text-to-speech). Only the project in front reaches this output, the gate silences the rest.
        // Request prompts are left out: the phone speaks those itself, with its own rules for voice answers.
        let phoneLink = phone
        voiceOutput.onPlay = { utterance, buffer in
            guard utterance.kind != .prompt else { return }
            phoneLink.speakAudioOnPhones(buffer, text: utterance.text)
        }
        voiceOutput.onStopped = { phoneLink.stopSpeakingOnPhones() }
        let engine = ConversationEngine(configuration: EngineConfiguration(settings: settings, project: projectPath),
                                        authKind: auth.kind, output: gate, advisor: advisor) { resume in
            var cfg = launch
            cfg.resumeSessionID = resume
            return ClaudeCLISession(configuration: cfg)
        }
        let session = ProjectSession(url: url, engine: engine, gate: gate)
        phone.engineBox.register(session.id.uuidString, engine)
        let cross = crossProject
        let interceptor: @Sendable (String) -> Bool = { text in cross.intercept(text) }
        let secondConfirm = settings.macSecondConfirmation
        Task {
            await engine.setUtteranceInterceptor(interceptor)
            if secondConfirm { await engine.setSecondConfirmation(Self.touchIDCheck) }
        }
        let box = inputBox
        voiceOutput.onPlaybackActiveChange = { [weak gate] active in
            if gate?.isActive == true || !active { box.input?.setPlaybackActive(active) }
        }

        if input == nil {
            let input = VoiceInputController(audio: voice.audio, transcriber: voice.transcriber, engine: engine,
                                             endSilence: settings.endOfTurnSilence)
            input.setBargeInEnabled(settings.bargeInEnabled)
            input.setMode(listeningMode)
            input.onLevel = { [weak self] level in Task { @MainActor in self?.inputLevel = level } }
            input.onError = { [weak self] msg in Task { @MainActor in self?.errorMessage = msg } }
            self.input = input
            configureAudioCallbacks()
        } else if sessionOrder.isEmpty {
            input?.setMode(listeningMode)   // it was muted when the last project closed
        }

        liveSessions[session.id] = session
        sessionOrder.append(session.id)
        if !voice.audio.isRunning { startAudio() }

        session.snapshotTask = Task { [weak self] in
            for await snap in engine.snapshots {
                self?.receive(snap, from: session)
            }
        }
        Task {
            await engine.setGrantHandler { [weak self] change in Task { @MainActor in self?.applyGrantChange(change) } }
            await engine.setProjectSwitchHandler { [weak self] name in
                await MainActor.run { self?.switchToProject(named: name) ?? false }
            }
            await engine.start()
            // Offer standing access once per project, after the greeting has had time to play.
            let folder = FolderScope.resolved(projectPath)
            let alreadyDecided = await MainActor.run {
                self.settings.folderGrants.contains { $0.path == folder } || self.settings.declinedGrantFolders.contains(folder)
            }
            if !alreadyDecided {
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                await engine.offerFolderGrant()
            }
        }

        // Bias speech recognition toward this project's names.
        let extra = settings.preferences(for: projectPath).vocabulary
        Task.detached(priority: .utility) { [weak self] in
            let words = extra + RepoVocabulary.scan(root: url)
            await MainActor.run {
                session.vocabulary = words
                if self?.activeSessionID == session.id { self?.input?.setVocabulary(words) }
            }
        }

        switchTo(session.id)
    }

    private func configureAudioCallbacks() {
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
        voice.audio.onRestartLoop = { [weak self] message in
            Task { @MainActor in self?.errorMessage = message }
        }
        voice.audio.onPlaybackDropped = { [weak self] in
            Task { @MainActor in
                guard let self, self.errorMessage == nil else { return }
                self.errorMessage = "PairVox can't play sound: the audio engine isn't running. Check the output device, then reopen the project."
            }
        }
    }

    // MARK: Switching between projects

    /// Moves the conversation to another open project. The one left goes quiet and keeps a list of what Claude says;
    /// the one entered offers to catch the user up on anything missed.
    func switchTo(_ id: UUID) {
        guard id != activeSessionID, let next = liveSessions[id] else { return }
        log.log(.info, .app, "project.switch", ["from": .string(activeSession?.name ?? "-"), "to": .string(next.name),
                                                "entries": .int(next.snapshot.transcript.count), "phase": .string("\(next.snapshot.phase)"),
                                                "sessions": .int(sessionOrder.count), "grantOffer": .bool(next.snapshot.grantOffer != nil),
                                                "pending": .bool(next.snapshot.pendingPermission != nil),
                                                "missed": .int(next.snapshot.missedMessages.count), "catchUp": .bool(next.snapshot.awaitingCatchUpChoice)])
        if let previous = activeSession {
            previous.gate.setActive(false)
            let engine = previous.engine
            Task { await engine.setActive(false) }
        }
        activeSessionID = id
        snapshot = next.snapshot
        // The phone follows the project on the Mac's screen: its typed text goes to this engine from now on, and it
        // is shown this project's conversation at once instead of waiting for the next change inside it.
        phone.engineBox.setActive(next.engine)
        republishToPhone()
        input?.setEngine(next.engine)
        input?.setVocabulary(next.vocabulary)
        next.gate.setActive(true)
        let engine = next.engine
        Task { await engine.setActive(true) }
        settings.noteProjectOpened(next.url.path)
        refreshSessions()
        crossProject.activeProjectChanged()
        log.log(.info, .app, "project.switched", ["open": .int(sessionOrder.count)])
    }

    /// "Switch to <name>": true if the name picked out exactly one open project.
    func switchToProject(named name: String) -> Bool {
        let ordered = sessionOrder.compactMap { liveSessions[$0] }
        guard let i = ProjectMatcher.match(name, in: ordered.map(\.name)) else { return false }
        switchTo(ordered[i].id)
        return true
    }

    func switchToProject(at index: Int) {
        guard sessionOrder.indices.contains(index) else { return }
        switchTo(sessionOrder[index])
    }

    func switchToNextProject(_ step: Int = 1) {
        guard sessionOrder.count > 1, let active = activeSessionID, let i = sessionOrder.firstIndex(of: active) else { return }
        switchTo(sessionOrder[(i + step + sessionOrder.count) % sessionOrder.count])
    }

    func closeProject(_ id: UUID) {
        guard let session = liveSessions[id] else { return }
        let wasActive = id == activeSessionID
        session.snapshotTask?.cancel()
        session.gate.setActive(false)
        let engine = session.engine
        Task { await engine.shutdown() }
        liveSessions.removeValue(forKey: id)
        sessionOrder.removeAll { $0 == id }
        crossProject.sessionClosed(id)
        phone.engineBox.unregister(id.uuidString)
        if wasActive {
            activeSessionID = nil
            snapshot = EngineSnapshot()
            if let next = sessionOrder.last {
                switchTo(next)
            } else {
                phone.engineBox.setActive(nil)   // nothing is open: the phone's text must not reach a closed project's engine
                input?.setMode(.muted)
            }
        }
        refreshSessions()
    }

    private func refreshSessions() {
        let open = sessionOrder.compactMap { liveSessions[$0]?.url.path }
        if settings.openProjects != open { settings.openProjects = open }
        let next: [SessionSummary] = sessionOrder.compactMap { id in
            guard let s = liveSessions[id] else { return nil }
            let snap = id == activeSessionID ? snapshot : s.snapshot
            return SessionSummary(id: id, name: s.name, path: s.url.path, phase: snap.phase,
                                  needsAttention: snap.pendingPermission != nil || snap.grantOffer != nil,
                                  missedCount: snap.missedMessages.count, isActive: id == activeSessionID)
        }
        // Called on every streaming delta; publishing an unchanged list re-rendered every view that reads the model.
        if next != sessions { sessions = next }
    }

    // MARK: Catch-up after switching

    /// "Play from the first missed message", "Play the last message" or "Skip".
    func catchUp(_ choice: CatchUpChoice) { Task { await engine?.resolveCatchUp(choice) } }

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
            // Every project reopened at launch comes through here; one request, then one restart with capture.
            guard !microphoneRequestInFlight else { return }
            microphoneRequestInFlight = true
            Task {
                _ = await VoicePermissions.requestMicrophone()
                await refreshSetup()
                microphoneRequestInFlight = false
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
        audio.separateEngines = settings.separateAudioEngines
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
            // The banner is gone with the window; the log is what a report is read from.
            log.log(.error, .audio, "engine.start.failed", ["capture": .bool(capture), "error": .string(error.localizedDescription)])
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

    /// Re-registers the hold-to-talk hotkey after the key setting changes.
    func applyPushToTalkKey() {
        let key = Shortcuts.pushToTalk(settings.pushToTalkKey)
        let ok = hotKeys.register(id: key.id.rawValue, keyCode: UInt32(key.keyCode), modifiers: key.carbonModifiers)
        log.log(ok ? .info : .warning, .hotkey, "register", ["key": .string(key.display), "action": .string(key.title), "ok": .bool(ok)])
    }

    func focusInputField() { focusInputTick += 1 }

    // MARK: Menu bar only

    /// Shows the main window. In menu-bar-only mode the Dock icon comes back for as long as the window is open.
    func showMainWindow(open: () -> Void) {
        if settings.menuBarOnly { NSApp.setActivationPolicy(.regular) }
        if let window = NSApp.windows.first(where: { $0.canBecomeMain && $0.identifier?.rawValue.contains("main") == true })
            ?? NSApp.windows.first(where: { $0.canBecomeMain && $0.title == "PairVox" }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            open()
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func applyActivationPolicy() {
        NSApp.setActivationPolicy(settings.menuBarOnly ? .accessory : .regular)
        if settings.menuBarOnly {
            for window in NSApp.windows where window.canBecomeMain { window.close() }
        }
    }

    private func watchMainWindowClosing() {
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, let closing = note.object as? NSWindow, closing.canBecomeMain else { return }
            Task { @MainActor in
                // Back to a menu-bar app once the last full window is gone.
                try? await Task.sleep(nanoseconds: 300_000_000)
                let anyMain = NSApp.windows.contains { $0.canBecomeMain && $0.isVisible && $0 !== closing }
                if self.settings.menuBarOnly, !anyMain { NSApp.setActivationPolicy(.accessory) }
            }
        }
    }

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
        let skip = AppSettings.pathBearingKeys
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

    /// Closes the project the user is in.
    func closeSession() {
        if let id = activeSessionID { closeProject(id) }
    }

    /// Starts the current project over with a fresh Claude Code process (after a change that needs one).
    func restartSession() {
        guard let url = project else { return }
        closeSession()
        openProject(url)
    }

    /// Starts every open project over, for a change that affects all of them (account, trusted project config).
    private func restartAllSessions() {
        let urls = sessionOrder.compactMap { liveSessions[$0]?.url }
        let active = project
        for id in sessionOrder { closeProject(id) }
        for url in urls where url != active { openProject(url) }
        if let active { openProject(active) }
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

    /// Approves the request that was on screen when the button was pressed; if it has changed since, nothing happens.
    // MARK: Folder access

    private func applyGrantChange(_ change: FolderGrantChange) {
        switch change {
        case .granted(let path, let shell):
            if let i = settings.folderGrants.firstIndex(where: { $0.path == path }) {
                if shell { settings.folderGrants[i].allowShell = true }
            } else {
                settings.folderGrants.append(FolderGrant(path: path, allowShell: false))
            }
            settings.declinedGrantFolders.removeAll { $0 == path }
        case .declined(let path):
            if !settings.declinedGrantFolders.contains(path) { settings.declinedGrantFolders.append(path) }
        }
    }

    func answerGrantOffer(yes: Bool) { Task { await engine?.answerGrantOffer(yes: yes) } }
    func dismissGrantOffer() { Task { await engine?.dismissGrantOffer() } }

    /// Takes access back at once; the running session stops skipping prompts immediately.
    func removeGrant(_ path: String) {
        settings.folderGrants.removeAll { $0.path == path }
        settings.declinedGrantFolders.removeAll { $0 == path }
    }

    func removeAllGrants() { settings.folderGrants.removeAll() }

    func turnOffShell(for path: String) {
        if let i = settings.folderGrants.firstIndex(where: { $0.path == path }) { settings.folderGrants[i].allowShell = false }
    }

    /// Shell access is turned on only through the spoken-or-clicked double confirmation, never by a plain switch.
    func requestShellGrant(for path: String) {
        guard let project, FolderScope.resolved(project.path) == path else {
            errorMessage = "Open that project first, then turn on shell commands for it."
            return
        }
        Task { await engine?.offerFolderGrant(shell: true) }
    }

    func ask(_ question: String) { Task { await engine?.askAboutPending(question) } }

    /// Requests waiting behind the one shown (plus the one shown) that can be allowed together.
    var approvableWaitingCount: Int {
        waitingForBulkApproval.count
    }

    /// Only requests whose whole text and reasons fit the list are approved together; the rest are reviewed one by one.
    private var waitingForBulkApproval: [PendingPermission] {
        ([snapshot.pendingPermission].compactMap { $0 } + snapshot.queuedPermissions)
            .filter { $0.assessment.voiceApprovable && $0.assessment.fitsCompactSurface }
    }

    /// Allows exactly the requests listed on screen right now, skipping high-risk ones.
    func approveAllWaiting() {
        let ids = waitingForBulkApproval.map(\.request.requestID)
        Task { await engine?.approveAllWaiting(requestIDs: ids) }
    }

    func approve(always: Bool = false, requestID: String? = nil) {
        let id = requestID ?? snapshot.pendingPermission?.request.requestID
        Task { await engine?.approvePending(always: always, requestID: id) }
    }
    func deny(requestID: String? = nil) {
        let id = requestID ?? snapshot.pendingPermission?.request.requestID
        Task { await engine?.denyPending(requestID: id) }
    }
    func interrupt() { Task { await engine?.interruptClaude() } }
    func stopSpeaking() { Task { await engine?.stopSpeaking() } }
    func newSession() { Task { await engine?.newSession() } }
    func resumeSession(_ id: String) { Task { await engine?.resumeSession(id: id) } }
    /// Earlier sessions of the open project, newest first.
    var pastSessions: [PastSession] { project.map { SessionCatalog.recent(for: $0.path) } ?? [] }
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
        guard hasAPIKey else {
            // Restarting now would only produce "no key is saved" for every project; say what actually failed.
            log.log(.error, .app, "apiKey.saveFailed", [:])
            errorMessage = "The API key could not be saved to the Keychain, so nothing changed. Try again, or check Keychain Access."
            return
        }
        if settings.authKind == .apiKey, !sessionOrder.isEmpty { restartAllSessions() }
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

    /// A quiet system sound when Claude starts and when it finishes, for people who look away while it works.
    private func playEarcon(from old: EnginePhase, to new: EnginePhase) {
        guard settings.earcons else { return }
        let busy: Set<EnginePhase> = [.thinking, .working]
        if busy.contains(new), !busy.contains(old) {
            NSSound(named: "Pop")?.play()
        } else if busy.contains(old), !busy.contains(new), new != .awaitingPermission {
            NSSound(named: "Glass")?.play()
        }
    }

    /// Sends the phone the active project's state plus every request waiting elsewhere.
    private func republishToPhone() {
        guard let active = activeSession else { return }
        phone.publish(snapshot, project: active.url.path,
                      others: crossProject.inbox.others(than: active.id.uuidString),
                      voiceHighRisk: settings.spokenHighRiskConfirmation, voiceNeedsScreen: settings.voiceApprovesNeedsScreen,
                      activeProjectID: active.id.uuidString,
                      projects: sessions.map { LinkProject(id: $0.id.uuidString, name: $0.name, isActive: $0.isActive,
                                                           needsAttention: $0.needsAttention, missed: $0.missedCount) })
    }

    /// The phone's project switcher: the same switch as the Mac's project list. False for a project that is not open.
    func switchFromPhone(_ projectID: String) -> Bool {
        guard let id = UUID(uuidString: projectID), liveSessions[id] != nil else { return false }
        log.log(.info, .app, "phoneLink.switchProject", ["to": .string(liveSessions[id]?.name ?? "?")])
        if id != activeSessionID { switchTo(id) }
        return true
    }

    private func receive(_ snap: EngineSnapshot, from session: ProjectSession) {
        guard liveSessions[session.id] != nil else { return }
        let previous = session.snapshot
        session.snapshot = snap
        let isActive = session.id == activeSessionID
        crossProject.sessionChanged(session, isActive: isActive)
        // The phone gets this snapshot, not the one before it: `republishToPhone` reads `self.snapshot`, so it must
        // be updated first. (It used to run before the assignment, and the phone was always one update behind:
        // a finished reply reached it only when the next thing changed.)
        if isActive { snapshot = snap }
        republishToPhone()
        if isActive {
            phone.engineBox.setActive(session.engine)
            // Voice commands ("faster", "summary mode") change these inside the engine; only such a change is copied
            // into General, never a project's own starting values (see `SettingsMirror`).
            if let mirrored = SettingsMirror.apply(previous: session.receivedFirstSnapshot ? previous : nil,
                                                   current: snap, to: settings) {
                syncingFromEngine = true
                settings = mirrored
                syncingFromEngine = false
            }
            session.receivedFirstSnapshot = true
            if snap.phase == .needsSetup && previous.phase != .needsSetup { showSetup = true }
            playEarcon(from: previous.phase, to: snap.phase)
        }

        // Notifications: anything in a project the user is not looking at, and everything while PairVox is in the background.
        let watching = isActive && NSApp.isActive
        if !watching {
            let prefix = sessionOrder.count > 1 ? "\(session.name): " : ""
            if let p = snap.pendingPermission, p.request.requestID != session.notifiedPermissionID {
                session.notifiedPermissionID = p.request.requestID
                notifier.post(title: "\(prefix)Claude needs your OK", body: p.assessment.summary, id: p.request.requestID)
            }
            if previous.isClaudeWorking && !snap.isClaudeWorking && snap.usage.turns > session.turnsAtLastNotification {
                let last = snap.transcript.last { $0.role == .assistant }?.text ?? "Done."
                notifier.post(title: "\(prefix)Claude finished", body: String(last.prefix(140)))
            }
        } else {
            session.turnsAtLastNotification = snap.usage.turns
        }
        refreshSessions()
    }

    /// Applies a setting to every open project's engine, not just the one the user is in.
    /// Touch ID or the login password, asked after a spoken high-risk approval when that option is on.
    nonisolated static let touchIDCheck: @Sendable () async -> Bool = { await CrossProjectController.authenticate(reason: "Allow a high-risk action") }

    private func broadcast(_ body: @escaping @Sendable (ConversationEngine) async -> Void) {
        let engines = sessionOrder.compactMap { liveSessions[$0]?.engine }
        Task { for engine in engines { await body(engine) } }
    }

    private func settingsChanged(from old: AppSettings) {
        do {
            try store.save(settings)
        } catch {
            // A revoked folder grant or a switched-off consent that is not on disk comes back at the next launch.
            log.log(.error, .app, "settings.saveFailed", ["error": .string(error.localizedDescription)])
            errorMessage = "Settings could not be saved (\(error.localizedDescription)). They apply until PairVox quits; "
                + "a folder access you removed or a switch you turned off would come back at the next launch."
        }
        logSettingChanges(from: old)
        if old.phoneLinkEnabled != settings.phoneLinkEnabled || old.phoneLinkPort != settings.phoneLinkPort {
            phone.apply(enabled: settings.phoneLinkEnabled, port: settings.phoneLinkPort)
        }
        voice.apply(settings)
        if old.verboseLogging != settings.verboseLogging || old.logConversationText != settings.logConversationText {
            Self.configureDiagnostics(settings)
        }
        voice.audio.recordPlayback = settings.recordPlaybackAudio
        voice.audio.captureFeedbackEvidence = settings.captureFeedbackAudio
        VoiceSpeechOutput.setTrimSilenceByDefault(settings.trimSentenceSilence)
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
        if old.separateAudioEngines != settings.separateAudioEngines {
            voice.audio.separateEngines = settings.separateAudioEngines
            restartAudioEngine()
        }
        input?.setBargeInEnabled(settings.bargeInEnabled)
        input?.setEndSilence(settings.endOfTurnSilence)
        if old.spokenReplyLimit != settings.spokenReplyLimit {
            let limit = settings.spokenReplyLimit
            broadcast { await $0.setSpokenReplyLimit(limit) }
        }
        if !syncingFromEngine, old.speechRate != settings.speechRate {
            let rate = settings.speechRate
            broadcast { await $0.setSpeechRate(rate) }
        }
        if !syncingFromEngine, old.speechMode != settings.speechMode {
            let mode = settings.speechMode
            broadcast { await $0.setSpeechMode(mode) }
        }
        if old.folderGrants != settings.folderGrants {
            let grants = settings.folderGrants
            broadcast { await $0.setFolderGrants(grants) }
        }
        if old.explainRequests != settings.explainRequests {
            let on = settings.explainRequests
            broadcast { await $0.setExplainRequests(on) }
        }
        if old.spokenHighRiskConfirmation != settings.spokenHighRiskConfirmation {
            let on = settings.spokenHighRiskConfirmation
            broadcast { await $0.setSpokenHighRiskConfirmation(on) }
        }
        if old.voiceApprovesNeedsScreen != settings.voiceApprovesNeedsScreen {
            let on = settings.voiceApprovesNeedsScreen
            broadcast { await $0.setVoiceApprovesNeedsScreen(on) }
        }
        if old.approveByVoiceFromSummary != settings.approveByVoiceFromSummary {
            let on = settings.approveByVoiceFromSummary
            broadcast { await $0.setApproveByVoiceFromSummary(on) }
        }
        if old.macSecondConfirmation != settings.macSecondConfirmation {
            let on = settings.macSecondConfirmation
            if on { broadcast { await $0.setSecondConfirmation(Self.touchIDCheck) } }
            else { broadcast { await $0.setSecondConfirmation(nil) } }
        }
        crossProject.settingsChanged()
        republishToPhone()
        if old.autoApproveLowRisk != settings.autoApproveLowRisk {
            let on = settings.autoApproveLowRisk
            broadcast { await $0.setAutoApproveLowRisk(on) }
        }
        if old.trustProjectConfiguration != settings.trustProjectConfiguration, !sessionOrder.isEmpty {
            restartAllSessions()
        }
        if old.menuBarOnly != settings.menuBarOnly { applyActivationPolicy() }
        if old.verbosity != settings.verbosity {
            let v = settings.verbosity
            broadcast { await $0.setVerbosity(v) }
        }
        if old.pronunciation != settings.pronunciation {
            let dict = settings.pronunciation
            broadcast { await $0.setPronunciation(dict) }
        }
        if old.whisperModel != settings.whisperModel || (old.transcriber == .apple && settings.transcriber != .apple) {
            reloadWhisper()
        }
        if old.synthesizer == .system && settings.synthesizer != .system { downloadKokoroNow() }
        if old.claudePathOverride != settings.claudePathOverride {
            Task { await refreshSetup() }
        }
        // Auth changes need a fresh process.
        if old.authKind != settings.authKind, !sessionOrder.isEmpty { restartAllSessions() }
    }

    var statusLine: String {
        switch snapshot.phase {
        case .starting: return "Starting…"
        case .idle:
            if !settings.microphoneEnabled { return "Microphone off" }
            if !microphoneAvailable { return "No microphone" }
            return listeningMode == .muted ? "Muted" : (listeningMode == .pushToTalk ? "Hold \(Shortcuts.pushToTalk(settings.pushToTalkKey).display) to talk" : "Listening")
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
