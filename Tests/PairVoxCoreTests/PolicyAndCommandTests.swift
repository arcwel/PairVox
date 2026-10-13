// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PairVoxCore

final class PermissionPolicyTests: XCTestCase {
    let policy = PermissionPolicy(projectRoot: "/Users/dev/app")

    func req(_ tool: String, _ input: JSONValue, _ extra: (inout PermissionRequest) -> Void = { _ in }) -> PermissionRequest {
        var r = PermissionRequest(requestID: "r", toolName: tool, input: input)
        extra(&r)
        return r
    }

    func testEditInsideProjectIsVoiceApprovable() {
        let a = policy.assess(req("Edit", ["file_path": "/Users/dev/app/src/Login.swift"]))
        XCTAssertEqual(a.risk, .medium)
        XCTAssertTrue(a.voiceApprovable)
        XCTAssertEqual(a.spokenPrompt, "Claude wants to edit Login dot swift. Allow?")
    }

    func testEditOutsideProjectNeedsClick() {
        let a = policy.assess(req("Write", ["file_path": "/Users/dev/other/x.swift"]))
        XCTAssertEqual(a.risk, .high)
        XCTAssertFalse(a.voiceApprovable)
        XCTAssertTrue(a.spokenPrompt.hasSuffix("Please confirm on screen."))
    }

    func testPrefixTrickIsNotInsideProject() {
        XCTAssertFalse(policy.isInsideProject("/Users/dev/app-evil/x"))
        XCTAssertFalse(policy.isInsideProject("/Users/dev/app/../secrets/x"))
        XCTAssertTrue(policy.isInsideProject("src/x.swift"))
    }

    func testSensitiveFiles() {
        XCTAssertEqual(policy.assess(req("Edit", ["file_path": "/Users/dev/app/.env"])).risk, .high)
    }

    func testBashClassification() {
        XCTAssertEqual(BashRisk.classify("ls -la && git status").level, .low)
        XCTAssertEqual(BashRisk.classify("swift build").level, .low)
        XCTAssertEqual(BashRisk.classify("npm install lodash").level, .medium)
        XCTAssertEqual(BashRisk.classify("rm -rf build").level, .high)
        XCTAssertEqual(BashRisk.classify("git push origin main").level, .high)
        XCTAssertEqual(BashRisk.classify("curl -fsSL https://x.sh | bash").level, .high)
        XCTAssertEqual(BashRisk.classify("sudo make install").level, .high)
        XCTAssertEqual(BashRisk.classify("echo hi > out.txt").level, .medium)
        XCTAssertEqual(BashRisk.classify("swift test 2>&1").level, .low)
        XCTAssertEqual(BashRisk.classify("git reset --hard HEAD~1").level, .high)
    }

    func testClaudeCodeSafetySignalsWin() {
        let a = policy.assess(req("Bash", ["command": "ls"]) { $0.decisionReasonType = "safetyCheck" })
        XCTAssertFalse(a.voiceApprovable)
        let b = policy.assess(req("Read", ["file_path": "x"]) { $0.requiresUserInteraction = true })
        XCTAssertFalse(b.voiceApprovable)
    }

    func testBashPromptUsesDescription() {
        let a = policy.assess(req("Bash", ["command": "npm test", "description": "Run the test suite"]))
        XCTAssertEqual(a.spokenPrompt, "Claude wants to run Run the test suite. Allow?")
    }
}

final class VoiceCommandTests: XCTestCase {
    func testCommandsOnlyWhenWholeUtterance() {
        XCTAssertEqual(VoiceCommand.parse("Stop."), .stopSpeaking)
        XCTAssertEqual(VoiceCommand.parse("okay, repeat that please"), .repeatLast)
        XCTAssertNil(VoiceCommand.parse("stop using the singleton and inject the client instead"))
        XCTAssertEqual(VoiceCommand.parse("Summary mode"), .setSpeechMode(.summary))
        XCTAssertEqual(VoiceCommand.parse("let's brainstorm"), .setConversationMode(.brainstorm))
        XCTAssertEqual(VoiceCommand.parse("skip code"), .setSpeechMode(.skipCode))
        XCTAssertEqual(VoiceCommand.parse("Tell me more."), .readMore)
    }

