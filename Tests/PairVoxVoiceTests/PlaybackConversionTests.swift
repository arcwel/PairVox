// SPDX-License-Identifier: Apache-2.0
import AVFoundation
import XCTest
@testable import PairVoxVoice

/// The conversion to a 16 kHz headset must remove what the headset cannot carry, not fold it back as noise.
final class PlaybackConversionTests: XCTestCase {
    private func tone(hz: Float, seconds: Double, rate: Double = 24_000) -> AVAudioPCMBuffer {
        let n = Int(seconds * rate)
        return AudioIO.playbackBuffer(samples: (0..<n).map { 0.5 * sinf(2 * .pi * hz * Float($0) / Float(rate)) }, sampleRate: rate)!
    }
    private func rms(_ b: AVAudioPCMBuffer, skip: Int = 2_000) -> Float {
        let p = b.floatChannelData![0], n = Int(b.frameLength)
        var s: Float = 0
        for i in skip..<n { s += p[i] * p[i] }
        return (s / Float(n - skip)).squareRoot()
    }

    func testContentAboveTheHeadsetsBandIsRemovedAndSpeechBandIsKept() throws {
        let sixteen = AudioIO.playerFormat(forOutputRate: 16_000)
        XCTAssertEqual(sixteen.sampleRate, 16_000)
        let kept = try XCTUnwrap(AudioIO.convert(tone(hz: 3_000, seconds: 1), to: sixteen))
        let removed = try XCTUnwrap(AudioIO.convert(tone(hz: 10_000, seconds: 1), to: sixteen))
        XCTAssertEqual(kept.format.sampleRate, 16_000)
        XCTAssertEqual(rms(kept), 0.5 / Float(2).squareRoot(), accuracy: 0.03, "a 3 kHz tone passes unchanged")
        XCTAssertLessThan(rms(removed), 0.01, "a 10 kHz tone cannot exist at 16 kHz; aliasing would leave a 6 kHz tone at full level")
    }

    func testTheDeviceRateIsOnlyUsedWhenItIsLower() {
        XCTAssertEqual(AudioIO.playerFormat(forOutputRate: 48_000), AudioIO.playbackFormat)
        XCTAssertEqual(AudioIO.playerFormat(forOutputRate: 0), AudioIO.playbackFormat)
        XCTAssertEqual(AudioIO.playerFormat(forOutputRate: 8_000).sampleRate, 8_000)
    }
}
