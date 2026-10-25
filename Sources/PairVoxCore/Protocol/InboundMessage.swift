// SPDX-License-Identifier: Apache-2.0

import Foundation

/// One line of Claude Code's `--output-format stream-json` output, decoded into
/// the parts PairVox cares about. Unknown or new message kinds are preserved as
/// `.unknown` so newer CLI versions never break the app.
///
/// Shapes were verified against Claude Code 2.1.296 and the published
/// `@anthropic-ai/claude-agent-sdk` type definitions.
public enum InboundMessage: Sendable, Equatable {
    case systemInit(SystemInit)
    case systemStatus(String)
    case system(subtype: String, raw: JSONValue)
    case streamEvent(StreamEvent, parentToolUseID: String?)
    case assistant(AssistantMessage)
    case user(UserMessage)
    case result(ResultMessage)
    case controlRequest(ControlRequest)
    case controlResponse(ControlResponse)
    case controlCancel(requestID: String)
    case rateLimit(RateLimitInfo)
    case unknown(type: String, raw: JSONValue)

    public enum ParseError: Error, Equatable {
        case notAnObject
        case missingType
    }

    public static func parse(line: Data) throws -> InboundMessage {
        try parse(json: JSONValue.parse(line))
    }

    public static func parse(line: String) throws -> InboundMessage {
        try parse(json: JSONValue.parse(line))
    }

    public static func parse(json: JSONValue) throws -> InboundMessage {
        guard case .object = json else { throw ParseError.notAnObject }
        guard let type = json["type"]?.stringValue else { throw ParseError.missingType }
        let subtype = json["subtype"]?.stringValue

        switch type {
        case "system":
            switch subtype {
            case "init": return .systemInit(SystemInit(json))
            case "status": return .systemStatus(json["status"]?.stringValue ?? "")
            default: return .system(subtype: subtype ?? "", raw: json)
            }
        case "stream_event":
            return .streamEvent(StreamEvent(json["event"] ?? .null), parentToolUseID: json["parent_tool_use_id"]?.stringValue)
        case "assistant":
            return .assistant(AssistantMessage(json))
        case "user":
            return .user(UserMessage(json))
        case "result":
            return .result(ResultMessage(json))
        case "control_request":
            return .controlRequest(ControlRequest(json))
        case "control_response":
            return .controlResponse(ControlResponse(json))
        case "control_cancel_request":
            return .controlCancel(requestID: json["request_id"]?.stringValue ?? "")
        case "rate_limit_event":
            return .rateLimit(RateLimitInfo(json["rate_limit_info"] ?? .null))
        default:
            return .unknown(type: type, raw: json)
        }
    }
}

// MARK: - System

public struct SystemInit: Sendable, Equatable {
    public var sessionID: String
    public var model: String
    public var cwd: String
    public var permissionMode: String
    public var tools: [String]
    public var cliVersion: String?
    public var apiKeySource: String?

    public init(sessionID: String, model: String, cwd: String, permissionMode: String, tools: [String] = [],
                cliVersion: String? = nil, apiKeySource: String? = nil) {
        self.sessionID = sessionID
        self.model = model
        self.cwd = cwd
        self.permissionMode = permissionMode
        self.tools = tools
        self.cliVersion = cliVersion
        self.apiKeySource = apiKeySource
    }

    init(_ j: JSONValue) {
        sessionID = j["session_id"]?.stringValue ?? ""
        model = j["model"]?.stringValue ?? ""
        cwd = j["cwd"]?.stringValue ?? ""
        permissionMode = j["permissionMode"]?.stringValue ?? "default"
        tools = j["tools"]?.arrayValue?.compactMap(\.stringValue) ?? []
        cliVersion = j["claude_code_version"]?.stringValue
        apiKeySource = j["apiKeySource"]?.stringValue
    }
}

// MARK: - Streaming events (raw Anthropic Messages API stream events)

