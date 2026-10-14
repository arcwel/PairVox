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
    /// How many utterances to synthesize ahead of the one playing.
    private let lookahead = 2

    /// True while audio is playing (the VAD uses this to resist echo).
    public var onPlaybackActiveChange: ((Bool) -> Void)?

    public init(audio: AudioIO, synthesizer: any SpeechSynthesizing) {
        self.audio = audio
        self.synthesizer = synthesizer
        var c: AsyncStream<SpeechOutputEvent>.Continuation!
        events = AsyncStream(bufferingPolicy: .unbounded) { c = $0 }
        continuation = c
    }

    public func enqueue(_ utterance: Utterance) {
        lock.lock()
        waiting.append(utterance)
        lock.unlock()
        pump()
    }

    @discardableResult
    public func stopAll() -> [Int] {
        lock.lock()
        generation += 1
        paused = false
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
        onPlaybackActiveChange?(false)
        continuation.yield(.idle)
        return ids
    }

    public func setRate(_ rate: Double) {
        lock.lock(); self.rate = rate; lock.unlock()
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
        let gen = generation
        let r = rate
        lock.unlock()

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            var result: Result<AVAudioPCMBuffer, Error>
            let began = DispatchTime.now()
            do {
                result = .success(try await self.synthesizer.synthesize(next.text, rate: r))
            } catch {
                result = .failure(error)
            }
            // Check every sentence before it can play. A buffer holding NaN or values in the thousands would
            // come out as a burst of loud noise: synthesize it once more, and if it is still bad, repair it.
            if case .success(var buffer) = result {
                var report = AudioIO.inspect(buffer)
                if !report.isClean {
                    self.log.log(.error, .tts, "synth.corrupt",
                                 ["id": .int(next.id), "engine": .string(self.synthesizer.displayName), "attempt": 1,
                                  "peak": .double(Double(report.peak)), "nonFinite": .int(report.nonFinite),
                                  "overRange": .int(report.overRange), "frames": .int(report.frames)])
                    if let again = try? await self.synthesizer.synthesize(next.text, rate: r) {
                        buffer = again
                        report = AudioIO.inspect(again)
                        if !report.isClean {
                            self.log.log(.error, .tts, "synth.corrupt",
                                         ["id": .int(next.id), "attempt": 2, "peak": .double(Double(report.peak)),
                                          "nonFinite": .int(report.nonFinite), "overRange": .int(report.overRange)])
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
            switch result {
            case .success(let buffer):
                let audioMs = Double(buffer.frameLength) / buffer.format.sampleRate * 1000
                let (readyCount, waitingCount) = self.lock.withLock { (self.ready.count, self.waiting.count) }
                self.log.log(.info, .tts, "synth",
                             ["id": .int(next.id), "chars": .int(next.text.count), "engine": .string(self.synthesizer.displayName),
                              "peak": .double(Double(AudioIO.inspect(buffer).peak)),
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
                let current = gen == self.generation
                if current, case .success(let buffer) = result {
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
        playing = utterance
        let gen = generation
        lock.unlock()

        onPlaybackActiveChange?(true)
        log.log(.debug, .tts, "play.start", ["id": .int(utterance.id), "kind": "\(utterance.kind)"])
        continuation.yield(.started(utterance.id))
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
