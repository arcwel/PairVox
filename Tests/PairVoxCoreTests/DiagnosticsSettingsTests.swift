// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PairVoxCore

final class DiagnosticsSettingsTests: XCTestCase {
    func testPrivacySensitiveOptionsAreOffByDefault() {
        let s = AppSettings()
        XCTAssertFalse(s.logConversationText)
        XCTAssertFalse(s.recordPlaybackAudio)
        XCTAssertFalse(s.verboseLogging)
        XCTAssertTrue(s.echoCancellation)
        XCTAssertNil(s.outputDeviceUID, "automatic output by default")
        XCTAssertTrue(s.microphoneEnabled, "an old settings file keeps the microphone on")
        XCTAssertFalse(s.separateAudioEngines, "the experimental mode is opt-in")
    }

    func testChosenOutputDeviceRoundTrips() throws {
        var s = AppSettings()
        s.outputDeviceUID = "34-0E-22-3D-4E-B4:output"
        let back = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back.outputDeviceUID, "34-0E-22-3D-4E-B4:output")
    }

    func testSettingsFileFromBeforeDiagnosticsStillLoadsWithSafeDefaults() throws {
        let old = #"{"speechMode":"summary","kokoroVoice":"bf_emma","handsFree":false}"#
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(old.utf8))
        XCTAssertEqual(s.speechMode, .summary)
        XCTAssertEqual(s.kokoroVoice, "bf_emma")
        XCTAssertFalse(s.handsFree)
        XCTAssertFalse(s.logConversationText)
        XCTAssertFalse(s.recordPlaybackAudio)
        XCTAssertTrue(s.echoCancellation)
    }

    func testDiagnosticsOptionsRoundTrip() throws {
        var s = AppSettings()
        s.verboseLogging = true
        s.logConversationText = true
        s.recordPlaybackAudio = true
        s.echoCancellation = false
        let back = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back, s)
    }
}

final class NewSettingsFieldTests: XCTestCase {
    func testOldSettingsFilesGetTheDefaultsForTheNewFields() throws {
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(decoded.spokenReplyLimit, 15)
        XCTAssertTrue(decoded.captureFeedbackAudio)
        XCTAssertTrue(decoded.trimSentenceSilence, "old settings files get the faster behaviour")
    }

    func testNewFieldsSurviveASaveAndLoad() throws {
        var settings = AppSettings()
        settings.spokenReplyLimit = 25
        settings.captureFeedbackAudio = false
        settings.trimSentenceSilence = false
        let back = try JSONDecoder().decode(AppSettings.self, from: try JSONEncoder().encode(settings))
        XCTAssertEqual(back.spokenReplyLimit, 25)
        XCTAssertFalse(back.captureFeedbackAudio)
        XCTAssertFalse(back.trimSentenceSilence)
    }

    func testANegativeReplyLimitIsTreatedAsNoLimit() throws {
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"spokenReplyLimit": -4}"#.utf8))
        XCTAssertEqual(decoded.spokenReplyLimit, 0)
    }

    func testTheSettingsReachTheEngineConfiguration() {
        var settings = AppSettings()
        settings.spokenReplyLimit = 10
        XCTAssertEqual(EngineConfiguration(settings: settings, project: nil).spokenReplyLimit, 10)
    }
}
