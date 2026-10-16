// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The conversation loop: user speech in → Claude Code → speech out.
///
/// Platform-independent. The macOS app feeds it transcripts and voice-activity
/// signals and gives it a `SpeechOutput`; the CLI and the tests do the same with
/// simpler parts.
public actor ConversationEngine {
    public nonisolated let snapshots: AsyncStream<EngineSnapshot>
    private let snapshotContinuation: AsyncStream<EngineSnapshot>.Continuation
    public private(set) var snapshot = EngineSnapshot()

    private var config: EngineConfiguration
    private let authKind: AuthKind
    private let makeBackend: SessionBackendFactory
    /// Requests that arrived while another was waiting. Answering the shown one promotes the next, so an
    /// approval can only ever apply to the request the user was shown and told about.
    private var permissionQueue: [PendingPermission] = []
    private let advisor: (any RequestAdvisor)?
    private var advisorTasks: [String: [Task<Void, Never>]] = [:]
    private var speakExplanationFor: String?
    static let maxQuestionsPerRequest = 5
    private var isActive = true
    private var attendedThrough = 0
    private var catchUpOpen = false
    private var secondConfirmation: (@Sendable () async -> Bool)?
    private var utteranceInterceptor: (@Sendable (String) -> Bool)?
    /// The words of the utterance being handled, for the checks that need more than the parsed command.
    private var lastUtteranceWords: [String] = []
    /// Ids read out to the user after a first "allow all"; only these can be allowed by the second.
    private var approveAllArmed: Set<String>?
    private var grantHandler: (@Sendable (FolderGrantChange) -> Void)?
    private var projectSwitchHandler: (@Sendable (String) async -> Bool)?
    /// The conversation mode the backend factory launches with; a later change is re-applied to new sessions.
    private var launchedConversationMode: ConversationMode
    private var backend: (any SessionBackend)?
    private var backendGeneration = 0
    private var eventTask: Task<Void, Never>?
    private let output: any SpeechOutput
    private var outputTask: Task<Void, Never>?

    private let ids = UtteranceIDs()
    private var planner: SpeechPlanner
    private var lastPlanner: SpeechPlanner?
    private var policy: PermissionPolicy
    private var pronunciation: Pronunciation

    // Turn bookkeeping
    private var sendTimes: [Date] = []           // one per user message not yet completed
    private var assistantEntryID: Int?
    private var turnMuted = false
    private var latency = TurnLatency()
    private var utterancesThisTurn = 0
    private let log = DiagnosticLog.shared
    private var ackTask: Task<Void, Never>?
    private var firstTokenSeen = false

    // Speech bookkeeping
    private var queued: [Int: Utterance] = [:]
    private var queueOrder: [Int] = []
    /// Utterances that count toward "first audio" (everything except fillers).
    private var measuredIDs: Set<Int> = []
    private var holdSpeech = false
    private var interruptedRemainder: [Utterance] = []
    /// While the user is talking over us and the output can hold its place, speech is paused rather than discarded, so a
    /// noise, a cough or an echo that turns out to be nothing carries on from the same spot instead of replaying.
    private var pausedBargeIn = false
    /// Utterances the speaker has begun playing, so a courtesy line that is still waiting can be told from one already out loud.
    private var startedIDs: Set<Int> = []
    private var pausedRemaining: [Utterance] = []
    private var pauseToken = 0
    /// If no transcript arrives (a stuck decode), speech carries on after this long.
    private var pauseWatchdogSeconds: Double = 12
    func setPauseWatchdog(seconds: Double) { pauseWatchdogSeconds = seconds }
    private var nextEntryID = 1
    private var spokenAuthProblem = false
    private var userIsSpeaking = false
    private var transcribing = false
    private var readMoreWhenDone = false

    public init(configuration: EngineConfiguration, authKind: AuthKind = .subscription, output: any SpeechOutput,
                advisor: (any RequestAdvisor)? = nil, backendFactory: @escaping SessionBackendFactory) {
        self.advisor = advisor
        self.config = configuration
        self.launchedConversationMode = configuration.conversationMode
        self.authKind = authKind
        self.output = output
        self.makeBackend = backendFactory
        self.pronunciation = Pronunciation(dictionary: configuration.pronunciation)
        self.policy = PermissionPolicy(projectRoot: configuration.projectRoot, pronunciation: pronunciation, grants: configuration.folderGrants, voiceFromSummary: configuration.approveByVoiceFromSummary)
        self.planner = SpeechPlanner(mode: configuration.speechMode, verbosity: configuration.verbosity,
                                     pronunciation: pronunciation, ids: ids, spokenLimit: configuration.spokenReplyLimit)
        var cont: AsyncStream<EngineSnapshot>.Continuation!
        self.snapshots = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { cont = $0 }
        self.snapshotContinuation = cont
        snapshot.speechMode = configuration.speechMode
        snapshot.conversationMode = configuration.conversationMode
        snapshot.verbosity = configuration.verbosity
        snapshot.speechRate = configuration.speechRate
    }

    // MARK: - Lifecycle

    /// Starts the Claude Code process and begins listening to it.
    public func start() {
        output.setRate(config.speechRate)
        if outputTask == nil {
            let stream = output.events
            outputTask = Task { [weak self] in
                for await e in stream { await self?.handleOutput(e) }
            }
        }
        openBackend(resume: nil)
        snapshot.phase = .idle
        publish()
    }

    public func shutdown() {
        ackTask?.cancel()
        eventTask?.cancel()
        outputTask?.cancel()
        output.stopAll()
        backend?.stop()
        backend = nil
        snapshotContinuation.finish()
    }

    private func openBackend(resume: String?) {
        backendGeneration += 1
        let gen = backendGeneration
        let b = makeBackend(resume)
        backend = b
        eventTask?.cancel()
        let stream = b.events
        eventTask = Task { [weak self] in
            for await e in stream { await self?.handleSession(e, generation: gen) }
        }
        do {
            try b.start()
        } catch {
            noteProblem("\(error)")
        }
        // The factory launches with the mode the project opened in; carry a later change into the new child.
        if config.conversationMode != launchedConversationMode {
            try? b.setPermissionMode(config.conversationMode.permissionMode)
        }
    }

    // MARK: - Input from the voice layer

    /// The user started talking (VAD). Stops our speech immediately (barge-in).
    public func userStartedSpeaking() {
        log.log(.info, .engine, "user.speech.start",
                ["bargeIn": .bool(snapshot.isSpeaking || !queueOrder.isEmpty), "phase": "\(snapshot.phase)"])
        if (snapshot.isSpeaking || !queueOrder.isEmpty), output.supportsPause {
            if !pausedBargeIn {
                pausedBargeIn = true
                pausedRemaining = queueOrder.compactMap { queued[$0] }
                output.pause()
                holdSpeech = true
                pauseToken += 1
                let token = pauseToken
                let wait = pauseWatchdogSeconds
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                    await self?.pauseExpired(token)
                }
            }
        } else if snapshot.isSpeaking || !queueOrder.isEmpty {
            let remaining = queueOrder.compactMap { queued[$0] }
            output.stopAll()
            queued.removeAll()
            queueOrder.removeAll()
            interruptedRemainder = remaining
            snapshot.isSpeaking = false
            holdSpeech = true
        }
        userIsSpeaking = true
        transcribing = false
        recomputePhase()
    }

    private func pauseExpired(_ token: Int) {
        guard pausedBargeIn, token == pauseToken else { return }
        log.log(.warning, .engine, "bargeIn.pauseExpired")
        userIsSpeaking = false
        transcribing = false
        resumePausedInPlace()
        recomputePhase()
    }

    /// What was said was not for us (or was an acknowledgement): carry on from the exact spot, then speak anything
    /// that arrived while paused.
    private func resumePausedInPlace() {
        guard pausedBargeIn else { return }
        pausedBargeIn = false
        pausedRemaining = []
        holdSpeech = false
        output.resume()
        let held = interruptedRemainder
        interruptedRemainder = []
        if !held.isEmpty { speak(held.map { make($0.text, $0.kind) }, record: false) }
    }

    /// What was said is for us: do what a barge-in always did. Stop, and keep what was not finished so a command can
    /// resume it.
    private func commitPausedBargeIn() {
        guard pausedBargeIn else { return }
        pausedBargeIn = false
        let remaining = queueOrder.compactMap { queued[$0] }
        output.stopAll()
        queued.removeAll()
        queueOrder.removeAll()
        interruptedRemainder = remaining + interruptedRemainder
        pausedRemaining = []
        snapshot.isSpeaking = false
        holdSpeech = true
    }

    /// The user stopped talking; a transcript will follow.
    public func userStoppedSpeaking() {
        log.log(.info, .engine, "user.speech.end")
        userIsSpeaking = false
        transcribing = true
        recomputePhase()
    }

    /// Speech recognition produced nothing usable.
    public func transcriptionFailed() {
        log.log(.warning, .engine, "user.transcription.empty")
        userIsSpeaking = false
        transcribing = false
        resumeAfterFalseBargeIn()
        recomputePhase()
    }

    /// A final transcript (or typed text) from the user.
    public func submit(_ rawText: String) {
        if let intercept = utteranceInterceptor, intercept(rawText) { userIsSpeaking = false; transcribing = false; recomputePhase(); return }
        process(rawText, allowProjectSwitch: true)
    }

    /// Text from a paired phone. It can be an instruction or a general voice command ("new session"), but never an
    /// answer to a waiting request: approvals from the phone arrive as explicit, ID-bound commands that the host
    /// checks first. Text said while a request waits is, as for speech, an instruction instead of it.
    public func submitFromRemote(_ rawText: String) {
        process(rawText, allowProjectSwitch: false, answersPermissions: false)
    }

    private func process(_ rawText: String, allowProjectSwitch: Bool, answersPermissions: Bool = true) {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        userIsSpeaking = false
        transcribing = false
        guard !text.isEmpty else {
            resumeAfterFalseBargeIn()
            recomputePhase()
            return
        }
        lastUtteranceWords = VoiceCommand.normalize(text)
        // While the catch-up question is open, the waiting request has not been announced yet, so a bare "okay" cannot answer it.
        let context = VoiceCommand.Context(awaitingPermission: answersPermissions && (snapshot.pendingPermission != nil || snapshot.grantOffer != nil) && !catchUpOpen,
                                           claudeIsWorking: !sendTimes.isEmpty,
                                           hasHeldBack: !(lastPlanner?.heldBack.isEmpty ?? true),
                                           awaitingHighRiskConfirmation: answersPermissions && (snapshot.pendingPermission.map(canConfirmHighRiskByVoice) ?? false),
                                           awaitingCatchUpChoice: catchUpOpen && answersPermissions,
                                           hasQueuedRequests: answersPermissions && !permissionQueue.isEmpty)
        var parsed = VoiceCommand.parse(text, context: context)
        // A bare acknowledgement ("okay", "mm-hmm") carries on from where speech was paused; anything else is meant for us.
        if pausedBargeIn { if parsed == .backchannel { resumePausedInPlace() } else { commitPausedBargeIn() } }
        // Text from a phone is an instruction for Claude. Only "stop" and a bare acknowledgement keep their command
        // meaning: it must not switch Brainstorm to Execute, restart the session or change settings on the Mac.
        if !answersPermissions {
            switch parsed {
            case .interruptClaude?, .backchannel?: break
            default: parsed = nil
            }
        }
        if parsed != .approveAllWaiting { approveAllArmed = nil }
        // "switch to X" is only a command when X is one of the open projects; otherwise it is an instruction for Claude.
        if case .switchProject(let name)? = parsed {
            if allowProjectSwitch, let handler = projectSwitchHandler {
                Task { [weak self] in
                    let matched = await handler(name)
                    await self?.finishProjectSwitch(text: text, matched: matched)
                }
                return
            }
            parsed = nil
        }
        log.log(.info, .engine, "user.submit",
                ["text": log.content(text), "command": parsed.map { "\($0)" } ?? "none",
                 "awaitingPermission": .bool(context.awaitingPermission), "claudeWorking": .bool(context.claudeIsWorking)])
        if parsed != .approveAllWaiting { approveAllArmed = nil }
        if let command = parsed {
            appendEntry(.user, text, status: .done)
            perform(command)
            return
        }
        // Carrying on with something else means the user does not want the catch-up.
        if catchUpOpen { resolveCatchUp(.skip, speakReprompt: false) }
        // Anything else said while a folder offer is open is not an answer: drop the offer without recording a no.
        if snapshot.grantOffer != nil, snapshot.pendingPermission == nil { snapshot.grantOffer = nil }
        // A question about the request on screen is asked of the advisor, never taken as a refusal.
        if snapshot.pendingPermission != nil, advisor != nil, text.hasSuffix("?") {
            appendEntry(.user, text, status: .done)
            askAboutPending(text, spoken: true)
            return
        }
        // Speaking over a permission prompt with something else = "no, do this instead".
        if let pending = snapshot.pendingPermission {
            appendEntry(.user, text, status: .done)
            dropRemainder()
            respondToPermission(pending.request, decision: .deny(message: "The user said instead: \(text)", interrupt: false))
            return
        }
        dropRemainder()
        if !sendTimes.isEmpty {
            // Redirect: stop the current turn, then send the new instruction (Claude Code queues it).
            turnMuted = true
            try? backend?.interrupt()
        }
        sendUserMessage(text)
    }

    // MARK: - UI actions

    /// Approves the request on screen. Pass the `requestID` the user was shown: if the shown request has
    /// since changed, nothing is approved.
    public func approvePending(always: Bool = false, requestID: String? = nil) {
        guard let p = snapshot.pendingPermission, requestID == nil || requestID == p.request.requestID else { return }
        respondToPermission(p.request, decision: always ? .allowAlways : .allow)
    }

    public func denyPending(message: String = "The user denied this action.", requestID: String? = nil) {
        guard let p = snapshot.pendingPermission, requestID == nil || requestID == p.request.requestID else { return }
        respondToPermission(p.request, decision: .deny(message: message, interrupt: false))
    }

    /// Turns the "auto-approve read-only tools" setting on or off for the running session.
    public func setAutoApproveLowRisk(_ on: Bool) {
        config.autoApproveLowRisk = on
    }

    public func setVoiceApprovesNeedsScreen(_ on: Bool) { config.voiceApprovesNeedsScreen = on }

    /// Set while the owner wants Touch ID or a password after a spoken high-risk approval; nil turns it off.
    public func setSecondConfirmation(_ confirm: (@Sendable () async -> Bool)?) { secondConfirmation = confirm }

    private func finishSecondConfirmation(requestID: String, confirmed: Bool) {
        guard snapshot.pendingPermission?.request.requestID == requestID else { return }
        if confirmed { approvePending(requestID: requestID) }
        else { speak([make("Not confirmed. The request is still waiting.", .notice)], record: false, force: true) }
    }

    /// Lets the app answer for a request in another project, or switch, before the engine parses an utterance.
    /// Return true to say the app handled it. Called for spoken or typed text from this Mac only.
    public func setUtteranceInterceptor(_ f: (@Sendable (String) -> Bool)?) { utteranceInterceptor = f }

    /// Speaks a short notice on this project's speakers now (used for announcements about other projects).
    public func announce(_ text: String) {
        speak([make(text, .notice)], record: false, force: true)
    }

    public func setExplainRequests(_ on: Bool) {
        config.explainRequests = on
    }

    /// Turns spoken confirmation of high-risk requests on or off for the running session.
    public func setSpokenHighRiskConfirmation(_ on: Bool) {
        config.spokenHighRiskConfirmation = on
    }

    // MARK: - Working in several projects

    /// The user left this project (`false`) or came back to it (`true`). While away it stays silent and keeps
    /// listing what Claude said; on return the user chooses what to hear.
    public func setActive(_ active: Bool) {
        guard active != isActive else { return }
        if !active {
            // A reply still streaming when the user left counts as missed from its start.
            if let id = assistantEntryID, snapshot.transcript.last(where: { $0.id == id })?.status == .streaming {
                attendedThrough = min(attendedThrough, id - 1)
            } else {
                attendedThrough = snapshot.transcript.last?.id ?? attendedThrough
            }
            isActive = false
            output.stopAll()
            publish()
            return
        }
        isActive = true
        let missed = snapshot.transcript.contains { $0.role == .assistant && $0.id > attendedThrough && !$0.spoken.isEmpty }
        if missed {
            catchUpOpen = true
            publish()
        } else {
            attendedThrough = snapshot.transcript.last?.id ?? attendedThrough
            publish()
            repromptWaitingQuestion()
        }
    }

    /// Plays the replies the user missed (all of them from the first, or only the last), or none, and returns the
    /// project to normal.
    public func resolveCatchUp(_ choice: CatchUpChoice, speakReprompt: Bool = true) {
        guard catchUpOpen else { return }
        let missed = snapshot.missedMessages
        catchUpOpen = false
        attendedThrough = snapshot.transcript.last?.id ?? attendedThrough
        var sentences: [String] = []
        switch choice {
        case .fromFirstMissed: sentences = missed.flatMap(\.sentences)
        case .lastMessage: sentences = missed.last?.sentences ?? []
        case .skip: break
        }
        log.log(.info, .engine, "catchUp", ["choice": "\(choice)", "messages": .int(missed.count), "sentences": .int(sentences.count)])
        publish()
        if !sentences.isEmpty { speak(sentences.map { make($0, .prose) }, record: false, force: true) }
        if speakReprompt { repromptWaitingQuestion() }
    }

    /// Says again what is waiting for the user's decision, because it was swallowed while they were away.
    private func repromptWaitingQuestion() {
        if let p = snapshot.pendingPermission {
            speak([make(permissionPrompt(for: p), .prompt)], record: false, force: true)
        } else if let offer = snapshot.grantOffer {
            speak([make(offer.text, .prompt)], record: false, force: true)
        }
    }

    // MARK: - Folder access

    private func finishProjectSwitch(text: String, matched: Bool) {
        if matched {
            appendEntry(.user, text, status: .done)
            publish()
        } else {
            process(text, allowProjectSwitch: false)
        }
    }

    /// Called with the name the user spoke; returns true if it matched an open project and the app switched to it.
    public func setProjectSwitchHandler(_ handler: (@Sendable (String) async -> Bool)?) {
        projectSwitchHandler = handler
    }

    public func setGrantHandler(_ handler: (@Sendable (FolderGrantChange) -> Void)?) {
        grantHandler = handler
    }

    /// Replaces the folder grants in force, for example after the user removed one in Settings.
    public func setFolderGrants(_ grants: [FolderGrant]) {
        config.folderGrants = grants
        policy = PermissionPolicy(projectRoot: config.projectRoot, pronunciation: pronunciation, grants: grants, voiceFromSummary: config.approveByVoiceFromSummary)
    }

    /// Asks whether Claude may work in the project folder without asking each time. Edits and shell commands are
    /// separate questions; each takes two yes answers.
    public func offerFolderGrant(shell: Bool = false) {
        guard let root = config.projectRoot, snapshot.pendingPermission == nil, snapshot.grantOffer == nil else { return }
        let folder = FolderScope.resolved(root)
        // Never offer standing access to the whole disk, the home folder, or a folder that holds PairVox's own
        // settings or Claude Code's configuration: those would let a model-driven edit rewrite the consent store.
        if folder == "/" || folder == FolderScope.resolved(NSHomeDirectory())
            || PermissionPolicy.protectedFolders.contains(where: { FolderScope.contains(folder: folder, path: $0) }) { return }
        let existing = config.folderGrants.first { $0.path == folder }
        if shell ? (existing?.allowShell ?? false) : existing != nil { return }
        if shell && existing == nil { return }   // shell access builds on the edit grant
        setOffer(GrantOffer(folder: folder, kind: shell ? .shell : .edit, stage: .asking, text: ""), stage: .asking)
    }

    /// Answers the open folder question. Called by voice and by the buttons, so both follow the same two steps.
    public func answerGrantOffer(yes: Bool) {
        guard var offer = snapshot.grantOffer else { return }
        guard yes else {
            snapshot.grantOffer = nil
            if offer.kind == .edit { grantHandler?(.declined(path: offer.folder)) }
            log.log(.info, .policy, "folderGrant.declined", ["kind": "\(offer.kind)", "stage": "\(offer.stage)"])
            speak([make("Okay, I'll keep asking.", .notice)], record: false, force: true)
            publish()
            return
        }
        switch offer.stage {
        case .asking:
            setOffer(offer, stage: .confirming)
        case .confirming:
            offer.stage = .confirming
            snapshot.grantOffer = nil
            let shell = offer.kind == .shell
            if let i = config.folderGrants.firstIndex(where: { $0.path == offer.folder }) {
                if shell { config.folderGrants[i].allowShell = true }
            } else {
                config.folderGrants.append(FolderGrant(path: offer.folder, allowShell: false))
            }
            policy = PermissionPolicy(projectRoot: config.projectRoot, pronunciation: pronunciation, grants: config.folderGrants, voiceFromSummary: config.approveByVoiceFromSummary)
            grantHandler?(.granted(path: offer.folder, shell: shell))
            log.log(.info, .policy, "folderGrant.granted", ["kind": "\(offer.kind)"])
            appendEntry(.system, shell ? "Shell commands in \(offer.folder) are now allowed without asking."
                                       : "Edits inside \(offer.folder) are now allowed without asking.", status: .done)
            speak([make(shell ? "Done. Commands inside the folder will run without asking. You can turn this off in Settings."
                              : "Done. I'll stop asking about edits in this folder. You can remove this in Settings.", .notice)],
                  record: false, force: true)
            publish()
        }
    }

    public func dismissGrantOffer() {
        guard snapshot.grantOffer != nil else { return }
        snapshot.grantOffer = nil
        publish()
    }

    private func setOffer(_ offer: GrantOffer, stage: GrantOffer.Stage) {
        var o = offer
        o.stage = stage
        let spokenPath = pronunciation.speak(o.folder)
        switch (o.kind, stage) {
        case (.edit, .asking):
            o.text = "This project works in \(spokenPath). Do you want to allow Claude to edit all files inside it without asking each time? Say yes or no."
        case (.edit, .confirming):
            o.text = "To confirm: Claude will be able to edit every file inside \(spokenPath), with no further questions, until you remove this in Settings. Shell commands are not included. Say confirm to allow it, or no."
        case (.shell, .asking):
            o.text = "Do you also want Claude to run shell commands inside \(spokenPath) without asking? Commands that reach outside the folder, use the network or install things will still ask. Say yes or no."
        case (.shell, .confirming):
            o.text = "To confirm: Claude will be able to run commands inside \(spokenPath) with no further questions, until you turn this off in Settings. Say confirm to allow it, or no."
        }
        snapshot.grantOffer = o
        speak([make(o.text, .prompt)], record: false, force: true)
        publish()
    }

    /// Asks the advisor a question about the request on screen. The answer is advice only: it never approves
    /// or denies anything.
    public func askAboutPending(_ question: String, spoken: Bool = false) {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let advisor, var pending = snapshot.pendingPermission, !q.isEmpty else { return }
        guard pending.questions.count < Self.maxQuestionsPerRequest else {
            speak([make("That is enough questions for this one. Please decide, or say no and tell Claude what to do instead.", .notice)],
                  record: false, force: true)
            return
        }
        let turn = AdvisorTurn(id: pending.questions.count + 1, question: q)
        let earlier = pending.questions
        pending.questions.append(turn)
        snapshot.pendingPermission = pending
        publish()
        let id = pending.request.requestID, project = config.projectRoot
        let (request, assessment) = (pending.request, pending.assessment)
        let task = Task { [weak self] in
            let result: Result<String, Error>
            do { result = .success(try await advisor.answer(q, about: request, assessment: assessment, project: project, earlier: earlier)) }
            catch { result = .failure(error) }
            await self?.questionAnswered(requestID: id, turnID: turn.id, result: result, spoken: spoken)
        }
        advisorTasks[id, default: []].append(task)
    }

    private func questionAnswered(requestID: String, turnID: Int, result: Result<String, Error>, spoken: Bool) {
        guard var pending = snapshot.pendingPermission, pending.request.requestID == requestID,
              let i = pending.questions.firstIndex(where: { $0.id == turnID }) else { return }
        switch result {
        case .success(let text):
            pending.questions[i].answer = text
            log.log(.info, .policy, "advisor.answer", ["ok": .bool(true)])
            if spoken { speak([make(Self.speakableAdvice(text), .notice)], record: false, force: true) }
        case .failure:
            pending.questions[i].failed = true
            pending.questions[i].answer = "I couldn't get an answer to that."
            log.log(.info, .policy, "advisor.answer", ["ok": .bool(false)])
            if spoken { speak([make("I couldn't get an answer to that.", .notice)], record: false, force: true) }
        }
        snapshot.pendingPermission = pending
        publish()
    }

    /// Advice text comes from a model that read the request, so it may be steered. A sentence that would itself
    /// work as a spoken approval ("Allow.", "Yes, always allow", "Confirm high risk") is dropped before it is read
    /// aloud, so PairVox cannot end up answering its own question when the microphone hears it back.
    static func speakableAdvice(_ text: String) -> String {
        let context = VoiceCommand.Context(awaitingPermission: true, awaitingHighRiskConfirmation: true)
        let sentences = text.split(whereSeparator: { ".!?\n".contains($0) }).map { String($0).trimmingCharacters(in: .whitespaces) }
        let kept = sentences.filter { sentence in
            guard !sentence.isEmpty else { return false }
            // Anything holding the high-risk phrase is dropped whatever its length: the announcement grammar accepts
            // the phrase with a project name after it, which is longer than the engine's own limit.
            let w = VoiceCommand.normalize(sentence)
            if w.joined(separator: " ").contains("confirm high risk") { return false }
            // "confirm, high risk" or "confirm high-risk": the same words with punctuation between them.
            if let i = w.indices.first(where: { $0 + 1 < w.count && w[$0] == "high" && w[$0 + 1] == "risk" }),
               w[max(0, i - 3)..<i].contains("confirm") { return false }
            if AnnouncementReply.parse(sentence, projectNames: []) != .notForUs { return false }
            switch VoiceCommand.parse(sentence, context: context) {
            case .approve?, .approveAlways?, .confirmHighRisk?, .approveAllWaiting?: return false
            default: return true
            }
        }
        return kept.isEmpty ? "There is nothing more to add. Please decide on screen." : kept.joined(separator: ". ") + "."
    }

    private func startExplanation(_ pending: PendingPermission) {
        guard let advisor, config.explainRequests else { return }
        var p = pending
        p.explanation = .loading
        snapshot.pendingPermission = p
        let id = pending.request.requestID, project = config.projectRoot
        let (request, assessment) = (pending.request, pending.assessment)
        let task = Task { [weak self] in
            let result: Result<String, Error>
            do { result = .success(try await advisor.summarize(request, assessment: assessment, project: project)) }
            catch { result = .failure(error) }
            await self?.explanationArrived(requestID: id, result: result)
        }
        advisorTasks[id, default: []].append(task)
    }

    private func explanationArrived(requestID: String, result: Result<String, Error>) {
        guard var pending = snapshot.pendingPermission, pending.request.requestID == requestID else { return }
        switch result {
        case .success(let text):
            pending.explanation = .ready(text)
            log.log(.info, .policy, "advisor.summary", ["ok": .bool(true)])
            if speakExplanationFor == requestID {
                speakExplanationFor = nil
                speak([make(Self.speakableAdvice(text), .notice)], record: false, force: true)
            }
        case .failure:
            pending.explanation = .unavailable
            log.log(.info, .policy, "advisor.summary", ["ok": .bool(false)])
            if speakExplanationFor == requestID {
                speakExplanationFor = nil
                speak([make("I couldn't get an explanation for this one.", .notice)], record: false, force: true)
            }
        }
        snapshot.pendingPermission = pending
        publish()
    }

    private func cancelAdvisorWork(for id: String? = nil) {
        if let id {
            advisorTasks.removeValue(forKey: id)?.forEach { $0.cancel() }
        } else {
            advisorTasks.values.joined().forEach { $0.cancel() }
            advisorTasks.removeAll()
        }
        speakExplanationFor = nil
    }

    /// Allows the waiting requests the user was shown. High-risk requests and anything that needs the screen are
    /// never included, whatever ids are passed.
    public func approveAllWaiting(requestIDs: [String]) {
        let ids = Set(requestIDs)
        func eligible(_ p: PendingPermission) -> Bool { ids.contains(p.request.requestID) && p.assessment.voiceApprovable }
        var kept: [PendingPermission] = []
        for p in permissionQueue {
            if eligible(p) { sendDecision(p.request, .allow) } else { kept.append(p) }
        }
        permissionQueue = kept
        snapshot.queuedPermissions = kept
        if let head = snapshot.pendingPermission, eligible(head) { respondToPermission(head.request, decision: .allow) }
        publish()
    }

    /// A high-risk request the user may confirm by saying the phrase. Anything Claude Code says needs the user at
    /// the screen stays a click.
    /// Spoken confirmation applies to anything the policy would not let a plain yes approve: high risk, or too long
    /// or complex to read out. Requests Claude Code says need the screen have their own switch.
    private func canConfirmHighRiskByVoice(_ p: PendingPermission) -> Bool {
        config.spokenHighRiskConfirmation && !p.assessment.voiceApprovable
            && (!p.request.needsPersonAtScreen || config.voiceApprovesNeedsScreen)
    }

    public func interruptClaude() {
        perform(.interruptClaude)
    }

    public func stopSpeaking() {
        perform(.stopSpeaking)
    }

    /// Applies from the next reply.
    public func setSpokenReplyLimit(_ limit: Int) {
        config.spokenReplyLimit = max(0, limit)
        planner.spokenLimit = config.spokenReplyLimit
    }

    public func setSpeechMode(_ mode: SpeechMode) {
        config.speechMode = mode
        planner.mode = mode
        snapshot.speechMode = mode
        publish()
    }

    public func setVerbosity(_ v: Verbosity) {
        config.verbosity = v
        planner.verbosity = v
        snapshot.verbosity = v
        publish()
    }

    public func setConversationMode(_ mode: ConversationMode) {
        config.conversationMode = mode
        snapshot.conversationMode = mode
        try? backend?.setPermissionMode(mode.permissionMode)
        publish()
    }

    /// Updates the user pronunciation dictionary without restarting the session.
    public func setPronunciation(_ dictionary: [String: String]) {
        config.pronunciation = dictionary
        pronunciation = Pronunciation(dictionary: dictionary)
        policy = PermissionPolicy(projectRoot: config.projectRoot, pronunciation: pronunciation, grants: config.folderGrants, voiceFromSummary: config.approveByVoiceFromSummary)
        planner.pronunciation = pronunciation
    }

    public func setModel(_ model: String?) {
        try? backend?.setModel(model)
    }

    public func setSpeechRate(_ rate: Double) {
        let r = min(max(rate, 0.6), 1.8)
        config.speechRate = r
        snapshot.speechRate = r
        output.setRate(r)
        publish()
    }

    public func newSession() { restart(resume: nil) }

    /// Continues an earlier Claude Code session. Anything that is not a session UUID is refused.
    public func resumeSession(id: String) {
        guard SessionCatalog.isValidSessionID(id) else { return }
        restart(resume: id)
    }

    private func restart(resume: String?) {
        startedIDs.removeAll()
        pausedBargeIn = false
        pausedRemaining = []
        output.stopAll()
        queued.removeAll()
        queueOrder.removeAll()
        backend?.stop()
        resetTurnState()
        sendTimes.removeAll()
        snapshot.pendingPermission = nil
        permissionQueue.removeAll()
        snapshot.queuedPermissions = []
        cancelAdvisorWork()
        snapshot.session = nil
        snapshot.isClaudeWorking = false
        appendEntry(.system, resume == nil ? "New session started." : "Resuming an earlier session.", status: .done)
        openBackend(resume: resume)
        recomputePhase()
    }

    // MARK: - Commands

    public func perform(_ command: VoiceCommand) {
        if command != .backchannel { commitPausedBargeIn() }
        log.log(.info, .engine, "command", ["name": "\(command)"])
        switch command {
        case .stopSpeaking:
            output.stopAll()
            queued.removeAll(); queueOrder.removeAll()
            dropRemainder()
            turnMuted = !sendTimes.isEmpty
        case .interruptClaude:
            output.stopAll()
            queued.removeAll(); queueOrder.removeAll()
            dropRemainder()
            if !sendTimes.isEmpty {
                turnMuted = true
                try? backend?.interrupt()
            }
        case .repeatLast:
            dropRemainder()
            let source = utterancesThisTurn > 0 ? planner.spokenThisTurn : (lastPlanner?.spokenThisTurn ?? [])
            let replay = source.filter { $0.kind != .ack && $0.kind != .narration }
            speak(replay.isEmpty ? [make("I haven't said anything yet.", .notice)] : replay.map { make($0.text, $0.kind) },
                  record: false)
        case .readMore:
            if !sendTimes.isEmpty {
                // Reply still coming: finish the summary, then read the detail when the turn ends.
                resumeRemainder()
                readMoreWhenDone = true
            } else if !interruptedRemainder.isEmpty {
                resumeRemainder()
            } else if let held = lastPlanner?.heldBack, !held.isEmpty {
                speak(held.map { make($0.text, $0.kind) }, record: false)
                lastPlanner = lastPlanner.map { var p = $0; p.clearHeldBack(); return p }
                snapshot.hasHeldBack = false
            } else {
                speak([make("That's everything.", .notice)], record: false)
            }
        case .readCode:
            dropRemainder()
            let code = planner.codeReadings.isEmpty ? (lastPlanner?.codeReadings ?? []) : planner.codeReadings
            speak(code.isEmpty ? [make("There's no code in the last reply.", .notice)] : code.map { make($0.text, .code) },
                  record: false)
        case .skip:
            // Skip the current utterance, keep the rest.
            let rest = Array((interruptedRemainder.isEmpty ? queueOrder.compactMap { queued[$0] } : interruptedRemainder).dropFirst())
            output.stopAll()
            queued.removeAll(); queueOrder.removeAll()
            interruptedRemainder = []
            holdSpeech = false
            speak(rest.map { make($0.text, $0.kind) }, record: false)
        case .setSpeechMode(let mode):
            setSpeechMode(mode)
            speak([make("\(mode.spokenName.capitalized) mode.", .notice)], record: false)
            resumeRemainder()
        case .setConversationMode(let mode):
            setConversationMode(mode)
            let msg = mode == .brainstorm ? "Brainstorm mode. I won't change any files." : "Execute mode. I'll make changes when you ask."
            dropRemainder()
            speak([make(msg, .notice)], record: false)
        case .approve, .approveAlways:
            guard !catchUpOpen else { break }   // never approve what has not been announced yet
            if snapshot.pendingPermission == nil, let offer = snapshot.grantOffer {
                // Standing access takes a deliberate answer: one word to open it, the word "confirm" to finish it.
                // A longer sentence, or one that begins "say", could be PairVox's own prompt heard back.
                let w = lastUtteranceWords
                let deliberate = w.first != "say"
                    && (offer.stage == .asking ? w.count <= 2 : (w.contains("confirm") && w.count <= 3))
                if deliberate { answerGrantOffer(yes: true) } else {
                    speak([make(offer.stage == .asking ? "Please answer yes or no." : "To grant it, say confirm. Or say no.", .notice)],
                          record: false, force: true)
                }
                break
            }
            // Spoken approvals only count for requests the policy rates as voice-approvable.
            guard let pending = snapshot.pendingPermission else { break }
            if pending.assessment.voiceApprovable {
                approvePending(always: command == .approveAlways)
            } else if canConfirmHighRiskByVoice(pending) {
                speak([make("That one is high risk. Say confirm high risk to allow it, or use the button.", .notice)],
                      record: false, force: true)
            } else {
                speak([make("That one needs a click. Please confirm it on screen.", .notice)], record: false, force: true)
            }
        case .catchUp(let choice):
            resolveCatchUp(choice)
        case .switchProject:
            break   // handled in submit, where the open projects are known
        case .approveAllWaiting:
            guard let head = snapshot.pendingPermission else { break }
            let waiting = [head] + permissionQueue
            let eligible = waiting.filter { $0.assessment.voiceApprovable }
            guard !eligible.isEmpty else {
                speak([make("None of these can be allowed by voice. Please use the buttons.", .notice)], record: false, force: true)
                break
            }
            if let armed = approveAllArmed {
                approveAllArmed = nil
                approveAllWaiting(requestIDs: Array(armed))
            } else {
                // Read what would be allowed first; a second \"allow all\" does it.
                approveAllArmed = Set(eligible.map(\.request.requestID))
                let items = eligible.map { $0.assessment.spokenPrompt.replacingOccurrences(of: " Allow?", with: "") }
                let skipped = waiting.count - eligible.count
                var text = "\(eligible.count) \(eligible.count == 1 ? "request" : "requests") can be allowed together. " + items.joined(separator: ". Then, ") + ". "
                if skipped > 0 { text += "\(skipped) high-risk \(skipped == 1 ? "one" : "ones") will still ask. " }
                text += "Say allow all again to allow them."
                speak([make(text, .prompt)], record: false, force: true)
            }
        case .explain:
            guard let pending = snapshot.pendingPermission else { break }
            switch pending.explanation {
            case .ready(let text): speak([make(Self.speakableAdvice(text), .notice)], record: false, force: true)
            case .loading: speakExplanationFor = pending.request.requestID
            default: speak([make("I don't have an explanation for this one. Say yes or no, or ask me a question.", .notice)], record: false, force: true)
            }
        case .confirmHighRisk:
            guard !catchUpOpen, let pending = snapshot.pendingPermission, canConfirmHighRiskByVoice(pending) else { break }
            log.log(.info, .policy, "permission.spokenHighRisk", ["tool": .string(pending.request.toolName)])
            if let confirm = secondConfirmation {
                // Touch ID or the login password, asked after the spoken phrase.
                let id = pending.request.requestID
                Task { [weak self] in
                    let ok = await confirm()
                    await self?.finishSecondConfirmation(requestID: id, confirmed: ok)
                }
            } else {
                approvePending(requestID: pending.request.requestID)
            }
        case .deny:
            if snapshot.pendingPermission == nil, snapshot.grantOffer != nil { answerGrantOffer(yes: false); break }
            denyPending()
        case .newSession:
            newSession()
            speak([make("Starting a new session.", .notice)], record: false)
        case .faster:
            setSpeechRate(config.speechRate + 0.1)
            resumeRemainder()
        case .slower:
            setSpeechRate(config.speechRate - 0.1)
            resumeRemainder()
        case .backchannel:
            // Just acknowledging: keep talking, keep working.
            resumeRemainder()
        }
        // Any speech held for a barge-in that the command didn't resume is dropped,
        // so later replies are never stuck behind it.
        if holdSpeech { dropRemainder() }
        recomputePhase()
    }

    // MARK: - Session events

    private func handleSession(_ event: SessionEvent, generation: Int) {
        guard generation == backendGeneration else { return }
        switch event {
        case .started(let info):
            log.log(.info, .session, "session.started", ["info": "\(info)"])
            snapshot.session = info
            snapshot.authProblem = nil
            spokenAuthProblem = false

        case .status:
            break

        case .textDelta(let t):
            if !firstTokenSeen, let start = sendTimes.first {
                firstTokenSeen = true
                latency.firstToken = Date().timeIntervalSince(start)
            }
            appendAssistantText(t)
            speakFromPlanner(planner.textDelta(t))

        case .textBlockEnded:
            speakFromPlanner(planner.textBlockEnded())
            if let id = assistantEntryID { updateEntry(id) { $0.status = .done } }

        case .thinking:
            break

        case .toolUse(let tool):
            guard !tool.isSubagent else { break }
            assistantEntryID = nil
            appendEntry(.tool, ToolSummary.describe(tool), status: .done)
            speakFromPlanner(planner.toolUse(tool))

        case .toolResult:
            break

        case .permissionRequested(let request):
            let assessment = policy.assess(request)
            if assessment.coveredByFolderGrant {
                log.log(.info, .policy, "permission.folderGrant", ["tool": .string(request.toolName)])
                try? backend?.respond(to: request, decision: .allow)
                appendEntry(.system, "Allowed by your folder access: \(assessment.summary)", status: .done)
                break
            }
            let auto = config.autoApproveLowRisk && assessment.autoApprovable
            log.log(.info, .policy, "permission.requested",
                    ["tool": .string(request.toolName), "risk": "\(assessment.risk)", "autoApproved": .bool(auto),
                     "queued": .bool(snapshot.pendingPermission != nil)])
            if auto {
                try? backend?.respond(to: request, decision: .allow)
                break
            }
            let pending = PendingPermission(request: request, assessment: assessment)
            if snapshot.pendingPermission != nil {
                // Never replace the request the user is looking at or has just heard.
                permissionQueue.append(pending)
                snapshot.queuedPermissions = permissionQueue
            } else {
                showPermission(pending)
            }

        case .permissionCancelled(let id):
            permissionQueue.removeAll { $0.request.requestID == id }
            snapshot.queuedPermissions = permissionQueue
            if snapshot.pendingPermission?.request.requestID == id {
                snapshot.pendingPermission = nil
                promoteNextPermission()
            }

        case .turnCompleted(let result):
            completeTurn(result)

        case .rateLimit(let info):
            snapshot.usage.fiveHourUtilization = info.fiveHourUtilization ?? snapshot.usage.fiveHourUtilization
            snapshot.usage.sevenDayUtilization = info.sevenDayUtilization ?? snapshot.usage.sevenDayUtilization
            snapshot.usage.limitResetsAt = info.resetsAt
            snapshot.usage.limitStatus = info.status

        case .authProblem(let message):
            noteProblem(message)

        case .notice(let message):
            snapshot.lastNotice = message
            speak([make(message, .notice)], record: false, force: true)

        case .processExited(let code, let stderr):
            log.log(code == 0 ? .info : .error, .session, "process.exited",
                    ["code": .int(Int(code)), "stderrTail": .string(String(stderr.suffix(400))),
                     "turnInFlight": .bool(!sendTimes.isEmpty)])
            if !sendTimes.isEmpty {
                let detail = code == 0 ? "" : " (exit code \(code))"
                snapshot.lastNotice = "Claude Code stopped unexpectedly\(detail)."
                if let id = assistantEntryID { updateEntry(id) { $0.status = .failed } }
                speak([make("Claude Code stopped unexpectedly. Say it again to retry.", .notice)], record: false, force: true)
                sendTimes.removeAll()
                resetTurnState()
                snapshot.isClaudeWorking = false
            }
            snapshot.pendingPermission = nil
            permissionQueue.removeAll()
            snapshot.queuedPermissions = []
            cancelAdvisorWork()
            if code != 0, !stderr.isEmpty { snapshot.lastNotice = String(stderr.suffix(300)) }
        }
        recomputePhase()
    }

    private func completeTurn(_ result: TurnResult) {
        func ms(_ t: TimeInterval?) -> LogValue { t.map { .int(Int($0 * 1000)) } ?? .int(-1) }
        log.log(.info, .engine, "turn.completed",
                ["outcome": "\(result.outcome)", "durationMs": .int(result.durationMs), "numTurns": .int(result.numTurns),
                 "firstTokenMs": ms(latency.firstToken), "firstUtteranceMs": ms(latency.firstUtterance),
                 "firstAudioMs": ms(latency.firstAudio), "utterances": .int(utterancesThisTurn)])
        var final = planner.finishTurn(result)
        if readMoreWhenDone {
            readMoreWhenDone = false
            final.removeAll { $0.kind == .prompt }
            final += planner.heldBack.map { make($0.text, $0.kind) }
            planner.clearHeldBack()
        }
        speakFromPlanner(final)
        if let id = assistantEntryID {
            updateEntry(id) {
                switch result.outcome {
                case .success: $0.status = .done
                case .interrupted: $0.status = .interrupted
                case .failed: $0.status = .failed
                }
            }
        }
        if case .interrupted = result.outcome, assistantEntryID == nil {
            appendEntry(.system, "Interrupted.", status: .interrupted)
        }
        snapshot.usage.turns += 1
        if authKind == .apiKey { snapshot.usage.costUSD += result.costUSD }
        snapshot.lastLatency = latency
        snapshot.pendingPermission = nil

        lastPlanner = planner
        snapshot.hasHeldBack = !planner.heldBack.isEmpty
        if !sendTimes.isEmpty { sendTimes.removeFirst() }
        resetTurnState()
        snapshot.isClaudeWorking = !sendTimes.isEmpty
        if snapshot.isClaudeWorking { scheduleAcknowledgement() }
    }

    private func resetTurnState() {
        planner = SpeechPlanner(mode: config.speechMode, verbosity: config.verbosity, pronunciation: pronunciation, ids: ids,
                                spokenLimit: config.spokenReplyLimit)
        assistantEntryID = nil
        turnMuted = false
        latency = TurnLatency()
        utterancesThisTurn = 0
        firstTokenSeen = false
        ackTask?.cancel()
        readMoreWhenDone = false
    }

    // MARK: - Speech output events

    private func handleOutput(_ event: SpeechOutputEvent) {
        switch event {
        case .started(let id):
            log.log(.debug, .tts, "utterance.started", ["id": .int(id)])
            startedIDs.insert(id)
            guard queued[id] != nil else { return }
            snapshot.isSpeaking = true
            if measuredIDs.contains(id), latency.firstAudio == nil, let start = sendTimes.first {
                latency.firstAudio = Date().timeIntervalSince(start)
            }
        case .finished(let id), .failed(let id, _):
            startedIDs.remove(id)
            if case .failed(_, let why) = event {
                log.log(.error, .tts, "utterance.failed", ["id": .int(id), "reason": .string(why)])
            } else {
                log.log(.debug, .tts, "utterance.finished", ["id": .int(id)])
            }
            queued.removeValue(forKey: id)
            queueOrder.removeAll { $0 == id }
            measuredIDs.remove(id)
        case .idle:
            if queueOrder.isEmpty { snapshot.isSpeaking = false }
        }
        recomputePhase()
    }

    // MARK: - Helpers

    private func sendUserMessage(_ text: String) {
        appendEntry(.user, text, status: .done)
        guard let backend else {
            noteProblem("No Claude Code session.")
            return
        }
        do {
            try backend.send(text)
        } catch {
            noteProblem("\(error)")
            return
        }
        if sendTimes.isEmpty {
            resetTurnState()
        }
        sendTimes.append(Date())
        snapshot.isClaudeWorking = true
        scheduleAcknowledgement()
        recomputePhase()
    }

    private func scheduleAcknowledgement() {
        guard config.acknowledgements else { return }
        ackTask?.cancel()
        let delay = config.acknowledgementDelay
        let seed = snapshot.usage.turns + snapshot.transcript.count
        ackTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.speakAcknowledgementIfSilent(seed: seed)
        }
    }

    private func speakAcknowledgementIfSilent(seed: Int) {
        guard !sendTimes.isEmpty, utterancesThisTurn == 0, !turnMuted, !holdSpeech,
              snapshot.pendingPermission == nil, queueOrder.isEmpty else { return }
        speak([make(planner.acknowledgement(seed: seed), .ack)], record: false)
    }

    private func respondToPermission(_ request: PermissionRequest, decision: PermissionDecision) {
        cancelAdvisorWork(for: request.requestID)
        sendDecision(request, decision)
        snapshot.pendingPermission = nil
        promoteNextPermission()
        recomputePhase()
    }

    private func sendDecision(_ request: PermissionRequest, _ decision: PermissionDecision) {
        log.log(.info, .policy, "permission.decided", ["tool": .string(request.toolName), "decision": .string({
            switch decision {
            case .allow: return "allow"
            case .allowAlways: return "allowAlways"
            case .deny: return "deny"
            }
        }())])
        do {
            try backend?.respond(to: request, decision: decision)
        } catch {
            snapshot.lastNotice = "\(error)"
        }
        appendEntry(.system, {
            switch decision {
            case .allow: return "Approved."
            case .allowAlways: return "Approved (don't ask again this session)."
            case .deny: return "Denied."
            }
        }(), status: .done)
    }

    private func showPermission(_ pending: PendingPermission) {
        snapshot.grantOffer = nil   // a real request outranks the standing-access question
        snapshot.pendingPermission = pending
        ackTask?.cancel()
        speak([make(permissionPrompt(for: pending), .prompt)], record: false, force: true)
        startExplanation(pending)
    }

    private func permissionPrompt(for pending: PendingPermission) -> String {
        var prompt = pending.assessment.spokenPrompt
        if canConfirmHighRiskByVoice(pending) {
            let lead = pending.assessment.risk == .high ? " This is high risk." : " This one needs care."
            var tail = ""
            if case .ready(let why) = pending.explanation { tail = " " + why }
            prompt = prompt.replacingOccurrences(of: " Please confirm on screen.",
                                                 with: lead + tail + " Say confirm high risk to allow it, or use the button.")
        }
        return prompt
    }

    private func promoteNextPermission() {
        guard snapshot.pendingPermission == nil, !permissionQueue.isEmpty else {
            snapshot.queuedPermissions = permissionQueue
            return
        }
        let next = permissionQueue.removeFirst()
        snapshot.queuedPermissions = permissionQueue
        showPermission(next)
    }

    private func speakFromPlanner(_ utterances: [Utterance]) {
        guard !utterances.isEmpty else { return }
        if let id = assistantEntryID {
            let spokenText = utterances.filter { $0.kind == .prose || $0.kind == .code }.map(\.text)
            if !spokenText.isEmpty { updateEntry(id) { $0.spoken += spokenText } }
        }
        if turnMuted { return }
        speak(utterances, record: true)
    }

    /// Queues utterances. While the user is mid-barge-in, speech is held until we know what they said.
    private func speak(_ utterances: [Utterance], record: Bool, force: Bool = false) {
        guard !utterances.isEmpty else { return }
        if holdSpeech && !force {
            interruptedRemainder += utterances
            return
        }
        dropCourtesyLinesBeforeSubstance(utterances)
        for u in utterances {
            queued[u.id] = u
            queueOrder.append(u.id)
            if record && u.kind != .ack { measuredIDs.insert(u.id) }
            output.enqueue(u)
            if record && u.kind != .ack {
                utterancesThisTurn += 1
                ackTask?.cancel()
                if latency.firstUtterance == nil, let start = sendTimes.first {
                    latency.firstUtterance = Date().timeIntervalSince(start)
                }
            }
        }
        recomputePhase()
    }

    /// An acknowledgement ("On it.") or a line of tool narration that is still waiting to be spoken is only there to fill a
    /// silence. Once the answer itself is ready it would just make the answer wait, so it is dropped. One that is already
    /// being spoken finishes.
    private func dropCourtesyLinesBeforeSubstance(_ incoming: [Utterance]) {
        guard incoming.contains(where: { [.prose, .code, .prompt, .notice].contains($0.kind) }) else { return }
        let courtesy = queueOrder.filter { id in
            guard let u = queued[id], u.kind == .ack || u.kind == .narration else { return false }
            return !startedIDs.contains(id)
        }
        guard !courtesy.isEmpty else { return }
        let removed = Set(output.cancelQueued(courtesy))
        guard !removed.isEmpty else { return }
        for id in removed { queued[id] = nil }
        queueOrder.removeAll { removed.contains($0) }
        log.log(.info, .engine, "courtesy.dropped", ["count": .int(removed.count)])
    }

    /// The user made a noise but said nothing: carry on where we stopped.
    private func resumeAfterFalseBargeIn() {
        if pausedBargeIn { resumePausedInPlace(); return }
        guard !interruptedRemainder.isEmpty || holdSpeech else { return }
        resumeRemainder()
    }

    private func resumeRemainder() {
        holdSpeech = false
        let items = interruptedRemainder
        interruptedRemainder = []
        speak(items.map { make($0.text, $0.kind) }, record: false)
    }

    private func dropRemainder() {
        holdSpeech = false
        interruptedRemainder = []
    }

    private func make(_ text: String, _ kind: Utterance.Kind) -> Utterance {
        Utterance(id: ids.make(), text: text, kind: kind)
    }

    private func noteProblem(_ message: String) {
        log.log(.error, .engine, "problem", ["message": .string(message)])
        snapshot.authProblem = message
        snapshot.phase = .needsSetup
        if !spokenAuthProblem {
            spokenAuthProblem = true
            let spoken: String
            if EventTranslator.looksLikeAuthProblem(message) {
                spoken = authKind == .apiKey
                    ? "Claude Code rejected the API key. Check it in Settings."
                    : "Claude Code isn't signed in. Open Terminal, run claude, sign in, then try again."
            } else {
                spoken = "I couldn't reach Claude Code. Check the setup screen."
            }
            speak([make(spoken, .notice)], record: false, force: true)
        }
        publish()
    }

    private func appendAssistantText(_ t: String) {
        if let id = assistantEntryID {
            updateEntry(id) { $0.text += t; $0.status = .streaming }
        } else {
            assistantEntryID = appendEntry(.assistant, t, status: .streaming)
        }
    }

    @discardableResult
    private func appendEntry(_ role: TranscriptEntry.Role, _ text: String, status: TranscriptEntry.Status) -> Int {
        let id = nextEntryID
        nextEntryID += 1
        snapshot.transcript.append(TranscriptEntry(id: id, role: role, text: text, status: status))
        if snapshot.transcript.count > 600 { snapshot.transcript.removeFirst(snapshot.transcript.count - 600) }
        return id
    }

    private func updateEntry(_ id: Int, _ change: (inout TranscriptEntry) -> Void) {
        guard let i = snapshot.transcript.lastIndex(where: { $0.id == id }) else { return }
        change(&snapshot.transcript[i])
        if case .assistant = snapshot.transcript[i].role {
            snapshot.transcript[i].skipped = planner.skipped
        }
    }

    private func recomputePhase() {
        if snapshot.phase == .needsSetup, snapshot.authProblem != nil {
            publish()
            return
        }
        if userIsSpeaking {
            snapshot.phase = .listening
        } else if transcribing {
            snapshot.phase = .transcribing
        } else if snapshot.pendingPermission != nil {
            snapshot.phase = .awaitingPermission
        } else if snapshot.isSpeaking || !queueOrder.isEmpty {
            snapshot.phase = .speaking
        } else if !sendTimes.isEmpty {
            snapshot.phase = utterancesThisTurn > 0 ? .working : .thinking
        } else {
            snapshot.phase = .idle
        }
        publish()
    }

    private func publish() {
        // Everything that happens while the user is here counts as heard; only what arrives while away is missed.
        if isActive, !catchUpOpen { attendedThrough = snapshot.transcript.last?.id ?? attendedThrough }
        snapshot.isActive = isActive
        snapshot.awaitingCatchUpChoice = catchUpOpen
        snapshot.missedMessages = (isActive && !catchUpOpen) ? [] : snapshot.transcript.compactMap { e in
            guard e.role == .assistant, e.id > attendedThrough, !e.spoken.isEmpty else { return nil }
            return MissedMessage(entryID: e.id, sentences: e.spoken, date: e.date)
        }
        snapshotContinuation.yield(snapshot)
    }
}

/// Short on-screen labels for tool calls.
public enum ToolSummary {
    public static func describe(_ tool: ToolUse) -> String {
        let i = tool.input
        switch tool.name {
        case "Read", "Write", "Edit", "MultiEdit":
            return "\(tool.name) \(i["file_path"]?.stringValue ?? "")"
        case "Bash":
            return "$ \(i["command"]?.stringValue ?? "")"
        case "Grep":
            return "Grep \(i["pattern"]?.stringValue ?? "")"
        case "Glob":
            return "Glob \(i["pattern"]?.stringValue ?? "")"
        case "WebSearch":
            return "Search: \(i["query"]?.stringValue ?? "")"
        case "WebFetch":
            return "Fetch \(i["url"]?.stringValue ?? "")"
        case "Task", "Agent":
            return "Agent: \(i["description"]?.stringValue ?? "")"
        default:
            return tool.name
        }
    }
}
