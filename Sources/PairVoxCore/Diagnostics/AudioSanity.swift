// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Valid audio samples are finite and within about ±1. Anything else (NaN, infinity, or values in the
/// thousands) is memory garbage that would play as a deafening burst of noise.
public enum AudioSanity {
    /// Above this a sample cannot be real speech (Float audio is nominally ±1; allow some overshoot).
    public static let maxValidPeak: Float = 1.5

    public struct Report: Equatable, Sendable {
        public var frames = 0
        public var peak: Float = 0
        public var nonFinite = 0
        public var overRange = 0
        public var isClean: Bool { nonFinite == 0 && overRange == 0 }
        public init(frames: Int = 0) { self.frames = frames }
    }

    public static func inspect(_ samples: UnsafeBufferPointer<Float>) -> Report {
        var report = Report(frames: samples.count)
        for v in samples {
            guard v.isFinite else { report.nonFinite += 1; continue }
            let a = abs(v)
            if a > maxValidPeak { report.overRange += 1 }
            report.peak = max(report.peak, a)
        }
        return report
    }

    public static func inspect(_ samples: [Float]) -> Report {
        samples.withUnsafeBufferPointer { inspect($0) }
    }

    /// Replaces non-finite samples with silence and clamps the rest to ±1, in place.
    public static func sanitize(_ samples: UnsafeMutableBufferPointer<Float>) {
        for i in samples.indices {
            let v = samples[i]
            samples[i] = v.isFinite ? max(-1, min(1, v)) : 0
        }
    }
}
