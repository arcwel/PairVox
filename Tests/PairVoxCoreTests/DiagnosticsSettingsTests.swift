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
