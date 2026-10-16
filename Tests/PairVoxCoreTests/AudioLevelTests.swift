// SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import PairVoxCore

final class AudioLevelTests: XCTestCase {
    /// Half a second of a tone at `amplitude`, padded like the voice pads a sentence.
    private func sentence(amplitude: Float, rate: Double = 24_000) -> [Float] {
        let pad = [Float](repeating: 0, count: Int(0.4 * rate))
        let tone = (0..<Int(0.5 * rate)).map { amplitude * sinf(Float($0) * 0.08) }
        return pad + tone + pad
    }

    private func speakingRMS(_ s: [Float], rate: Double = 24_000) -> Float {
        let tone = s[Int(0.4 * rate)..<Int(0.9 * rate)]
        return (tone.reduce(0) { $0 + $1 * $1 } / Float(tone.count)).squareRoot()
    }

    func testAQuietAndALoudRenderOfTheSameSentenceEndUpAtTheSameLevel() {
        var quiet = sentence(amplitude: 0.22), loud = sentence(amplitude: 0.43)
        quiet.withUnsafeMutableBufferPointer { _ = AudioLevel.normalize($0, sampleRate: 24_000) }
        loud.withUnsafeMutableBufferPointer { _ = AudioLevel.normalize($0, sampleRate: 24_000) }
        XCTAssertEqual(speakingRMS(quiet), speakingRMS(loud), accuracy: 0.005)
        XCTAssertEqual(speakingRMS(loud), AudioLevel.targetRMS, accuracy: 0.015)
    }

    func testTheGainIsBoundedSoNoiseIsNotAmplifiedAndPeaksStayUnderTheCap() {
        var faint = sentence(amplitude: 0.01)
        let g = faint.withUnsafeMutableBufferPointer { AudioLevel.normalize($0, sampleRate: 24_000) }
        XCTAssertEqual(g, AudioLevel.maxGain)
        var spiky = sentence(amplitude: 0.05)
        spiky[Int(0.5 * 24_000)] = 0.8   // one spike: the cap must win over the target level
        let g2 = spiky.withUnsafeMutableBufferPointer { AudioLevel.normalize($0, sampleRate: 24_000) }
        XCTAssertLessThanOrEqual(spiky.map(abs).max()!, AudioLevel.maxPeak + 0.001)
        XCTAssertLessThan(g2, AudioLevel.targetRMS / (Float(0.05) / Float(2).squareRoot()))
    }

    func testSilenceIsLeftAlone() {
        var silence = [Float](repeating: 0, count: 24_000)
        XCTAssertEqual(silence.withUnsafeMutableBufferPointer { AudioLevel.normalize($0, sampleRate: 24_000) }, 1)
    }
}
