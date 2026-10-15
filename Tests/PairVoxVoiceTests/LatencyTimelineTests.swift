// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import XCTest
import PairVoxCore
@testable import PairVoxVoice

/// One conversational turn on the real engine and the real speaker pipeline, with audio shaped like Kokoro's (silence
/// around every sentence), timed from the moment the person's words are sent to Claude. Claude's own thinking time is
/// scaled down (the reply arrives after 1.0 s here, not 2 s); what is measured is what PairVox adds.
final class LatencyTimelineTests: XCTestCase {
    /// Kokoro-shaped audio: the "Okay." acknowledgement is 0.42 s of silence, 0.48 s of speech and 0.54 s of silence; any
    /// other sentence has 0.35 s before and 0.5 s after 1.5 s of speech. The tone is very quiet.
    final class KokoroShaped: SpeechSynthesizing, @unchecked Sendable {
        let displayName = "kokoro-shaped", isReady = true
        func synthesize(_ text: String, rate: Double) async throws -> AVAudioPCMBuffer {
            let r = AudioIO.playbackFormat.sampleRate
            let (lead, speech, tail) = text.count <= 8 ? (0.42, 0.48, 0.54) : (0.35, 1.5, 0.5)
            let samples = [Float](repeating: 0, count: Int(lead * r)) + (0..<Int(speech * r)).map { 0.02 * sinf(Float($0) * 0.3) } + [Float](repeating: 0, count: Int(tail * r))
            return AudioIO.playbackBuffer(samples: samples, sampleRate: r)!
        }
    }

    /// Seconds from sending the person's words to the answer's first sentence starting to play, and the same plus the
    /// silence that sentence still has in front of it (when it becomes audible).
    private func answerTimes(trim: Bool, cancelCourtesy: Bool) async throws -> (started: Double, audible: Double) {
        let audio = AudioIO()
        do { try audio.start(captureWanted: false) } catch { throw XCTSkip("no audio output on this machine: \(error)") }
        defer { audio.stop() }
        let backend = ReplayBackend()
        let inner = VoiceSpeechOutput(audio: audio, synthesizer: KokoroShaped())
        inner.trimSilence = trim
        let output: any SpeechOutput = cancelCourtesy ? inner : NoCancel(inner: inner)
        let engine = ConversationEngine(configuration: EngineConfiguration(projectRoot: "/tmp/latency", speechMode: .skipCode, acknowledgements: true,
                                                                           acknowledgementDelay: 0.5),
                                        output: output, backendFactory: { _ in backend })
        await engine.start()
        await engine.submit("Explain the module")
        try await Task.sleep(nanoseconds: 1_000_000_000)                 // Claude takes 1.0 s to start answering (the acknowledgement fires at 0.5 s)
        backend.emit(.textDelta("Here is the first point about the module. "))
        backend.emit(.textBlockEnded)
        try await Task.sleep(nanoseconds: 3_000_000_000)                 // the turn ends after the answer has started, as it does for a longer reply
        backend.emit(.turnCompleted(TurnResult(outcome: .success)))
        try await Task.sleep(nanoseconds: 400_000_000)
        let snap = await engine.snapshot
        let latency = try XCTUnwrap(snap.lastLatency, "no latency was recorded")
        await engine.shutdown()
        let started = try XCTUnwrap(latency.firstAudio)
        return (started, started + (trim ? 0.03 : 0.35))
    }

    /// An output that behaves like the old one: it cannot cancel queued lines.
    final class NoCancel: SpeechOutput, @unchecked Sendable {
        let inner: VoiceSpeechOutput
        init(inner: VoiceSpeechOutput) { self.inner = inner }
        var events: AsyncStream<SpeechOutputEvent> { inner.events }
        func enqueue(_ u: Utterance) { inner.enqueue(u) }
        @discardableResult func stopAll() -> [Int] { inner.stopAll() }
        func setRate(_ rate: Double) { inner.setRate(rate) }
        var supportsPause: Bool { inner.supportsPause }
        func pause() { inner.pause() }
        func resume() { inner.resume() }
    }

    func testTheAnswerIsAudibleAboutAFullSecondSoonerThanBefore() async throws {
        let before = try await answerTimes(trim: false, cancelCourtesy: false)
        let after = try await answerTimes(trim: true, cancelCourtesy: true)
        print("LATENCY turn timeline (Claude's first token at 1.0 s): answer audible at \(String(format: "%.2f", before.audible)) s before, \(String(format: "%.2f", after.audible)) s now (\(String(format: "%.2f", before.audible - after.audible)) s sooner); starts \(String(format: "%.2f", before.started)) -> \(String(format: "%.2f", after.started))")
        XCTAssertGreaterThan(before.audible - after.audible, 0.8, "the answer should be audible at least 0.8 s sooner")
        XCTAssertLessThan(after.started, 1.6, "the answer must not wait behind the acknowledgement")
    }
}
