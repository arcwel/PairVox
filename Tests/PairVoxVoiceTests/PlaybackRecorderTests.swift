// SPDX-License-Identifier: Apache-2.0
import AVFoundation
import XCTest
@testable import PairVoxVoice

final class PlaybackRecorderTests: XCTestCase {
    private func buffer(seconds: Double, rate: Double = 16_000) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let frames = AVAudioFrameCount(seconds * rate)
        let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        b.frameLength = frames
        for i in 0..<Int(frames) { b.floatChannelData![0][i] = sinf(Float(i) * 0.1) * 0.5 }
        return b
    }

    private func seconds(of url: URL) throws -> Double {
        let f = try AVAudioFile(forReading: url)
        return Double(f.length) / f.fileFormat.sampleRate
    }

    func testEachEngineStartGetsItsOwnFileAndNothingRecordedBeforeARestartIsLost() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pairvox-recorder-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let recorder = PlaybackRecorder()

        recorder.write(buffer(seconds: 2), directory: dir, runID: "run1")
        recorder.finish()                                   // the engine stopped (say, the headset went away)
        recorder.write(buffer(seconds: 1), directory: dir, runID: "run1")
        recorder.write(buffer(seconds: 1), directory: dir, runID: "run1")
        recorder.finish()

        let first = dir.appendingPathComponent(PlaybackRecorder.fileName(runID: "run1", segment: 1))
        let second = dir.appendingPathComponent(PlaybackRecorder.fileName(runID: "run1", segment: 2))
        XCTAssertEqual(first.lastPathComponent, "playback-run1.caf")
        XCTAssertEqual(second.lastPathComponent, "playback-run1-2.caf")
        XCTAssertEqual(try seconds(of: first), 2, accuracy: 0.001, "the first segment must survive the restart")
        XCTAssertEqual(try seconds(of: second), 2, accuracy: 0.001)
    }
}