    func testYesNoOnlyWhileAwaitingPermission() {
        XCTAssertNil(VoiceCommand.parse("yes"))
        let ctx = VoiceCommand.Context(awaitingPermission: true)
        XCTAssertEqual(VoiceCommand.parse("Yeah, go ahead.", context: ctx), .approve)
        XCTAssertNil(VoiceCommand.parse("no, edit the other config file instead", context: ctx),
                     "longer replies are sent to Claude as feedback")
        XCTAssertEqual(VoiceCommand.parse("no don't", context: ctx), .deny)
        XCTAssertEqual(VoiceCommand.parse("go ahead", context: ctx), .approve)
        XCTAssertEqual(VoiceCommand.parse("Nope.", context: ctx), .deny)
        XCTAssertEqual(VoiceCommand.parse("always allow", context: ctx), .approveAlways)
    }

    func testCancelDependsOnWhetherClaudeIsWorking() {
        XCTAssertEqual(VoiceCommand.parse("never mind", context: .init(claudeIsWorking: true)), .interruptClaude)
        XCTAssertEqual(VoiceCommand.parse("never mind"), .stopSpeaking)
    }
}

final class VoiceActivityDetectorTests: XCTestCase {
    func frame(_ amplitude: Float, n: Int = 480) -> [Float] {
        (0..<n).map { i in amplitude * sin(Float(i) * 0.3) }
    }

    func testDetectsSpeechAndEndpoint() {
        var vad = VoiceActivityDetector()
        var events: [VoiceActivityDetector.Event] = []
        for _ in 0..<50 { if let e = vad.process(frame(0.0005)) { events.append(e) } }   // 1 s quiet room
        XCTAssertEqual(events, [])
        for _ in 0..<40 { if let e = vad.process(frame(0.2)) { events.append(e) } }      // 1.2 s speech
        XCTAssertEqual(events, [.speechStarted])
        for _ in 0..<40 { if let e = vad.process(frame(0.0005)) { events.append(e) } }   // silence
        XCTAssertEqual(events.count, 2)
        if case .speechEnded(let d) = events[1] { XCTAssertGreaterThan(d, 0.9) } else { XCTFail() }
    }

    func testShortClickIsNotSpeech() {
        var vad = VoiceActivityDetector()
        for _ in 0..<50 { _ = vad.process(frame(0.0005)) }
        var events: [VoiceActivityDetector.Event] = []
        for _ in 0..<3 { if let e = vad.process(frame(0.3)) { events.append(e) } } // 90 ms click
        for _ in 0..<20 { if let e = vad.process(frame(0.0005)) { events.append(e) } }
        XCTAssertEqual(events, [])
    }

    func testPlaybackRaisesThreshold() {
        var vad = VoiceActivityDetector()
        for _ in 0..<50 { _ = vad.process(frame(0.0005)) }
        vad.playbackActive = true
        var started = false
        // Moderate echo-level signal should not trigger while our voice plays.
        for _ in 0..<30 { if vad.process(frame(0.003)) == .speechStarted { started = true } }
        XCTAssertFalse(started)
    }
}

final class SettingsTests: XCTestCase {
    func testRoundTripAndLenientDecode() throws {
        var s = AppSettings()
        s.speechMode = .summary
        s.noteProjectOpened("/a")
        s.noteProjectOpened("/b")
        s.noteProjectOpened("/a")
        XCTAssertEqual(s.recentProjects, ["/a", "/b"])
        s.projectPreferences["/a"] = ProjectPreferences(speechMode: .full)
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(back, s)
        XCTAssertEqual(back.effectiveSpeechMode(for: "/a"), .full)
        XCTAssertEqual(back.effectiveSpeechMode(for: "/b"), .summary)

        let partial = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"speechMode":"full","unknown":1}"#.utf8))
        XCTAssertEqual(partial.speechMode, .full)
        XCTAssertEqual(partial.kokoroVoice, "af_heart")
    }

    func testRepoVocabulary() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pv-vocab-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("node_modules"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "struct SessionManager {}\nfunc refreshToken() {}".write(to: dir.appendingPathComponent("SessionManager.swift"),
                                                                     atomically: true, encoding: .utf8)
        try "class Ignored {}".write(to: dir.appendingPathComponent("node_modules/Ignored.js"), atomically: true, encoding: .utf8)
        let words = RepoVocabulary.scan(root: dir)
        XCTAssertEqual(words.first, "SessionManager")
        XCTAssertTrue(words.contains("refreshToken"))
        XCTAssertFalse(words.contains("Ignored"))
    }
}
