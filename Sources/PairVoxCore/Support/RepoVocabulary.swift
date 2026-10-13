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
    public static func scan(root: URL, limit: Int = 150, maxFiles: Int = 1500, maxBytesPerFile: Int = 200_000) -> [String] {
        var counts: [String: Int] = [:]
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                                             options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var files = 0
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            if values?.isDirectory == true {
                if skipDirectories.contains(name) { enumerator.skipDescendants() }
                else if name.count >= 3 { counts[name, default: 0] += 1 }
                continue
            }
            let ext = url.pathExtension.lowercased()
            guard sourceExtensions.contains(ext) else { continue }
            files += 1
            if files > maxFiles { break }
            let base = url.deletingPathExtension().lastPathComponent
            if base.count >= 3 { counts[base, default: 0] += 3 }
            guard (values?.fileSize ?? 0) <= maxBytesPerFile,
                  let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let ns = text as NSString
            for m in declarationPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let ident = ns.substring(with: m.range(at: 1))
                if !commonWords.contains(ident.lowercased()) { counts[ident, default: 0] += 1 }
            }
        }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(limit).map(\.key)
    }

    static let commonWords: Set<String> = [
        "init", "main", "test", "tests", "self", "the", "get", "set", "new", "run", "app", "index", "utils", "helper",
        "helpers", "string", "data", "value", "error", "result", "body", "view", "model", "item", "items",
    ]
}
