// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The environment `scripts/pv-install.sh` gets when PairVox starts it (PairVox, Install Latest Build…).
///
/// The installer fetches, builds and signs a pulled tree, and the build runs that tree's scripts, so it gets only what
/// git, Xcode, the signing step and the launch check use, named one by one. `ChildEnvironment`'s deny-list is right
/// for Claude Code, which needs the user's whole shell setup, but here it let through every token it does not know
/// about (`GITHUB_TOKEN`, `AWS_SECRET_ACCESS_KEY`, a service key in `.zshrc`). An allow-list keeps those out
/// (audit run 9). Run from a terminal, the script has the terminal's environment, as any command does.
public enum InstallerEnvironment {
    /// Names passed through unchanged (case-sensitive, as the environment is).
    static let allowedNames: Set<String> = [
        // Finding programs, the home folder, temporary files, the user and their shell.
        "PATH", "HOME", "TMPDIR", "USER", "LOGNAME", "SHELL",
        // Text: locale, and the encoding macOS tools read.
        "LANG", "TERM", "__CF_USER_TEXT_ENCODING",
        // Which Xcode to build with, and git over SSH (the agent socket, not a key).
        "DEVELOPER_DIR", "SSH_AUTH_SOCK",
        // The signing choices scripts/build-app.sh reads, and where scripts/launch-check.sh finds the log.
        "SIGN_IDENTITY", "DEVELOPMENT_TEAM", "PAIRVOX_LOG",
    ]
    /// Locale variables (`LC_ALL`, `LC_CTYPE`, …).
    static let allowedPrefixes = ["LC_"]
    /// A user behind a proxy cannot fetch without these; the same ones reach the Claude child.
    static var proxyNames: Set<String> {
        Set(ChildEnvironment.passedProxyNames.flatMap { [$0, $0.lowercased()] })
    }

    public static func isAllowed(_ key: String) -> Bool {
        allowedNames.contains(key) || proxyNames.contains(key) || allowedPrefixes.contains { key.hasPrefix($0) }
    }

    /// Only the allowed variables.
    public static func filter(_ environment: [String: String]) -> [String: String] {
        environment.filter { isAllowed($0.key) }
    }
}