public enum StreamEvent: Sendable, Equatable {
    case messageStart(messageID: String)
    case contentBlockStart(index: Int, block: BlockStart)
    case contentBlockDelta(index: Int, delta: Delta)
    case contentBlockStop(index: Int)
    case messageDelta(stopReason: String?)
    case messageStop
    case other(type: String)

    public enum BlockStart: Sendable, Equatable {
        case text
        case thinking
        case toolUse(id: String, name: String)
        case other(type: String)
    }

    public enum Delta: Sendable, Equatable {
        case text(String)
        case thinking(String)
        case inputJSON(String)
        case signature
        case other(type: String)
    }

    init(_ e: JSONValue) {
        let type = e["type"]?.stringValue ?? ""
        let index = e["index"]?.intValue ?? 0
        switch type {
        case "message_start":
            self = .messageStart(messageID: e["message"]?["id"]?.stringValue ?? "")
        case "content_block_start":
            let block = e["content_block"] ?? .null
            switch block["type"]?.stringValue ?? "" {
            case "text": self = .contentBlockStart(index: index, block: .text)
            case "thinking", "redacted_thinking": self = .contentBlockStart(index: index, block: .thinking)
            case "tool_use", "server_tool_use":
                self = .contentBlockStart(index: index, block: .toolUse(
                    id: block["id"]?.stringValue ?? "", name: block["name"]?.stringValue ?? ""))
            case let t: self = .contentBlockStart(index: index, block: .other(type: t))
            }
        case "content_block_delta":
            let d = e["delta"] ?? .null
            switch d["type"]?.stringValue ?? "" {
            case "text_delta": self = .contentBlockDelta(index: index, delta: .text(d["text"]?.stringValue ?? ""))
            case "thinking_delta": self = .contentBlockDelta(index: index, delta: .thinking(d["thinking"]?.stringValue ?? ""))
            case "input_json_delta": self = .contentBlockDelta(index: index, delta: .inputJSON(d["partial_json"]?.stringValue ?? ""))
            case "signature_delta": self = .contentBlockDelta(index: index, delta: .signature)
            case let t: self = .contentBlockDelta(index: index, delta: .other(type: t))
            }
        case "content_block_stop":
            self = .contentBlockStop(index: index)
        case "message_delta":
            self = .messageDelta(stopReason: e["delta"]?["stop_reason"]?.stringValue)
        case "message_stop":
            self = .messageStop
        default:
            self = .other(type: type)
        }
    }
}

// MARK: - Complete messages

public enum ContentBlock: Sendable, Equatable {
    case text(String)
    case thinking
    case toolUse(id: String, name: String, input: JSONValue)
    case toolResult(toolUseID: String, text: String, isError: Bool)
    case other(type: String)

    init(_ b: JSONValue) {
        switch b["type"]?.stringValue ?? "" {
        case "text": self = .text(b["text"]?.stringValue ?? "")
        case "thinking", "redacted_thinking": self = .thinking
        case "tool_use", "server_tool_use":
            self = .toolUse(id: b["id"]?.stringValue ?? "", name: b["name"]?.stringValue ?? "", input: b["input"] ?? .object([:]))
        case "tool_result":
            self = .toolResult(toolUseID: b["tool_use_id"]?.stringValue ?? "",
                               text: ContentBlock.flattenText(b["content"]),
                               isError: b["is_error"]?.boolValue ?? false)
        case let t: self = .other(type: t)
        }
    }

    static func flattenText(_ v: JSONValue?) -> String {
        switch v {
        case .string(let s)?: return s
        case .array(let items)?:
            return items.compactMap { $0["text"]?.stringValue }.joined(separator: "\n")
        default: return ""
        }
    }

    static func parseContent(_ v: JSONValue?) -> [ContentBlock] {
        switch v {
        case .string(let s)?: return [.text(s)]
        case .array(let items)?: return items.map(ContentBlock.init)
        default: return []
        }
    }
}

