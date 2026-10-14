// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import PairVoxCore
import XCTest
@testable import PairVoxVoice

/// Uses the real audio engine with a buffer of silence, so nothing is audible.
final class PlaybackPauseTests: XCTestCase {
    private func silence(seconds: Double) -> AVAudioPCMBuffer {
        let format = AudioIO.playbackFormat
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(seconds * format.sampleRate))!
        buffer.frameLength = buffer.frameCapacity
        return buffer
    }

    func testPausedPlaybackHoldsItsPlaceAndFinishesAfterResume() async throws {
        let audio = AudioIO()
        do { try audio.start(captureWanted: false) } catch { throw XCTSkip("no audio output on this machine: \(error)") }
        defer { audio.stop() }
        let finished = LockedFlag()
        let began = Date()
        audio.schedule(silence(seconds: 1.0)) { finished.set(Date().timeIntervalSince(began)) }
        try await Task.sleep(nanoseconds: 300_000_000)
        audio.pausePlayback()
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertNil(finished.value, "a paused buffer must not finish while paused")
        audio.resumePlayback()
        let deadline = Date().addingTimeInterval(4)
        while finished.value == nil, Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        let total = try XCTUnwrap(finished.value, "playback never finished after resume")
        // 0.3 s played, 1.5 s paused, about 0.7 s left: finishing in place, not replaying the whole second.
        XCTAssertEqual(total, 0.3 + 1.5 + 0.7, accuracy: 0.45)
    }

    func testStopWhilePausedDiscardsAndLaterSpeechPlaysNormally() async throws {
        let audio = AudioIO()
        do { try audio.start(captureWanted: false) } catch { throw XCTSkip("no audio output on this machine: \(error)") }
        defer { audio.stop() }
        let first = LockedFlag(), second = LockedFlag()
        audio.schedule(silence(seconds: 1.0)) { first.set(1) }
        try await Task.sleep(nanoseconds: 200_000_000)
        audio.pausePlayback()
        try await Task.sleep(nanoseconds: 200_000_000)
        audio.stopPlayback()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertNotNil(first.value, "stopping reports the discarded buffer as finished, as before")
        audio.schedule(silence(seconds: 0.3)) { second.set(1) }
        let deadline = Date().addingTimeInterval(3)
        while second.value == nil, Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertNotNil(second.value, "a stale pause must not hold the next sentence")
    }
}

final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Double?
    var value: Double? { lock.lock(); defer { lock.unlock() }; return _value }
    func set(_ v: Double) { lock.lock(); _value = v; lock.unlock() }
}

final class PausedSynthesisTests: XCTestCase {
    final class CountingSynth: SpeechSynthesizing, @unchecked Sendable {
        let displayName = "test", isReady = true
        private let lock = NSLock()
        private var _calls = 0
        var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }
        func synthesize(_ text: String, rate: Double) async throws -> AVAudioPCMBuffer {
            lock.lock(); _calls += 1; lock.unlock()
            let format = AudioIO.playbackFormat
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(0.8 * format.sampleRate))!
            buffer.frameLength = buffer.frameCapacity
            return buffer
        }
    }

    func testNoNewSynthesisWhilePausedAndItCatchesUpAfterResume() async throws {
        let audio = AudioIO()
        do { try audio.start(captureWanted: false) } catch { throw XCTSkip("no audio output on this machine: \(error)") }
        defer { audio.stop() }
        let synth = CountingSynth()
        let output = VoiceSpeechOutput(audio: audio, synthesizer: synth)
        for i in 0..<8 { output.enqueue(Utterance(id: i, text: "Sentence number \(i).", kind: .prose)) }
        try await Task.sleep(nanoseconds: 400_000_000)
        output.pause()
        try await Task.sleep(nanoseconds: 300_000_000)   // let any synthesis already running finish
        let frozen = synth.calls
        try await Task.sleep(nanoseconds: 900_000_000)
        XCTAssertEqual(synth.calls, frozen, "the GPU is left to the transcriber while the user talks")
        output.resume()
        try await Task.sleep(nanoseconds: 1_200_000_000)
        XCTAssertGreaterThan(synth.calls, frozen, "synthesis carries on after resume")
        output.stopAll()
    }
}
