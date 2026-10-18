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

    func writeScript(_ name: String, _ body: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try ("#!/bin/sh\n" + body).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    static let streamStart = #"""
    echo '{"type":"stream_event","event":{"type":"message_start","message":{"id":"m1"}},"parent_tool_use_id":null}'
    echo '{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}},"parent_tool_use_id":null}'
    """#
    static let delta = #"echo '{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"word "}},"parent_tool_use_id":null}'"#

    /// Review task 4.4: a child that writes a large burst ending in its `result` and exits at once. The exit used to
    /// be reported from the termination handler while those lines were still unread, so a finished turn looked like
    /// a crash. The result must arrive before `.processExited`.
    func testTheLastLinesArriveBeforeTheExitIsReported() async throws {
        #if os(Linux)
        // Foundation on Linux does not report pipe end-of-file through readabilityHandler, nor the exit promptly, the
        // way macOS does; this test checks the macOS app's behaviour. Linux gap recorded in the hardening backlog.
        throw XCTSkip("pipe end-of-file and exit timing differ in Foundation on Linux")
        #endif
        let exe = try writeScript("burst", """
        read -r line
        \(Self.streamStart)
        i=0
        while [ $i -lt 4000 ]; do \(Self.delta); i=$((i+1)); done
        echo '{"type":"result","subtype":"success","is_error":false,"result":"done","session_id":"s","duration_ms":1,"num_turns":1,"total_cost_usd":0}'
        exit 0
        """)
        let session = ClaudeCLISession(configuration: LaunchConfiguration(executable: exe, workingDirectory: dir,
                                                                          baseEnvironment: ["PATH": "/usr/bin:/bin"]))
        try session.send("go")
        let events = await collect(session, until: { if case .processExited = $0 { return true }; return false }, timeout: 20)
        let completed = events.firstIndex { if case .turnCompleted = $0 { return true }; return false }
        let exited = events.firstIndex { if case .processExited = $0 { return true }; return false }
        XCTAssertNotNil(completed, "the result line was lost")
        XCTAssertNotNil(exited)
        if let completed, let exited { XCTAssertLessThan(completed, exited, "the exit was reported before the last lines") }
    }

    /// Review task 4.5: a child that never reads stdin but keeps printing. A message larger than the pipe buffer
    /// blocks its write; output must keep arriving meanwhile. The write used to hold the session lock, which the
    /// stdout reader needs, so nothing arrived until the child gave up.
    func testOutputKeepsArrivingWhileAWriteIsBlockedOnAFullStdin() async throws {
        let exe = try writeScript("deaf", """
        \(Self.streamStart)
        i=0
        while [ $i -lt 80 ]; do \(Self.delta); sleep 0.05; i=$((i+1)); done
        exit 0
        """)
        let session = ClaudeCLISession(configuration: LaunchConfiguration(executable: exe, workingDirectory: dir,
                                                                          baseEnvironment: ["PATH": "/usr/bin:/bin"]))
        try session.start()
        let big = String(repeating: "x", count: 1_000_000)
        DispatchQueue.global().async { try? session.send(big) }   // blocks: the child never reads stdin
        try? await Task.sleep(nanoseconds: 200_000_000)
        final class Count: @unchecked Sendable {
            private let lock = NSLock(); private var n = 0
            func add() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
        }
        let deltas = Count()
        let events = await collect(session, until: { e in
            if case .textDelta = e { return deltas.add() >= 10 }
            return false
        }, timeout: 3)
        let count = events.filter { if case .textDelta = $0 { return true }; return false }.count
        XCTAssertGreaterThanOrEqual(count, 10, "output stopped while a stdin write was blocked")
        session.stop()
    }

    /// Review task 4.3: a login shell whose rc file starts a background process that inherits stdout. The shell
    /// exits at once, but the pipe stays open while that process lives, and the runner used to wait for it, with
    /// no timeout, so the app never finished launching. It must return the shell's output within its timeout.
    func testARunnerReturnsWhenABackgroundProcessKeepsThePipeOpen() async throws {
        #if os(Linux)
        // Foundation on Linux does not report pipe end-of-file through readabilityHandler, nor the exit promptly, the
        // way macOS does; this test checks the macOS app's behaviour. Linux gap recorded in the hardening backlog.
        throw XCTSkip("pipe end-of-file and exit timing differ in Foundation on Linux")
        #endif
        let exe = try writeScript("rc-shell", """
        sleep 30 &
        echo __PAIRVOX_ENV__
        echo PATH=/usr/bin
        exit 0
        """)
        let started = Date()
        let result = await withTaskGroup(of: String?.self) { group -> String? in
            group.addTask { (try? await ProcessRunner.run(exe, arguments: [], timeout: 5))?.stdout }
            group.addTask { try? await Task.sleep(nanoseconds: 8_000_000_000); return "HUNG" }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        XCTAssertNotEqual(result, "HUNG", "the runner waited for the background process")
        XCTAssertTrue(result?.contains("__PAIRVOX_ENV__") ?? false, "the output that did arrive was kept")
        XCTAssertLessThan(Date().timeIntervalSince(started), 4)
    }
}

