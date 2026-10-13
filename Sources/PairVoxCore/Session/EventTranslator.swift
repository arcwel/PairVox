// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Converts raw `InboundMessage`s into `SessionEvent`s.
///
/// With `--include-partial-messages`, Claude Code sends assistant text twice:
/// once as `stream_event` deltas and again as a complete `assistant` message.
/// The translator emits each piece of text exactly once: deltas when streaming
/// happened for a message, the complete text otherwise.
public struct EventTranslator: Sendable {
    /// Message IDs whose text has already been delivered through deltas.
    private var streamedMessages: Set<String> = []
    private var currentMessageID: String?
    /// Content-block index → kind, for the message currently streaming.
    private var openTextBlocks: Set<Int> = []
    private var announcedThinking: Set<Int> = []
    private var startedSessionID: String?

    /// Set by the backend when it sends an interrupt, so the following
    /// `error_during_execution` result is reported as `.interrupted`.
    public var interruptPending = false

    public init() {}

    public mutating func translate(_ message: InboundMessage) -> [SessionEvent] {
        switch message {
        case .systemInit(let i):
            // Claude Code re-sends init at the start of each turn; announce once per session.
            guard startedSessionID != i.sessionID else { return [] }
            startedSessionID = i.sessionID
            return [.started(SessionInfo(sessionID: i.sessionID, model: i.model, cwd: i.cwd,
                                         permissionMode: i.permissionMode, cliVersion: i.cliVersion,
                                         apiKeySource: i.apiKeySource))]

        case .systemStatus(let s):
            return s.isEmpty ? [] : [.status(s)]

        case .system:
            return []

        case .streamEvent(let event, let parent):
            guard parent == nil else { return [] } // sub-agent chatter is not spoken
            return translateStream(event)

        case .assistant(let a):
            return translateAssistant(a)

        case .user(let u):
            var out: [SessionEvent] = []
            for block in u.content {
                if case .toolResult(let id, let text, let isError) = block {
                    out.append(.toolResult(toolUseID: id, isError: isError, preview: String(text.prefix(200))))
                }
            }
            return out

        case .result(let r):
            let outcome: TurnResult.Outcome
            if r.isSuccess {
                outcome = .success
            } else if interruptPending || (r.subtype == "error_during_execution" && r.result == nil
                                             && r.errors.allSatisfy { $0.hasPrefix("[ede_diagnostic]") }) {
                outcome = .interrupted
            } else {
                let msg = r.errors.first ?? r.result ?? r.subtype
                outcome = .failed(msg)
            }
            interruptPending = false
            var events: [SessionEvent] = []
            if case .failed(let msg) = outcome, EventTranslator.looksLikeAuthProblem(msg) {
                events.append(.authProblem(msg))
            }
            events.append(.turnCompleted(TurnResult(outcome: outcome, finalText: r.result, sessionID: r.sessionID,
                                                    durationMs: r.durationMs, numTurns: r.numTurns,
                                                    costUSD: r.totalCostUSD)))
            return events

        case .controlRequest(let req):
            if let p = req.permission { return [.permissionRequested(p)] }
            return []

        case .controlCancel(let id):
            return [.permissionCancelled(requestID: id)]

        case .controlResponse:
            return []

        case .rateLimit(let info):
            return [.rateLimit(info)]

        case .unknown:
            return []
        }
    }

    private mutating func translateStream(_ event: StreamEvent) -> [SessionEvent] {
        switch event {
        case .messageStart(let id):
            currentMessageID = id
            openTextBlocks.removeAll()
            announcedThinking.removeAll()
            return []
        case .contentBlockStart(let index, let block):
            switch block {
            case .text:
                openTextBlocks.insert(index)
                if let id = currentMessageID { streamedMessages.insert(id) }
                return []
            case .thinking:
                guard !announcedThinking.contains(index) else { return [] }
                announcedThinking.insert(index)
                return [.thinking]
            case .toolUse, .other:
                return []
            }
        case .contentBlockDelta(let index, let delta):
            if case .text(let t) = delta, !t.isEmpty {
                openTextBlocks.insert(index)
                if let id = currentMessageID { streamedMessages.insert(id) }
                return [.textDelta(t)]
            }
            return []
        case .contentBlockStop(let index):
            if openTextBlocks.remove(index) != nil { return [.textBlockEnded] }
            return []
        case .messageDelta, .messageStop, .other:
            return []
        }
    }

    private mutating func translateAssistant(_ a: AssistantMessage) -> [SessionEvent] {
        var out: [SessionEvent] = []
        if let err = a.error {
            switch err {
            case "authentication_failed", "oauth_org_not_allowed", "account_on_hold", "verification_required",
                 "billing_error", "cloud_credential_error":
                out.append(.authProblem(err))
            case "rate_limit":
                out.append(.notice("Usage limit reached."))
            case "overloaded":
                out.append(.notice("Claude is overloaded right now."))
            default:
                break
            }
        }
        let isSub = a.parentToolUseID != nil
        let alreadyStreamed = streamedMessages.contains(a.messageID)
        for block in a.content {
            switch block {
            case .text(let t):
                if !isSub && !alreadyStreamed && !t.isEmpty {
                    out.append(.textDelta(t))
                    out.append(.textBlockEnded)
                }
            case .toolUse(let id, let name, let input):
                out.append(.toolUse(ToolUse(id: id, name: name, input: input, isSubagent: isSub)))
            case .thinking, .toolResult, .other:
                break
            }
        }
        return out
    }

    static func looksLikeAuthProblem(_ message: String) -> Bool {
        let m = message.lowercased()
        let needles = ["invalid api key", "not logged in", "please run /login", "/login", "authentication",
                       "oauth", "credit balance is too low", "unauthorized", "401"]
        return needles.contains { m.contains($0) }
    }
}
