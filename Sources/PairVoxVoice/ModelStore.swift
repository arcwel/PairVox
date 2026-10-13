// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation

/// Downloads and verifies the Kokoro model files into Application Support.
///
/// Sources are the files published alongside the KokoroTestApp reference app
/// (MIT; the weights are hexgrad/Kokoro-82M, Apache-2.0). Every file is checked
/// against a pinned SHA-256 before it is loaded.
public final class ModelStore: NSObject, @unchecked Sendable {
    public struct RemoteFile: Sendable {
        public let name: String
        public let url: URL
        public let sha256: String
        public let bytes: Int64
    }

    public static let kokoroWeights = RemoteFile(
        name: "kokoro-v1_0.safetensors",
        url: URL(string: "https://media.githubusercontent.com/media/mlalma/KokoroTestApp/main/Resources/kokoro-v1_0.safetensors")!,
        sha256: "4e9ecdf03b8b6cf906070390237feda473dc13327cb8d56a43deaa374c02acd8",
        bytes: 327_115_152)

    public static let kokoroVoices = RemoteFile(
        name: "voices.npz",
        url: URL(string: "https://raw.githubusercontent.com/mlalma/KokoroTestApp/main/Resources/voices.npz")!,
        sha256: "56dbfa2f2970af2e395397020393d368c5f441d09b3de4e9b77f6222e790f10f",
        bytes: 14_629_684)

    public enum Status: Equatable, Sendable {
        case missing
        case downloading(fraction: Double)
        case verifying
        case ready
        case failed(String)
    }

    public let directory: URL
    public var onStatus: ((Status) -> Void)?

    public init(directory: URL = ModelStore.defaultDirectory()) {
        self.directory = directory
    }

    public static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("PairVox/Models/Kokoro", isDirectory: true)
    }

    public var weightsURL: URL { directory.appendingPathComponent(Self.kokoroWeights.name) }
    public var voicesURL: URL { directory.appendingPathComponent(Self.kokoroVoices.name) }

    /// Fast check (size only); full hash is verified after download and on first load.
    public var isPresent: Bool {
        size(of: weightsURL) == Self.kokoroWeights.bytes && size(of: voicesURL) == Self.kokoroVoices.bytes
    }

    /// Downloads whatever is missing, verifying hashes. Idempotent.
    public func ensureKokoro() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let files = [Self.kokoroVoices, Self.kokoroWeights]
        let totalBytes = Double(files.reduce(0) { $0 + $1.bytes })
        var doneBytes: Double = 0
        for file in files {
            let dest = directory.appendingPathComponent(file.name)
            if size(of: dest) == file.bytes, (try? verify(dest, sha256: file.sha256)) == true {
                doneBytes += Double(file.bytes)
                continue
            }
            try? FileManager.default.removeItem(at: dest)
            let base = doneBytes
            let tmp = try await download(file.url) { [weak self] fraction in
                self?.onStatus?(.downloading(fraction: (base + fraction * Double(file.bytes)) / totalBytes))
            }
            onStatus?(.verifying)
            guard try verify(tmp, sha256: file.sha256) else {
                try? FileManager.default.removeItem(at: tmp)
                let msg = "\(file.name) failed its checksum. Try again later."
                onStatus?(.failed(msg))
                throw ModelStoreError.checksumMismatch(file.name)
            }
            try FileManager.default.moveItem(at: tmp, to: dest)
            doneBytes += Double(file.bytes)
        }
        onStatus?(.ready)
    }

    /// Hash check for files already on disk (call before loading).
    public func verifyKokoro() -> Bool {
        (try? verify(weightsURL, sha256: Self.kokoroWeights.sha256)) == true
            && (try? verify(voicesURL, sha256: Self.kokoroVoices.sha256)) == true
    }

    // MARK: Internals

    private func size(of url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? -1
    }

    private func verify(_ url: URL, sha256 expected: String) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return hex == expected
    }

    private func download(_ url: URL, progress: @escaping (Double) -> Void) async throws -> URL {
        let kept = directory.appendingPathComponent(UUID().uuidString + ".part")
        return try await withCheckedThrowingContinuation { cont in
            let delegate = DownloadDelegate(destination: kept, progress: progress) { result in
                cont.resume(with: result)
            }
            let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
            session.downloadTask(with: url).resume()
            session.finishTasksAndInvalidate()
        }
    }
}

public enum ModelStoreError: Error, LocalizedError {
    case checksumMismatch(String)
    case httpError(Int)
    public var errorDescription: String? {
        switch self {
        case .checksumMismatch(let n): return "\(n) failed its checksum."
        case .httpError(let c): return "Download failed (HTTP \(c))."
        }
    }
}

private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let destination: URL
    let progress: (Double) -> Void
    let completion: (Result<URL, Error>) -> Void
    private var moved = false
    private var finished = false
    private let lock = NSLock()

    init(destination: URL, progress: @escaping (Double) -> Void, completion: @escaping (Result<URL, Error>) -> Void) {
        self.destination = destination
        self.progress = progress
        self.completion = completion
    }

    private func finish(_ result: Result<URL, Error>) {
        lock.lock()
        let first = !finished
        finished = true
        lock.unlock()
        if first { completion(result) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            finish(.failure(ModelStoreError.httpError(http.statusCode)))
            return
        }
        // The temporary file disappears when this method returns: move it now.
        do {
            try FileManager.default.moveItem(at: location, to: destination)
            lock.lock(); moved = true; lock.unlock()
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            finish(.failure(error))
            return
        }
        lock.lock(); let ok = moved; lock.unlock()
        finish(ok ? .success(destination) : .failure(ModelStoreError.httpError(-1)))
    }
}
