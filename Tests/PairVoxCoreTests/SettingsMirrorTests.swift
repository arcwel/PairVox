// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PairVoxCore

final class SettingsMirrorTests: XCTestCase {
    func snapshot(mode: SpeechMode = .skipCode, conversation: ConversationMode = .execute, rate: Double = 1.0) -> EngineSnapshot {
        var s = EngineSnapshot()
        s.speechMode = mode
        s.conversationMode = conversation
        s.speechRate = rate
        return s
    }

    /// The reviewed bug: a project with a "Summaries only" override sent the same value in its second snapshot, and
    /// it was written into General.
    func testAProjectsStartingOverrideNeverReachesGeneral() {
        var general = AppSettings()
        general.speechMode = .full
        let first = snapshot(mode: .summary)
        let second = snapshot(mode: .summary)
        XCTAssertNil(SettingsMirror.apply(previous: nil, current: first, to: general), "first snapshot")
        XCTAssertNil(SettingsMirror.apply(previous: first, current: second, to: general), "unchanged override")
    }

    func testAVoiceCommandIsCopied() {
        var general = AppSettings()
        general.speechMode = .full
        let before = snapshot(mode: .full)
        let after = snapshot(mode: .summary)
        XCTAssertEqual(SettingsMirror.apply(previous: before, current: after, to: general)?.speechMode, .summary)
    }

    func testRateAndConversationModeFollowTheSameRule() {
        let general = AppSettings()
        let before = snapshot(conversation: .execute, rate: 1.0)
        let after = snapshot(conversation: .brainstorm, rate: 1.2)
        let out = SettingsMirror.apply(previous: before, current: after, to: general)
        XCTAssertEqual(out?.conversationMode, .brainstorm)
        XCTAssertEqual(out?.speechRate ?? 0, 1.2, accuracy: 0.0001)
        XCTAssertNil(SettingsMirror.apply(previous: after, current: after, to: general), "no change, nothing copied")
    }

    func testAChangeGeneralAlreadyHasIsNotAWrite() {
        var general = AppSettings()
        general.speechMode = .summary
        XCTAssertNil(SettingsMirror.apply(previous: snapshot(mode: .full), current: snapshot(mode: .summary), to: general))
    }
}
