// SPDX-License-Identifier: Apache-2.0

import Foundation
import XCTest
@testable import PairVoxCore

final class MicHibernationTests: XCTestCase {
    // The continuous clock, as the app uses: the wall clock can be set back, this one cannot (audit run 9).
    private let start = ContinuousClock.now

    private func at(_ seconds: Double) -> MicHibernation.Instant { start.advanced(by: .seconds(seconds)) }

    func testSleepsAfterThreeQuietMinutes() {
        var h = MicHibernation(now: start)
        XCTAssertFalse(h.tick(phases: [.idle], handsFreeListening: true, minutes: 3, now: at(179)))
        XCTAssertTrue(h.tick(phases: [.idle], handsFreeListening: true, minutes: 3, now: at(180)))
    }

    // Stability audit 2026-10-26: the microphone slept while the card was being read, so the spoken yes was lost.
    // A waiting request keeps it awake for as long as a spoken answer can count (five minutes), not for ever.
    func testAWaitingRequestKeepsTheMicrophoneAwakeOnlyWhileAnAnswerCanCount() {
        var h = MicHibernation(now: start)
        for t in stride(from: 0.0, through: 300, by: 5) {
            XCTAssertFalse(h.tick(phases: [.awaitingPermission], handsFreeListening: true, minutes: 3, now: at(t)), "\(t)")
        }
        XCTAssertFalse(h.tick(phases: [.awaitingPermission], handsFreeListening: true, minutes: 3, now: at(450)))
        XCTAssertTrue(h.tick(phases: [.awaitingPermission], handsFreeListening: true, minutes: 3, now: at(481)),
                      "three quiet minutes after the request went stale")
    }

    func testClaudeWorkingInAnyProjectRestartsTheClock() {
        var h = MicHibernation(now: start)
        XCTAssertFalse(h.tick(phases: [.idle, .working], handsFreeListening: true, minutes: 3, now: at(170)))
        XCTAssertFalse(h.tick(phases: [.idle, .idle], handsFreeListening: true, minutes: 3, now: at(300)))
        XCTAssertTrue(h.tick(phases: [.idle, .idle], handsFreeListening: true, minutes: 3, now: at(350)))
    }

    func testSpeakingAndThinkingCountAsConversation() {
        for phase in [EnginePhase.starting, .thinking, .working, .speaking] {
            XCTAssertTrue(MicHibernation.isConversation(phase), "\(phase)")
        }
        for phase in [EnginePhase.idle, .listening, .transcribing, .awaitingPermission, .needsSetup] {
            XCTAssertFalse(MicHibernation.isConversation(phase), "\(phase)")
        }
    }

    func testNoiseThatNeverBecameAMessageDoesNotKeepItAwake() {
        var h = MicHibernation(now: start)
        _ = h.tick(phases: [.listening], handsFreeListening: true, minutes: 3, now: at(100))
        XCTAssertEqual(h.lastActivity, start)
        XCTAssertTrue(h.tick(phases: [.idle], handsFreeListening: true, minutes: 3, now: at(181)))
    }

    func testNeverSleepsWhileSomeoneIsTalking() {
        var h = MicHibernation(now: start)
        XCTAssertFalse(h.tick(phases: [.listening], handsFreeListening: true, minutes: 3, now: at(400)))
        XCTAssertFalse(h.tick(phases: [.idle, .transcribing], handsFreeListening: true, minutes: 3, now: at(401)))
    }

    func testAUserActionRestartsTheClock() {
        var h = MicHibernation(now: start)
        h.noteActivity(at: at(150))
        XCTAssertFalse(h.tick(phases: [.idle], handsFreeListening: true, minutes: 3, now: at(300)))
        XCTAssertTrue(h.tick(phases: [.idle], handsFreeListening: true, minutes: 3, now: at(330)))
    }

    func testAnEarlierActivityNeverMovesTheClockBack() {
        var h = MicHibernation(now: at(100))
        h.noteActivity(at: at(50))
        XCTAssertEqual(h.lastActivity, at(100))
    }

    // Audit run 9: a session hung in "working" kept a hands-free microphone listening to the room for ever.
    func testTheSamePhasesStopCountingAsConversationAfterTwentyMinutes() {
        var h = MicHibernation(now: start)
        let cap = Double(MicHibernation.maxUnchangedConversation.components.seconds)
        var t = 0.0
        while t <= cap {
            XCTAssertFalse(h.tick(phases: [.idle, .working], handsFreeListening: true, minutes: 3, now: at(t)), "\(t)")
            t += 5
        }
        XCTAssertFalse(h.tick(phases: [.idle, .working], handsFreeListening: true, minutes: 3, now: at(cap + 179)))
        XCTAssertTrue(h.tick(phases: [.idle, .working], handsFreeListening: true, minutes: 3, now: at(cap + 181)),
                      "three quiet minutes after the hung phase stopped counting")
    }

    func testAConversationThatKeepsMovingStaysAwakePastTheCap() {
        var h = MicHibernation(now: start)
        let cycle: [[EnginePhase]] = [[.thinking], [.working], [.speaking], [.idle]]
        var t = 0.0
        while t <= 3600 {
            XCTAssertFalse(h.tick(phases: cycle[Int(t / 30) % cycle.count], handsFreeListening: true, minutes: 3, now: at(t)), "\(t)")
            t += 5
        }
    }

    func testOnlyAHandsFreeMicrophoneSleeps() {
        var h = MicHibernation(now: start)
        XCTAssertFalse(h.tick(phases: [.idle], handsFreeListening: false, minutes: 3, now: at(3600)))
    }

    func testZeroMinutesMeansNever() {
        var h = MicHibernation(now: start)
        XCTAssertFalse(h.tick(phases: [.idle], handsFreeListening: true, minutes: 0, now: at(86_400)))
    }

    func testTheSettingDefaultsToThreeMinutesAndSurvivesOldFiles() throws {
        XCTAssertEqual(AppSettings().micSleepMinutes, 3)
        let old = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"handsFree": true}"#.utf8))
        XCTAssertEqual(old.micSleepMinutes, 3)
        let off = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"micSleepMinutes": 0}"#.utf8))
        XCTAssertEqual(off.micSleepMinutes, 0)
        let odd = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"micSleepMinutes": 7}"#.utf8))
        XCTAssertEqual(odd.micSleepMinutes, 3, "a value Settings does not offer falls back to the default")
    }

    // 2026-10-25: a 0.65 s pause ended the turn mid-sentence. Old short values move to 1.5 s; longer ones are kept.
    func testTheEndOfTurnSilenceIsAtLeastOneSecond() throws {
        XCTAssertEqual(AppSettings().endOfTurnSilence, 1.5)
        let old = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"endOfTurnSilence": 0.65}"#.utf8))
        XCTAssertEqual(old.endOfTurnSilence, 1.5)
        let chosen = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"endOfTurnSilence": 2.0}"#.utf8))
        XCTAssertEqual(chosen.endOfTurnSilence, 2.0)
    }
}
