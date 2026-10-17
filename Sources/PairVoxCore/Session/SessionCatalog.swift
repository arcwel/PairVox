// SPDX-License-Identifier: Apache-2.0

import Foundation

/// An earlier Claude Code conversation in a project, found in Claude Code's own session folder.
public struct PastSession: Sendable, Equatable, Identifiable {
    public let id: String
    public let modified: Date
    /// The first thing the person said in it, shortened.
    public let preview: String
}

/// Lists a project's earlier sessions so one can be resumed by its ID. Read-only: it never touches the files.
public enum SessionCatalog {
    /// Claude Code names a project's folder after its path, with `/` and `.` turned into `-`.
    static func folderName(for project: String) -> String {
        project.map { $0 == "/" || $0 == "." ? "-" : String($0) }.joined()
    }

    /// Only a UUID may be passed to `--resume`, so an odd file name can never become a command-line argument.
    public static func isValidSessionID(_ id: String) -> Bool { UUID(uuidString: id) != nil }

    public static func recent(for project: String, claudeHome: URL? = nil, limit: Int = 8) -> [PastSession] {
        let home = claudeHome ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude")
        let dir = home.appendingPathComponent("projects").appendingPathComponent(folderName(for: FolderScope.resolved(project)))
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey], options: [.skipsHiddenFiles]) else { return [] }
        var found: [PastSession] = []
        for file in files where file.pathExtension == "jsonl" {
            let id = file.deletingPathExtension().lastPathComponent
            guard isValidSessionID(id),
                  let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true, let modified = values.contentModificationDate,
                  let preview = firstUserText(in: file) else { continue }
            found.append(PastSession(id: id, modified: modified, preview: preview))
        }
        return Array(found.sorted { $0.modified > $1.modified }.prefix(limit))
    }

    /// The first user message, read from at most the first 64 KB.
    static func firstUserText(in file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 64 * 1024), !data.isEmpty else { return nil }
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  object["type"] as? String == "user", let message = object["message"] as? [String: Any] else { continue }
            var text: String?
            if let s = message["content"] as? String { text = s }
            else if let parts = message["content"] as? [[String: Any]] {
                text = parts.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.first
            }
            guard let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty, !t.hasPrefix("<") else { continue }
            let oneLine = t.replacingOccurrences(of: "\n", with: " ")
            return oneLine.count > 80 ? String(oneLine.prefix(80)) + "…" : oneLine
        }
        return nil
    }
}