public struct AssistantMessage: Sendable, Equatable {
    public var messageID: String
    public var content: [ContentBlock]
    public var parentToolUseID: String?
    /// Set by Claude Code when the API call failed, e.g. `authentication_failed`, `rate_limit`, `billing_error`.
    public var error: String?

    init(_ j: JSONValue) {
        messageID = j["message"]?["id"]?.stringValue ?? ""
        content = ContentBlock.parseContent(j["message"]?["content"])
        parentToolUseID = j["parent_tool_use_id"]?.stringValue
        error = j["error"]?.stringValue
    }

    public init(messageID: String, content: [ContentBlock], parentToolUseID: String? = nil, error: String? = nil) {
        self.messageID = messageID
        self.content = content
        self.parentToolUseID = parentToolUseID
        self.error = error
    }
}

public struct UserMessage: Sendable, Equatable {
    public var content: [ContentBlock]
    public var parentToolUseID: String?

    init(_ j: JSONValue) {
        content = ContentBlock.parseContent(j["message"]?["content"])
        parentToolUseID = j["parent_tool_use_id"]?.stringValue
    }
}

public struct ResultMessage: Sendable, Equatable {
    public var subtype: String
    public var isError: Bool
    public var result: String?
    public var sessionID: String
    public var durationMs: Int
    public var durationAPIMs: Int
    public var numTurns: Int
    public var totalCostUSD: Double
    public var errors: [String]

    public var isSuccess: Bool { subtype == "success" && !isError }

    init(_ j: JSONValue) {
        subtype = j["subtype"]?.stringValue ?? ""
        isError = j["is_error"]?.boolValue ?? (subtype != "success")
        result = j["result"]?.stringValue
        sessionID = j["session_id"]?.stringValue ?? ""
        durationMs = j["duration_ms"]?.intValue ?? 0
        durationAPIMs = j["duration_api_ms"]?.intValue ?? 0
        numTurns = j["num_turns"]?.intValue ?? 0
        totalCostUSD = j["total_cost_usd"]?.doubleValue ?? 0
        errors = j["errors"]?.arrayValue?.compactMap(\.stringValue) ?? []
    }

    public init(subtype: String, isError: Bool, result: String?, sessionID: String = "", durationMs: Int = 0,
                durationAPIMs: Int = 0, numTurns: Int = 0, totalCostUSD: Double = 0, errors: [String] = []) {
        self.subtype = subtype
        self.isError = isError
        self.result = result
        self.sessionID = sessionID
        self.durationMs = durationMs
        self.durationAPIMs = durationAPIMs
        self.numTurns = numTurns
        self.totalCostUSD = totalCostUSD
        self.errors = errors
    }
}

// MARK: - Control protocol

public struct ControlRequest: Sendable, Equatable {
    public var requestID: String
    public var subtype: String
    public var body: JSONValue

    /// Non-nil when this is a tool-permission prompt (`can_use_tool`).
    public var permission: PermissionRequest? {
        subtype == "can_use_tool" ? PermissionRequest(requestID: requestID, body: body) : nil
    }

    init(_ j: JSONValue) {
        requestID = j["request_id"]?.stringValue ?? ""
        body = j["request"] ?? .null
        subtype = body["subtype"]?.stringValue ?? ""
    }
}

public struct ControlResponse: Sendable, Equatable {
    public var requestID: String
    public var isSuccess: Bool
    public var response: JSONValue?
    public var error: String?

    init(_ j: JSONValue) {
        let r = j["response"] ?? .null
        requestID = r["request_id"]?.stringValue ?? ""
        isSuccess = r["subtype"]?.stringValue == "success"
        response = r["response"]
        error = r["error"]?.stringValue
    }
}

/// A `can_use_tool` request: Claude Code is asking whether a tool call may run.
public struct PermissionRequest: Sendable, Equatable, Identifiable {
    public var id: String { requestID }
    public var requestID: String
    public var toolName: String
    public var displayName: String?
    public var input: JSONValue
    public var description: String?
    public var toolUseID: String?
    public var decisionReason: String?
    public var decisionReasonType: String?
    public var blockedPath: String?
    public var defaultToNo: Bool
    public var requiresUserInteraction: Bool
    public var suppressAlwaysAllow: Bool
    /// Permission updates the CLI proposes for "always allow"; echoed back on approval.
    public var suggestions: JSONValue?

