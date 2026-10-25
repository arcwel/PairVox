// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PairVoxCore

final class HealthTests: XCTestCase {
    private func item(_ report: HealthReport, _ id: String) -> HealthItem? { report.items.first { $0.id == id } }

    func testAllWorkingIsReadyAndAnOffPartDoesNotCount() {
        var i = HealthInputs()
        i.recognizer = .whisperReady("small.en")
        let r = HealthReport.evaluate(i)
        XCTAssertEqual(r.overall, .ok)
        XCTAssertEqual(r.summary, "Ready")
        XCTAssertTrue(r.problems.isEmpty)
        XCTAssertEqual(item(r, "phone")?.status, .off, "the phone link is off and that is fine")
    }

    func testTheWorstPartSetsTheWholeAndEachProblemHasItsFix() {
        var i = HealthInputs()
        i.recognizer = .whisperReady("small.en")
        i.voice = .missing
        var r = HealthReport.evaluate(i)
        XCTAssertEqual(r.overall, .limited)
        XCTAssertEqual(r.summary, "Limited")
        XCTAssertEqual(item(r, "voice")?.fix, .downloadVoice)
        i.microphone = .denied
        r = HealthReport.evaluate(i)
        XCTAssertEqual(r.overall, .broken)
        XCTAssertEqual(r.summary, "Not working")
        XCTAssertEqual(item(r, "microphone")?.fix, .openMicrophonePrivacy)
        XCTAssertEqual(r.problems.count, 2)
    }

    func testEveryStateMapsToARowWithTheRightFix() {
        var i = HealthInputs()
        i.microphone = .notDetermined
        i.claudeFound = false
        i.recognizer = .whisperFailed("no model")
        i.echo = .off
        i.phone = .waiting(paired: 0)
        i.audioRunning = false
        let r = HealthReport.evaluate(i)
        XCTAssertEqual(item(r, "microphone")?.fix, .requestMicrophone)
        XCTAssertEqual(item(r, "claude")?.fix, .chooseClaude)
        XCTAssertEqual(item(r, "recognizer")?.fix, .retrySpeechModel)
        XCTAssertEqual(item(r, "echo")?.fix, .turnOnEchoCancellation)
        XCTAssertEqual(item(r, "phone")?.fix, .pairPhone)
        XCTAssertEqual(item(r, "audio")?.fix, .restartAudio)
        var signedOut = HealthInputs()
        signedOut.authProblem = "Claude Code is not logged in."
        XCTAssertEqual(item(HealthReport.evaluate(signedOut), "claude")?.fix, .signInToClaude)
        var apple = HealthInputs()
        apple.recognizer = .appleSpeech
        apple.speechPermission = .denied
        XCTAssertEqual(item(HealthReport.evaluate(apple), "recognizer")?.fix, .openSpeechPrivacy)
        XCTAssertTrue(HealthFix.allCases.allSatisfy { !$0.label.isEmpty })
    }
}
