// SPDX-License-Identifier: Apache-2.0

import Foundation

public enum RiskLevel: Int, Sendable, Comparable, Codable {
    case low = 0, medium = 1, high = 2
    public static func < (a: RiskLevel, b: RiskLevel) -> Bool { a.rawValue < b.rawValue }
}

/// What PairVox does with a permission request.
public struct PermissionAssessment: Sendable, Equatable {
    public var risk: RiskLevel
    /// Whether a spoken "yes" may approve it. High-risk requests always need a click.
    public var voiceApprovable: Bool
    /// What PairVox says out loud.
    public var spokenPrompt: String
    /// One-line description for the on-screen card.
    public var summary: String
    /// Why it was rated this way (shown on screen).
    public var reasons: [String]
    /// Whether the opt-in "auto-approve read-only tools" setting may answer this without asking.
    /// Only plain read-only tools qualify, never an unrecognized shell command.
    public var autoApprovable: Bool = false
}

/// Classifies tool-permission requests so misheard voice approvals can't do
/// anything destructive. This is a guardrail on top of Claude Code's own
/// permission system, never a replacement for it.
public struct PermissionPolicy: Sendable {
    public var projectRoot: String?
    public var pronunciation: Pronunciation

    public init(projectRoot: String?, pronunciation: Pronunciation = Pronunciation()) {
        self.projectRoot = projectRoot.map { ($0 as NSString).standardizingPath }
        self.pronunciation = pronunciation
    }

    static let readOnlyTools: Set<String> = ["Read", "Glob", "Grep", "LS", "WebSearch", "TodoWrite", "TaskCreate",
                                             "TaskUpdate", "TaskList", "TaskGet", "ExitPlanMode", "ToolSearch"]
    /// Read-only in the policy's eyes, but leaving plan mode changes what Claude may do, so a person decides.
    static let neverAutoApprove: Set<String> = ["ExitPlanMode"]
    static let fileWriteTools: Set<String> = ["Edit", "MultiEdit", "Write", "NotebookEdit"]

    public func assess(_ r: PermissionRequest) -> PermissionAssessment {
        var risk: RiskLevel
        var reasons: [String] = []
        var spoken: String
        var summary: String

        switch r.toolName {
        case let t where PermissionPolicy.readOnlyTools.contains(t):
            risk = .low
            summary = "\(r.displayName ?? t)"
            spoken = "Claude wants to use \(Pronunciation.splitIdentifier(t)). Allow?"
            let target = r.input["file_path"]?.stringValue ?? r.input["path"]?.stringValue ?? ""
            if PermissionPolicy.isSensitivePath(target) {
                risk = .medium
                summary = "\(r.displayName ?? t) \(target)"
                reasons.append("It would read a file that looks sensitive (credentials, keys, shell or git config).")
            }

        case "WebFetch":
            risk = .medium
            let url = r.input["url"]?.stringValue ?? ""
            summary = "Fetch \(url)"
            spoken = "Claude wants to read \(pronunciation.speak(url)). Allow?"

        case let t where PermissionPolicy.fileWriteTools.contains(t):
            let path = r.input["file_path"]?.stringValue ?? r.input["notebook_path"]?.stringValue ?? r.blockedPath ?? ""
            let verb = t == "Write" ? "write" : "edit"
            summary = "\(verb.capitalized) \(path)"
            spoken = "Claude wants to \(verb) \(path.isEmpty ? "a file" : pronunciation.speak(path)). Allow?"
            if isInsideProject(path) {
                risk = .medium
            } else {
                risk = .high
                reasons.append("The file is outside the project folder.")
            }
            if PermissionPolicy.isSensitivePath(path) {
                risk = .high
                reasons.append("The file looks sensitive (credentials, keys, shell or git config).")
            }

        case "Bash":
            let command = r.input["command"]?.stringValue ?? ""
            let bash = BashRisk.classify(command)
            risk = bash.level
            reasons += bash.reasons
            summary = "Run: \(command)"
            // Spoken from the command itself. Claude's own `description` field is free text the model
            // (or a prompt-injected repo) chooses, so it never stands in for what will run.
            let what = ToolNarrator.commandSummary(command, pronunciation: pronunciation)
            spoken = "Claude wants to run \(pronunciation.speak(what)). Allow?"

        default:
            risk = .medium
            let name = r.displayName ?? r.toolName
            summary = "Use \(name)"
            spoken = "Claude wants to use \(Pronunciation.splitIdentifier(name)). Allow?"
        }

        // Signals from Claude Code itself always win.
        if r.decisionReasonType == "safetyCheck" || r.defaultToNo {
            risk = .high
            reasons.append(r.decisionReason ?? "Claude Code flagged this as needing explicit approval.")
        }
        var voiceOK = risk < .high
        if r.requiresUserInteraction {
            voiceOK = false
            reasons.append("This request needs you at the screen.")
        }
        if !voiceOK {
            spoken = spoken.replacingOccurrences(of: " Allow?", with: ". Please confirm on screen.")
        }
        let auto = risk == .low && voiceOK && !r.requiresUserInteraction
            && PermissionPolicy.readOnlyTools.contains(r.toolName) && !PermissionPolicy.neverAutoApprove.contains(r.toolName)
        return PermissionAssessment(risk: risk, voiceApprovable: voiceOK, spokenPrompt: spoken, summary: summary,
                                    reasons: reasons, autoApprovable: auto)
    }

