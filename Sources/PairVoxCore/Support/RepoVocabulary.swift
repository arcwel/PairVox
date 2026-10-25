// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Collects identifiers from a repository (file names, type and function names)
/// to bias speech recognition toward words the user is likely to say.
public enum RepoVocabulary {
    static let skipDirectories: Set<String> = [
        ".git", "node_modules", ".build", "build", "dist", "DerivedData", "Pods", "vendor", ".venv", "venv",
        "__pycache__", ".next", ".swiftpm", "target", "out", ".gradle", ".idea", "coverage", "Carthage", ".cache",
    ]
    static let sourceExtensions: Set<String> = [
        "swift", "ts", "tsx", "js", "jsx", "py", "rb", "go", "rs", "java", "kt", "c", "h", "m", "mm", "cpp", "hpp",
        "cs", "php", "dart", "scala", "ex", "exs", "vue", "svelte",
    ]
    static let declarationPattern = try! NSRegularExpression(
        pattern: #"\b(?:class|struct|enum|protocol|actor|extension|interface|type|func|function|def|fn|trait|impl|module)\s+([A-Za-z_][A-Za-z0-9_]{2,})"#)

    /// Scans `root` and returns up to `limit` terms, most frequent first.
    public static func scan(root: URL, limit: Int = 150, maxFiles: Int = 1500, maxBytesPerFile: Int = 200_000,
                            maxEntries: Int = 50_000) -> [String] {
        var counts: [String: Int] = [:]
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey],
                                             options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var files = 0
        var entries = 0
        for case let url as URL in enumerator {
            entries += 1
            if entries > maxEntries { break }
            let name = url.lastPathComponent
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
            // A repository can contain links to devices or huge files elsewhere; only real files and folders count.
            if values?.isSymbolicLink == true { if values?.isDirectory == true { enumerator.skipDescendants() }; continue }
            if values?.isDirectory == true {
                if skipDirectories.contains(name) { enumerator.skipDescendants() }
                else if admissible(name) { counts[name, default: 0] += 1 }
                continue
            }
            let ext = url.pathExtension.lowercased()
            guard sourceExtensions.contains(ext) else { continue }
            files += 1
            if files > maxFiles { break }
            let base = url.deletingPathExtension().lastPathComponent
            if admissible(base) { counts[base, default: 0] += 3 }
            guard values?.isRegularFile == true, (values?.fileSize ?? Int.max) <= maxBytesPerFile,
                  let text = readText(url, limit: maxBytesPerFile) else { continue }
            let ns = text as NSString
            for m in declarationPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let ident = ns.substring(with: m.range(at: 1))
                if !commonWords.contains(ident.lowercased()), admissible(ident) { counts[ident, default: 0] += 1 }
            }
        }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(limit).map(\.key)
    }

    static let termPattern = try! NSRegularExpression(pattern: #"^_{0,2}[A-Za-z][A-Za-z0-9_\-]{2,60}$"#)
    /// Words that only fill out an answer ("allow all", "yes please", "go ahead").
    static let answerFillers: Set<String> = ["all", "it", "please", "go", "ahead", "do", "them", "everything", "high", "risk", "once", "now"]

    /// The repository is untrusted, and its names become the recognizer's context: only identifier-shaped names, and
    /// none made of the words that answer a request, so a file named "allow it" or "confirm high risk" cannot bias
    /// the transcript toward an approval (audit run 7).
    static func admissible(_ term: String) -> Bool {
        let range = NSRange(term.startIndex..., in: term)
        guard termPattern.firstMatch(in: term, range: range) != nil else { return false }
        // A name is dropped only when it is nothing but an answer ("AllowAll", "yes_please", "ConfirmHighRisk"):
        // "NotFound", "WaitGroup" and "CancelToken" are ordinary code words and stay.
        let words = answerWords(in: term).filter { !$0.isEmpty }
        let answering = VoiceCommand.answerVocabulary.union(answerFillers)
        if words.contains(where: VoiceCommand.answerVocabulary.contains), words.allSatisfy(answering.contains) { return false }
        let joined = " " + words.joined(separator: " ") + " "
        return !VoiceCommand.approvePhrases.contains { joined.contains(" \($0) ") }
    }

    /// The words inside an identifier: split at `_`, `-` and lower-to-upper case changes ("AllowIt" → allow, it).
    static func answerWords(in term: String) -> [String] {
        var words: [String] = [], current = ""
        for ch in term {
            if ch == "_" || ch == "-" { if !current.isEmpty { words.append(current) }; current = ""; continue }
            if ch.isUppercase, let last = current.last, last.isLowercase { words.append(current); current = "" }
            current.append(ch)
        }
        if !current.isEmpty { words.append(current) }
        return words.map { $0.lowercased() }
    }

    /// Reads at most `limit` bytes, so the size check on the directory entry is not the only bound.
    static func readText(_ url: URL, limit: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: limit) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static let commonWords: Set<String> = [
        "init", "main", "test", "tests", "self", "the", "get", "set", "new", "run", "app", "index", "utils", "helper",
        "helpers", "string", "data", "value", "error", "result", "body", "view", "model", "item", "items",
    ]
}
