// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import Foundation
import PairVoxCore

/// `SpeechOutput` backed by a synthesizer and `AudioIO`. Synthesizes ahead of
/// playback (pipelined) so sentences follow each other without gaps, and stops
/// within one audio buffer on barge-in.
public final class VoiceSpeechOutput: SpeechOutput, @unchecked Sendable {
    public let events: AsyncStream<SpeechOutputEvent>
    private let continuation: AsyncStream<SpeechOutputEvent>.Continuation

    private let audio: AudioIO
    private let synthesizer: any SpeechSynthesizing
    private let lock = NSLock()
    private let log = DiagnosticLog.shared

    private var waiting: [Utterance] = []                       // not yet synthesized
    private var ready: [(Utterance, AVAudioPCMBuffer)] = []     // synthesized, not yet playing
    private var playing: Utterance?
    private var synthesizing = false
    private var generation = 0
    private var rate: Double = 1.0
    private var paused = false
    private var enqueuedAt: [Int: DispatchTime] = [:]
    /// The utterance being synthesized right now, and ones cancelled while that was happening.
    private var synthesizingID: Int?
    private var cancelledWhileSynthesizing: Set<Int> = []
    /// Cut the silence a synthesizer puts around each sentence (see `AudioTrim`). Follows the app-wide setting unless a test
    /// or caller sets it for this output.
    public var trimSilence: Bool?
    private static let defaultTrim = TrimDefault()
    private final class TrimDefault: @unchecked Sendable {
        private let lock = NSLock(); private var on = true
        var value: Bool { get { lock.lock(); defer { lock.unlock() }; return on } set { lock.lock(); on = newValue; lock.unlock() } }
    }
    /// The app-wide setting ("Tighten pauses between sentences"): applies to every output from the next sentence on.
    public static func setTrimSilenceByDefault(_ on: Bool) { defaultTrim.value = on }
    /// Tool narration that waited longer than this to start is out of date and is skipped.
    public var narrationMaxWaitSeconds: Double = 2.5
    /// How many utterances to synthesize ahead of the one playing.
    private let lookahead = 2

    /// True while audio is playing (the VAD uses this to resist echo).
    public var onPlaybackActiveChange: ((Bool) -> Void)?
    /// Each sentence as it starts playing, with the exact audio played (after trimming and leveling). A paired phone
    /// plays the same audio, so it speaks with this voice instead of its own text-to-speech.
    public var onPlay: ((Utterance, AVAudioPCMBuffer) -> Void)?
    /// Everything queued or playing was stopped (barge-in, interrupt, a new turn): a phone stops too.
    public var onStopped: (() -> Void)?

    public init(audio: AudioIO, synthesizer: any SpeechSynthesizing) {
        self.audio = audio
        self.synthesizer = synthesizer
        var c: AsyncStream<SpeechOutputEvent>.Continuation!
        events = AsyncStream(bufferingPolicy: .unbounded) { c = $0 }
        continuation = c
    }

    /// Sentences longer than this many characters are synthesized in clause-sized pieces and joined. Every corrupt
    /// buffer seen in the wild came from a sentence over a hundred characters, and its two halves came out clean;
    /// shorter pieces also start playing sooner. The synthesizer's own silence around each piece is trimmed so the
    /// join sounds like a comma, not a dropout.
    static let pieceLimit = 110

    func synthesizeInPieces(_ text: String, rate: Double) async throws -> AVAudioPCMBuffer {
        guard text.count > Self.pieceLimit, let (first, second) = SynthesisRecovery.split(text) else {
            return try await synthesizer.synthesize(text, rate: rate)
        }
        let a = AudioTrim.trim(try await synthesizeInPieces(first, rate: rate))
        let b = AudioTrim.trim(try await synthesizeInPieces(second, rate: rate))
        guard let joined = SynthesisRecovery.join(a, b) else { throw SynthesisError.failed("Could not join the pieces of a sentence.") }
        return joined
    }

    public func enqueue(_ utterance: Utterance) {
        lock.lock()
        enqueuedAt[utterance.id] = .now()
        waiting.append(utterance)
        lock.unlock()
        pump()
    }

    @discardableResult
    public func stopAll() -> [Int] {
        lock.lock()
        generation += 1
        paused = false
        enqueuedAt.removeAll()
        cancelledWhileSynthesizing.removeAll()
        let hadAudio = playing != nil
        var ids: [Int] = []
        if let p = playing { ids.append(p.id) }
        ids += ready.map(\.0.id) + waiting.map(\.id)
        playing = nil
        ready.removeAll()
        waiting.removeAll()
        lock.unlock()
        // Only touch the shared player if this output was actually playing.
        if hadAudio { audio.stopPlayback() }
        if !ids.isEmpty { onStopped?() }
        onPlaybackActiveChange?(false)
        continuation.yield(.idle)
        return ids
    }

