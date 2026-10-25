// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Puts a hands-free microphone to sleep after a stretch with no conversation, so PairVox does not keep listening to
/// a room nobody is talking to it in. Asleep, the microphone is muted until the user turns it back on.
///
/// Conversation means Claude thinking, working or speaking in any open project, or something the user did: sending a
/// message, pushing to talk, turning the microphone on. Sound the microphone heard that never became a message (a
/// television, a cough) does not count, or a noisy room would keep it awake for ever. The microphone is never put to
/// sleep while it is hearing or transcribing someone, so a long sentence is not cut off.
public struct MicHibernation: Sendable, Equatable {
    /// The choices offered in Settings, in minutes. 0 means never.
    public static let minuteChoices = [0, 3, 5, 10, 30]
    public static let defaultMinutes = 3

    public private(set) var lastActivity: Date

    public init(now: Date = Date()) { lastActivity = now }

    /// Phases in which a conversation is going on.
    public static func isConversation(_ phase: EnginePhase) -> Bool {
        switch phase {
        case .starting, .thinking, .working, .speaking: return true
        case .idle, .listening, .transcribing, .awaitingPermission, .needsSetup: return false
        }
    }

    /// Phases in which someone may be talking right now.
    static func isHearing(_ phase: EnginePhase) -> Bool { phase == .listening || phase == .transcribing }

    /// The user did something, or a conversation is going on: the idle clock starts again.
    public mutating func noteActivity(at now: Date = Date()) { lastActivity = max(lastActivity, now) }

    /// Called on a timer with every open project's phase. Notes activity when a conversation is going on, then says
    /// whether the microphone should go to sleep now.
    public mutating func tick(phases: [EnginePhase], handsFreeListening: Bool, minutes: Int, now: Date = Date()) -> Bool {
        if phases.contains(where: Self.isConversation) { noteActivity(at: now) }
        guard handsFreeListening, minutes > 0, !phases.contains(where: Self.isHearing) else { return false }
        return now.timeIntervalSince(lastActivity) >= TimeInterval(minutes * 60)
    }
}
