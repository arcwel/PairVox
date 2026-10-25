// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The AppleScript that opens Terminal running `claude`, so the user signs in through Anthropic's own flow.
public enum TerminalLogin {
    /// The path is quoted for the shell first (a path with a space, `$` or a quote stays one word), then escaped for
    /// the AppleScript string. It used to escape only double quotes, so a path with a space did not run (audit run 7).
    public static func appleScript(claudePath: String?) -> String {
        let command = claudePath.map(shellQuoted) ?? "claude"
        let literal = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "tell application \"Terminal\" to do script \"\(literal)\"\ntell application \"Terminal\" to activate"
    }

    /// One shell word: the text in single quotes, each single quote written as '\''.
    public static func shellQuoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
