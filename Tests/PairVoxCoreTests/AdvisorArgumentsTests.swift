// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PairVoxCore

/// Task 4.2 of docs/plans/2026-10-16-hardening-task-list.md: the advisor's one-shot `claude` call can read the
/// project and nothing more. No real call is made; this checks the command line `ClaudeAdvisor` builds.
final class AdvisorArgumentsTests: XCTestCase {
    private let advisor = ClaudeAdvisor(executable: URL(fileURLWithPath: "/usr/local/bin/claude"),
                                        workingDirectory: URL(fileURLWithPath: "/tmp/repo"), auth: .subscription,
                                        baseEnvironment: [:])

    private func value(after flag: String, in args: [String]) -> String? {
        args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
    }

    func testOnlyReadGrepAndGlobAreOfferedAndEverythingElseIsDeniedByName() {
        let args = advisor.arguments(prompt: "Explain it.")
        XCTAssertEqual(value(after: "--tools", in: args), "Read,Grep,Glob")
        let denied = Set(value(after: "--disallowedTools", in: args)?.split(separator: ",").map(String.init) ?? [])
        for tool in ["Bash", "Edit", "Write", "NotebookEdit", "WebFetch", "WebSearch", "Agent", "Task",
                     "TodoWrite", "Skill", "KillShell", "BashOutput", "ExitPlanMode"] {
            XCTAssertTrue(denied.contains(tool), "\(tool) is not denied")
        }
        for tool in ["Read", "Grep", "Glob"] { XCTAssertFalse(denied.contains(tool), "\(tool) is the advisor's job") }
    }

    func testNoMCPServerLoads() throws {
        let args = advisor.arguments(prompt: "Explain it.")
        XCTAssertTrue(args.contains("--strict-mcp-config"), "without it the user's own MCP servers load from ~/.claude.json")
        let config = try XCTUnwrap(value(after: "--mcp-config", in: args))
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(config.utf8)) as? [String: Any])
        let servers = try XCTUnwrap(parsed["mcpServers"] as? [String: Any])
        XCTAssertTrue(servers.isEmpty, "the one MCP config the strict flag honours names no server")
        XCTAssertEqual(args.filter { $0 == "--mcp-config" }.count, 1)
    }

    func testProjectSettingsHooksAndPersistenceAreOff() {
        let args = advisor.arguments(prompt: "Explain it.")
        XCTAssertEqual(value(after: "--setting-sources", in: args), "user")
        XCTAssertTrue(args.contains("--no-session-persistence"))
        XCTAssertEqual(value(after: "--output-format", in: args), "text")
        XCTAssertEqual(args.first, "-p")
        XCTAssertFalse(args.contains("--permission-mode"), "the advisor never gets a permission mode: it has nothing to approve")
        XCTAssertFalse(args.contains("--dangerously-skip-permissions"))
    }

    func testThePromptIsTheLastArgumentAfterTheSeparatorEvenWhenItLooksLikeAFlag() {
        let args = advisor.arguments(prompt: "--help me understand rm -rf")
        let separator = try! XCTUnwrap(args.lastIndex(of: "--"))
        XCTAssertEqual(args.count, separator + 2)
        XCTAssertEqual(args.last, "--help me understand rm -rf")
    }

    func testTheModelIsTheOneConfigured() {
        let haiku = ClaudeAdvisor(executable: URL(fileURLWithPath: "/usr/local/bin/claude"),
                                  workingDirectory: URL(fileURLWithPath: "/tmp/repo"), auth: .subscription,
                                  baseEnvironment: [:], model: "haiku")
        XCTAssertEqual(value(after: "--model", in: haiku.arguments(prompt: "x")), "haiku")
    }
}
