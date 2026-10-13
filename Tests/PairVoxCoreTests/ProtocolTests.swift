// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PairVoxCore

/// Replays a real Claude Code 2.1.296 stream-json session (captured live; paths sanitised):
/// T1 text + code, T2 Write permission, T3 interrupt mid-stream, T4 follow-up, T5 interrupt during permission.
final class ProtocolTests: XCTestCase {
    func fixtureLines() throws -> [String] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "claude-2.1.296-session", withExtension: "jsonl",
                                                  subdirectory: "Fixtures"))
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
    }

    func testEveryLineParses() throws {
        let lines = try fixtureLines()
        XCTAssertGreaterThan(lines.count, 100)
        var unknown = 0
        for line in lines {
            let msg = try InboundMessage.parse(line: line)
            if case .unknown = msg { unknown += 1 }
        }
        XCTAssertEqual(unknown, 0)
    }

    func testTranslatedSessionMatchesWhatHappened() throws {
        var translator = EventTranslator()
        var events: [SessionEvent] = []
        for line in try fixtureLines() {
            events += translator.translate(try InboundMessage.parse(line: line))
        }
        let started = events.filter { if case .started = $0 { return true }; return false }
        XCTAssertEqual(started.count, 1, "init is re-sent each turn but should be announced once")

        let outcomes: [TurnResult.Outcome] = events.compactMap {
            if case .turnCompleted(let r) = $0 { return r.outcome }
            return nil
        }
        XCTAssertEqual(outcomes, [.success, .success, .interrupted, .success, .interrupted])

        let permissions: [PermissionRequest] = events.compactMap {
            if case .permissionRequested(let p) = $0 { return p }
            return nil
        }
        XCTAssertEqual(permissions.map(\.toolName), ["Write", "Bash"])
        XCTAssertEqual(permissions.first?.input["file_path"]?.stringValue, "/Users/dev/project/note.txt")
        XCTAssertNotNil(permissions.first?.suggestions)

        let cancels = events.filter { if case .permissionCancelled = $0 { return true }; return false }
        XCTAssertEqual(cancels.count, 1, "interrupting during a permission prompt cancels it")

        let tools: [String] = events.compactMap { if case .toolUse(let t) = $0 { return t.name }; return nil }
        XCTAssertEqual(tools, ["Write", "Bash"])
    }

    func testStreamedTextIsNotDuplicatedByAssistantMessage() throws {
        var translator = EventTranslator()
        var firstTurnText = ""
        var finalResult: String?
        for line in try fixtureLines() {
            for e in translator.translate(try InboundMessage.parse(line: line)) {
                if case .textDelta(let t) = e, finalResult == nil { firstTurnText += t }
                if case .turnCompleted(let r) = e, finalResult == nil { finalResult = r.finalText }
            }
            if finalResult != nil { break }
        }
        XCTAssertEqual(firstTurnText, finalResult)
        XCTAssertTrue(firstTurnText.contains("```python"))
    }

    func testAssistantTextWithoutStreamingIsEmitted() {
        var t = EventTranslator()
        let msg = AssistantMessage(messageID: "m1", content: [.text("Hello there.")])
        XCTAssertEqual(t.translate(.assistant(msg)), [.textDelta("Hello there."), .textBlockEnded])
    }

    func testSubagentTextIsIgnoredButToolsAreFlagged() {
        var t = EventTranslator()
        XCTAssertEqual(t.translate(.streamEvent(.contentBlockDelta(index: 0, delta: .text("x")), parentToolUseID: "toolu_1")), [])
        let msg = AssistantMessage(messageID: "m2", content: [.text("sub"), .toolUse(id: "t", name: "Read", input: [:])],
                                   parentToolUseID: "toolu_1")
        XCTAssertEqual(t.translate(.assistant(msg)), [.toolUse(ToolUse(id: "t", name: "Read", input: [:], isSubagent: true))])
    }

    func testAuthErrorsSurface() {
        var t = EventTranslator()
        let msg = AssistantMessage(messageID: "m", content: [.text("Invalid API key · Please run /login")],
                                   error: "authentication_failed")
        let events = t.translate(.assistant(msg))
        XCTAssertEqual(events.first, .authProblem("authentication_failed"))
    }

    func testInterruptPendingMarksResultInterrupted() throws {
        var t = EventTranslator()
        t.interruptPending = true
        let r = try InboundMessage.parse(line: #"{"type":"result","subtype":"error_during_execution","is_error":true,"session_id":"s","errors":["boom"]}"#)
        guard case .turnCompleted(let result)? = t.translate(r).last else { return XCTFail() }
        XCTAssertEqual(result.outcome, .interrupted)
        XCTAssertFalse(t.interruptPending)
    }

    func testRealErrorIsFailure() throws {
        var t = EventTranslator()
        let r = try InboundMessage.parse(line: #"{"type":"result","subtype":"error_max_turns","is_error":true,"session_id":"s","errors":["Reached max turns"]}"#)
        guard case .turnCompleted(let result)? = t.translate(r).last else { return XCTFail() }
        XCTAssertEqual(result.outcome, .failed("Reached max turns"))
    }

    // MARK: Outbound

    func testUserMessageShape() throws {
        let v = try JSONValue.parse(OutboundMessage.userText("Fix the \"login\" bug"))
        XCTAssertEqual(v["type"], "user")
        XCTAssertEqual(v["message"]?["role"], "user")
        XCTAssertEqual(v["message"]?["content"], "Fix the \"login\" bug")
        XCTAssertEqual(v["parent_tool_use_id"], .null)
        XCTAssertEqual(OutboundMessage.userText("x").last, 0x0A)
    }

    func testPermissionResponses() throws {
        let req = PermissionRequest(requestID: "r1", toolName: "Write", input: ["file_path": "a.txt", "content": "hi"],
                                    suggestions: [["type": "setMode", "mode": "acceptEdits", "destination": "session"]])
        let allow = try JSONValue.parse(OutboundMessage.permissionResponse(for: req, decision: .allow))
        XCTAssertEqual(allow["type"], "control_response")
        XCTAssertEqual(allow["response"]?["subtype"], "success")
        XCTAssertEqual(allow["response"]?["request_id"], "r1")
        XCTAssertEqual(allow["response"]?["response"]?["behavior"], "allow")
        XCTAssertEqual(allow["response"]?["response"]?["updatedInput"]?["file_path"], "a.txt")
        XCTAssertNil(allow["response"]?["response"]?["updatedPermissions"])

        let always = try JSONValue.parse(OutboundMessage.permissionResponse(for: req, decision: .allowAlways))
        XCTAssertEqual(always["response"]?["response"]?["updatedPermissions"]?[0]?["mode"], "acceptEdits")

        let deny = try JSONValue.parse(OutboundMessage.permissionResponse(for: req, decision: .deny(message: "no", interrupt: true)))
        XCTAssertEqual(deny["response"]?["response"]?["behavior"], "deny")
        XCTAssertEqual(deny["response"]?["response"]?["message"], "no")
        XCTAssertEqual(deny["response"]?["response"]?["interrupt"], true)
    }

    func testInterruptAndModeRequests() throws {
        let i = try JSONValue.parse(OutboundMessage.interrupt(requestID: "x"))
        XCTAssertEqual(i["type"], "control_request")
        XCTAssertEqual(i["request"]?["subtype"], "interrupt")
        let m = try JSONValue.parse(OutboundMessage.setPermissionMode(.plan, requestID: "y"))
        XCTAssertEqual(m["request"]?["mode"], "plan")
    }

    func testLineBufferHandlesSplitsAndCRLF() {
        var b = LineBuffer()
        XCTAssertEqual(b.append(Data("{\"a\":".utf8)), [])
        let lines = b.append(Data("1}\r\n{\"b\":2}\n{\"c\"".utf8))
        XCTAssertEqual(lines.map { String(decoding: $0, as: UTF8.self) }, ["{\"a\":1}", "{\"b\":2}"])
        XCTAssertEqual(b.flush().map { String(decoding: $0, as: UTF8.self) }, "{\"c\"")
    }

    func testJSONValueRoundTripKeepsIntegers() throws {
        let v: JSONValue = ["n": 3, "f": 1.5, "b": true, "s": "x", "a": [1, nil]]
        let back = try JSONValue.parse(v.serialized())
        XCTAssertEqual(back, v)
        XCTAssertTrue(v.serializedString().contains("\"n\":3"))
    }

    // MARK: Launch configuration

    func testArgumentsUseStdioPermissionsAndStreamJSON() {
        let cfg = LaunchConfiguration(executable: URL(fileURLWithPath: "/usr/local/bin/claude"),
                                      workingDirectory: URL(fileURLWithPath: "/tmp"), model: "sonnet",
                                      permissionMode: .plan, appendSystemPrompt: "Be brief", resumeSessionID: "abc")
        let args = cfg.arguments()
        XCTAssertEqual(Array(args.prefix(1)), ["-p"])
        for pair in [["--input-format", "stream-json"], ["--output-format", "stream-json"],
                     ["--permission-prompt-tool", "stdio"], ["--permission-mode", "plan"], ["--model", "sonnet"],
                     ["--resume", "abc"], ["--append-system-prompt", "Be brief"]] {
            let idx = args.firstIndex(of: pair[0])
            XCTAssertNotNil(idx, pair[0])
            if let idx { XCTAssertEqual(args[idx + 1], pair[1]) }
        }
        XCTAssertTrue(args.contains("--include-partial-messages"))
        XCTAssertTrue(args.contains("--verbose"))
    }

    func testSubscriptionModeStripsKeysAndAPIKeyModeSetsIt() {
        let base = ["PATH": "/usr/bin", "ANTHROPIC_API_KEY": "sk-from-shell", "ANTHROPIC_AUTH_TOKEN": "t", "CLAUDECODE": "1"]
        var cfg = LaunchConfiguration(executable: URL(fileURLWithPath: "/opt/x/bin/claude"),
                                      workingDirectory: URL(fileURLWithPath: "/tmp"), auth: .subscription,
                                      baseEnvironment: base)
        var env = cfg.environment()
        XCTAssertNil(env["ANTHROPIC_API_KEY"])
        XCTAssertNil(env["ANTHROPIC_AUTH_TOKEN"])
        XCTAssertNil(env["CLAUDECODE"])
        XCTAssertTrue(env["PATH"]!.hasPrefix("/opt/x/bin:"))

        cfg.auth = .apiKey("sk-user")
        env = cfg.environment()
        XCTAssertEqual(env["ANTHROPIC_API_KEY"], "sk-user")
        XCTAssertNil(env["ANTHROPIC_AUTH_TOKEN"])
    }

    func testLocatorFindsExecutable() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pv-loc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let exe = dir.appendingPathComponent("claude")
        try "#!/bin/sh\necho 2.1.296\n".write(to: exe, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
        XCTAssertEqual(ClaudeLocator.locate(pathVariable: dir.path, home: "/nonexistent")?.path, exe.path)
        XCTAssertNil(ClaudeLocator.locate(override: "/nonexistent/claude"))
    }
}
