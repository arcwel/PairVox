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
