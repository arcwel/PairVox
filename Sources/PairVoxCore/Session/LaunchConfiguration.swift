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
    /// When false (the default) the child loads only the user's own Claude Code settings and MCP servers, not the
    /// opened repository's `.claude/settings*.json` (hooks, allow rules) or `.mcp.json`, which would otherwise run
    /// at session start with no permission request reaching PairVox (checked by scripts/validate-claude-config.sh;
    /// `--strict-mcp-config` is deliberately not used because it would also drop the user's own MCP servers).
    public var trustProjectConfiguration: Bool

    public init(executable: URL, workingDirectory: URL, auth: AuthMode = .subscription, model: String? = nil,
                permissionMode: PermissionMode = .default, appendSystemPrompt: String? = nil,
                resumeSessionID: String? = nil, includePartialMessages: Bool = true, extraArguments: [String] = [],
                baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
                trustProjectConfiguration: Bool = false) {
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
        self.trustProjectConfiguration = trustProjectConfiguration
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
        if !trustProjectConfiguration { args += ["--setting-sources", "user"] }
        if includePartialMessages { args.append("--include-partial-messages") }
        if let model, !model.isEmpty { args += ["--model", model] }
        if let appendSystemPrompt, !appendSystemPrompt.isEmpty { args += ["--append-system-prompt", appendSystemPrompt] }
        if let resumeSessionID, !resumeSessionID.isEmpty { args += ["--resume", resumeSessionID] }
        args += extraArguments
        return args
    }

    /// Environment for the child process: the login shell's variables minus everything that could redirect,
    /// replace or expose credentials (`ChildEnvironment`), then the auth the user chose.
    public func environment() -> [String: String] {
        var env = ChildEnvironment.filter(baseEnvironment)
        // Make sure the CLI (often a Node script) can find node and friends.
        let cliDir = executable.deletingLastPathComponent().path
        env["PATH"] = ShellEnvironment.mergedPath(env["PATH"], prepending: [cliDir])

        switch auth {
        case .subscription:
            // Nothing is set: the child uses its own login. The filter has already removed any exported key or
            // token that would silently override it.
            break
        case .apiKey(let key):
            env["ANTHROPIC_API_KEY"] = key
        }
        return env
    }
}
