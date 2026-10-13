// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Rewrites developer text so a TTS voice says it the way an engineer would.
/// Applied to prose after markdown has been stripped.
public struct Pronunciation: Sendable {
    /// User dictionary: exact token → spoken form (e.g. "kubectl" → "cube control").
    public var dictionary: [String: String]

    public init(dictionary: [String: String] = [:]) {
        self.dictionary = dictionary
    }

    /// Brand / mixed-case words that must not be split at case boundaries.
    static let keepAsIs: Set<String> = [
        "iOS", "macOS", "iPadOS", "watchOS", "tvOS", "visionOS", "iPhone", "iPad", "iCloud", "iMac", "AirPods",
        "GitHub", "GitLab", "JavaScript", "TypeScript", "CoffeeScript", "WebSocket", "WebSockets", "SwiftUI", "UIKit",
        "AppKit", "OpenAI", "YouTube", "PayPal", "LinkedIn", "PostgreSQL", "MySQL", "SQLite", "MongoDB", "GraphQL",
        "DynamoDB", "CloudFront", "DevOps", "OAuth", "JWT", "PowerShell", "VSCode", "IntelliJ", "WordPress", "DeepMind",
        "FastAPI", "NumPy", "PyTorch", "TensorFlow", "WhisperKit", "PairVox", "macBook", "MacBook", "HashMap", "README",
        "localhost", "npm", "ESLint", "WebKit", "CocoaPods", "XCTest", "SwiftPM", "CoreML", "MLX", "TestFlight",
    ]

    /// Extensions spoken letter-by-letter or by name.
    static let extensionNames: [String: String] = [
        "ts": "T S", "tsx": "T S X", "js": "J S", "jsx": "J S X", "mjs": "M J S", "py": "pie", "rb": "ruby",
        "rs": "rust", "go": "go", "md": "markdown", "json": "JSON", "yml": "yaml", "yaml": "yaml", "toml": "toml",
        "sh": "shell", "zsh": "Z shell", "txt": "text", "css": "C S S", "scss": "S C S S", "html": "H T M L",
        "swift": "swift", "kt": "kotlin", "java": "java", "c": "C", "h": "header", "cpp": "C plus plus",
        "hpp": "C plus plus header", "cs": "C sharp", "sql": "S Q L", "xml": "X M L", "plist": "P list",
        "lock": "lock", "env": "env", "vue": "view", "svelte": "svelte", "dart": "dart", "php": "P H P",
        "gradle": "gradle", "lua": "lua", "ex": "elixir", "exs": "elixir script", "dockerfile": "dockerfile",
    ]

    static let wordReplacements: [String: String] = [
        "e.g.": "for example", "i.e.": "that is", "etc.": "etcetera", "vs.": "versus", "vs": "versus",
        "w/": "with", "w/o": "without", "approx.": "approximately", "->": "to", "=>": "to", "→": "to",
        "←": "from", "==": "equals", "===": "strictly equals", "!=": "not equal to", "!==": "not equal to",
        "&&": "and", "||": "or", ">=": "at least", "<=": "at most", "&": "and", "~": "about",
        "TODO": "to do", "TL;DR": "in short", "tl;dr": "in short", "FYI": "F Y I", "PR": "P R", "PRs": "P Rs",
        "CI": "C I", "CLI": "C L I", "API": "A P I", "APIs": "A P Is", "UI": "U I", "UX": "U X", "LLM": "L L M",
        "LLMs": "L L Ms", "SDK": "S D K", "URL": "U R L", "URLs": "U R Ls", "ID": "I D", "IDs": "I Ds",
        "async": "a-sync", "stdin": "standard in", "stdout": "standard out", "stderr": "standard error",
        "regex": "rejex", "sudo": "sue-doo", "nginx": "engine X", "kubectl": "cube control", "k8s": "kubernetes",
        "Xcode": "X code", "repo": "repo", "repos": "repos", "config": "config", "env": "env",
    ]

    public func speak(_ text: String) -> String {
        var out: [String] = []
        for rawToken in text.split(separator: " ", omittingEmptySubsequences: true) {
            out.append(transformToken(String(rawToken)))
        }
        return out.joined(separator: " ")
            .replacingOccurrences(of: "  ", with: " ")
    }

    /// Transforms one whitespace-delimited token, keeping leading/trailing punctuation.
    func transformToken(_ token: String) -> String {
        if let custom = dictionary[token] { return custom }
        if let r = Pronunciation.wordReplacements[token] { return r }

        // Peel surrounding punctuation so "(see foo.ts)," still matches.
        let leadingSet = CharacterSet(charactersIn: "([{\"'“‘")
        let trailingSet = CharacterSet(charactersIn: ")]}\"'”’,;:!?.")
        var core = Substring(token)
        var lead = "", trail = ""
        while let f = core.unicodeScalars.first, leadingSet.contains(f) {
            lead.append(Character(f)); core = core.dropFirst()
        }
        while let l = core.unicodeScalars.last, trailingSet.contains(l) {
            // Keep a trailing dot that belongs to an abbreviation in the table.
            if l == ".", Pronunciation.wordReplacements[String(core)] != nil { break }
            trail = String(Character(l)) + trail; core = core.dropLast()
        }
        let c = String(core)
        if c.isEmpty { return token }
        if let custom = dictionary[c] { return lead + custom + trail }
        if let r = Pronunciation.wordReplacements[c] { return lead + r + trail }
        return lead + transformCore(c) + trail
    }

