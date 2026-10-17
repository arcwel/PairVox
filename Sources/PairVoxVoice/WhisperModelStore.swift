// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation

/// Downloads the Whisper speech model and its tokenizer at the exact Hugging Face commits listed in
/// `WhisperPins`, and checks every file against its pinned SHA-256 before WhisperKit sees it. Nothing is
/// fetched from a moving branch, and a file that does not match is deleted and refused.
public final class WhisperModelStore: @unchecked Sendable {
    public struct Folders: Sendable {
        public let model: URL
        public let tokenizer: URL
    }

    public let directory: URL

    public init(directory: URL = WhisperModelStore.defaultDirectory()) {
        self.directory = directory
    }

    public static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("PairVox/Models/Whisper", isDirectory: true)
    }

    public static func isPinned(_ variant: String) -> Bool { WhisperPins.variants[variant] != nil }

    /// Downloads whatever is missing or damaged, then returns the verified model and tokenizer folders.
    public func ensure(variant: String, progress: ((Double) -> Void)? = nil) async throws -> Folders {
        guard let pins = WhisperPins.variants[variant] else { throw WhisperModelError.notPinned(variant) }
        let root = directory.appendingPathComponent(variant, isDirectory: true)
        let modelRoot = root.appendingPathComponent("model", isDirectory: true)
        let tokenizerRoot = root.appendingPathComponent("tokenizer", isDirectory: true)
        let jobs = pins.model.files.map { (pins.model, $0, modelRoot) } + pins.tokenizer.files.map { (pins.tokenizer, $0, tokenizerRoot) }
        let total = Double(jobs.reduce(0) { $0 + $1.1.bytes })
        var done = 0.0
        for (pin, file, base) in jobs {
            guard let dest = Self.destination(for: file.path, under: base) else {
                throw WhisperModelError.checksumMismatch(file.path)
            }
            if size(of: dest) == file.bytes, (try? Self.sha256(of: dest)) == file.sha256 {
                done += Double(file.bytes)
                continue
            }
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            let before = done
            let tmp = try await download(Self.url(pin, file), into: dest.deletingLastPathComponent()) { fraction in
                progress?((before + fraction * Double(file.bytes)) / max(total, 1))
            }
            guard size(of: tmp) == file.bytes, (try? Self.sha256(of: tmp)) == file.sha256 else {
                try? FileManager.default.removeItem(at: tmp)
                throw WhisperModelError.checksumMismatch(file.path)
            }
            try FileManager.default.moveItem(at: tmp, to: dest)
            done += Double(file.bytes)
        }
        return Folders(model: modelRoot,
                       tokenizer: tokenizerRoot)
    }

    /// Where a pinned file goes, or nil when its path is absolute, empty, or climbs out of the model folder.
    static func destination(for path: String, under base: URL) -> URL? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.hasPrefix("/"), !parts.isEmpty,
              !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return nil }
        let dest = base.appendingPathComponent(path).standardizedFileURL
        guard dest.path.hasPrefix(base.standardizedFileURL.path + "/") else { return nil }
        return dest
    }

    static func url(_ pin: WhisperPins.Pin, _ file: WhisperPins.File) -> URL {
        let folder = pin.folder.isEmpty ? "" : pin.folder + "/"
        let path = (folder + file.path).split(separator: "/")
            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }.joined(separator: "/")
        return URL(string: "https://huggingface.co/\(pin.repo)/resolve/\(pin.commit)/\(path)")!
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func size(of url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? -1
    }

    private func download(_ url: URL, into folder: URL, progress: @escaping (Double) -> Void) async throws -> URL {
        let kept = folder.appendingPathComponent(UUID().uuidString + ".part")
        return try await withCheckedThrowingContinuation { cont in
            let delegate = DownloadDelegate(destination: kept, progress: progress) { cont.resume(with: $0) }
            let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
            session.downloadTask(with: url).resume()
            session.finishTasksAndInvalidate()
        }
    }
}

public enum WhisperModelError: Error, LocalizedError {
    case notPinned(String)
    case checksumMismatch(String)
    public var errorDescription: String? {
        switch self {
        case .notPinned(let v): return "The speech model “\(v)” is not one PairVox has a verified copy of."
        case .checksumMismatch(let f): return "A speech model file (\(f)) failed its checksum and was discarded."
        }
    }
}
