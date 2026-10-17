// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PairVoxCore

final class AudioSanityTests: XCTestCase {
    func testNormalSpeechRangeIsClean() {
        let samples: [Float] = (0..<1000).map { 0.4 * sinf(Float($0) * 0.05) }
        let report = AudioSanity.inspect(samples)
        XCTAssertTrue(report.isClean)
        XCTAssertEqual(report.frames, 1000)
        XCTAssertLessThanOrEqual(report.peak, 0.4)
    }

    func testDetectsNonFiniteAndHugeSamples() {
        var samples = [Float](repeating: 0.1, count: 100)
        samples[10] = .nan
        samples[20] = .infinity
        samples[30] = 4_555_093.5
        let report = AudioSanity.inspect(samples)
        XCTAssertFalse(report.isClean)
        XCTAssertEqual(report.nonFinite, 2)
        XCTAssertEqual(report.overRange, 1)
        XCTAssertEqual(report.peak, 4_555_093.5)
    }

    func testSanitizeMakesAnyBufferClean() {
        var samples: [Float] = [0.2, .nan, 9000, -9000, .infinity, -.infinity, 0.9]
        samples.withUnsafeMutableBufferPointer { AudioSanity.sanitize($0) }
        XCTAssertTrue(AudioSanity.inspect(samples).isClean)
        XCTAssertEqual(samples[0], 0.2)
        XCTAssertEqual(samples[1], 0)
        XCTAssertEqual(samples[2], 1)
        XCTAssertEqual(samples[3], -1)
        XCTAssertEqual(samples[6], 0.9)
    }

    func testSlightOvershootIsStillValid() {
        XCTAssertTrue(AudioSanity.inspect([1.2, -1.3, 0.5]).isClean)
    }
}

// MARK: - Noise bursts (garbage that stays within ±1)

extension AudioSanityTests {
    /// Deterministic noise, so a failure reproduces.
    private struct LCG { var s: UInt32 = 12345; mutating func next() -> Float { s = s &* 1_664_525 &+ 1_013_904_223; return Float(s >> 8) / Float(1 << 24) * 2 - 1 } }

    /// A voice-like signal: a 200 Hz fundamental with harmonics up to 3 kHz.
    private func voiceLike(seconds: Double, rate: Double = 24_000) -> [Float] {
        (0..<Int(seconds * rate)).map { i in
            let t = Float(i) / Float(rate)
            var v: Float = 0
            for h in 1...15 { v += sinf(2 * .pi * 200 * Float(h) * t) / Float(h) }
            return 0.3 * v / 3.3
        }
    }

    func testAStretchOfWhiteNoiseInsideSpeechIsCaught() {
        var samples = voiceLike(seconds: 1)
        var rng = LCG()
        for i in 12_000..<(12_000 + 2_400) { samples[i] = 0.5 * rng.next() }   // 100 ms of garbage within ±0.5
        let report = AudioSanity.inspect(samples)
        XCTAssertEqual(report.overRange, 0, "nothing is out of range, so the old check would have passed it")
        XCTAssertGreaterThanOrEqual(report.noisyWindows, 2)
        XCTAssertGreaterThan(report.maxHighBandShare, AudioSanity.maxHighBandShare)
        XCTAssertTrue(report.isClean, "the noise metric is reported, not a verdict: a loud sibilant looks the same")
    }

    func testVoiceLikeSoundAndSibilantsAreNotNoise() {
        XCTAssertEqual(AudioSanity.inspect(voiceLike(seconds: 1)).noisyWindows, 0)
        // A sibilant: energy spread from 4 to 8 kHz, nothing above the band the check looks at.
        var rng = LCG()
        let phases = (0..<81).map { _ in rng.next() * .pi }
        let sibilant: [Float] = (0..<24_000).map { i in
            let t = Float(i) / 24_000
            var v: Float = 0
            for (k, phase) in phases.enumerated() { v += sinf(2 * .pi * (4_000 + Float(k) * 50) * t + phase) }
            return 0.3 * v / 9
        }
        let report = AudioSanity.inspect(sibilant)
        XCTAssertEqual(report.noisyWindows, 0, "share \(report.maxHighBandShare)")
    }

    func testASingleClickIsNotABurst() {
        var samples = voiceLike(seconds: 0.5)
        var rng = LCG()
        for i in 6_000..<(6_000 + 120) { samples[i] = 0.5 * rng.next() }   // 5 ms: a click, not a burst
        XCTAssertEqual(AudioSanity.inspect(samples).noisyWindows, 0)
    }

    func testLowSampleRatesSkipTheSpectralCheck() {
        var rng = LCG()
        let noise = (0..<16_000).map { _ in 0.5 * rng.next() }
        XCTAssertEqual(AudioSanity.inspect(noise, sampleRate: 16_000).noisyWindows, 0, "9 kHz is outside a 16 kHz band; no judgement")
    }
}
