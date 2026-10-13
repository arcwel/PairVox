// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import Foundation
import KokoroSwift
import MLX
import MLXUtilsLibrary
import PairVoxCore

/// Turns text into a playback buffer (`AudioIO.playbackFormat`).
public protocol SpeechSynthesizing: AnyObject, Sendable {
    var displayName: String { get }
    var isReady: Bool { get }
    func synthesize(_ text: String, rate: Double) async throws -> AVAudioPCMBuffer
}

public enum SynthesisError: Error, LocalizedError {
    case notReady, failed(String)
    public var errorDescription: String? {
        switch self {
        case .notReady: return "The voice isn't ready yet."
        case .failed(let m): return m
        }
    }
}

// MARK: - Kokoro (primary)

/// Kokoro-82M (Apache-2.0 weights) through kokoro-ios / MLX Swift (MIT), with
/// MisakiSwift (Apache-2.0) for phonemes. Runs on the GPU via Metal.
public final class KokoroSynthesizer: SpeechSynthesizing, @unchecked Sendable {
    public let displayName = "Kokoro"
    public var voice: String {
        get { lock.lock(); defer { lock.unlock() }; return _voice }
        set { lock.lock(); _voice = newValue; lock.unlock() }
    }
    private var _voice: String

    private let queue = DispatchQueue(label: "app.pairvox.kokoro", qos: .userInitiated)
    private let lock = NSLock()
    private var tts: KokoroTTS?
    private var voices: [String: MLXArray] = [:]
    private var loadError: String?

    public init(voice: String) {
        self._voice = voice
    }

    public var isReady: Bool {
        lock.lock(); defer { lock.unlock() }
        return tts != nil
    }

    public var lastError: String? {
        lock.lock(); defer { lock.unlock() }
        return loadError
    }

    public var availableVoices: [String] {
        lock.lock(); defer { lock.unlock() }
        return voices.keys.map { $0.replacingOccurrences(of: ".npy", with: "") }.sorted()
    }

    /// Loads weights and voices. Call only after `ModelStore` verified the files,
    /// because the underlying loader traps on a corrupt file.
    public func load(model: URL, voices voicesURL: URL) async throws {
        if isReady { return }
        guard MLXRuntime.metalLibraryAvailable() else {
            let msg = "Kokoro needs MLX's Metal shaders. Build the app with Xcode or scripts/build-app.sh."
            lock.lock(); loadError = msg; lock.unlock()
            throw SynthesisError.failed(msg)
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async {
                let engine = KokoroTTS(modelPath: model)
                let loaded = NpyzReader.read(fileFromPath: voicesURL) ?? [:]
                guard !loaded.isEmpty else {
                    cont.resume(throwing: SynthesisError.failed("Kokoro voice file could not be read."))
                    return
                }
                // Warm up so the first real sentence is fast.
                if let style = loaded[self._voice + ".npy"] ?? loaded.values.first {
                    _ = try? engine.generateAudio(voice: style, language: .enUS, text: "Ready.")
                }
                self.lock.lock()
                self.tts = engine
                self.voices = loaded
                self.loadError = nil
                self.lock.unlock()
                cont.resume()
            }
        }
    }

