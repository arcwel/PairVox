// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The iPhone app's own log: one JSON object per line, in the app's Library/Logs/PairVox folder, so a problem on the
/// phone can be read afterwards (Share Logs in the app, or `scripts/pull-phone-logs.sh` over the cable). Nothing is
/// sent anywhere. Like the Mac log it records events and lengths, never what was said, a request's text, a key or a
/// pairing secret: callers pass only short fields, and values are scrubbed and cut to `maxValue` characters.
public final class PhoneLog: @unchecked Sendable {
    public static let fileName = "phone.log"
    /// The current file is moved to phone.1.log at this size; phone.2.log is the oldest kept.
    public static let maxFileBytes = 1_000_000
    public static let keptFiles = 3
    public static let maxValue = 200

    public let directory: URL
    private let lock = NSLock()
    private let run = String(UUID().uuidString.prefix(8)).lowercased()
    private let clock: @Sendable () -> Date

    public init(directory: URL, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory
        self.clock = clock
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// The app's default folder: Library/Logs/PairVox inside its container.
    public static func defaultDirectory() -> URL {
        let lib = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return lib.appendingPathComponent("Logs/PairVox", isDirectory: true)
    }

    public var currentFile: URL { directory.appendingPathComponent(Self.fileName) }

    /// The files that exist, newest first: what Share Logs hands over.
    public var files: [URL] {
        let names = [Self.fileName] + (1..<Self.keptFiles).map { "phone.\($0).log" }
        let fm = FileManager.default
        var out = names.map { directory.appendingPathComponent($0) }.filter { fm.fileExists(atPath: $0.path) }
        let crashes = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))?
            .filter { $0.lastPathComponent.hasPrefix("crash-") }.sorted { $0.lastPathComponent > $1.lastPathComponent } ?? []
        out += crashes
        return out
    }

    private static let stamp: ISO8601DateFormatter = ISO8601DateFormatter()

    public func log(_ event: String, _ fields: [String: String] = [:]) {
        var line: [String: String] = ["t": Self.stamp.string(from: clock()), "run": run, "ev": Self.clean(event)]
        for (k, v) in fields { line[Self.clean(k)] = Self.clean(v) }
        guard let data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]) else { return }
        lock.lock(); defer { lock.unlock() }
        rotateIfNeeded()
        let url = currentFile
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data + Data("\n".utf8))
    }

    /// Keeps an iOS crash or hang report (MetricKit's JSON) beside the log. Crash and hang reports are kept apart,
    /// the five newest of each, so a run of hangs cannot push the one crash out; one already kept is not written
    /// again. Returns false when it was already there.
    @discardableResult
    public func saveCrashReport(_ json: @autoclosure () -> Data, receivedAt date: Date, kind: String = "crash") -> Bool {
        lock.lock(); defer { lock.unlock() }
        let kind = kind == "hang" ? "hang" : "crash"
        let stamp = Self.stamp.string(from: date).replacingOccurrences(of: ":", with: "-")
        let fm = FileManager.default
        let url = directory.appendingPathComponent("crash-\(kind)-\(stamp).json")
        guard !fm.fileExists(atPath: url.path) else { return false }
        try? json().write(to: url)   // serialized only for a report not kept yet
        let same = ((try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("crash-\(kind)-") }.sorted { $0.lastPathComponent > $1.lastPathComponent }
        for old in same.dropFirst(5) { try? fm.removeItem(at: old) }
        return true
    }

    private func rotateIfNeeded() {
        let fm = FileManager.default
        let size = (try? fm.attributesOfItem(atPath: currentFile.path)[.size] as? Int) ?? 0
        guard size >= Self.maxFileBytes else { return }
        for i in stride(from: Self.keptFiles - 1, through: 1, by: -1) {
            let older = directory.appendingPathComponent("phone.\(i).log")
            let newer = i == 1 ? currentFile : directory.appendingPathComponent("phone.\(i - 1).log")
            try? fm.removeItem(at: older)
            try? fm.moveItem(at: newer, to: older)
        }
    }

    /// The Mac log's patterns (LogRedactor; LinkKit cannot depend on PairVoxCore, so they are repeated here and kept in
    /// step), plus a pairing secret in a link and any long run of key characters. Compiled once.
    private static let patterns: [(NSRegularExpression, String)] = [
        (#"sk-ant-[A-Za-z0-9_\-]{8,}"#, "<api-key>"),
        (#"\bsk-[A-Za-z0-9]{20,}"#, "<api-key>"),
        (#"\bgh[pousr]_[A-Za-z0-9]{20,}"#, "<github-token>"),
        (#"\bAKIA[0-9A-Z]{16}\b"#, "<aws-key>"),
        (#"(?i)\bBearer\s+[A-Za-z0-9._~+/=\-]{12,}"#, "Bearer <token>"),
        (#"(?i)(api[_-]?key|auth[_-]?token|access[_-]?token|secret|password)(\s*[=:]\s*)\S+"#, "$1$2<redacted>"),
        (#"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#, "<email>"),
        (#"([?&]s=)[^&\s]+"#, "$1<secret>"),
        (#"[A-Za-z0-9+/=_-]{32,}"#, "<redacted>"),
    ].compactMap { spec in (try? NSRegularExpression(pattern: spec.0)).map { ($0, spec.1) } }

    /// One line, at most `maxValue` characters, with anything that looks like a key or secret replaced. A very long
    /// value is cut before it is scrubbed, so a huge error message costs no more than a short one.
    static func clean(_ value: String) -> String {
        var s = String(value.prefix(maxValue * 4)).replacingOccurrences(of: "\n", with: " ")
        for (regex, template) in patterns {
            s = regex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
        }
        return s.count > maxValue ? String(s.prefix(maxValue)) + "…" : s
    }
}
