// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import Foundation

/// Cuts the silence a synthesizer puts around every sentence. Kokoro adds about 0.4 s before and 0.5 s after each
/// one, which delays the first sound of a reply, leaves almost a second of dead air between sentences and makes a
/// one-word acknowledgement occupy the speaker for over a second. A short, natural pause is kept instead.
public enum AudioTrim {
    public struct Settings: Sendable {
        /// Silence kept before the first sound.
        public var leadMs: Double = 30
        /// Silence kept after the last sound: the pause between sentences.
        public var tailMs: Double = 170
        /// Fade over the first and last few milliseconds, so the cut cannot click.
        public var fadeInMs: Double = 4
        public var fadeOutMs: Double = 12
        /// Sound counts as speech above this fraction of the loudest sample (never below the noise floor).
        public var relativeThreshold: Float = 0.02
        public var noiseFloor: Float = 0.004
        public init() {}
    }

    /// The trimmed samples, or the originals if there is no sound in them to measure.
    public static func trim(_ samples: [Float], sampleRate: Double, settings: Settings = Settings()) -> [Float] {
        guard samples.count > 1 else { return samples }
        let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
        guard peak > settings.noiseFloor else { return samples }
        let threshold = max(settings.noiseFloor, peak * settings.relativeThreshold)
        guard let first = samples.firstIndex(where: { abs($0) > threshold }),
              let last = samples.lastIndex(where: { abs($0) > threshold }) else { return samples }
        let lead = Int(settings.leadMs / 1000 * sampleRate), tail = Int(settings.tailMs / 1000 * sampleRate)
        let start = max(0, first - lead), end = min(samples.count, last + 1 + tail)
        guard end > start else { return samples }
        var out = Array(samples[start..<end])
        let fadeIn = min(out.count, Int(settings.fadeInMs / 1000 * sampleRate))
        let fadeOut = min(out.count, Int(settings.fadeOutMs / 1000 * sampleRate))
        for i in 0..<fadeIn { out[i] *= Float(i) / Float(fadeIn) }
        for i in 0..<fadeOut { out[out.count - 1 - i] *= Float(i) / Float(fadeOut) }
        return out
    }

    /// The same for a mono buffer.
    public static func trim(_ buffer: AVAudioPCMBuffer, settings: Settings = Settings()) -> AVAudioPCMBuffer {
        guard let data = buffer.floatChannelData, buffer.format.channelCount == 1, buffer.frameLength > 1 else { return buffer }
        let samples = Array(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
        let trimmed = trim(samples, sampleRate: buffer.format.sampleRate, settings: settings)
        guard trimmed.count != samples.count,
              let out = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: AVAudioFrameCount(trimmed.count)) else { return buffer }
        out.frameLength = AVAudioFrameCount(trimmed.count)
        trimmed.withUnsafeBufferPointer { out.floatChannelData![0].update(from: $0.baseAddress!, count: trimmed.count) }
        return out
    }
}
