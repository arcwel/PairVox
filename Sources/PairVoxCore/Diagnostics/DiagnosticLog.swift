// SPDX-License-Identifier: Apache-2.0

import Foundation

public enum LogLevel: Int, Comparable, Sendable {
    case debug, info, warning, error
    public static func < (a: LogLevel, b: LogLevel) -> Bool { a.rawValue < b.rawValue }
    var label: String { ["debug", "info", "warn", "error"][rawValue] }
}

public enum LogCategory: String, Sendable {
    case app, engine, session, audio, input, stt, tts, ui, hotkey, permission, policy
}

/// A value in a log line. Strings are redacted before they are written.
public enum LogValue: Sendable, Equatable, ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral, ExpressibleByStringInterpolation {
    case string(String), int(Int), double(Double), bool(Bool)

    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .int(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

/// Structured, shareable diagnostics: one JSON object per line in a rotating file.
///
/// Privacy: nothing is sent anywhere. Conversation text (what you say, what Claude says,
/// tool input) is logged as a length only, unless `includeContent` is on; every string is
/// scrubbed by `LogRedactor`. Logging never throws or blocks the caller: lines are queued
/// and written on a utility queue.
public final class DiagnosticLog: @unchecked Sendable {
    public static let shared = DiagnosticLog()

    public struct Configuration: Sendable {
        public var directory: URL?
        public var minLevel: LogLevel = .info
        public var includeContent = false
        public var maxFileBytes = 5_000_000
        public var maxFiles = 6
        public init(directory: URL? = nil, minLevel: LogLevel = .info, includeContent: Bool = false,
                    maxFileBytes: Int = 5_000_000, maxFiles: Int = 6) {
            self.directory = directory
            self.minLevel = minLevel
            self.includeContent = includeContent
            self.maxFileBytes = maxFileBytes
            self.maxFiles = maxFiles
        }
    }

    public static let fileName = "pairvox.log"
    /// Run identifier, so lines from one launch can be told apart after a restart.
    public let runID = String(UUID().uuidString.prefix(8)).lowercased()

    private let queue = DispatchQueue(label: "app.pairvox.diagnostics", qos: .utility)
    private let started = DispatchTime.now()
    private var config = Configuration()
    private var redactor = LogRedactor()
    private var handle: FileHandle?
    private var written = 0
    private let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    /// Receives every written line (tests, and a live view if one is added).
    private var sink: (@Sendable (String) -> Void)?

    public init() {}

    public func configure(_ new: Configuration, redactor: LogRedactor = LogRedactor()) {
        queue.sync {
            let dirChanged = config.directory != new.directory
            config = new
            self.redactor = redactor
            if dirChanged { closeFile() }
        }
    }

    public func setSink(_ sink: (@Sendable (String) -> Void)?) {
        queue.sync { self.sink = sink }
    }

    public var includeContent: Bool { queue.sync { config.includeContent } }
    public var directory: URL? { queue.sync { config.directory } }

    public func isEnabled(_ level: LogLevel) -> Bool { queue.sync { level >= config.minLevel } }

    /// Logs one event. `event` is a short dotted name such as `audio.engine.start`.
    public func log(_ level: LogLevel = .info, _ category: LogCategory, _ event: String,
                    _ fields: [String: LogValue] = [:]) {
        let wall = Date()
        let uptimeMs = Int((DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000)
        queue.async { [self] in
            guard level >= config.minLevel else { return }
            var object: [String: Any] = [
                "t": formatter.string(from: wall), "ms": uptimeMs, "run": runID,
                "lvl": level.label, "cat": category.rawValue, "ev": event,
            ]
            if !fields.isEmpty {
                var out: [String: Any] = [:]
                for (key, value) in fields {
                    switch value {
                    case .string(let s): out[key] = redactor.scrub(s)
                    case .int(let i): out[key] = i
                    case .double(let d): out[key] = d.isFinite ? (d * 1000).rounded() / 1000 : 0
                    case .bool(let b): out[key] = b
                    }
                }
                object["f"] = out
            }
            guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
                  let line = String(data: data, encoding: .utf8) else { return }
            sink?(line)
            append(line + "\n")
        }
    }

    /// Conversation text as a loggable value: its length only, unless content logging is on.
    public func content(_ text: String, limit: Int = 400) -> LogValue {
        if includeContent {
            return .string(text.count > limit ? String(text.prefix(limit)) + "…" : text)
        }
        return .string("<\(text.count) chars>")
    }

    /// Conversation text for a line that must identify one sentence without quoting it (`synth.corrupt`): the text
    /// itself when content logging is on, otherwise its length (`chars`) and the first 16 hex characters of its
    /// SHA-256 (`sha256`), enough to match the sentence when it is tried again with `--tts-probe`.
    public func contentFingerprint(_ text: String) -> [String: LogValue] {
        if includeContent { return ["text": content(text, limit: 2_000)] }
        return ["chars": .int(text.count), "sha256": .string(String(TextDigest.sha256Hex(text).prefix(16)))]
    }

    /// Blocks until queued lines are on disk (call before reading the files or exiting).
    public func flush() { queue.sync { try? handle?.synchronize() } }

    /// Every log file, newest first.
    public func files() -> [URL] {
        queue.sync {
            guard let dir = config.directory else { return [] }
            return (0..<config.maxFiles).map { fileURL(dir, index: $0) }
                .filter { FileManager.default.fileExists(atPath: $0.path) }
        }
    }

    // MARK: Files (call on `queue` only)

    private func fileURL(_ dir: URL, index: Int) -> URL {
        dir.appendingPathComponent(index == 0 ? Self.fileName : "pairvox.\(index).log")
    }

    private func closeFile() {
        try? handle?.close()
        handle = nil
        written = 0
    }

    private func openIfNeeded(_ dir: URL) -> FileHandle? {
        if let handle { return handle }
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = fileURL(dir, index: 0)
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
        guard let h = try? FileHandle(forWritingTo: url) else { return nil }
        written = Int((try? h.seekToEnd()) ?? 0)
        handle = h
        return h
    }

    private func append(_ text: String) {
        guard let dir = config.directory, let data = text.data(using: .utf8) else { return }
        if written + data.count > config.maxFileBytes, written > 0 { rotate(dir) }
        guard let h = openIfNeeded(dir) else { return }
        try? h.write(contentsOf: data)
        written += data.count
    }

    private func rotate(_ dir: URL) {
        closeFile()
        let fm = FileManager.default
        try? fm.removeItem(at: fileURL(dir, index: config.maxFiles - 1))
        for index in stride(from: config.maxFiles - 2, through: 0, by: -1) {
            let from = fileURL(dir, index: index)
            if fm.fileExists(atPath: from.path) { try? fm.moveItem(at: from, to: fileURL(dir, index: index + 1)) }
        }
    }
}
