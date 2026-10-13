// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Describes or reads code blocks aloud.
public enum CodeReader {
    static let languageNames: [String: String] = [
        "swift": "Swift", "ts": "TypeScript", "typescript": "TypeScript", "tsx": "TypeScript", "js": "JavaScript",
        "javascript": "JavaScript", "jsx": "JavaScript", "py": "Python", "python": "Python", "rb": "Ruby",
        "ruby": "Ruby", "go": "Go", "rust": "Rust", "rs": "Rust", "java": "Java", "kotlin": "Kotlin", "kt": "Kotlin",
        "c": "C", "cpp": "C plus plus", "c++": "C plus plus", "cs": "C sharp", "csharp": "C sharp", "sh": "shell",
        "bash": "shell", "zsh": "shell", "shell": "shell", "console": "terminal", "json": "JSON", "yaml": "YAML",
        "yml": "YAML", "toml": "TOML", "sql": "SQL", "html": "HTML", "css": "CSS", "diff": "diff", "patch": "diff",
        "md": "markdown", "markdown": "markdown", "dockerfile": "Dockerfile", "php": "PHP", "dart": "Dart",
        "xml": "XML", "graphql": "GraphQL", "text": "", "txt": "", "plaintext": "",
    ]

    public static func spokenLanguage(_ lang: String?) -> String {
        guard let l = lang?.lowercased(), !l.isEmpty else { return "" }
        return languageNames[l] ?? l
    }

    static func lineCount(_ code: String) -> Int {
        code.isEmpty ? 0 : code.split(separator: "\n", omittingEmptySubsequences: false).count
    }

    /// Short spoken description: "A 12-line Swift snippet."
    public static func describe(language: String?, code: String) -> String {
        let n = lineCount(code)
        let lang = spokenLanguage(language)
        let kind = (language?.lowercased()).map { ["diff", "patch"].contains($0) } == true ? "diff" : "snippet"
        let langPart = lang.isEmpty || kind == "diff" ? "" : "\(lang) "
        if n <= 1 {
            if ["shell", "terminal"].contains(lang), let cmd = code.split(separator: "\n").first {
                let words = cmd.split(separator: " ").prefix(3).joined(separator: " ")
                if words.count <= 30 { return "A command: \(words)." }
            }
            return "A one-line \(langPart)\(kind)."
        }
        return "A \(n)-line \(langPart)\(kind)."
    }

    /// Reads code aloud line by line, grouped into a few chunks.
    public static func read(language: String?, code: String, pronunciation: Pronunciation = Pronunciation(),
                            maxLines: Int = 30, linesPerChunk: Int = 3) -> [String] {
        let lines = code.split(separator: "\n", omittingEmptySubsequences: true)
            .map { speakLine(String($0), pronunciation: pronunciation) }
            .filter { !$0.isEmpty }
        var chunks: [String] = []
        var group: [String] = []
        for line in lines.prefix(maxLines) {
            group.append(line)
            if group.count == linesPerChunk {
                chunks.append(group.joined(separator: ". ") + ".")
                group = []
            }
        }
        if !group.isEmpty { chunks.append(group.joined(separator: ". ") + ".") }
        if lines.count > maxLines {
            chunks.append("And \(lines.count - maxLines) more lines.")
        }
        return chunks
    }

    static let multiCharSymbols: [(String, String)] = [
        ("===", " strictly equals "), ("!==", " not equal "), ("==", " equals "), ("!=", " not equal "),
        ("=>", " arrow "), ("->", " returns "), ("&&", " and "), ("||", " or "), ("+=", " plus equals "),
        ("-=", " minus equals "), ("<=", " less or equal "), (">=", " greater or equal "), ("::", " "),
        ("...", " "), ("..<", " up to "), ("??", " or else "),
    ]

    static let singleSymbols: [Character: String] = [
        "=": " equals ", "+": " plus ", "*": " times ", "<": " less than ", ">": " greater than ", "%": " mod ",
        "!": " not ", "?": " ", "{": " ", "}": " ", "(": " ", ")": " ", "[": " ", "]": " ", ";": " ", ",": " ",
        "\"": " ", "'": " ", "`": " ", "$": " ", "@": " ", "#": " ", "|": " ", "\\": " ", "^": " ", "&": " ",
        "~": " ",
    ]

    static func speakLine(_ raw: String, pronunciation: Pronunciation) -> String {
        var line = raw.trimmingCharacters(in: .whitespaces)
        // Comments: say them as comments.
        for marker in ["//", "#"] where line.hasPrefix(marker) {
            let body = line.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
            return body.isEmpty ? "" : "comment: " + pronunciation.speak(body)
        }
        for (sym, word) in multiCharSymbols { line = line.replacingOccurrences(of: sym, with: word) }
        var out = ""
        let chars = Array(line)
        for (i, ch) in chars.enumerated() {
            if ch == ".", i > 0, i + 1 < chars.count, chars[i - 1].isLetter || chars[i - 1] == ")", chars[i + 1].isLetter {
                out += " dot "
            } else if ch == "-", i > 0, i + 1 < chars.count, chars[i - 1] == " ", chars[i + 1] == " " {
                out += " minus "
            } else if ch == "/", i > 0, i + 1 < chars.count, chars[i - 1] == " ", chars[i + 1] == " " {
                out += " divided by "
            } else if let w = singleSymbols[ch] {
                out += w
            } else {
                out.append(ch)
            }
        }
        let collapsed = out.split(separator: " ").joined(separator: " ")
        return pronunciation.speak(collapsed)
    }
}
