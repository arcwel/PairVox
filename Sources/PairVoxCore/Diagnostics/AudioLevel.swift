// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Brings every spoken sentence to the same loudness. The voice renders the same text at levels that differ by
/// 4 dB between calls, and across a session its peaks ranged from 0.26 to 0.92 (measured 2026-10-16, 200
/// sentences): one sentence whispers and the next shouts, which no listener accepts. The gain is set from the
/// loud part of the sentence (the RMS of its louder half of windows), bounded so a quiet aside is not blown up
/// into noise, and capped so the peak never exceeds `maxPeak`.
public enum AudioLevel {
    /// Target RMS of the speaking part, about -20 dBFS: the level the voice reaches on its own on a good render.
    public static let targetRMS: Float = 0.1
    public static let maxPeak: Float = 0.9
    public static let minGain: Float = 0.25
    public static let maxGain: Float = 3

    /// The gain that `normalize` would apply, or 1 for a buffer with no speaking part.
    public static func gain(for samples: UnsafeBufferPointer<Float>, sampleRate: Double) -> Float {
        let window = max(1, Int(sampleRate * 0.02))
        var rms: [Float] = []
        var i = 0
        while i + window <= samples.count {
            var sum: Float = 0
            for j in i..<(i + window) { sum += samples[j] * samples[j] }
            rms.append((sum / Float(window)).squareRoot())
            i += window
        }
        // The speaking part: windows above a tenth of the loudest one (the rest is the voice's own silence).
        guard let loudest = rms.max(), loudest > 0.002 else { return 1 }
        let speaking = rms.filter { $0 >= loudest * 0.1 }.sorted()
        guard !speaking.isEmpty else { return 1 }
        let upperHalf = speaking[(speaking.count / 2)...]
        let level = (upperHalf.reduce(0) { $0 + $1 * $1 } / Float(upperHalf.count)).squareRoot()
        guard level > 0 else { return 1 }
        var g = min(maxGain, max(minGain, targetRMS / level))
        var peak: Float = 0
        for v in samples { peak = max(peak, abs(v)) }
        if peak * g > maxPeak { g = maxPeak / peak }
        return g
    }

    /// Scales the samples in place; returns the gain applied.
    @discardableResult
    public static func normalize(_ samples: UnsafeMutableBufferPointer<Float>, sampleRate: Double) -> Float {
        let g = gain(for: UnsafeBufferPointer(samples), sampleRate: sampleRate)
        if g != 1 { for i in samples.indices { samples[i] *= g } }
        return g
    }
}
