// SPDX-License-Identifier: Apache-2.0

import Foundation
import XCTest
@testable import PairVoxCore

final class MicHibernationTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    func testSleepsAfterThreeQuietMinutes() {
        var h = MicHibernation(now: start)
        XCTAssertFalse(h.tick(phases: [.idle], handsFreeListening: true, minutes: 3, now: at(179)))
        XCTAssertTrue(h.tick(phases: [.idle], handsFreeListening: true, minutes: 3, now: at(180)))
    }

    func testAWaitingRequestDoesNotKeepTheMicrophoneAwake() {
        var h = MicHibernation(now: start)
        XCTAssertTrue(h.tick(phases: [.awaitingPermission], handsFreeListening: true, minutes: 3, now: at(181)))
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
}
