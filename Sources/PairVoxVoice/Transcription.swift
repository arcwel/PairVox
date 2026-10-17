// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import Foundation
import PairVoxCore
import Speech
import WhisperKit

/// Turns one spoken utterance (16 kHz mono samples) into text.
public protocol UtteranceTranscriber: AnyObject, Sendable {
    var displayName: String { get }
    var isReady: Bool { get }
    func transcribe(_ samples: [Float], vocabulary: [String]) async throws -> String
}

public enum TranscriberState: Equatable, Sendable {
    case notLoaded
    case loading(String)
    case ready
    case failed(String)
}

// MARK: - WhisperKit (primary)

/// On-device Whisper via WhisperKit (MIT). The model downloads on first use
/// and is cached by WhisperKit.
public final class WhisperKitTranscriber: UtteranceTranscriber, @unchecked Sendable {
    public let displayName = "WhisperKit"
    private let lock = NSLock()
    private var pipe: WhisperKit?
    private var loadedModel: String?
    private var _state: TranscriberState = .notLoaded
    /// WhisperKit instances are not re-entrant: one transcription at a time.
    private let gate = AsyncGate()
    public var onStateChange: ((TranscriberState) -> Void)?

    public init() {}

    public var state: TranscriberState {
        lock.lock(); defer { lock.unlock() }
        return _state
    }

    public var isReady: Bool { state == .ready }

    private func setState(_ s: TranscriberState) {
        lock.lock(); _state = s; lock.unlock()
        DiagnosticLog.shared.log(.info, .stt, "whisper.state", ["state": .string("\(s)")])
        onStateChange?(s)
    }

    /// Downloads (first run) and loads the model. Safe to call more than once.
    public func load(model: String) async {
        let (current, same) = lock.withLock { (_state, loadedModel == model) }
        if case .loading = current { return }
        if same, current == .ready { return }
        setState(.loading("Loading speech recognition model…"))
        do {
            // Model and tokenizer come from commit-pinned, hash-checked copies, never from a moving branch.
            let folders = try await WhisperModelStore().ensure(variant: model)
            let config = WhisperKitConfig(model: model, modelFolder: folders.model.path, tokenizerFolder: folders.tokenizer,
                                          verbose: false, prewarm: true, load: true, download: false)
            let kit = try await WhisperKit(config)
            lock.withLock { pipe = kit; loadedModel = model }
            setState(.ready)
        } catch {
            setState(.failed(error.localizedDescription))
        }
    }

    public func transcribe(_ samples: [Float], vocabulary: [String]) async throws -> String {
        let kit = lock.withLock { pipe }
        guard let kit else { throw TranscriptionError.notReady }

        var options = DecodingOptions(language: "en", temperature: 0, usePrefillPrompt: true, skipSpecialTokens: true,
                                      withoutTimestamps: true)
        if !vocabulary.isEmpty, let tokenizer = kit.tokenizer {
            // Bias decoding toward project words ("SessionManager", "Postgres", ...).
            let prompt = " " + vocabulary.prefix(40).joined(separator: ", ")
            let limit = tokenizer.specialTokens.specialTokenBegin
            let tokens = tokenizer.encode(text: prompt).filter { $0 < limit }
            if !tokens.isEmpty { options.promptTokens = Array(tokens.suffix(120)) }
        }
        await gate.enter()
        do {
            let results = try await kit.transcribe(audioArray: samples, decodeOptions: options)
            await gate.leave()
            return TranscriptCleaner.clean(results.map(\.text).joined(separator: " "))
        } catch {
            await gate.leave()
            throw error
        }
    }
}

// MARK: - Apple Speech (fallback)

