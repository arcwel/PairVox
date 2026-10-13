// SPDX-License-Identifier: Apache-2.0

import Foundation

/// High-level events the conversation engine consumes. Produced by
/// `EventTranslator` from raw stream-json messages.
public enum SessionEvent: Sendable, Equatable {
    case started(SessionInfo)
    case status(String)
    /// Main-thread assistant text, streamed as it is generated.
    case textDelta(String)
    /// The current assistant text block finished.
    case textBlockEnded
    /// Claude began extended thinking (no content is exposed).
    case thinking
    /// A tool call was issued. `isSubagent` is true for calls made inside a sub-agent.
    case toolUse(ToolUse)
    case toolResult(toolUseID: String, isError: Bool, preview: String)
    case permissionRequested(PermissionRequest)
    case permissionCancelled(requestID: String)
    case turnCompleted(TurnResult)
    case rateLimit(RateLimitInfo)
    /// The CLI could not authenticate (not logged in, bad API key, org not allowed, ...).
    case authProblem(String)
    /// Recoverable notice worth showing (e.g. overloaded / rate limited).
    case notice(String)
    case processExited(code: Int32, stderrTail: String)
}

public struct SessionInfo: Sendable, Equatable {
    public var sessionID: String
    public var model: String
    public var cwd: String
    public var permissionMode: String
    public var cliVersion: String?
    public var apiKeySource: String?

    public init(sessionID: String, model: String, cwd: String, permissionMode: String,
                cliVersion: String? = nil, apiKeySource: String? = nil) {
        self.sessionID = sessionID
        self.model = model
        self.cwd = cwd
        self.permissionMode = permissionMode
        self.cliVersion = cliVersion
        self.apiKeySource = apiKeySource
    }
}

public struct ToolUse: Sendable, Equatable {
    public var id: String
    public var name: String
    public var input: JSONValue
    public var isSubagent: Bool

    public init(id: String, name: String, input: JSONValue, isSubagent: Bool = false) {
        self.id = id
        self.name = name
        self.input = input
        self.isSubagent = isSubagent
    }
}

public struct TurnResult: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable {
        case success
        case interrupted
        case failed(String)
    }

    public var outcome: Outcome
    public var finalText: String?
    public var sessionID: String
    public var durationMs: Int
    public var numTurns: Int
    public var costUSD: Double

    public init(outcome: Outcome, finalText: String? = nil, sessionID: String = "", durationMs: Int = 0,
                numTurns: Int = 0, costUSD: Double = 0) {
        self.outcome = outcome
        self.finalText = finalText
        self.sessionID = sessionID
        self.durationMs = durationMs
        self.numTurns = numTurns
        self.costUSD = costUSD
    }
}
