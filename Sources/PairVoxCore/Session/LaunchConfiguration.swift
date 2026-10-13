// SPDX-License-Identifier: Apache-2.0

import Foundation

/// How the spawned Claude Code CLI authenticates.
///
/// PairVox never reads, stores or forwards Claude.ai credentials. In
/// `.subscription` mode the user's own, unmodified `claude` CLI uses the login
/// the user completed in Anthropic's own flow (`claude` → `/login`). In
/// `.apiKey` mode the user's own Console key (kept in the macOS Keychain by the
/// app) is passed to the child process environment only.
public enum AuthMode: Sendable, Equatable {
    case subscription
    case apiKey(String)

    public var kind: AuthKind {
        switch self {
        case .subscription: return .subscription
        case .apiKey: return .apiKey
        }
    }
}

public enum AuthKind: String, Sendable, Codable, CaseIterable {
    case subscription
    case apiKey
}

/// Everything needed to launch one Claude Code session.
public struct LaunchConfiguration: Sendable, Equatable {
    public var executable: URL
    public var workingDirectory: URL
    public var auth: AuthMode
    public var model: String?
    public var permissionMode: PermissionMode
    public var appendSystemPrompt: String?
    public var resumeSessionID: String?
    public var includePartialMessages: Bool
    public var extraArguments: [String]
    /// Base environment (normally the user's login-shell environment).
    public var baseEnvironment: [String: String]

    public init(executable: URL, workingDirectory: URL, auth: AuthMode = .subscription, model: String? = nil,
                permissionMode: PermissionMode = .default, appendSystemPrompt: String? = nil,
                resumeSessionID: String? = nil, includePartialMessages: Bool = true, extraArguments: [String] = [],
                baseEnvironment: [String: String] = ProcessInfo.processInfo.environment) {
        self.executable = executable
        self.workingDirectory = workingDirectory
        self.auth = auth
        self.model = model
        self.permissionMode = permissionMode
        self.appendSystemPrompt = appendSystemPrompt
        self.resumeSessionID = resumeSessionID
        self.includePartialMessages = includePartialMessages
        self.extraArguments = extraArguments
        self.baseEnvironment = baseEnvironment
    }

    public func arguments() -> [String] {
        var args = [
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            // Route tool-permission prompts over stdio as `can_use_tool` control requests.
            "--permission-prompt-tool", "stdio",
            "--permission-mode", permissionMode.rawValue,
        ]
        if includePartialMessages { args.append("--include-partial-messages") }
        if let model, !model.isEmpty { args += ["--model", model] }
        if let appendSystemPrompt, !appendSystemPrompt.isEmpty { args += ["--append-system-prompt", appendSystemPrompt] }
        if let resumeSessionID, !resumeSessionID.isEmpty { args += ["--resume", resumeSessionID] }
        args += extraArguments
        return args
    }

    /// Environment for the child process.
    public func environment() -> [String: String] {
        var env = baseEnvironment
        // Never inherit nested-session markers from a parent Claude Code process.
        for key in env.keys where key == "CLAUDECODE" || key.hasPrefix("CLAUDE_CODE_SESSION") {
            env.removeValue(forKey: key)
        }
        // Make sure the CLI (often a Node script) can find node and friends.
        let cliDir = executable.deletingLastPathComponent().path
        env["PATH"] = ShellEnvironment.mergedPath(env["PATH"], prepending: [cliDir])

        switch auth {
        case .subscription:
            // An exported key would silently override the subscription login.
            env.removeValue(forKey: "ANTHROPIC_API_KEY")
            env.removeValue(forKey: "ANTHROPIC_AUTH_TOKEN")
        case .apiKey(let key):
            env["ANTHROPIC_API_KEY"] = key
            env.removeValue(forKey: "ANTHROPIC_AUTH_TOKEN")
        }
        return env
    }
}