    public func synthesize(_ text: String, rate: Double) async throws -> AVAudioPCMBuffer {
        lock.lock()
        let engine = tts
        let style = voices[_voice + ".npy"] ?? voices["af_heart.npy"] ?? voices.values.first
        let language: Language = _voice.hasPrefix("b") ? .enGB : .enUS
        lock.unlock()
        guard let engine, let style else { throw SynthesisError.notReady }

        let samples: [Float] = try await withCheckedThrowingContinuation { cont in
            queue.async {
                do {
                    let (audio, _) = try engine.generateAudio(voice: style, language: language, text: text,
                                                              speed: Float(rate))
                    cont.resume(returning: audio)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
        guard let buffer = AudioIO.playbackBuffer(samples: samples, sampleRate: Double(KokoroTTS.Constants.samplingRate))
        else { throw SynthesisError.failed("Could not create audio buffer.") }
        return buffer
    }
}

/// MLX traps if its Metal library is missing (e.g. a plain `swift build`), so check first.
public enum MLXRuntime {
    public static func metalLibraryAvailable() -> Bool {
        let fm = FileManager.default
        var roots: [URL] = [Bundle.main.bundleURL]
        if let r = Bundle.main.resourceURL { roots.append(r) }
        if let exe = Bundle.main.executableURL { roots.append(exe.deletingLastPathComponent()) }
        for root in roots {
            guard let e = fm.enumerator(at: root, includingPropertiesForKeys: nil,
                                        options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in e {
                if e.level > 5 { e.skipDescendants(); continue }
                if url.pathExtension == "metallib" { return true }
            }
        }
        return false
    }
}

// MARK: - System voice (fallback)

/// macOS system voices via `AVSpeechSynthesizer`, rendered to buffers so they go
/// through the same echo-cancelled playback path as Kokoro.
public final class SystemSynthesizer: SpeechSynthesizing, @unchecked Sendable {
    public let displayName = "System voice"
    public var voiceIdentifier: String? {
        get { lock.lock(); defer { lock.unlock() }; return _voiceIdentifier }
        set { lock.lock(); _voiceIdentifier = newValue; lock.unlock() }
    }
    private var _voiceIdentifier: String?
    private let synthesizer = AVSpeechSynthesizer()
    private let lock = NSLock()

    public init(voiceIdentifier: String? = nil) {
        self._voiceIdentifier = voiceIdentifier
    }

    public var isReady: Bool { true }

    /// Best available English voices (premium/enhanced first).
    public static func englishVoices() -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") }
            .sorted { a, b in
                if a.quality != b.quality { return a.quality.rawValue > b.quality.rawValue }
                return a.name < b.name
            }
    }

    public func synthesize(_ text: String, rate: Double) async throws -> AVAudioPCMBuffer {
        guard text.contains(where: { $0.isLetter || $0.isNumber }) else { throw SynthesisError.failed("Nothing to say.") }
        let utterance = AVSpeechUtterance(string: text)
        if let id = voiceIdentifier, let v = AVSpeechSynthesisVoice(identifier: id) {
            utterance.voice = v
        } else {
            utterance.voice = SystemSynthesizer.englishVoices().first ?? AVSpeechSynthesisVoice(language: "en-US")
        }
        let base = AVSpeechUtteranceDefaultSpeechRate
        utterance.rate = min(AVSpeechUtteranceMaximumSpeechRate, max(AVSpeechUtteranceMinimumSpeechRate, base * Float(rate)))

        let synth = synthesizer
        return try await withCheckedThrowingContinuation { cont in
            let collected = BufferBox()
            let once = ResumeOnce()
            func finish() {
                // Merge in the voice's own format, then resample once (no clicks between chunks).
                if let merged = SystemSynthesizer.merge(collected.items), let out = AudioIO.convertForPlayback(merged) {
                    cont.resume(returning: out)
                } else {
                    cont.resume(throwing: SynthesisError.failed("System voice produced no audio."))
                }
            }
            synth.write(utterance) { buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                if pcm.frameLength == 0 {
                    // A zero-length buffer marks the end.
                    if once.claim() { finish() }
                    return
                }
                collected.append(pcm)
            }
            // Some voices never send the end marker: never stall the speech queue.
            DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
                if once.claim() {
                    synth.stopSpeaking(at: .immediate)
                    finish()
                }
            }
        }
    }

    /// Concatenates buffers that share one format.
    static func merge(_ buffers: [AVAudioPCMBuffer]) -> AVAudioPCMBuffer? {
        guard let first = buffers.first else { return nil }
        let format = first.format
        let same = buffers.filter { $0.format == format }
        let total = same.reduce(0) { $0 + Int($1.frameLength) }
        guard total > 0, let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(total)) else {
            return nil
        }
        let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
        let dst = UnsafeMutableAudioBufferListPointer(out.mutableAudioBufferList)
        var offsetFrames = 0
        for b in same {
            let src = UnsafeMutableAudioBufferListPointer(b.mutableAudioBufferList)
            let n = Int(b.frameLength)
            for i in 0..<min(src.count, dst.count) {
                guard let s = src[i].mData, let d = dst[i].mData else { continue }
                memcpy(d.advanced(by: offsetFrames * bytesPerFrame), s, n * bytesPerFrame)
            }
            offsetFrames += n
        }
        out.frameLength = AVAudioFrameCount(total)
        return out
    }
}

// MARK: - Fallback

/// Kokoro when loaded (and when chosen), system voice otherwise or on error.
public final class FallbackSynthesizer: SpeechSynthesizing, @unchecked Sendable {
    public let kokoro: KokoroSynthesizer
    public let system: SystemSynthesizer
    private let lock = NSLock()
    private var _choice: SynthesizerChoice
    public var choice: SynthesizerChoice {
        get { lock.lock(); defer { lock.unlock() }; return _choice }
        set { lock.lock(); _choice = newValue; lock.unlock() }
    }

    public init(kokoro: KokoroSynthesizer, system: SystemSynthesizer, choice: SynthesizerChoice) {
        self.kokoro = kokoro
        self.system = system
        self._choice = choice
    }

    public var isReady: Bool { true }

    public var displayName: String {
        choice != .system && kokoro.isReady ? kokoro.displayName : system.displayName
    }

    public func synthesize(_ text: String, rate: Double) async throws -> AVAudioPCMBuffer {
        if choice != .system, kokoro.isReady {
            do {
                return try await kokoro.synthesize(text, rate: rate)
            } catch {
                NSLog("PairVox: Kokoro failed (\(error)); using the system voice")
            }
        }
        return try await system.synthesize(text, rate: rate)
    }
}

/// Thread-safe accumulator for synthesizer callbacks.
final class BufferBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _items: [AVAudioPCMBuffer] = []
    var items: [AVAudioPCMBuffer] { lock.lock(); defer { lock.unlock() }; return _items }
    func append(_ b: AVAudioPCMBuffer) { lock.lock(); _items.append(b); lock.unlock() }
}