    public func prepare() { synthesizer.warmUpIfIdle() }

    public func setRate(_ rate: Double) {
        lock.lock(); self.rate = rate; lock.unlock()
    }

    @discardableResult
    public func cancelQueued(_ ids: [Int]) -> [Int] {
        lock.lock()
        let wanted = Set(ids)
        let removed = waiting.filter { wanted.contains($0.id) }.map(\.id) + ready.filter { wanted.contains($0.0.id) }.map(\.0.id)
        waiting.removeAll { wanted.contains($0.id) }
        ready.removeAll { wanted.contains($0.0.id) }
        var all = removed
        if let id = synthesizingID, wanted.contains(id) { cancelledWhileSynthesizing.insert(id); all.append(id) }
        for id in all { enqueuedAt[id] = nil }
        lock.unlock()
        if !all.isEmpty { pump() }
        return all
    }

    public var supportsPause: Bool { true }

    /// Holds playback where it is. Synthesis carries on, so nothing is lost; the next sentence waits.
    public func pause() {
        lock.lock()
        paused = true
        let hasAudio = playing != nil
        lock.unlock()
        if hasAudio { audio.pausePlayback() }
    }

    /// Carries on from the same spot, then starts whatever was synthesized meanwhile.
    public func resume() {
        lock.lock()
        let was = paused
        paused = false
        lock.unlock()
        guard was else { return }
        audio.resumePlayback()
        pump()
    }

    // MARK: Pipeline

    private func pump() {
        startSynthesisIfNeeded()
        startPlaybackIfNeeded()
    }