/// Apple's on-device speech recognizer. Used while WhisperKit downloads, or if it fails.
public final class AppleSpeechTranscriber: UtteranceTranscriber, @unchecked Sendable {
    public let displayName = "Apple Speech"
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))

    public init() {}

    public var isReady: Bool {
        SFSpeechRecognizer.authorizationStatus() == .authorized && (recognizer?.isAvailable ?? false)
    }

    public static func requestAuthorization() async -> Bool {
        await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in cont.resume(returning: status == .authorized) }
        }
    }

    public func transcribe(_ samples: [Float], vocabulary: [String]) async throws -> String {
        guard let recognizer, recognizer.isAvailable else { throw TranscriptionError.notReady }
        guard let buffer = AudioIO.recognitionBuffer(samples: samples) else { throw TranscriptionError.badAudio }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = false
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        request.addsPunctuation = true
        request.taskHint = .dictation
        request.contextualStrings = Array(vocabulary.prefix(100))
        request.append(buffer)
        request.endAudio()

        return try await withCheckedThrowingContinuation { cont in
            let once = ResumeOnce()
            let task = recognizer.recognitionTask(with: request) { result, error in
                if let result, result.isFinal {
                    if once.claim() { cont.resume(returning: TranscriptCleaner.clean(result.bestTranscription.formattedString)) }
                } else if let error {
                    let ns = error as NSError
                    // 1110 = "No speech detected": not an error for us.
                    if ns.code == 1110 || ns.code == 203 {
                        if once.claim() { cont.resume(returning: "") }
                    } else if once.claim() {
                        cont.resume(throwing: error)
                    }
                }
            }
            // Never hang the conversation on the recognizer.
            DispatchQueue.global().asyncAfter(deadline: .now() + 8) {
                if once.claim() {
                    task.cancel()
                    cont.resume(throwing: TranscriptionError.timedOut)
                }
            }
        }
    }
}

// MARK: - Fallback

/// WhisperKit when it's ready, Apple Speech otherwise (and if WhisperKit throws).
public final class FallbackTranscriber: UtteranceTranscriber, @unchecked Sendable {
    public let primary: WhisperKitTranscriber
    public let fallback: AppleSpeechTranscriber
    private let lock = NSLock()
    private var _choice: TranscriberChoice
    public var choice: TranscriberChoice {
        get { lock.lock(); defer { lock.unlock() }; return _choice }
        set { lock.lock(); _choice = newValue; lock.unlock() }
    }

    public init(primary: WhisperKitTranscriber, fallback: AppleSpeechTranscriber, choice: TranscriberChoice) {
        self.primary = primary
        self.fallback = fallback
        self._choice = choice
    }

    public var displayName: String {
        switch choice {
        case .apple: return fallback.displayName
        case .whisperKit: return primary.displayName
        case .automatic: return primary.isReady ? primary.displayName : "\(fallback.displayName) (WhisperKit loading)"
        }
    }

    public var isReady: Bool { primary.isReady || fallback.isReady }

    public func transcribe(_ samples: [Float], vocabulary: [String]) async throws -> String {
        let usePrimary: Bool
        switch choice {
        case .apple: usePrimary = false
        case .whisperKit: usePrimary = primary.isReady || !fallback.isReady
        case .automatic: usePrimary = primary.isReady
        }
        if usePrimary {
            do {
                return try await primary.transcribe(samples, vocabulary: vocabulary)
            } catch {
                guard fallback.isReady else { throw error }
                NSLog("PairVox: WhisperKit failed (\(error)); using Apple Speech")
                DiagnosticLog.shared.log(.warning, .stt, "fallback.apple", ["error": .string("\(error)")])
            }
        }
        return try await fallback.transcribe(samples, vocabulary: vocabulary)
    }
}

public enum TranscriptionError: Error, LocalizedError {
    case notReady, badAudio, timedOut
    public var errorDescription: String? {
        switch self {
        case .notReady: return "Speech recognition isn't ready yet."
        case .badAudio: return "Couldn't read the recorded audio."
        case .timedOut: return "Speech recognition timed out."
        }
    }
}

/// Removes Whisper artefacts like "[BLANK_AUDIO]" and "(music)".
public enum TranscriptCleaner {
    public static func clean(_ text: String) -> String {
        var t = text
        for pattern in [#"\[[^\]]*\]"#, #"\((?:music|applause|laughs?|silence|inaudible|noise)[^)]*\)"#, #"<\|[^|]*\|>"#] {
            t = t.replacingOccurrences(of: pattern, with: " ", options: [.regularExpression, .caseInsensitive])
        }
        t = t.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        // Whisper hallucinates these on near-silence.
        let junk: Set<String> = ["you", "thank you.", "thanks for watching!", "thank you for watching.", "bye.", "."]
        if junk.contains(t.lowercased()) { return "" }
        return t
    }
}

final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

/// A FIFO async mutex.
actor AsyncGate {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func enter() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func leave() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}
