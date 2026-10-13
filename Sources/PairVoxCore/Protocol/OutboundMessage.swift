// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Permission modes understood by Claude Code (`--permission-mode` / `set_permission_mode`).
public enum PermissionMode: String, Sendable, Codable, CaseIterable {
    case `default`
    case acceptEdits
    case plan
    case bypassPermissions
}

/// Answer to a `can_use_tool` permission request.
public enum PermissionDecision: Sendable, Equatable {
    /// Allow this one call.
    case allow
    /// Allow and apply the CLI's own "don't ask again" suggestions for this session.
    case allowAlways
    /// Deny; `interrupt` also stops the current turn.
    case deny(message: String, interrupt: Bool)
}

/// Builders for lines written to Claude Code's stdin (`--input-format stream-json`).
/// Every builder returns one complete NDJSON line, newline included.
public enum OutboundMessage {
    public static func userText(_ text: String) -> Data {
        line([
            "type": "user",
            "message": ["role": "user", "content": .string(text)],
            "parent_tool_use_id": .null,
        ])
    }

    public static func permissionResponse(for request: PermissionRequest, decision: PermissionDecision) -> Data {
        let payload: JSONValue
        switch decision {
        case .allow:
            payload = ["behavior": "allow", "updatedInput": request.input]
        case .allowAlways:
            var p: [String: JSONValue] = ["behavior": "allow", "updatedInput": request.input]
            if let s = request.suggestions, case .array(let items) = s, !items.isEmpty, !request.suppressAlwaysAllow {
                p["updatedPermissions"] = s
            }
            payload = .object(p)
        case .deny(let message, let interrupt):
            payload = ["behavior": "deny", "message": .string(message), "interrupt": .bool(interrupt)]
        }
        return controlSuccess(requestID: request.requestID, response: payload)
    }

    public static func interrupt(requestID: String) -> Data {
        controlRequest(requestID: requestID, request: ["subtype": "interrupt"])
    }

    public static func setPermissionMode(_ mode: PermissionMode, requestID: String) -> Data {
        controlRequest(requestID: requestID, request: ["subtype": "set_permission_mode", "mode": .string(mode.rawValue)])
    }

    public static func setModel(_ model: String?, requestID: String) -> Data {
        controlRequest(requestID: requestID, request: ["subtype": "set_model", "model": model.map(JSONValue.string) ?? .null])
    }

    /// Reply to a control request PairVox does not handle, so the CLI never waits forever.
    public static func controlError(requestID: String, message: String) -> Data {
        line([
            "type": "control_response",
            "response": ["subtype": "error", "request_id": .string(requestID), "error": .string(message)],
        ])
    }

    static func controlSuccess(requestID: String, response: JSONValue) -> Data {
        line([
            "type": "control_response",
            "response": ["subtype": "success", "request_id": .string(requestID), "response": response],
        ])
    }

    static func controlRequest(requestID: String, request: JSONValue) -> Data {
        line(["type": "control_request", "request_id": .string(requestID), "request": request])
    }

    static func line(_ value: JSONValue) -> Data {
        var data = (try? value.serialized()) ?? Data("{}".utf8)
        data.append(0x0A)
        return data
    }
}
