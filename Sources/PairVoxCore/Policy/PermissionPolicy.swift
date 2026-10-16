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
    /// A folder grant the user gave covers this request, so it is allowed without asking.
    public var coveredByFolderGrant: Bool = false

    /// Whether a small surface (menu bar, mini window, "allow together" list) shows enough to approve from:
    /// one short line and at most one reason. Anything longer is reviewed on the full card.
    public var fitsCompactSurface: Bool {
        risk < .high && reasons.count <= 1 && !summary.contains("\n") && summary.count <= 90
    }
}

/// Classifies tool-permission requests so misheard voice approvals can't do
/// anything destructive. This is a guardrail on top of Claude Code's own
/// permission system, never a replacement for it.
public struct PermissionPolicy: Sendable {
    public var projectRoot: String?
    public var pronunciation: Pronunciation
    public var grants: [FolderGrant]
    /// A spoken yes may answer a request from its one-line summary (file name, first command step) even when the
    /// full command is too long to read out; the full command is on screen. Off, a long or complex command needs a
    /// click. The owner's choice (Settings, Permissions); on by default since a 250-character path read aloud
    /// tells a listener nothing.
    public var voiceFromSummary: Bool

    public init(projectRoot: String?, pronunciation: Pronunciation = Pronunciation(), grants: [FolderGrant] = [],
                voiceFromSummary: Bool = true) {
        self.projectRoot = projectRoot.map { ($0 as NSString).standardizingPath }
        self.pronunciation = pronunciation
        self.grants = grants
        self.voiceFromSummary = voiceFromSummary
    }

