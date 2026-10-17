// SPDX-License-Identifier: Apache-2.0
import AVFoundation
import XCTest
import PairVoxCore
@testable import PairVoxVoice

/// Task 4.6: `synth.corrupt` is written through the real pipeline without the sentence when conversation-text
/// logging is off. Nothing is played: the utterance is cancelled while it is being synthesized.
final class CorruptSynthesisLogTests: XCTestCase {
    /// Returns a buffer full of NaN, which `AudioIO.inspect` reports as corrupt.
    final class BrokenSynth: SpeechSynthesizing, @unchecked Sendable {
        let displayName = "broken", isReady = true
        func synthesize(_ text: String, rate: Double) async throws -> AVAudioPCMBuffer {
            let r = AudioIO.playbackFormat.sampleRate
            return AudioIO.playbackBuffer(samples: [Float](repeating: .nan, count: Int(0.05 * r)), sampleRate: r)!
        }
    }

    private final class Captured: @unchecked Sendable {
        private let lock = NSLock(); private var _lines: [[String: Any]] = []
        func add(_ line: String) {
            guard let o = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { return }
            lock.lock(); _lines.append(o); lock.unlock()
        }
        var lines: [[String: Any]] { lock.lock(); defer { lock.unlock() }; return _lines }
    }

    override func tearDown() {
        DiagnosticLog.shared.setSink(nil)
        DiagnosticLog.shared.configure(.init())
    }

    private func corruptLines(includeContent: Bool) async throws -> [[String: Any]] {
        let captured = Captured()
        DiagnosticLog.shared.configure(.init(includeContent: includeContent))
        DiagnosticLog.shared.setSink { captured.add($0) }
        let output = VoiceSpeechOutput(audio: AudioIO(), synthesizer: BrokenSynth())
        output.enqueue(Utterance(id: 1, text: "A sentence the voice renders as noise.", kind: .prose))
        output.cancelQueued([1])   // logged while synthesizing, never played
        for _ in 0..<100 {
            try await Task.sleep(nanoseconds: 50_000_000)
            let found = captured.lines.filter { $0["ev"] as? String == "synth.corrupt" }
            if found.count >= 2 { return found }   // attempt 1 and the retry
        }
        output.stopAll()
        return captured.lines.filter { $0["ev"] as? String == "synth.corrupt" }
    }

    func testTheSentenceIsNotInTheLogByDefault() async throws {
        let lines = try await corruptLines(includeContent: false)
        let first = try XCTUnwrap(lines.first, "no synth.corrupt line")
        let f = try XCTUnwrap(first["f"] as? [String: Any])
        XCTAssertNil(f["text"], "\(f)")
        XCTAssertEqual(f["chars"] as? Int, "A sentence the voice renders as noise.".count)
        XCTAssertEqual((f["sha256"] as? String)?.count, 16)
        XCTAssertEqual(f["attempt"] as? Int, 1)
        XCTAssertGreaterThan(f["nonFinite"] as? Int ?? 0, 0)
        for line in lines { XCTAssertFalse("\(line)".contains("renders as noise"), "\(line)") }
    }

    func testTheSentenceIsInTheLogWhenTextLoggingIsOn() async throws {
        let lines = try await corruptLines(includeContent: true)
        let f = try XCTUnwrap(lines.first?["f"] as? [String: Any])
        XCTAssertEqual(f["text"] as? String, "A sentence the voice renders as noise.")
        XCTAssertNil(f["sha256"])
    }
}
