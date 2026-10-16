// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Valid audio samples are finite, within about ±1, and shaped like speech. Anything else (NaN, infinity,
/// values in the thousands, or a stretch of white noise) is memory garbage that would play as a burst of noise.
public enum AudioSanity {
    /// Above this a sample cannot be real speech (Float audio is nominally ±1; allow some overshoot).
    public static let maxValidPeak: Float = 1.5

    /// A 20 ms window at speaking level whose energy above 9 kHz (fourth-order high-pass) is more than this share
    /// of its total is not speech. Measured on the real voice at 24 kHz, 1,963 windows: among windows with an
    /// RMS of 0.05 or more, speech never passed 0.031 (the sibilants, which do put most of their energy above
    /// 9 kHz, are all quieter than that); uniform noise never dropped below 0.19 at any level. Garbage from a bad
    /// synthesis is noise-like and loud, and lands in the second group.
    public static let maxHighBandShare: Float = 0.14
    /// Windows quieter than this are not judged: that is where the sibilants live, and garbage this quiet is no
    /// screech.
    public static let minJudgedRMS: Float = 0.05
    /// One noisy window can be a click; the bursts seen in the wild last 90 ms and more.
    public static let noisyWindowsToFail = 2
    static let windowSeconds = 0.02
    static let highBandHz = 9_000.0

    public struct Report: Equatable, Sendable {
        public var frames = 0
        public var peak: Float = 0
        public var nonFinite = 0
        public var overRange = 0
        /// 20 ms windows at speaking level that look like white noise (see `maxHighBandShare`), counted only in a
        /// run of `noisyWindowsToFail` or more. A metric for the log, not a verdict (see `isClean`).
        public var noisyWindows = 0
        /// The largest high-band share seen in any judged window, for the log.
        public var maxHighBandShare: Float = 0
        /// Non-finite or out-of-range samples. `noisyWindows` is reported but does not fail a buffer: measured on the
        /// real voice, a loud sibilant has the same spectrum as noise (shares up to 0.88 at speaking level), so the
        /// spectral check cannot tell them apart; it stays as a logged metric.
        public var isClean: Bool { nonFinite == 0 && overRange == 0 }
        public init(frames: Int = 0) { self.frames = frames }
    }

    /// `sampleRate` enables the noise-burst check; it needs at least 22.05 kHz so that 9 kHz is inside the band.
    public static func inspect(_ samples: UnsafeBufferPointer<Float>, sampleRate: Double = 24_000) -> Report {
        var report = Report(frames: samples.count)
        for v in samples {
            guard v.isFinite else { report.nonFinite += 1; continue }
            let a = abs(v)
            if a > maxValidPeak { report.overRange += 1 }
            report.peak = max(report.peak, a)
        }
        guard report.nonFinite == 0, sampleRate >= 22_050 else { return report }
        noiseBursts(samples, sampleRate: sampleRate, into: &report)
        return report
    }

    public static func inspect(_ samples: [Float], sampleRate: Double = 24_000) -> Report {
        samples.withUnsafeBufferPointer { inspect($0, sampleRate: sampleRate) }
    }

    /// Replaces non-finite samples with silence and clamps the rest to ±1, in place.
    public static func sanitize(_ samples: UnsafeMutableBufferPointer<Float>) {
        for i in samples.indices {
            let v = samples[i]
            samples[i] = v.isFinite ? max(-1, min(1, v)) : 0
        }
    }

    /// One stage of the high-pass: a biquad with the given Q.
    private struct Biquad {
        let b0, b1, b2, a1, a2: Double
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        init(highPassAt hz: Double, sampleRate: Double, q: Double) {
            let k = tan(Double.pi * hz / sampleRate)
            let n = 1 / (1 + k / q + k * k)
            b0 = n; b1 = -2 * n; b2 = n; a1 = 2 * n * (k * k - 1); a2 = n * (1 - k / q + k * k)
        }
        mutating func step(_ v: Double) -> Double {
            let o = b0 * v + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = v; y2 = y1; y1 = o
            return o
        }
    }

    /// Fourth-order Butterworth high-pass at `highBandHz` (two biquads), then per-window energy share above it.
    private static func noiseBursts(_ samples: UnsafeBufferPointer<Float>, sampleRate: Double, into report: inout Report) {
        var stage1 = Biquad(highPassAt: highBandHz, sampleRate: sampleRate, q: 0.5412)
        var stage2 = Biquad(highPassAt: highBandHz, sampleRate: sampleRate, q: 1.3066)
        let window = Int(sampleRate * windowSeconds)
        guard window > 0 else { return }
        var run = 0, counted = 0
        var i = 0
        while i + window <= samples.count {
            var total = 0.0, high = 0.0
            for j in i..<(i + window) {
                let v = Double(samples[j])
                let o = stage2.step(stage1.step(v))
                total += v * v; high += o * o
            }
            i += window
            let rms = (total / Double(window)).squareRoot()
            guard rms >= Double(minJudgedRMS) else { run = 0; continue }
            let share = Float(high / (total + 1e-12))
            report.maxHighBandShare = max(report.maxHighBandShare, share)
            if share > maxHighBandShare {
                run += 1
                if run == noisyWindowsToFail { counted += run } else if run > noisyWindowsToFail { counted += 1 }
            } else {
                run = 0
            }
        }
        report.noisyWindows = counted
    }
}
