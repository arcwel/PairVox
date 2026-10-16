// SPDX-License-Identifier: Apache-2.0
import AVFoundation
import XCTest
@testable import PairVoxVoice

final class SynthesisPiecesTests: XCTestCase {
    /// Records what it was asked to say; each piece becomes 10 ms of tone per character, padded like Kokoro.
    final class CountingSynth: SpeechSynthesizing, @unchecked Sendable {
        let displayName = "counting", isReady = true
        private let lock = NSLock(); private var asked: [String] = []
        var texts: [String] { lock.lock(); defer { lock.unlock() }; return asked }
        func synthesize(_ text: String, rate: Double) async throws -> AVAudioPCMBuffer {
            lock.lock(); asked.append(text); lock.unlock()
            let r = AudioIO.playbackFormat.sampleRate
            let tone = (0..<Int(0.01 * r) * text.count).map { 0.3 * sinf(Float($0) * 0.1) }
            let samples = [Float](repeating: 0, count: Int(0.4 * r)) + tone + [Float](repeating: 0, count: Int(0.5 * r))
            return AudioIO.playbackBuffer(samples: samples, sampleRate: r)!
        }
    }

    func testALongSentenceIsSynthesizedInClauseSizedPiecesAndJoined() async throws {
        let synth = CountingSynth()
        let output = VoiceSpeechOutput(audio: AudioIO(), synthesizer: synth)
        let text = "The reconnect loop no longer loses a nudge that arrives while an attempt is in flight, a replaced loop no longer clears the new session, a stuck connect is released when the loop is cancelled, and a Mac with no project open now sends an idle heartbeat so the phone keeps its link."
        XCTAssertGreaterThan(text.count, 2 * VoiceSpeechOutput.pieceLimit)
        let buffer = try await output.synthesizeInPieces(text, rate: 1)
        let pieces = synth.texts
        XCTAssertGreaterThanOrEqual(pieces.count, 3)
        for p in pieces { XCTAssertLessThanOrEqual(p.count, VoiceSpeechOutput.pieceLimit, "piece too long: \(p)") }
        XCTAssertEqual(pieces.joined(separator: " ").split(separator: " ").count, text.split(separator: " ").count, "every word spoken once")
        // The join carries the pieces' tone and only a short pause between them, not Kokoro's 0.9 s of padding per piece.
        let seconds = Double(buffer.frameLength) / buffer.format.sampleRate
        let toneSeconds = 0.01 * Double(pieces.map(\.count).reduce(0, +))
        XCTAssertLessThan(seconds, toneSeconds + 0.3 * Double(pieces.count))
        XCTAssertGreaterThan(seconds, toneSeconds)
    }

    func testAShortSentenceIsSynthesizedWhole() async throws {
        let synth = CountingSynth()
        let output = VoiceSpeechOutput(audio: AudioIO(), synthesizer: synth)
        _ = try await output.synthesizeInPieces("Okay, the tests pass.", rate: 1)
        XCTAssertEqual(synth.texts, ["Okay, the tests pass."])
    }
}
