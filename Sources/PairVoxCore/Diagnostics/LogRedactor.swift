// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Scrubs text before it reaches a log file that may be shared outside this machine:
/// API keys and tokens, e-mail addresses, and the user's home folder and account name.
public struct LogRedactor: Sendable {
    public let homeDirectory: String
    public let userName: String

    public init(homeDirectory: String = NSHomeDirectory(), userName: String = NSUserName()) {
        self.homeDirectory = homeDirectory
        self.userName = userName
    }

    private static let patterns: [(NSRegularExpression, String)] = {
        let specs: [(String, String)] = [
            (#"sk-ant-[A-Za-z0-9_\-]{8,}"#, "<api-key>"),
            (#"\bsk-[A-Za-z0-9]{20,}"#, "<api-key>"),
            (#"\bgh[pousr]_[A-Za-z0-9]{20,}"#, "<github-token>"),
            (#"\bAKIA[0-9A-Z]{16}\b"#, "<aws-key>"),
            (#"(?i)\bBearer\s+[A-Za-z0-9._~+/=\-]{12,}"#, "Bearer <token>"),
            (#"(?i)(api[_-]?key|auth[_-]?token|access[_-]?token|secret|password)(\s*[=:]\s*)\S+"#, "$1$2<redacted>"),
            (#"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#, "<email>"),
        ]
        return specs.compactMap { spec in
            (try? NSRegularExpression(pattern: spec.0)).map { ($0, spec.1) }
        }
    }()

    public func scrub(_ text: String) -> String {
        var out = text
        if homeDirectory.count > 1 { out = out.replacingOccurrences(of: homeDirectory, with: "~") }
        if userName.count >= 3 { out = out.replacingOccurrences(of: userName, with: "<user>") }
        for (regex, template) in Self.patterns {
            out = regex.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: template)
        }
        return out
    }
}