    /// How a path is spoken: its file name, and whether it is in the project. A listener gets nothing from the
    /// folders above it, and a long path takes ten seconds to read.
    func spokenFile(_ path: String) -> String {
        guard !path.isEmpty else { return "a file" }
        let name = pronunciation.speak((path as NSString).lastPathComponent)
        return isInsideProject(path) ? "\(name) in the project folder" : "\(name) outside the project"
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
        var screenOnly = false

        switch r.toolName {
        case let t where PermissionPolicy.readOnlyTools.contains(t):
            risk = .low
            summary = "\(r.displayName ?? t)"
            let targets = PermissionPolicy.readTargets(r)
            spoken = targets.count == 1 ? "Claude wants to read \(spokenFile(targets[0])). Allow?"
                : "Claude wants to use \(Pronunciation.splitIdentifier(t)). Allow?"
            if let target = targets.first(where: PermissionPolicy.isSensitivePath) {
                risk = .medium
                summary = "\(r.displayName ?? t) \(target)"
                reasons.append("It would read a file that looks sensitive (credentials, keys, shell or git config).")
            }
            if projectRoot != nil, targets.contains(where: { !isInsideProject($0) }) {
                risk = max(risk, .medium)
                reasons.append("It would read outside the project folder.")
            }

        case "WebFetch":
            risk = .medium
            let url = r.input["url"]?.stringValue ?? ""
            summary = "Fetch \(url)"
            let host = URL(string: url)?.host ?? url
            spoken = "Claude wants to fetch a page from \(pronunciation.speak(host)). Allow?"

        case let t where PermissionPolicy.fileWriteTools.contains(t):
            let path = r.input["file_path"]?.stringValue ?? r.input["notebook_path"]?.stringValue ?? r.blockedPath ?? ""
            let verb = t == "Write" ? "write" : "edit"
            summary = "\(verb.capitalized) \(path)"
            spoken = "Claude wants to \(verb) \(spokenFile(path)). Allow?"
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
            let bash = BashRisk.classify(command, projectRoot: projectRoot)
            risk = bash.level
            reasons += bash.reasons
            summary = "Run: \(command)"
            // Spoken from the command itself. Claude's own `description` field is free text the model
            // (or a prompt-injected repo) chooses, so it never stands in for what will run.
            let narration = BashRisk.narration(command, pronunciation: pronunciation)
            // The first step and a count: the rest of a long command is read from the screen, not the speaker.
            let steps = BashRisk.segments(command).count
            let firstStep = ToolNarrator.commandSummary(command, pronunciation: pronunciation)
            let more = steps > 1 ? " and \(steps - 1) more \(steps == 2 ? "step" : "steps") shown on screen" : ""
            // With the summary setting off, the whole command is read, so that a yes covers only what was heard.
            spoken = voiceFromSummary ? "Claude wants to run \(firstStep)\(more). Allow?" : "Claude wants to run \(narration.text). Allow?"
            // Without the summary setting, a spoken yes must cover exactly what was heard.
            screenOnly = (narration.partial && !voiceFromSummary)
                || bash.reasons.contains { BashRisk.networkReasons.contains($0) }

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
        var voiceOK = risk < .high && !screenOnly
        if screenOnly, risk < .high {
            reasons.append(voiceFromSummary ? "The command reaches the network. Check it on screen."
                                            : "The command is too long or complex to read out, or reaches the network. Check it on screen.")
        }
        if r.requiresUserInteraction {
            voiceOK = false
            reasons.append("This request needs you at the screen.")
        }
        if !voiceOK {
            spoken = spoken.replacingOccurrences(of: " Allow?", with: ". Please confirm on screen.")
        }
        let auto = risk == .low && voiceOK && !r.requiresUserInteraction
            && PermissionPolicy.readOnlyTools.contains(r.toolName) && !PermissionPolicy.neverAutoApprove.contains(r.toolName)
        // A folder grant only ever covers requests that are otherwise ordinary (never high risk, never flagged).
        var covered = false
        if risk <= .medium, !r.requiresUserInteraction, !r.defaultToNo, r.decisionReasonType != "safetyCheck" {
            if PermissionPolicy.fileWriteTools.contains(r.toolName) {
                covered = FolderScope.editGrant(for: r, in: grants, projectRoot: projectRoot) != nil
            } else if r.toolName == "Bash" {
                covered = FolderScope.shellGrant(for: r, risk: risk, reasons: reasons, in: grants, projectRoot: projectRoot) != nil
            }
        }
        return PermissionAssessment(risk: risk, voiceApprovable: voiceOK, spokenPrompt: spoken, summary: summary,
                                    reasons: reasons, autoApprovable: auto, coveredByFolderGrant: covered)
    }

    /// Whether `path` is inside the project folder. Both sides are symlink-resolved, so /tmp vs /private/tmp (which
    /// Claude Code reports) does not make a project's own files look foreign, and a link inside the project that
    /// leads elsewhere does not look like it belongs to it.
    func isInsideProject(_ path: String) -> Bool {
        guard let root = projectRoot, !path.isEmpty else { return false }
        return FolderScope.contains(folder: root, path: path, relativeTo: root)
    }

    /// Every path a read-only tool would look at: `file_path`, `path`, and an absolute or home-relative Glob `pattern`.
    static func readTargets(_ r: PermissionRequest) -> [String] {
        var out: [String] = []
        for key in ["file_path", "path"] {
            if let v = r.input[key]?.stringValue, !v.isEmpty { out.append(v) }
        }
        if let pattern = r.input["pattern"]?.stringValue, r.toolName == "Glob",
           pattern.hasPrefix("/") || pattern.hasPrefix("~") || pattern.contains("..") {
            // Keep only the part before the first wildcard, which is the folder the glob starts in.
            let cut = pattern.firstIndex(where: { "*?[{".contains($0) }) ?? pattern.endIndex
            out.append(String(pattern[..<cut]))
        }
        return out
    }

    /// PairVox's own settings (the consent store) and the Claude Code configuration folder.
    static var protectedFolders: [String] {
        [SettingsStore.defaultURL().deletingLastPathComponent().path, NSHomeDirectory() + "/.claude"]
            .map { FolderScope.resolved($0) }
    }

    static func isSensitivePath(_ path: String) -> Bool {
        let p = path.lowercased()
        let needles = ["/.ssh", "/.aws", "/.gnupg", "/.docker", "/.kube", "/.config/gh", "/.config/gcloud",
                       "/library/keychains", "/.claude", "application support/pairvox", ".git-credentials",
                       ".env", "id_rsa", "id_ed25519", ".pem", ".p12", "/.git/config",
                       ".zshrc", ".bashrc", ".bash_profile", ".zprofile", ".zshenv", ".npmrc", ".netrc", "credentials",
                       "/library/launchagents/", "/etc/"]
        if needles.contains(where: { p.contains($0) }) { return true }
        guard path.hasPrefix("/") || path.hasPrefix("~") else { return false }
        let resolved = FolderScope.resolved(path)
        return protectedFolders.contains { resolved == $0 || resolved.hasPrefix($0 + "/") }
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
        Rule(pattern: #"\b(ssh|scp|rsync|nc|ncat|netcat|telnet|ftp|sftp|tftp|socat)\s"#, level: .medium, reason: "Connects to another machine."),
        Rule(pattern: #"\bgit\s+(fetch|pull|clone|remote|ls-remote|submodule)\b"#, level: .medium, reason: "Accesses the network."),
        Rule(pattern: #"\b(gh|docker|podman|kubectl|aws|gcloud|az|terraform|heroku|vercel|fly|flyctl)\s"#, level: .medium, reason: "Uses a tool that acts on outside services."),
        Rule(pattern: #"\b(curl|wget)\s"#, level: .medium, reason: "Accesses the network."),
        Rule(pattern: #"\b(npm|yarn|pnpm)\s+(i|install|add)\b|\bpip3?\s+install\b|\bbrew\s+(install|upgrade|uninstall)\b|\bcargo\s+install\b"#, level: .medium, reason: "Installs packages."),
        Rule(pattern: #"\bmv\s"#, level: .medium, reason: "Moves or renames files."),
        Rule(pattern: #"\bgit\s+(commit|merge|rebase|checkout|switch|stash|tag)\b"#, level: .medium, reason: "Changes git state."),
        Rule(pattern: #"(^|[^>])>\s*[^\s&]"#, level: .medium, reason: "Writes a file via redirection."),
        Rule(pattern: #"\b(python3?|node|deno|bun|perl|ruby|php|lua|osascript|swift|go\s+run)\b"#, level: .medium, reason: "Runs a script or interpreter."),
        Rule(pattern: #"(^|[\s;&|(])(ba|z)?sh\s|\beval\b|\bxargs\b|\bexec\b|\bsource\s|<\("#, level: .medium, reason: "Runs a nested shell or evaluates text as code."),
        Rule(pattern: #"\bopen\s"#, level: .medium, reason: "Opens a file or URL with another app."),
    ]


    /// Reasons that mean the command reaches another machine or service.
    static let networkReasons: Set<String> = ["Connects to another machine.", "Accesses the network.",
                                              "Uses a tool that acts on outside services.", "Pipes a download into a shell."]

    static let shellNames: Set<String> = ["sh", "bash", "zsh", "dash", "ksh", "fish", "csh", "tcsh", "python", "python3",
                                          "node", "deno", "bun", "ruby", "perl", "php", "lua"]
    static let wrapperNames: Set<String> = ["env", "command", "nohup", "time", "nice", "exec", "builtin", "caffeinate", "stdbuf"]

    struct Segment {
        var separator: String
        var words: [String]
        /// Program name without its directory, with leading `VAR=value` words and wrappers like `env` skipped.
        var program: String
        var args: [String]
    }

    /// Splits a command at `&&`, `||`, `;`, `|`, `&` and newlines (quotes are not honored, which only errs toward more segments).
    static func segments(_ command: String) -> [Segment] {
        var out: [Segment] = []
        var current = ""
        var separator = ""
        let chars = Array(command)
        var i = 0
        func flush(next: String) {
            let words = current.split(whereSeparator: { $0 == " " || $0 == "\t" }).map { w -> String in
                var t = String(w)
                while let f = t.first, f == "'" || f == "\"" || f == "\\" || f == "(" || f == "{" { t.removeFirst() }
                while let l = t.last, l == "'" || l == "\"" || l == ")" || l == "}" { t.removeLast() }
                return t
            }.filter { !$0.isEmpty }
            if !words.isEmpty {
                var rest = words[...]
                while let w = rest.first, (w.contains("=") && !w.hasPrefix("-") && !w.contains("/") ) || wrapperNames.contains((w as NSString).lastPathComponent) {
                    rest = rest.dropFirst()
                }
                let program = rest.first.map { ($0 as NSString).lastPathComponent } ?? ""
                out.append(Segment(separator: separator, words: words, program: program, args: Array(rest.dropFirst())))
            }
            current = ""
            separator = next
        }
        while i < chars.count {
            let c = chars[i]
            if c == "&" || c == "|" {
                if i + 1 < chars.count, chars[i + 1] == c { flush(next: String([c, c])); i += 2; continue }
                flush(next: String(c)); i += 1; continue
            }
            if c == ";" || c == "\n" { flush(next: ";"); i += 1; continue }
            current.append(c); i += 1
        }
        flush(next: "")
        return out
    }

    /// Classifies by program and subcommand instead of by spelling, so `--recursive`, `git -p push`,
    /// `/usr/bin/sudo` and `| /bin/sh` rate the same as their common forms.
    static func structuralFindings(_ command: String) -> [(RiskLevel, String)] {
        var found: [(RiskLevel, String)] = []
        let segs = segments(command)
        var sawDownloader = false
        for seg in segs {
            let p = seg.program, a = seg.args
            let flags = a.filter { $0.hasPrefix("-") }
            func shortHas(_ letters: String) -> Bool {
                flags.contains { $0.hasPrefix("-") && !$0.hasPrefix("--") && $0.contains(where: { letters.contains($0) }) }
            }
            if ["sudo", "doas", "su", "pkexec"].contains(p) { found.append((.high, "Runs as administrator (sudo).")) }
            if p == "rm" {
                if shortHas("rRf") || flags.contains(where: { ["--recursive", "--force", "--no-preserve-root"].contains($0) }) {
                    found.append((.high, "Deletes files recursively or forcefully."))
                }
            }
            if ["chmod", "chown", "chgrp"].contains(p), shortHas("R") || flags.contains("--recursive") {
                found.append((.high, "Changes permissions recursively."))
            }
            if p == "git" {
                var rest = a[...]
                while let w = rest.first, w.hasPrefix("-") {
                    rest = rest.dropFirst()
                    if ["-C", "-c", "--git-dir", "--work-tree", "--namespace", "--exec-path", "--super-prefix"].contains(w) { rest = rest.dropFirst() }
                }
                let sub = rest.first ?? ""
                if a.contains("-c") || sub == "config" || sub == "alias" {
                    found.append((.medium, "Runs a nested shell or evaluates text as code."))
                }
                let subArgs = Array(rest.dropFirst())
                let subFlags = subArgs.filter { $0.hasPrefix("-") }
                switch sub {
                case "push":
                    found.append((.high, subFlags.contains(where: { $0.hasPrefix("--force") || $0 == "-f" })
                        ? "Force-pushes to a remote." : "Pushes to a remote."))
                case "reset" where subFlags.contains("--hard"):
                    found.append((.high, "Discards local changes."))
                case "clean" where subFlags.contains(where: { $0 == "--force" || ($0.hasPrefix("-") && !$0.hasPrefix("--") && $0.contains("f")) }):
                    found.append((.high, "Deletes untracked files."))
                case "checkout" where subArgs.contains("."), "restore" where subArgs.contains("."):
                    found.append((.high, "Discards local changes."))
                case "branch" where subFlags.contains(where: { $0 == "-D" || $0 == "--delete" || $0 == "-d" }):
                    found.append((.high, "Deletes a branch."))
                default: break
                }
            }
            if p == "find", a.contains(where: { ["-delete", "-exec", "-execdir", "-ok", "-okdir"].contains($0) }) {
                found.append((.medium, "Runs a nested shell or evaluates text as code."))
            }
            if ["awk", "gawk", "mawk"].contains(p), command.contains("system(") || command.contains("| getline") {
                found.append((.medium, "Runs a nested shell or evaluates text as code."))
            }
            if ["sh", "bash", "zsh", "dash", "ksh", "fish", "csh", "tcsh"].contains(p) {
                found.append((.medium, "Runs a nested shell or evaluates text as code."))
            }
            if shellNames.contains(p), seg.separator == "|" {
                found.append((.medium, "Runs a nested shell or evaluates text as code."))
            }
            if ["docker", "podman"].contains(p), a.contains(where: { ["rm", "rmi", "prune"].contains($0) }) {
                found.append((.high, "Removes Docker resources."))
            }
            if ["npm", "yarn", "pnpm", "cargo", "gem", "twine"].contains(p), a.contains("publish") {
                found.append((.high, "Publishes a package."))
            }
            if ["curl", "wget", "fetch"].contains(p) { sawDownloader = true }
            if shellNames.contains(p), seg.separator == "|", sawDownloader {
                found.append((.high, "Pipes a download into a shell."))
            }
            if shellNames.contains(p), a.contains("-c"), command.contains("curl") || command.contains("wget") {
                found.append((.high, "Pipes a download into a shell."))
            }
        }
        return found
    }

    /// What is said aloud for a Bash request. `partial` is true when the readout cannot stand for the whole command,
    /// so a spoken yes would approve something the person did not hear.
    static func narration(_ command: String, pronunciation: Pronunciation) -> (text: String, partial: Bool) {
        let segs = segments(command)
        let hidden = command.contains("$(") || command.contains("`") || command.contains("<<") || command.contains(">")
            || command.contains("<(")
        let parts = segs.map { ToolNarrator.commandSummary(([$0.program] + $0.args).joined(separator: " "), pronunciation: pronunciation) }
        let text = parts.count <= 1 ? (parts.first ?? "a command")
            : "a command with \(parts.count) steps: " + parts.joined(separator: ", then ")
        let partial = segs.count > 3 || hidden || text.count > 160 || parts.contains("a command")
        return (text, partial)
    }

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

    /// True if any word of the command, once `~`, `$HOME`, backslashes and quotes are resolved, is inside a folder
    /// that holds the consent store (PairVox's settings) or Claude Code's configuration.
    static func touchesProtectedFolder(_ command: String, projectRoot: String? = nil, depth: Int = 0) -> Bool {
        let home = NSHomeDirectory()
        let folders = PermissionPolicy.protectedFolders
        func isProtected(_ path: String) -> Bool {
            let resolved = FolderScope.resolved(path)
            return folders.contains { resolved == $0 || resolved.hasPrefix($0 + "/") }
        }
        // `cd`, `pushd` or a bare `cd` change what a relative word means, so later words are read from there.
        var base = projectRoot
        var words = shellWords(command)
        var i = 0
        while i < words.count {
            var w = words[i]; i += 1
            if w == "cd" || w == "pushd" {
                let next = i < words.count ? words[i] : "~"
                base = (next.hasPrefix("-") || next == "~" || next.hasPrefix("~/") || next.hasPrefix("$HOME") || next == "${HOME}") ? home
                     : (next.hasPrefix("/") ? next : (base.map { ($0 as NSString).appendingPathComponent(next) } ?? home))
                continue
            }
            // A quoted word that is itself a command line (sh -c '...', eval '...') is read the same way.
            if depth < 3, w.contains(" "), w.contains("/") || w.contains("~") || w.contains("HOME") {
                if touchesProtectedFolder(w, projectRoot: base, depth: depth + 1) { return true }
            }
            guard w.contains("/") || w.hasPrefix("~") || w.contains("HOME") || w.contains(".") || w.contains("*") || w.contains("?") else { continue }
            w = w.replacingOccurrences(of: "${HOME}", with: home).replacingOccurrences(of: "$HOME", with: home)
            if w.hasPrefix("~") { w = (w as NSString).expandingTildeInPath }
            let absolute = w.hasPrefix("/") ? w : (base.map { ($0 as NSString).appendingPathComponent(w) } ?? "")
            guard !absolute.isEmpty else { continue }
            if absolute.contains("*") || absolute.contains("?") || absolute.contains("[") {
                // Expand the pattern for real and check what it can reach.
                var g = glob_t()
                defer { globfree(&g) }
                if glob(absolute, GLOB_BRACE | GLOB_TILDE | GLOB_MARK, nil, &g) == 0 {
                    for k in 0..<Int(g.gl_pathc) { if let c = g.gl_pathv[k], isProtected(String(cString: c)) { return true } }
                }
            } else if isProtected(absolute) { return true }
        }
        return false
    }

    /// Splits a command into words the way a shell does for quotes and backslashes (no expansion), treating `;`,
    /// `&`, `|`, `<`, `>`, `(`, `)` and `=` as word breaks outside quotes.
    static func shellWords(_ command: String) -> [String] {
        var words: [String] = [], current = "", quote: Character?, escaped = false, started = false
        func flush() { if started { words.append(current) }; current = ""; started = false }
        for ch in command {
            if escaped { current.append(ch); started = true; escaped = false; continue }
            if ch == "\\", quote != "'" { escaped = true; continue }
            if let q = quote { if ch == q { quote = nil } else { current.append(ch) }; continue }
            if ch == "\"" || ch == "'" { quote = ch; started = true; continue }
            if " \t\n;&|<>()=,".contains(ch) { flush(); continue }
            current.append(ch); started = true
        }
        flush()
        return words
    }

    public static func classify(_ original: String, projectRoot: String? = nil) -> Result {
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
        for (lvl, reason) in structuralFindings(original) {
            if lvl > level { level = lvl }
            if !reasons.contains(reason) { reasons.append(reason) }
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
        // Reaching PairVox's own settings or Claude Code's configuration by any spelling (`~`, `$HOME`, backslash or
        // quoted paths) is as serious in a shell command as writing there with Edit: it is high risk.
        if touchesProtectedFolder(original, projectRoot: projectRoot) {
            level = .high
            reasons.append("Touches PairVox's own settings or Claude Code's configuration.")
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
        if reasons.contains("Deletes files.") && reasons.contains("Deletes files recursively or forcefully.") {
            reasons.removeAll { $0 == "Deletes files." }
        }
        if reasons.contains("Force-pushes to a remote.") {
            reasons.removeAll { $0 == "Pushes to a remote." }
        }
        return Result(level: level, reasons: reasons)
    }
}


extension PermissionRequest {
    /// Claude Code itself says this request needs the person at the screen (a safety check, a required interaction,
    /// or a default-to-no). Its own flag always wins over PairVox's rating.
    public var needsPersonAtScreen: Bool { requiresUserInteraction || decisionReasonType == "safetyCheck" || defaultToNo }
}
