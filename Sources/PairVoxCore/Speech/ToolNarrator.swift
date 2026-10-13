// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Turns tool calls into short spoken status lines ("Reading auth dot T S."),
/// so the user is never left in silence while Claude works.
public struct ToolNarrator: Sendable {
    public var pronunciation: Pronunciation
    /// Minimum seconds between narrations.
    public var minInterval: TimeInterval
    private var lastNarration: Date?
    private var suppressedSinceLast = 0

    public init(pronunciation: Pronunciation = Pronunciation(), minInterval: TimeInterval = 4) {
        self.pronunciation = pronunciation
        self.minInterval = minInterval
    }

    public mutating func reset() {
        lastNarration = nil
        suppressedSinceLast = 0
    }

    /// Returns a phrase to speak, or nil if throttled.
    public mutating func narrate(_ tool: ToolUse, now: Date = Date()) -> String? {
        guard !tool.isSubagent else { return nil }
        if let last = lastNarration, now.timeIntervalSince(last) < minInterval {
            suppressedSinceLast += 1
            return nil
        }
        lastNarration = now
        defer { suppressedSinceLast = 0 }
        return describe(tool)
    }

    public func describe(_ tool: ToolUse) -> String? {
        let input = tool.input
        func file(_ key: String) -> String? {
            guard let p = input[key]?.stringValue, !p.isEmpty else { return nil }
            return pronunciation.speak(p)
        }
        switch tool.name {
        case "Read":
            return file("file_path").map { "Reading \($0)." } ?? "Reading a file."
        case "Write":
            return file("file_path").map { "Writing \($0)." } ?? "Writing a file."
        case "Edit", "MultiEdit":
            return file("file_path").map { "Editing \($0)." } ?? "Editing a file."
        case "NotebookEdit":
            return "Editing a notebook."
        case "Bash":
            if let d = input["description"]?.stringValue, !d.isEmpty, d.count <= 60 {
                return pronunciation.speak(d.hasSuffix(".") ? d : d + ".")
            }
            if let cmd = input["command"]?.stringValue {
                return "Running " + ToolNarrator.commandSummary(cmd, pronunciation: pronunciation) + "."
            }
            return "Running a command."
        case "Glob", "Grep", "LS":
            return "Searching the code."
        case "WebSearch":
            if let q = input["query"]?.stringValue, q.count <= 60 { return "Searching the web for \(q)." }
            return "Searching the web."
        case "WebFetch":
            return "Reading a web page."
        case "Task", "Agent":
            return "Starting a helper agent."
        case "TodoWrite", "TaskCreate", "TaskUpdate":
            return "Updating the plan."
        case "ExitPlanMode":
            return "The plan is ready."
        case "AskUserQuestion":
            return nil
        default:
            if tool.name.hasPrefix("mcp__") {
                let parts = tool.name.split(separator: "_", omittingEmptySubsequences: true)
                let server = parts.count > 1 ? String(parts[1]) : "a connected"
                return "Using the \(Pronunciation.splitIdentifier(server)) tool."
            }
            return "Using \(Pronunciation.splitIdentifier(tool.name))."
        }
    }

    /// "npm run test -- --watch" → "npm run test"
    static func commandSummary(_ cmd: String, pronunciation: Pronunciation) -> String {
        let first = cmd.split(whereSeparator: { $0 == "&" || $0 == "|" || $0 == ";" || $0 == "\n" }).first.map(String.init) ?? cmd
        let words = first.split(separator: " ").filter { !$0.hasPrefix("-") && !$0.contains("=") && !$0.hasPrefix("\"") }
        let short = words.prefix(3).joined(separator: " ")
        if short.isEmpty || short.count > 40 { return "a command" }
        return pronunciation.speak(short)
    }
}
