// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Energy-based voice activity detector with an adaptive noise floor.
/// Platform-independent DSP so it can be unit-tested; the macOS audio layer
/// feeds it 16 kHz mono frames.
public struct VoiceActivityDetector: Sendable {
    public struct Config: Sendable {
        public var sampleRate: Double = 16_000
        /// Speech must be this far above the noise floor (dB).
        public var startThresholdDB: Float = 12
        /// Speech ends when energy drops below floor + this (dB).
        public var continueThresholdDB: Float = 7
        /// Absolute minimum level for speech (dBFS); ignores very quiet rooms' noise.
        public var minimumSpeechDBFS: Float = -50
        /// Speech must persist this long before `speechStarted` (barge-in confirmation).
        public var minSpeechDuration: TimeInterval = 0.18
        /// Silence after speech that ends the utterance.
        public var endSilence: TimeInterval = 0.65
        /// Hard cap on one utterance.
        public var maxUtterance: TimeInterval = 45
        /// Extra margin while our own voice is playing (echo that AEC missed).
        public var playbackPenaltyDB: Float = 6
        public init() {}
    }

    public enum Event: Sendable, Equatable {
        case speechStarted
        case speechEnded(duration: TimeInterval)
    }

    public var config: Config
    public private(set) var noiseFloorDB: Float = -60
    public private(set) var isSpeaking = false
    /// Set while TTS is playing so echo is less likely to count as speech.
    public var playbackActive = false

    private var candidateDuration: TimeInterval = 0
    private var silenceDuration: TimeInterval = 0
    private var speechDuration: TimeInterval = 0

    public init(config: Config = Config()) {
        self.config = config
    }

    public mutating func reset() {
        isSpeaking = false
        candidateDuration = 0
        silenceDuration = 0
        speechDuration = 0
    }

    /// Lets the user hold the conversation open ("keep listening") by stretching the endpoint.
    public mutating func setEndSilence(_ seconds: TimeInterval) {
        config.endSilence = max(0.2, seconds)
    }

    public static func levelDB(_ frame: [Float]) -> Float {
        guard !frame.isEmpty else { return -120 }
        var sum: Float = 0
        for s in frame { sum += s * s }
        let rms = (sum / Float(frame.count)).squareRoot()
        return 20 * log10(max(rms, 1e-7))
    }

    /// Processes one frame (typically 20–30 ms). Returns an event when state changes.
    public mutating func process(_ frame: [Float]) -> Event? {
        let level = VoiceActivityDetector.levelDB(frame)
        let dt = Double(frame.count) / config.sampleRate
        let penalty = playbackActive ? config.playbackPenaltyDB : 0

        if !isSpeaking {
            let isCandidate = level > noiseFloorDB + config.startThresholdDB + penalty && level > config.minimumSpeechDBFS
            if isCandidate {
                candidateDuration += dt
                if candidateDuration >= config.minSpeechDuration {
                    isSpeaking = true
                    speechDuration = candidateDuration
                    silenceDuration = 0
                    return .speechStarted
                }
            } else {
                candidateDuration = max(0, candidateDuration - dt)
                adaptFloor(level, rate: 0.05)
            }
            return nil
        }

        speechDuration += dt
        let stillSpeech = level > noiseFloorDB + config.continueThresholdDB + penalty / 2 && level > config.minimumSpeechDBFS - 6
        if stillSpeech {
            silenceDuration = 0
        } else {
            silenceDuration += dt
            adaptFloor(level, rate: 0.01)
        }
        if silenceDuration >= config.endSilence || speechDuration >= config.maxUtterance {
            let d = speechDuration - silenceDuration
            reset()
            return .speechEnded(duration: max(0, d))
        }
        return nil
    }

    private mutating func adaptFloor(_ level: Float, rate: Float) {
        // Track downward quickly, upward slowly.
        if level < noiseFloorDB {
            noiseFloorDB = noiseFloorDB + (level - noiseFloorDB) * 0.3
        } else {
            noiseFloorDB = noiseFloorDB + (level - noiseFloorDB) * rate
        }
        noiseFloorDB = min(max(noiseFloorDB, -90), -20)
    }
}
