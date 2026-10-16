// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import PairVoxCore
import XCTest
@testable import PairVoxVoice

final class AudioTrimTests: XCTestCase {
    let rate = 24_000.0

    /// `lead` seconds of silence, `speech` seconds of a tone, `tail` seconds of silence.
    private func padded(lead: Double, speech: Double, tail: Double, amplitude: Float = 0.4) -> [Float] {
        let tone = (0..<Int(speech * rate)).map { amplitude * sinf(Float($0) * 0.3) }
        return [Float](repeating: 0, count: Int(lead * rate)) + tone + [Float](repeating: 0, count: Int(tail * rate))
    }

    func testPaddingIsCutToTheKeptPauses() {
        let input = padded(lead: 0.42, speech: 0.48, tail: 0.54)             // "Okay." as Kokoro makes it: 1.44 s
        let out = AudioTrim.trim(input, sampleRate: rate)
        let seconds = Double(out.count) / rate
        XCTAssertEqual(seconds, 0.03 + 0.48 + 0.17, accuracy: 0.03, "30 ms lead, the speech, 170 ms pause")
        XCTAssertLessThan(Double(out.count) / Double(input.count), 0.5)
    }

    func testTheSpeechItselfIsNotTouched() {
        let input = padded(lead: 0.3, speech: 0.5, tail: 0.4)
        let out = AudioTrim.trim(input, sampleRate: rate)
        let loud = { (x: [Float]) in x.filter { abs($0) > 0.3 }.count }
        XCTAssertEqual(loud(out), loud(input), accuracy: 40, "the loud part of the sentence must survive, apart from the fades")
    }

    func testTheEdgesFadeSoACutCannotClick() {
        let out = AudioTrim.trim(padded(lead: 0.3, speech: 0.5, tail: 0.4, amplitude: 0.5), sampleRate: rate)
        XCTAssertEqual(out.first ?? 1, 0, accuracy: 0.001)
        XCTAssertEqual(out.last ?? 1, 0, accuracy: 0.001)
        let jump = zip(out, out.dropFirst()).map { abs($0 - $1) }.max() ?? 0
        XCTAssertLessThan(jump, 0.4, "no sample-to-sample jump anywhere")
    }

    func testAQuietTailThatIsStillSpeechIsKept() {
        // A final consonant or breath at 5% of the peak must not be cut off as "silence".
        var input = padded(lead: 0.2, speech: 0.4, tail: 0.0, amplitude: 0.5)
        input += (0..<Int(0.08 * rate)).map { 0.03 * sinf(Float($0) * 0.5) } + [Float](repeating: 0, count: Int(0.5 * rate))
        let out = AudioTrim.trim(input, sampleRate: rate)
        XCTAssertGreaterThanOrEqual(Double(out.count) / rate, 0.03 + 0.4 + 0.08 + 0.17 - 0.03)
    }

    func testSilenceOrNoiseOnlyAudioIsReturnedUnchanged() {
        let silence = [Float](repeating: 0, count: 5000)
        XCTAssertEqual(AudioTrim.trim(silence, sampleRate: rate), silence)
        let hiss = (0..<5000).map { _ in Float.random(in: -0.001...0.001) }
        XCTAssertEqual(AudioTrim.trim(hiss, sampleRate: rate), hiss)
        XCTAssertEqual(AudioTrim.trim([0.2], sampleRate: rate), [0.2])
    }

    func testAnAlreadyTightSentenceIsLeftAlone() {
        let input = padded(lead: 0.02, speech: 0.5, tail: 0.1)
        let out = AudioTrim.trim(input, sampleRate: rate)
        XCTAssertEqual(out.count, input.count, accuracy: Int(0.012 * rate), "less silence than the pauses we keep: nothing to cut")
    }
}

/// Through the real speaker pipeline: padded sentences must not leave long dead air between them.
final class SentenceGapTests: XCTestCase {
    final class PaddedSynth: SpeechSynthesizing, @unchecked Sendable {
        let displayName = "padded", isReady = true
        func synthesize(_ text: String, rate: Double) async throws -> AVAudioPCMBuffer {
            let format = AudioIO.playbackFormat
            let r = format.sampleRate
            // 0.42 s of silence, 0.30 s of a very quiet tone, 0.54 s of silence: how Kokoro makes a short sentence.
            let samples = [Float](repeating: 0, count: Int(0.42 * r)) + (0..<Int(0.30 * r)).map { 0.02 * sinf(Float($0) * 0.3) } + [Float](repeating: 0, count: Int(0.54 * r))
            return AudioIO.playbackBuffer(samples: samples, sampleRate: r)!
        }
    }

