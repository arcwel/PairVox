// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PairVoxCore

/// Exercises the real subprocess plumbing against a tiny fake `claude` script.
final class CLISessionTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("pv-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Writes a fake CLI that answers each stdin line the way Claude Code does.
    func makeFakeClaude() throws -> URL {
        let script = #"""
        #!/bin/sh
        # Records argv and the API-key env var so the test can check them.
        echo "$@" > "$(dirname "$0")/args.txt"
        echo "${ANTHROPIC_API_KEY:-<none>}" > "$(dirname "$0")/key.txt"
        n=0
        while IFS= read -r line; do
          case "$line" in
            *'"subtype":"interrupt"'*)
              echo '{"type":"control_response","response":{"subtype":"success","request_id":"x","response":{"still_queued":[]}}}'
              ;;
            *'"type":"control_response"'*)
              echo '{"type":"result","subtype":"success","is_error":false,"result":"Wrote it.","session_id":"sess-1","duration_ms":5,"num_turns":2,"total_cost_usd":0.001}'
              ;;
            *'"type":"user"'*)
              n=$((n+1))
              echo '{"type":"system","subtype":"init","session_id":"sess-1","model":"fake","cwd":"/tmp","permissionMode":"default","tools":[]}'
              if [ $n -eq 1 ]; then
                echo '{"type":"stream_event","event":{"type":"message_start","message":{"id":"m1"}},"parent_tool_use_id":null}'
                echo '{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}},"parent_tool_use_id":null}'
                echo '{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello "}},"parent_tool_use_id":null}'
                echo '{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"there."}},"parent_tool_use_id":null}'
                echo '{"type":"stream_event","event":{"type":"content_block_stop","index":0},"parent_tool_use_id":null}'
                echo '{"type":"assistant","message":{"id":"m1","content":[{"type":"text","text":"Hello there."}]},"parent_tool_use_id":null}'
                echo '{"type":"result","subtype":"success","is_error":false,"result":"Hello there.","session_id":"sess-1","duration_ms":5,"num_turns":1,"total_cost_usd":0.001}'
              else
                echo '{"type":"control_request","request_id":"perm-1","request":{"subtype":"can_use_tool","tool_name":"Write","input":{"file_path":"/tmp/a.txt","content":"hi"},"tool_use_id":"t1"}}'
                echo '{"type":"control_request","request_id":"hook-1","request":{"subtype":"hook_callback","callback_id":"c"}}'
              fi
              ;;
          esac
        done
        """#
        let url = dir.appendingPathComponent("claude")
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    func collect(_ session: ClaudeCLISession, until predicate: @escaping @Sendable (SessionEvent) -> Bool,
                 timeout: TimeInterval = 10) async -> [SessionEvent] {
        await withTaskGroup(of: [SessionEvent].self) { group in
            group.addTask {
                var got: [SessionEvent] = []
                for await e in session.events {
                    got.append(e)
                    if predicate(e) { break }
                }
                return got
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return []
            }
            let first = await group.next() ?? []
            group.cancelAll()
            return first
        }
    }

    func testFullRoundTripThroughSubprocess() async throws {
        let exe = try makeFakeClaude()
        let cfg = LaunchConfiguration(executable: exe, workingDirectory: dir, auth: .apiKey("sk-test"),
                                      appendSystemPrompt: SystemPrompts.voice,
                                      baseEnvironment: ["PATH": "/usr/bin:/bin", "HOME": dir.path])
        let session = ClaudeCLISession(configuration: cfg)
        try session.start()
        try session.send("hi")
        let first = await collect(session) { if case .turnCompleted = $0 { return true }; return false }
        let text = first.compactMap { e -> String? in if case .textDelta(let t) = e { return t }; return nil }.joined()
        XCTAssertEqual(text, "Hello there.")
        XCTAssertTrue(first.contains { if case .started(let i) = $0 { return i.sessionID == "sess-1" }; return false })
        XCTAssertEqual(session.sessionID, "sess-1")

        // Permission round trip; the unsupported hook request is auto-answered with an error.
        try session.send("write a file")
        let second = await collect(session) { if case .permissionRequested = $0 { return true }; return false }
        guard case .permissionRequested(let req)? = second.last else { return XCTFail("no permission request") }
        XCTAssertEqual(req.toolName, "Write")
        try session.respond(to: req, decision: .allow)
        let third = await collect(session) { if case .turnCompleted = $0 { return true }; return false }
        guard case .turnCompleted(let r)? = third.last else { return XCTFail() }
        XCTAssertEqual(r.finalText, "Wrote it.")

        let args = try String(contentsOf: dir.appendingPathComponent("args.txt"), encoding: .utf8)
        XCTAssertTrue(args.contains("--permission-prompt-tool stdio"))
        XCTAssertTrue(args.contains("--input-format stream-json"))
        let key = try String(contentsOf: dir.appendingPathComponent("key.txt"), encoding: .utf8)
        XCTAssertEqual(key.trimmingCharacters(in: .whitespacesAndNewlines), "sk-test")

        session.stop()
        let exit = await collect(session) { if case .processExited = $0 { return true }; return false }
        XCTAssertTrue(exit.contains { if case .processExited = $0 { return true }; return false })
    }

    func testSubscriptionModeDoesNotLeakKey() async throws {
        let exe = try makeFakeClaude()
        let cfg = LaunchConfiguration(executable: exe, workingDirectory: dir, auth: .subscription,
                                      baseEnvironment: ["PATH": "/usr/bin:/bin", "ANTHROPIC_API_KEY": "sk-shell"])
        let session = ClaudeCLISession(configuration: cfg)
        try session.send("hi") // send() launches on demand
        _ = await collect(session) { if case .turnCompleted = $0 { return true }; return false }
        let key = try String(contentsOf: dir.appendingPathComponent("key.txt"), encoding: .utf8)
        XCTAssertEqual(key.trimmingCharacters(in: .whitespacesAndNewlines), "<none>")
        session.stop()
    }

    func testRestartResumesSession() async throws {
        let exe = try makeFakeClaude()
        let cfg = LaunchConfiguration(executable: exe, workingDirectory: dir,
                                      baseEnvironment: ["PATH": "/usr/bin:/bin"])
        let session = ClaudeCLISession(configuration: cfg)
        try session.send("hi")
        _ = await collect(session) { if case .turnCompleted = $0 { return true }; return false }
        session.stop()
        _ = await collect(session) { if case .processExited = $0 { return true }; return false }
        XCTAssertFalse(session.isRunning)
        try session.send("again")
        _ = await collect(session) { if case .started = $0 { return true }; return false }
        let args = try String(contentsOf: dir.appendingPathComponent("args.txt"), encoding: .utf8)
        XCTAssertTrue(args.contains("--resume sess-1"))
        session.stop()
    }
}