    private func startSynthesisIfNeeded() {
        lock.lock()
        // While paused the user is talking and the transcriber needs the GPU; synthesis catches up after resume.
        guard !synthesizing, !waiting.isEmpty, ready.count < lookahead, !paused else {
            lock.unlock()
            return
        }
        synthesizing = true
        let next = waiting.removeFirst()
        synthesizingID = next.id
        let gen = generation
        let r = rate
        lock.unlock()

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            var result: Result<AVAudioPCMBuffer, Error>
            let began = DispatchTime.now()
            do {
                result = .success(try await self.synthesizeInPieces(next.text, rate: r))
            } catch {
                result = .failure(error)
            }
            // Check every sentence before it can play. A buffer holding NaN or values in the thousands would
            // come out as a burst of loud noise: synthesize it once more, and if it is still bad, repair it.
            if case .success(var buffer) = result {
                var report = AudioIO.inspect(buffer)
                if !report.isClean {
                    // The sentence identifies the fault for `--tts-probe`, but it is reply text: with conversation-text
                    // logging off only its length and a hash are written (docs/DEV_ENVIRONMENT.md says how to reproduce).
                    self.log.log(.error, .tts, "synth.corrupt",
                                 ["id": .int(next.id), "engine": .string(self.synthesizer.displayName), "attempt": 1,
                                  "peak": .double(Double(report.peak)), "nonFinite": .int(report.nonFinite),
                                  "overRange": .int(report.overRange), "noisyWindows": .int(report.noisyWindows),
                                  "highBand": .double(Double(report.maxHighBandShare)), "frames": .int(report.frames)]
                                    .merging(self.log.contentFingerprint(next.text)) { $1 })
                    if let again = try? await self.synthesizeInPieces(next.text, rate: r) {
                        buffer = again
                        report = AudioIO.inspect(again)
                        if !report.isClean {
                            self.log.log(.error, .tts, "synth.corrupt",
                                         ["id": .int(next.id), "attempt": 2, "peak": .double(Double(report.peak)),
                                          "nonFinite": .int(report.nonFinite), "overRange": .int(report.overRange),
                                          "noisyWindows": .int(report.noisyWindows), "highBand": .double(Double(report.maxHighBandShare))])
                        }
                    }
                    // Still noise: the same text tends to come out bad every time, so change what is asked of the voice.
                    // First two shorter pieces, then the plain system voice; repairing the samples is the last resort.
                    if !report.isClean, let (first, second) = SynthesisRecovery.split(next.text),
                       let x = try? await self.synthesizer.synthesize(first, rate: r),
                       let y = try? await self.synthesizer.synthesize(second, rate: r),
                       AudioIO.inspect(x).isClean, AudioIO.inspect(y).isClean,
                       let joined = SynthesisRecovery.join(x, y) {
                        buffer = joined; report = AudioIO.inspect(joined)
                        self.log.log(.warning, .tts, "synth.recovered", ["id": .int(next.id), "how": "split"])
                    }
                    if !report.isClean, let plain = try? await self.synthesizer.synthesizeWithSystemVoice(next.text, rate: r),
                       AudioIO.inspect(plain).isClean {
                        buffer = plain; report = AudioIO.inspect(plain)
                        self.log.log(.warning, .tts, "synth.recovered", ["id": .int(next.id), "how": "systemVoice"])
                    }
                    if !report.isClean { AudioIO.sanitize(buffer) }
                    result = .success(buffer)
                }
            }
            let synthMs = Double(DispatchTime.now().uptimeNanoseconds - began.uptimeNanoseconds) / 1_000_000
            // Cut the synthesizer's own silence around the sentence (after the corruption checks above, which look at the raw audio).
            if trimSilence ?? Self.defaultTrim.value, case .success(let raw) = result { result = .success(AudioTrim.trim(raw)) }
            // One level for every sentence: the voice's own level swings by 11 dB from one render to the next.
            var gain: Float = 1
            if case .success(let buffer) = result, let data = buffer.floatChannelData {
                gain = AudioLevel.normalize(UnsafeMutableBufferPointer(start: data[0], count: Int(buffer.frameLength)),
                                            sampleRate: buffer.format.sampleRate)
            }
            switch result {
            case .success(let buffer):
                let audioMs = Double(buffer.frameLength) / buffer.format.sampleRate * 1000
                let (readyCount, waitingCount) = self.lock.withLock { (self.ready.count, self.waiting.count) }
                self.log.log(.info, .tts, "synth",
                             ["id": .int(next.id), "chars": .int(next.text.count), "engine": .string(self.synthesizer.displayName),
                              "peak": .double(Double(AudioIO.inspect(buffer).peak)), "gain": .double(Double(gain)),
                              "synthMs": .double(synthMs), "audioMs": .double(audioMs),
                              "realtimeFactor": .double(audioMs > 0 ? synthMs / audioMs : 0),
                              "ready": .int(readyCount), "waiting": .int(waitingCount)])
            case .failure(let error):
                self.log.log(.error, .tts, "synth.failed",
                             ["id": .int(next.id), "engine": .string(self.synthesizer.displayName),
                              "error": .string(error.localizedDescription), "synthMs": .double(synthMs)])
            }
            let current = self.lock.withLock { () -> Bool in
                self.synthesizing = false
                self.synthesizingID = nil
                let current = gen == self.generation
                let cancelled = self.cancelledWhileSynthesizing.remove(next.id) != nil
                if current, !cancelled, case .success(let buffer) = result {
                    self.ready.append((next, buffer))
                }
                return current
            }
            if current, case .failure(let error) = result {
                self.continuation.yield(.failed(next.id, error.localizedDescription))
            }
            self.pump()
        }
    }

    private func startPlaybackIfNeeded() {
        lock.lock()
        guard playing == nil, !ready.isEmpty, !paused else {
            let idle = playing == nil && ready.isEmpty && !paused && waiting.isEmpty && !synthesizing
            lock.unlock()
            if idle {
                onPlaybackActiveChange?(false)
                continuation.yield(.idle)
            }
            return
        }
        let (utterance, buffer) = ready.removeFirst()
        let waited = enqueuedAt[utterance.id].map { Double(DispatchTime.now().uptimeNanoseconds - $0.uptimeNanoseconds) / 1_000_000_000 } ?? 0
        enqueuedAt[utterance.id] = nil
        if utterance.kind == .narration, waited > narrationMaxWaitSeconds {
            // "Reading the file" said three seconds late is noise: skip it and go on with what matters.
            lock.unlock()
            log.log(.info, .tts, "narration.skipped", ["id": .int(utterance.id), "waitedMs": .int(Int(waited * 1000))])
            continuation.yield(.finished(utterance.id))
            pump()
            return
        }
        playing = utterance
        let gen = generation
        lock.unlock()

        onPlaybackActiveChange?(true)
        log.log(.debug, .tts, "play.start", ["id": .int(utterance.id), "kind": "\(utterance.kind)"])
        continuation.yield(.started(utterance.id))
        onPlay?(utterance, buffer)
        audio.schedule(buffer) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let current = gen == self.generation && self.playing?.id == utterance.id
            if current { self.playing = nil }
            self.lock.unlock()
            guard current else { return }
            self.continuation.yield(.finished(utterance.id))
            self.pump()
        }
        // Keep the synthesizer busy while this one plays.
        startSynthesisIfNeeded()
    }
}
