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

    private var waiting: [Utterance] = []                       // not yet synthesized
    private var ready: [(Utterance, AVAudioPCMBuffer)] = []     // synthesized, not yet playing
    private var playing: Utterance?
    private var synthesizing = false
    private var generation = 0
    private var rate: Double = 1.0
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
        var ids: [Int] = []
        if let p = playing { ids.append(p.id) }
        ids += ready.map(\.0.id) + waiting.map(\.id)
        playing = nil
        ready.removeAll()
        waiting.removeAll()
        lock.unlock()
        audio.stopPlayback()
        onPlaybackActiveChange?(false)
        continuation.yield(.idle)
        return ids
    }

    public func setRate(_ rate: Double) {
        lock.lock(); self.rate = rate; lock.unlock()
    }

    // MARK: Pipeline

    private func pump() {
        startSynthesisIfNeeded()
        startPlaybackIfNeeded()
    }

    private func startSynthesisIfNeeded() {
        lock.lock()
        guard !synthesizing, !waiting.isEmpty, ready.count < lookahead else {
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
            let result: Result<AVAudioPCMBuffer, Error>
            do {
                result = .success(try await self.synthesizer.synthesize(next.text, rate: r))
            } catch {
                result = .failure(error)
            }
            self.lock.lock()
            self.synthesizing = false
            let current = gen == self.generation
            if current, case .success(let buffer) = result {
                self.ready.append((next, buffer))
            }
            self.lock.unlock()
            if current, case .failure(let error) = result {
                self.continuation.yield(.failed(next.id, error.localizedDescription))
            }
            self.pump()
        }
    }

    private func startPlaybackIfNeeded() {
        lock.lock()
        guard playing == nil, !ready.isEmpty else {
            let idle = playing == nil && ready.isEmpty && waiting.isEmpty && !synthesizing
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
