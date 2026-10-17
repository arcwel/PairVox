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
        /// While our voice plays, speech must also stand this far above the echo we expect to hear (the playback
        /// level plus the learned coupling between speaker and microphone).
        public var echoMarginDB: Float = 6
        /// Where the coupling estimate starts: the microphone hears the speaker this far below its level. High, so a
        /// session starts safe and learns the real value from the first moments of echo.
        public var initialCouplingDB: Float = -20
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
    /// The loudest recent level of what the speaker is playing (dBFS), when the caller knows it. With it the detector
    /// learns how loudly the microphone hears the speaker and ignores that much sound. Nil leaves the old behaviour.
    public var playbackLevelDB: Float?
    /// How far below the speaker's level the microphone hears it, as an upper envelope of echo-only frames.
    public private(set) var couplingDB: Float

    private var candidateDuration: TimeInterval = 0
    private var silenceDuration: TimeInterval = 0
    private var speechDuration: TimeInterval = 0

    public init(config: Config = Config()) {
        self.config = config
        self.couplingDB = config.initialCouplingDB
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
        // What the microphone should hear of our own voice right now.
        let echoCeiling: Float? = playbackActive ? playbackLevelDB.map { $0 + couplingDB + config.echoMarginDB } : nil

        if !isSpeaking {
            var isCandidate = level > noiseFloorDB + config.startThresholdDB + penalty && level > config.minimumSpeechDBFS
            var rejectedAsEcho = false
            if isCandidate, let ceiling = echoCeiling, level <= ceiling { isCandidate = false; rejectedAsEcho = true }
            if !isCandidate, candidateDuration == 0, let reference = playbackLevelDB, playbackActive, level > config.minimumSpeechDBFS - 10 {
                learnCoupling(micLevel: level, playbackLevel: reference)
            }
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
                // Echo that was recognised as our own voice says nothing about the room's noise: leaving it out keeps
                // the floor from rising to the echo level and deafening the detector once the speaker stops.
                if !rejectedAsEcho { adaptFloor(level, rate: 0.05) }
            }
            return nil
        }

        speechDuration += dt
        var stillSpeech = level > noiseFloorDB + config.continueThresholdDB + penalty / 2 && level > config.minimumSpeechDBFS - 6
        // An utterance that began over our own voice only goes on while it is clearly above the echo.
        if stillSpeech, let ceiling = echoCeiling, level <= ceiling - 3 { stillSpeech = false }
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

    /// Echo-only frames set how loud the speaker sounds in the microphone: up quickly, down slowly.
    private mutating func learnCoupling(micLevel: Float, playbackLevel: Float) {
        let observed = micLevel - playbackLevel
        if observed > couplingDB {
            couplingDB += (observed - couplingDB) * 0.25
        } else {
            couplingDB += (observed - couplingDB) * 0.01
        }
        couplingDB = min(max(couplingDB, -80), -6)
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