    func isInsideProject(_ path: String) -> Bool {
        guard let root = projectRoot, !path.isEmpty else { return false }
        let p = (path as NSString).standardizingPath
        let absolute = p.hasPrefix("/") ? p : (root as NSString).appendingPathComponent(p)
        let normalized = (absolute as NSString).standardizingPath
        return normalized == root || normalized.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    static func isSensitivePath(_ path: String) -> Bool {
        let p = path.lowercased()
        let needles = ["/.ssh/", "/.aws/", "/.gnupg/", ".env", "id_rsa", "id_ed25519", ".pem", ".p12", "/.git/config",
                       ".zshrc", ".bashrc", ".bash_profile", ".zprofile", ".npmrc", ".netrc", "credentials",
                       "/library/launchagents/", "/etc/"]
        return needles.contains { p.contains($0) }
    }
}

/// Heuristic classification of shell commands.
public enum BashRisk {
    public struct Result: Sendable, Equatable {
        public var level: RiskLevel
        public var reasons: [String]
    }

    struct Rule {
        let pattern: String
        let level: RiskLevel
        let reason: String
    }

    static let rules: [Rule] = [
        Rule(pattern: #"(^|[\s;&|(])sudo\s"#, level: .high, reason: "Runs as administrator (sudo)."),
        Rule(pattern: #"\brm\s+(-[a-zA-Z]*[rRfF][a-zA-Z]*\s+)+"#, level: .high, reason: "Deletes files recursively or forcefully."),
        Rule(pattern: #"\brm\s"#, level: .medium, reason: "Deletes files."),
        Rule(pattern: #"\bgit\s+push\b.*(--force|-f\b|--force-with-lease)"#, level: .high, reason: "Force-pushes to a remote."),
        Rule(pattern: #"\bgit\s+push\b"#, level: .high, reason: "Pushes to a remote."),
        Rule(pattern: #"\bgit\s+reset\s+--hard\b"#, level: .high, reason: "Discards local changes."),
        Rule(pattern: #"\bgit\s+clean\s+-[a-zA-Z]*f"#, level: .high, reason: "Deletes untracked files."),
        Rule(pattern: #"\bgit\s+(checkout|restore)\s+(--\s+)?\.(\s|$)"#, level: .high, reason: "Discards local changes."),
        Rule(pattern: #"\bgit\s+branch\s+-D\b"#, level: .high, reason: "Deletes a branch."),
        Rule(pattern: #"\b(chmod|chown)\s+-R\b"#, level: .high, reason: "Changes permissions recursively."),
        Rule(pattern: #"\bdd\s+if="#, level: .high, reason: "Raw disk write (dd)."),
        Rule(pattern: #"\bmkfs\b|\bdiskutil\s+(erase|partition)"#, level: .high, reason: "Formats a disk."),
        Rule(pattern: #"(curl|wget)\b[^|]*\|\s*(sudo\s+)?(sh|bash|zsh|python3?)\b"#, level: .high, reason: "Pipes a download into a shell."),
        Rule(pattern: #">\s*/dev/(sd|disk)"#, level: .high, reason: "Writes to a raw device."),
        Rule(pattern: #":\(\)\s*\{"#, level: .high, reason: "Fork bomb."),
        Rule(pattern: #"\b(shutdown|reboot|halt)\b"#, level: .high, reason: "Shuts down the machine."),
        Rule(pattern: #"\bkill(all)?\s+-9\b|\bpkill\b"#, level: .high, reason: "Kills processes."),
        Rule(pattern: #"\blaunchctl\b|\bdefaults\s+write\b|\bcrontab\b"#, level: .high, reason: "Changes system configuration."),
        Rule(pattern: #"\b(npm|yarn|pnpm|cargo|gem|twine)\s+publish\b|\bpod\s+trunk\s+push\b"#, level: .high, reason: "Publishes a package."),
        Rule(pattern: #"\bdocker\s+(system\s+prune|rm|rmi|volume\s+rm)\b"#, level: .high, reason: "Removes Docker resources."),
        Rule(pattern: #"(?i)\b(drop\s+(table|database)|truncate\s+table)\b"#, level: .high, reason: "Destroys database data."),
        Rule(pattern: #"\bgh\s+(pr\s+merge|release\s+create|repo\s+delete)\b"#, level: .high, reason: "Changes a GitHub repository."),
        Rule(pattern: #"\b(ssh|scp|rsync)\s"#, level: .medium, reason: "Connects to another machine."),
        Rule(pattern: #"\b(curl|wget)\s"#, level: .medium, reason: "Accesses the network."),
        Rule(pattern: #"\b(npm|yarn|pnpm)\s+(i|install|add)\b|\bpip3?\s+install\b|\bbrew\s+(install|upgrade|uninstall)\b|\bcargo\s+install\b"#, level: .medium, reason: "Installs packages."),
        Rule(pattern: #"\bmv\s"#, level: .medium, reason: "Moves or renames files."),
        Rule(pattern: #"\bgit\s+(commit|merge|rebase|checkout|switch|stash|tag)\b"#, level: .medium, reason: "Changes git state."),
        Rule(pattern: #"(^|[^>])>\s*[^\s&]"#, level: .medium, reason: "Writes a file via redirection."),
        Rule(pattern: #"\b(python3?|node|deno|bun|perl|ruby|php|lua|osascript|swift|go\s+run)\b"#, level: .medium, reason: "Runs a script or interpreter."),
        Rule(pattern: #"(^|[\s;&|(])(ba|z)?sh\s|\beval\b|\bxargs\b|\bexec\b|\bsource\s|<\("#, level: .medium, reason: "Runs a nested shell or evaluates text as code."),
        Rule(pattern: #"\bopen\s"#, level: .medium, reason: "Opens a file or URL with another app."),
    ]

    /// Commands that only read and print, when they stand alone (no chaining, redirection or substitution).
    static let readOnlyCommands: Set<String> = ["ls", "pwd", "cat", "head", "tail", "wc", "echo", "grep", "rg", "which",
                                               "whoami", "date", "diff", "file", "stat", "tree", "du", "df", "uname",
                                               "sort", "uniq", "basename", "dirname", "realpath", "true"]
    static let readOnlyGitSubcommands: Set<String> = ["status", "diff", "log", "show", "rev-parse", "ls-files", "blame"]

    /// Global git options (`-C dir`, `-c k=v`, ...) sit between `git` and the subcommand and would hide it from the
    /// rules, so matching is done on a copy with them removed.
    static func normalizedForMatching(_ command: String) -> String {
        let pattern = #"\bgit(\s+(-C\s+\S+|-c\s+\S+|--git-dir(=|\s+)\S+|--work-tree(=|\s+)\S+|--no-pager|-P|--no-optional-locks))+"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return command }
        return re.stringByReplacingMatches(in: command, range: NSRange(location: 0, length: (command as NSString).length),
                                           withTemplate: "git")
    }

    /// True for plain read-only commands such as `ls -la src` or `git status | head`, optionally joined
    /// with `&&` or a pipe. Anything with substitution, redirection, backgrounding or `;` is not plain.
    static func isPlainReadOnly(_ command: String) -> Bool {
        let c = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !c.isEmpty else { return false }
        let joined = c.replacingOccurrences(of: "&&", with: "|")
        guard joined.rangeOfCharacter(from: CharacterSet(charactersIn: ";&<>`$()\n\\")) == nil else { return false }
        let segments = joined.components(separatedBy: "|")
        return segments.allSatisfy { segment in
            let words = segment.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let first = words.first else { return false }  // an empty segment means `||` or a stray pipe
            if first == "git" { return words.count > 1 && readOnlyGitSubcommands.contains(words[1]) }
            return readOnlyCommands.contains(first)
        }
    }

    public static func classify(_ original: String) -> Result {
        let command = normalizedForMatching(original)
        var level: RiskLevel = .low
        var reasons: [String] = []
        let ns = command as NSString
        let range = NSRange(location: 0, length: ns.length)
        for rule in rules {
            guard let re = try? NSRegularExpression(pattern: rule.pattern) else { continue }
            if re.firstMatch(in: command, range: range) != nil {
                if rule.level > level { level = rule.level }
                if !reasons.contains(rule.reason) { reasons.append(rule.reason) }
            }
        }
        // Mentions of paths outside the project via absolute system locations.
        if command.contains("~/") || command.contains("$HOME") {
            level = max(level, .medium)
            reasons.append("Touches your home folder.")
        }
        if PermissionPolicy.isSensitivePath(command) {
            level = max(level, .medium)
            reasons.append("Mentions a file that looks sensitive (credentials, keys, shell or git config).")
        }
        // Anything not recognized as a plain read-only command is not "low": low means known-harmless.
        if level == .low, !isPlainReadOnly(command) {
            level = .medium
            reasons.append("Not a recognized read-only command.")
        }
        // A deletion rule implies the weaker "Deletes files." reason; keep the strongest only.
        if reasons.contains("Deletes files recursively or forcefully.") {
            reasons.removeAll { $0 == "Deletes files." }
        }
        if reasons.contains("Force-pushes to a remote.") {
            reasons.removeAll { $0 == "Pushes to a remote." }
        }
        return Result(level: level, reasons: reasons)
    }
}
