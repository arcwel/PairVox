// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Puts a hands-free microphone to sleep after a stretch with no conversation, so PairVox does not keep listening to
/// a room nobody is talking to it in. Asleep, the microphone is muted until the user turns it back on.
///
/// Conversation means Claude thinking, working or speaking in any open project, or something the user did: sending a
/// message, pushing to talk, turning the microphone on. Sound the microphone heard that never became a message (a
/// television, a cough) does not count, or a noisy room would keep it awake for ever. The microphone is never put to
/// sleep while it is hearing or transcribing someone, so a long sentence is not cut off.
///
/// Time is read from the continuous clock, not the wall clock: setting the clock back (or an NTP correction) cannot
/// keep the microphone awake, and the time the Mac spent asleep still counts as quiet (audit run 9).
public struct MicHibernation: Sendable, Equatable {
    public typealias Instant = ContinuousClock.Instant

    /// The choices offered in Settings, in minutes. 0 means never.
    public static let minuteChoices = [0, 3, 5, 10, 30]
    public static let defaultMinutes = 3
    /// The longest the same unchanging phases count as conversation. A real conversation keeps moving between
    /// listening, thinking and speaking; a session hung in "working" would otherwise keep the microphone awake for
    /// ever (audit run 9).
    public static let maxUnchangedConversation: Duration = .seconds(20 * 60)

    public private(set) var lastActivity: Instant
    /// The phases seen at the last tick, and since when they have been the same.
    private var lastPhases: [EnginePhase] = []
    private var phasesSince: Instant

    public init(now: Instant = .now) {
        lastActivity = now
        phasesSince = now
    }

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
    public mutating func noteActivity(at now: Instant = .now) { lastActivity = max(lastActivity, now) }

    /// Called on a timer with every open project's phase. Notes activity when a conversation is going on, then says
    /// whether the microphone should go to sleep now.
    public mutating func tick(phases: [EnginePhase], handsFreeListening: Bool, minutes: Int, now: Instant = .now) -> Bool {
        if phases != lastPhases {
            lastPhases = phases
            phasesSince = now
        }
        if phases.contains(where: Self.isConversation), now - phasesSince <= Self.maxUnchangedConversation { noteActivity(at: now) }
        guard handsFreeListening, minutes > 0, !phases.contains(where: Self.isHearing) else { return false }
        return now - lastActivity >= .seconds(minutes * 60)
    }
}