    func transformCore(_ c: String) -> String {
        if Pronunciation.keepAsIs.contains(c) { return c }
        if Pronunciation.isURL(c) { return Pronunciation.speakURL(c) }
        if Pronunciation.isUUID(c) { return "an I D" }
        if Pronunciation.isHash(c) { return "a hash" }
        if let v = Pronunciation.speakVersion(c) { return v }
        if c.hasPrefix("#"), c.count > 1, c.dropFirst().allSatisfy(\.isNumber) { return "number \(c.dropFirst())" }
        if Pronunciation.looksLikePath(c) { return speakPath(c) }
        if let f = speakFileName(c) { return f }
        return Pronunciation.splitIdentifier(c)
    }

    // MARK: Pieces

    static func isURL(_ s: String) -> Bool {
        s.hasPrefix("http://") || s.hasPrefix("https://") || s.hasPrefix("www.") || s.hasPrefix("ssh://")
            || s.hasPrefix("git@")
    }

    static func speakURL(_ s: String) -> String {
        var rest = s
        for p in ["https://", "http://", "ssh://", "git@"] where rest.hasPrefix(p) { rest.removeFirst(p.count) }
        if rest.hasPrefix("www.") { rest.removeFirst(4) }
        let host = rest.split(whereSeparator: { $0 == "/" || $0 == ":" }).first.map(String.init) ?? rest
        if host.hasPrefix("localhost") || host.first?.isNumber == true { return "a local link" }
        return "a link to " + host.replacingOccurrences(of: ".", with: " dot ")
    }

    static func isUUID(_ s: String) -> Bool {
        let parts = s.split(separator: "-")
        return parts.count == 5 && parts.map(\.count) == [8, 4, 4, 4, 12] && s.allSatisfy { $0.isHexDigit || $0 == "-" }
    }

    static func isHash(_ s: String) -> Bool {
        guard s.count >= 7, s.count <= 64, s.allSatisfy(\.isHexDigit) else { return false }
        return s.contains(where: \.isNumber) && s.contains(where: \.isLetter)
    }

    static func speakVersion(_ s: String) -> String? {
        var v = Substring(s)
        let hadV = v.first == "v" || v.first == "V"
        if hadV { v = v.dropFirst() }
        let parts = v.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2, parts.count <= 4, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else {
            return nil
        }
        // "3.14" in prose is a number; only treat as a version with a "v" or 3+ parts.
        guard hadV || parts.count >= 3 else { return nil }
        return "version " + parts.joined(separator: " point ")
    }

    static func looksLikePath(_ s: String) -> Bool {
        guard s.contains("/"), !s.contains("//"), s.count > 2 else { return false }
        let segments = s.split(separator: "/")
        guard segments.count >= 2 || s.hasPrefix("/") || s.hasPrefix("~/") || s.hasPrefix("./") else { return false }
        // "and/or", "read/write" are prose, not paths.
        if segments.count == 2, segments.allSatisfy({ $0.allSatisfy(\.isLetter) && $0.count <= 6 }),
           !s.hasPrefix("/"), !s.hasPrefix("~") { return false }
        return true
    }

    func speakPath(_ s: String) -> String {
        let trimmed = s.hasSuffix("/") ? String(s.dropLast()) : s
        let last = trimmed.split(separator: "/").last.map(String.init) ?? trimmed
        if let f = speakFileName(last) { return f }
        return Pronunciation.splitIdentifier(last) + (s.hasSuffix("/") ? " folder" : "")
    }

    /// "AuthService.swift" → "Auth Service dot swift"; returns nil if not a file name.
    func speakFileName(_ s: String) -> String? {
        guard let dot = s.lastIndex(of: "."), dot != s.startIndex else {
            // Dotfiles like ".env" or ".gitignore"
            if s.hasPrefix("."), s.count > 1, s.dropFirst().allSatisfy({ $0.isLetter || $0 == "_" || $0 == "-" }) {
                return "dot " + String(s.dropFirst())
            }
            return nil
        }
        let ext = String(s[s.index(after: dot)...]).lowercased()
        let base = String(s[..<dot])
        guard let spokenExt = Pronunciation.extensionNames[ext], !base.isEmpty,
              base.allSatisfy({ $0.isLetter || $0.isNumber || "_-.+@".contains($0) }) else { return nil }
        let spokenBase = base.split(separator: ".").map { Pronunciation.splitIdentifier(String($0)) }.joined(separator: " dot ")
        return "\(spokenBase) dot \(spokenExt)"
    }

    /// camelCase / PascalCase / snake_case / kebab-case → separate words.
    static func splitIdentifier(_ s: String) -> String {
        if keepAsIs.contains(s) { return s }
        let hasSeparators = s.contains("_") || (s.contains("-") && s.split(separator: "-").count > 2)
        let hasCaseHumps = zip(s, s.dropFirst()).contains { $0.isLowercase && $1.isUppercase }
        guard hasSeparators || hasCaseHumps else { return s }
        guard s.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) else { return s }

        var words: [String] = []
        var current = ""
        let chars = Array(s)
        for (i, ch) in chars.enumerated() {
            if ch == "_" || ch == "-" {
                if !current.isEmpty { words.append(current); current = "" }
                continue
            }
            if !current.isEmpty, ch.isUppercase {
                let prev = chars[i - 1]
                let nextIsLower = i + 1 < chars.count && chars[i + 1].isLowercase
                // fooBar | HTTPServer (split before "Server") | foo2Bar
                if prev.isLowercase || prev.isNumber || (prev.isUppercase && nextIsLower) {
                    words.append(current); current = ""
                }
            }
            current.append(ch)
        }
        if !current.isEmpty { words.append(current) }
        return words.joined(separator: " ")
    }
}