    public init(requestID: String, toolName: String, input: JSONValue, displayName: String? = nil,
                description: String? = nil, toolUseID: String? = nil, decisionReason: String? = nil,
                decisionReasonType: String? = nil, blockedPath: String? = nil, defaultToNo: Bool = false,
                requiresUserInteraction: Bool = false, suppressAlwaysAllow: Bool = false, suggestions: JSONValue? = nil) {
        self.requestID = requestID
        self.toolName = toolName
        self.input = input
        self.displayName = displayName
        self.description = description
        self.toolUseID = toolUseID
        self.decisionReason = decisionReason
        self.decisionReasonType = decisionReasonType
        self.blockedPath = blockedPath
        self.defaultToNo = defaultToNo
        self.requiresUserInteraction = requiresUserInteraction
        self.suppressAlwaysAllow = suppressAlwaysAllow
        self.suggestions = suggestions
    }

    init(requestID: String, body b: JSONValue) {
        self.init(
            requestID: requestID,
            toolName: b["tool_name"]?.stringValue ?? "",
            input: b["input"] ?? .object([:]),
            displayName: b["display_name"]?.stringValue,
            description: b["description"]?.stringValue,
            toolUseID: b["tool_use_id"]?.stringValue,
            decisionReason: b["decision_reason"]?.stringValue,
            decisionReasonType: b["decision_reason_type"]?.stringValue,
            blockedPath: b["blocked_path"]?.stringValue,
            defaultToNo: b["default_to_no"]?.boolValue ?? false,
            requiresUserInteraction: b["requires_user_interaction"]?.boolValue ?? false,
            suppressAlwaysAllow: b["suppress_always_allow_rule"]?.boolValue ?? false,
            suggestions: b["permission_suggestions"]
        )
    }
}

// MARK: - Usage limits

public struct RateLimitInfo: Sendable, Equatable {
    public var status: String
    public var rateLimitType: String?
    public var resetsAt: Date?
    public var fiveHourUtilization: Double?
    public var sevenDayUtilization: Double?

    public init(status: String, rateLimitType: String? = nil, resetsAt: Date? = nil,
                fiveHourUtilization: Double? = nil, sevenDayUtilization: Double? = nil) {
        self.status = status
        self.rateLimitType = rateLimitType
        self.resetsAt = resetsAt
        self.fiveHourUtilization = fiveHourUtilization
        self.sevenDayUtilization = sevenDayUtilization
    }

    init(_ j: JSONValue) {
        status = j["status"]?.stringValue ?? ""
        rateLimitType = j["rateLimitType"]?.stringValue
        resetsAt = j["resetsAt"]?.doubleValue.map { Date(timeIntervalSince1970: $0) }
        fiveHourUtilization = j["unifiedWindows"]?["five_hour"]?["utilization"]?.doubleValue
        sevenDayUtilization = j["unifiedWindows"]?["seven_day"]?["utilization"]?.doubleValue
    }
}

extension PermissionRequest {
    /// Claude Code's "don't ask again" suggestions that "Always allow" may apply: allow rules only, each scoped to the
    /// session. Mode changes, added folders and rule replacements or removals are dropped, since each would widen what
    /// runs without PairVox seeing it. Empty when nothing narrow is left, and then "Always allow" is not offered.
    public var sessionSuggestions: [JSONValue] {
        guard !suppressAlwaysAllow, case .array(let items)? = suggestions else { return [] }
        return items.compactMap {
            guard case .object(var o) = $0, o["type"]?.stringValue == "addRules", o["behavior"]?.stringValue == "allow" else { return nil }
            o["destination"] = "session"
            return .object(o)
        }
    }
}