    func testTheGapBetweenSentencesIsAFractionOfWhatKokoroPads() async throws {
        let audio = AudioIO()
        try startAudioOrSkip(audio)
        defer { audio.stop() }
        let output = VoiceSpeechOutput(audio: audio, synthesizer: PaddedSynth())
        final class Starts: @unchecked Sendable { private let l = NSLock(); private var t: [Date] = []
            func note() { l.lock(); t.append(Date()); l.unlock() }; var all: [Date] { l.lock(); defer { l.unlock() }; return t } }
        let starts = Starts()
        let watcher = Task { for await e in output.events { if case .started = e { starts.note() } } }
        for i in 0..<3 { output.enqueue(Utterance(id: i, text: "Sentence \(i).", kind: .prose)) }
        let deadline = Date().addingTimeInterval(6)
        while starts.all.count < 3, Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        watcher.cancel(); output.stopAll()
        XCTAssertEqual(starts.all.count, 3)
        let spacing = zip(starts.all, starts.all.dropFirst()).map { $1.timeIntervalSince($0) }
        // Untrimmed each sentence plays for 1.26 s, so sentences would start 1.26 s apart. Trimmed: 30 ms + 300 ms + 170 ms.
        for s in spacing { XCTAssertLessThan(s, 0.8, "sentences start \(s) s apart; the padding was not removed") }
    }
}

final class CourtesyQueueTests: XCTestCase {
    /// A sentence that plays for about `seconds` (very quiet tone), no padding.
    final class TimedSynth: SpeechSynthesizing, @unchecked Sendable {
        let displayName = "timed", isReady = true
        func synthesize(_ text: String, rate: Double) async throws -> AVAudioPCMBuffer {
            let r = AudioIO.playbackFormat.sampleRate
            let seconds = text.hasPrefix("Long") ? 1.2 : 0.3
            return AudioIO.playbackBuffer(samples: (0..<Int(seconds * r)).map { 0.02 * sinf(Float($0) * 0.3) }, sampleRate: r)!
        }
    }

    final class Events: @unchecked Sendable {
        private let l = NSLock(); private var s: [Int] = [], f: [Int] = []
        func started(_ id: Int) { l.lock(); s.append(id); l.unlock() }
        func finished(_ id: Int) { l.lock(); f.append(id); l.unlock() }
        var startedIDs: [Int] { l.lock(); defer { l.unlock() }; return s }
        var finishedIDs: [Int] { l.lock(); defer { l.unlock() }; return f }
    }

    private func rig() throws -> (VoiceSpeechOutput, AudioIO, Events, Task<Void, Never>) {
        let audio = AudioIO()
        try startAudioOrSkip(audio)
        let output = VoiceSpeechOutput(audio: audio, synthesizer: TimedSynth())
        let events = Events()
        let watcher = Task { for await e in output.events { if case .started(let id) = e { events.started(id) }; if case .finished(let id) = e { events.finished(id) } } }
        return (output, audio, events, watcher)
    }

    func testNarrationThatWaitedTooLongIsSkippedButTheAnswerIsStillSpoken() async throws {
        let (output, audio, events, watcher) = try rig()
        defer { watcher.cancel(); output.stopAll(); audio.stop() }
        output.narrationMaxWaitSeconds = 0.5
        output.enqueue(Utterance(id: 1, text: "Long first sentence.", kind: .prose))      // plays for 1.2 s
        output.enqueue(Utterance(id: 2, text: "Reading the file.", kind: .narration))     // would start 1.2 s later: out of date
        output.enqueue(Utterance(id: 3, text: "The answer.", kind: .prose))
        try await Task.sleep(nanoseconds: 2_600_000_000)
        XCTAssertEqual(events.startedIDs, [1, 3], "narration 2 must be skipped, never played: \(events.startedIDs)")
        XCTAssertTrue(events.finishedIDs.contains(2), "a skipped line is reported finished so the engine does not wait for it")
    }

    func testNarrationThatIsNotLateIsSpoken() async throws {
        let (output, audio, events, watcher) = try rig()
        defer { watcher.cancel(); output.stopAll(); audio.stop() }
        output.enqueue(Utterance(id: 1, text: "Short.", kind: .prose))
        output.enqueue(Utterance(id: 2, text: "Reading the file.", kind: .narration))
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertEqual(events.startedIDs, [1, 2])
    }

    func testQueuedCourtesyLinesCanBeCancelledButAPlayingOneCannot() async throws {
        let (output, audio, events, watcher) = try rig()
        defer { watcher.cancel(); output.stopAll(); audio.stop() }
        output.enqueue(Utterance(id: 1, text: "Long playing now.", kind: .ack))
        try await Task.sleep(nanoseconds: 300_000_000)
        output.enqueue(Utterance(id: 2, text: "Queued narration.", kind: .narration))
        let removed = output.cancelQueued([1, 2])
        XCTAssertEqual(removed, [2], "id 1 is already playing and must stay")
        try await Task.sleep(nanoseconds: 1_400_000_000)
        XCTAssertEqual(events.startedIDs, [1])
    }
}
