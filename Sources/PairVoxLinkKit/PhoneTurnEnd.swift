// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Decides when a hands-free utterance on the phone is over. The phone used to end it 1.2 s after the recognizer last
/// changed its text, and that text lags the voice, so a short pause to think sent half a sentence to Claude and the
/// rest came through as a second message (2026-10-28: "Pair box but basically it's a conversation that", then "Your
/// computer"). Now the turn ends after `silence` with neither new words nor a voice-loud sound, the Mac's default end
/// of turn, and a steady noise cannot hold it open: with no new words for `noWordsLimit` it ends anyway.
public struct PhoneTurnEnd: Sendable, Equatable {
    /// The Mac's default end-of-turn silence (Settings, General, Listening).
    public static let silence: TimeInterval = 1.5
    public static let noWordsLimit: TimeInterval = 4
    /// A sound this far above the room's quiet level counts as someone talking.
    public static let voiceMarginDB: Float = 10
    /// Never counted as talking below this level.
    public static let voiceMinimumDB: Float = -50
    /// How fast the quiet level follows a louder room, so speech itself does not become the new quiet.
    public static let floorRisePerSecond: Float = 1

    public let silence: TimeInterval
    private var lastWords: TimeInterval?
    private var lastVoice: TimeInterval?
    private var floorDB: Float?
    private var lastLevelAt: TimeInterval?

    public init(silence: TimeInterval = PhoneTurnEnd.silence) { self.silence = silence }

    /// The recognizer's text changed.
    public mutating func heardWords(at now: TimeInterval) { lastWords = now }

    /// The microphone's level, a few times a second.
    public mutating func heardLevel(_ db: Float, at now: TimeInterval) {
        if let floor = floorDB, let then = lastLevelAt {
            floorDB = db < floor ? db : min(db, floor + Self.floorRisePerSecond * Float(now - then))
        } else {
            floorDB = db
        }
        lastLevelAt = now
        if isVoice(db) { lastVoice = now }
    }

    func isVoice(_ db: Float) -> Bool { db >= max((floorDB ?? db) + Self.voiceMarginDB, Self.voiceMinimumDB) }

    /// True once the person has said something and then stopped. Before any words, the recognizer's own error or
    /// the person muting ends the listen.
    public func isOver(at now: TimeInterval) -> Bool {
        guard let words = lastWords else { return false }
        if now - words >= Self.noWordsLimit { return true }
        return now - max(words, lastVoice ?? words) >= silence
    }
}
