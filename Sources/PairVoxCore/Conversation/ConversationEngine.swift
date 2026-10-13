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
    private var ackTask: Task<Void, Never>?
    private var firstTokenSeen = false

    // Speech bookkeeping
    private var queued: [Int: Utterance] = [:]
    private var queueOrder: [Int] = []
    private var proseIDs: Set<Int> = []
    private var holdSpeech = false
    private var interruptedRemainder: [Utterance] = []
    private var nextEntryID = 1
    private var spokenAuthProblem = false
    private var userIsSpeaking = false
    private var transcribing = false

    public init(configuration: EngineConfiguration, authKind: AuthKind = .subscription, output: any SpeechOutput,
                backendFactory: @escaping SessionBackendFactory) {
        self.config = configuration
        self.authKind = authKind
        self.output = output
        self.makeBackend = backendFactory
        self.pronunciation = Pronunciation(dictionary: configuration.pronunciation)
        self.policy = PermissionPolicy(projectRoot: configuration.projectRoot, pronunciation: pronunciation)
        self.planner = SpeechPlanner(mode: configuration.speechMode, verbosity: configuration.verbosity,
                                     pronunciation: pronunciation, ids: ids)
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
    }

    // MARK: - Input from the voice layer

    /// The user started talking (VAD). Stops our speech immediately (barge-in).
    public func userStartedSpeaking() {
        if snapshot.isSpeaking || !queueOrder.isEmpty {
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

    /// The user stopped talking; a transcript will follow.
    public func userStoppedSpeaking() {
        userIsSpeaking = false
        transcribing = true
        recomputePhase()
    }

    /// Speech recognition produced nothing usable.
    public func transcriptionFailed() {
        userIsSpeaking = false
        transcribing = false
        resumeAfterFalseBargeIn()
        recomputePhase()
    }

    /// A final transcript (or typed text) from the user.
    public func submit(_ rawText: String) {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        userIsSpeaking = false
        transcribing = false
        guard !text.isEmpty else {
            resumeAfterFalseBargeIn()
            recomputePhase()
            return
        }
        let context = VoiceCommand.Context(awaitingPermission: snapshot.pendingPermission != nil,
                                           claudeIsWorking: !sendTimes.isEmpty,
                                           hasHeldBack: !(lastPlanner?.heldBack.isEmpty ?? true))
        if let command = VoiceCommand.parse(text, context: context) {
            appendEntry(.user, text, status: .done)
            perform(command)
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

    public func approvePending(always: Bool = false) {
        guard let p = snapshot.pendingPermission else { return }
        respondToPermission(p.request, decision: always ? .allowAlways : .allow)
    }

    public func denyPending(message: String = "The user denied this action.") {
        guard let p = snapshot.pendingPermission else { return }
        respondToPermission(p.request, decision: .deny(message: message, interrupt: false))
    }

    public func interruptClaude() {
        perform(.interruptClaude)
    }

    public func stopSpeaking() {
        perform(.stopSpeaking)
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

    public func newSession() {
        output.stopAll()
        queued.removeAll()
        queueOrder.removeAll()
        backend?.stop()
        resetTurnState()
        sendTimes.removeAll()
        snapshot.pendingPermission = nil
        snapshot.session = nil
        snapshot.isClaudeWorking = false
        appendEntry(.system, "New session started.", status: .done)
        openBackend(resume: nil)
        recomputePhase()
    }

    // MARK: - Commands

    public func perform(_ command: VoiceCommand) {
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
            if !interruptedRemainder.isEmpty {
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
            // Spoken approvals only count for requests the policy rates as voice-approvable.
            guard let pending = snapshot.pendingPermission else { break }
            if pending.assessment.voiceApprovable {
                approvePending(always: command == .approveAlways)
            } else {
                speak([make("That one needs a click. Please confirm it on screen.", .notice)], record: false, force: true)
            }
        case .deny:
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
        }
        recomputePhase()
    }

    // MARK: - Session events

    private func handleSession(_ event: SessionEvent, generation: Int) {
        guard generation == backendGeneration else { return }
        switch event {
        case .started(let info):
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
            if config.autoApproveLowRisk && assessment.risk == .low {
                try? backend?.respond(to: request, decision: .allow)
                break
            }
            snapshot.pendingPermission = PendingPermission(request: request, assessment: assessment)
            ackTask?.cancel()
            speak([make(assessment.spokenPrompt, .prompt)], record: false, force: true)

        case .permissionCancelled(let id):
            if snapshot.pendingPermission?.request.requestID == id {
                snapshot.pendingPermission = nil
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
            if code != 0, !stderr.isEmpty { snapshot.lastNotice = String(stderr.suffix(300)) }
        }
        recomputePhase()
    }

    private func completeTurn(_ result: TurnResult) {
        let final = planner.finishTurn(result)
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
        planner = SpeechPlanner(mode: config.speechMode, verbosity: config.verbosity, pronunciation: pronunciation, ids: ids)
        assistantEntryID = nil
        turnMuted = false
        latency = TurnLatency()
        utterancesThisTurn = 0
        firstTokenSeen = false
        ackTask?.cancel()
    }

    // MARK: - Speech output events

    private func handleOutput(_ event: SpeechOutputEvent) {
        switch event {
        case .started(let id):
            guard queued[id] != nil else { return }
            snapshot.isSpeaking = true
            if proseIDs.contains(id), latency.firstAudio == nil, let start = sendTimes.first {
                latency.firstAudio = Date().timeIntervalSince(start)
            }
        case .finished(let id), .failed(let id, _):
            queued.removeValue(forKey: id)
            queueOrder.removeAll { $0 == id }
            proseIDs.remove(id)
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
        do {
            try backend?.respond(to: request, decision: decision)
        } catch {
            snapshot.lastNotice = "\(error)"
        }
        snapshot.pendingPermission = nil
        appendEntry(.system, {
            switch decision {
            case .allow: return "Approved."
            case .allowAlways: return "Approved (don't ask again this session)."
            case .deny: return "Denied."
            }
        }(), status: .done)
        recomputePhase()
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
        for u in utterances {
            queued[u.id] = u
            queueOrder.append(u.id)
            if u.kind == .prose || u.kind == .code { proseIDs.insert(u.id) }
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

    /// The user made a noise but said nothing: carry on where we stopped.
    private func resumeAfterFalseBargeIn() {
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
