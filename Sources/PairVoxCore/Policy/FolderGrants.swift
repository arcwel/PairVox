// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The user's standing permission for Claude to work inside one folder without asking each time.
/// Grants live only in PairVox's own settings; a repository can never create one.
public struct FolderGrant: Codable, Sendable, Equatable, Identifiable {
    /// Resolved path (symlinks followed) of the granted folder.
    public var path: String
    public var grantedAt: Date
    /// Separate, stronger grant: also run shell commands in this folder without asking.
    public var allowShell: Bool

    public var id: String { path }

    public init(path: String, grantedAt: Date = Date(), allowShell: Bool = false) {
        self.path = path
        self.grantedAt = grantedAt
        self.allowShell = allowShell
    }
}

/// Decides whether a request falls inside a folder grant. All checks use fully resolved paths, so a symlink inside
/// the folder that points elsewhere does not carry the grant with it.
public enum FolderScope {
    /// `path` made absolute against `base`, `..` removed, and every existing part of it symlink-resolved.
    /// Works for files that do not exist yet (a new file in an existing folder).
    public static func resolved(_ path: String, relativeTo base: String? = nil) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        let absolute = expanded.hasPrefix("/") ? expanded : ((base ?? "/") as NSString).appendingPathComponent(expanded)
        let standard = (absolute as NSString).standardizingPath
        let fm = FileManager.default
        var existing = standard
        var tail: [String] = []
        while existing != "/", !fm.fileExists(atPath: existing) {
            tail.insert((existing as NSString).lastPathComponent, at: 0)
            existing = (existing as NSString).deletingLastPathComponent
        }
        var result = URL(fileURLWithPath: existing).resolvingSymlinksInPath().path
        for part in tail { result = (result as NSString).appendingPathComponent(part) }
        return result
    }

    public static func contains(folder: String, path: String, relativeTo base: String? = nil) -> Bool {
        let root = resolved(folder)
        let target = resolved(path, relativeTo: base ?? folder)
        return target == root || target.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    /// The grant that covers a file edit, if any.
    public static func editGrant(for request: PermissionRequest, in grants: [FolderGrant], projectRoot: String?) -> FolderGrant? {
        guard PermissionPolicy.fileWriteTools.contains(request.toolName) else { return nil }
        let path = request.input["file_path"]?.stringValue ?? request.input["notebook_path"]?.stringValue ?? ""
        guard !path.isEmpty else { return nil }
        return grants.first { contains(folder: $0.path, path: path, relativeTo: projectRoot) }
    }

    /// Reasons (from `BashRisk`) that mean a command reaches beyond its own folder or runs code PairVox cannot read.
    static let shellDisqualifiers: Set<String> = [
        "Connects to another machine.", "Accesses the network.", "Installs packages.", "Touches your home folder.",
        "Mentions a file that looks sensitive (credentials, keys, shell or git config).",
        "Runs a nested shell or evaluates text as code.", "Opens a file or URL with another app.",
        "Pushes to a remote.", "Force-pushes to a remote.", "Uses a tool that acts on outside services.",
        "Deletes files recursively or forcefully.", "Pipes a download into a shell.",
    ]

    /// The grant that covers a shell command, if any. Heuristic and deliberately narrow: anything it cannot
    /// confidently place inside the folder still asks.
    public static func shellGrant(for request: PermissionRequest, risk: RiskLevel, reasons: [String],
                                  in grants: [FolderGrant], projectRoot: String?) -> FolderGrant? {
        guard request.toolName == "Bash", risk <= .medium, !request.requiresUserInteraction,
              let command = request.input["command"]?.stringValue, !command.isEmpty,
              let root = projectRoot,
              let grant = grants.first(where: { $0.allowShell && contains(folder: $0.path, path: root) }) else { return nil }
        guard !reasons.contains(where: shellDisqualifiers.contains) else { return nil }
        // Variables and command substitution expand to paths this check cannot see.
        guard !command.contains("$"), !command.contains("`"), !hasInlineCode(command) else { return nil }
        // Brace expansion, history expansion and bracket classes rewrite words after this check has read them.
        guard command.rangeOfCharacter(from: CharacterSet(charactersIn: "{}[]!\\")) == nil else { return nil }
        // Quote removal and substitution forms that rewrite a word after this check has read it: `.''./x`, `>(…)`, `=(…)`, heredocs.
        guard command.range(of: #"\.['"]|['"]\.|[>=*]\(|<<"#, options: .regularExpression) == nil else { return nil }
        guard directoryChangesStayInside(command, grant: grant, root: root) else { return nil }
        guard pathTokens(in: command).allSatisfy({ pathCandidates($0).allSatisfy { contains(folder: grant.path, path: $0, relativeTo: root) } })
        else { return nil }
        return grant
    }

    /// `cd`, `pushd` and `popd` move later words away from the folder this check resolves them against.
    /// A bare `cd` goes to the home folder, so only `cd <one plain folder inside the grant>` passes.
    static func directoryChangesStayInside(_ command: String, grant: FolderGrant, root: String) -> Bool {
        for seg in BashRisk.segments(command) where ["cd", "pushd", "popd", "chdir"].contains(seg.program) {
            let args = seg.args.filter { !$0.hasPrefix("-") }
            guard seg.program == "cd" || seg.program == "pushd", args.count == 1, seg.args.count == 1,
                  !args[0].hasPrefix("~"), !args[0].contains("..") else { return false }
            guard contains(folder: grant.path, path: args[0], relativeTo: root) else { return false }
        }
        return true
    }

    /// The paths a token could name: the token itself, plus the part after a leading option letter (`-C/etc`)
    /// or a URL scheme (`file:///etc/passwd`), which a relative reading would wrongly place inside the folder.
    static func pathCandidates(_ token: String) -> [String] {
        var out = [token]
        let attached = token.hasPrefix("-") || (token.firstIndex(of: ":").map { $0 < (token.firstIndex(of: "/") ?? token.endIndex) } ?? false)
        if attached, let slash = token.firstIndex(of: "/") { out.append(String(token[slash...])) }
        if token.contains("..") { out.append("/..") }  // cannot be placed with certainty, so it never counts as inside
        return out
    }

    /// `python -c "…"`, `node -e "…"`, `perl -e`, `ruby -e`: code written into the command line itself.
    static func hasInlineCode(_ command: String) -> Bool {
        let interpreters: Set<String> = ["python", "python3", "node", "deno", "bun", "perl", "ruby", "php", "lua", "osascript"]
        return BashRisk.segments(command).contains { seg in
            interpreters.contains(seg.program) && seg.args.contains { arg in
                arg == "--eval" || arg == "--print" || arg == "--execute"
                    || arg.range(of: #"^-[a-zA-Z]*[ceEprx]$|^-[a-zA-Z]*e"#, options: .regularExpression) != nil
            }
        }
    }

    /// Tokens that look like file paths: anything with a slash, a leading dot-dot, or a home-folder tilde.
    static func pathTokens(in command: String) -> [String] {
        let separators = CharacterSet(charactersIn: " \t\n;&|<>()`\"'=")
        return command.components(separatedBy: separators).filter { token in
            guard !token.isEmpty else { return false }
            return token.contains("/") || token == ".." || token.hasPrefix("~") || token.hasPrefix("$")
        }.filter { !$0.hasPrefix("-") || $0.contains("/") }
    }
}
