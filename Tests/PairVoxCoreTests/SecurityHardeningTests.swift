// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PairVoxCore

/// Regression tests for the 2026-10-13 security audit (docs/security/2026-10-13-phase1-hardening.md).
final class SecurityHardeningTests: XCTestCase {
    func testAlwaysAllowIsScopedToTheSession() throws {
        let suggestions: JSONValue = [
            ["type": "addRules", "behavior": "allow", "destination": "localSettings",
             "rules": [["toolName": "Bash", "ruleContent": "echo pairvox-test *"]]],
            ["type": "addDirectories", "directories": ["/tmp/x"], "destination": "userSettings"],
        ]
        let req = PermissionRequest(requestID: "r", toolName: "Bash", input: ["command": "echo hi"], suggestions: suggestions)
        let v = try JSONValue.parse(OutboundMessage.permissionResponse(for: req, decision: .allowAlways))
        let updated = try XCTUnwrap(v["response"]?["response"]?["updatedPermissions"])
        guard case .array(let items) = updated else { return XCTFail("expected an array") }
        XCTAssertEqual(items.count, 2)
        for item in items { XCTAssertEqual(item["destination"], "session", "nothing may outlive the session") }
        XCTAssertEqual(items[0]["rules"]?[0]?["ruleContent"], "echo pairvox-test *", "the rule itself is kept")
    }

    func testChildOnlyLoadsUserSettingsUnlessProjectConfigIsTrusted() {
        let exe = URL(fileURLWithPath: "/usr/local/bin/claude"), dir = URL(fileURLWithPath: "/tmp/repo")
        let untrusted = LaunchConfiguration(executable: exe, workingDirectory: dir).arguments()
        XCTAssertEqual(untrusted.firstIndex(of: "--setting-sources").map { untrusted[$0 + 1] }, "user")
        XCTAssertFalse(untrusted.contains("--strict-mcp-config"), "the user's own MCP servers must keep loading")
        let trusted = LaunchConfiguration(executable: exe, workingDirectory: dir, trustProjectConfiguration: true).arguments()
        XCTAssertFalse(trusted.contains("--setting-sources"))
        XCTAssertFalse(trusted.contains("--strict-mcp-config"))
        XCTAssertFalse(AppSettings().trustProjectConfiguration, "off by default")
    }

    func testRepoVocabularyIgnoresSymlinksAndBoundsReads() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pv-vocab-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "class RealWidgetController {}".write(to: root.appendingPathComponent("Real.swift"), atomically: true, encoding: .utf8)
        // A repository can link a "source file" to a device that never ends.
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Evil.swift"),
                                                   withDestinationURL: URL(fileURLWithPath: "/dev/zero"))
        let done = expectation(description: "scan returns")
        var terms: [String] = []
        DispatchQueue.global().async { terms = RepoVocabulary.scan(root: root); done.fulfill() }
        wait(for: [done], timeout: 10)
        XCTAssertTrue(terms.contains("RealWidgetController"))
        XCTAssertFalse(terms.contains("Evil"))
        // And a plain read never goes past the limit.
        let big = root.appendingPathComponent("Big.swift")
        try Data(repeating: UInt8(ascii: "a"), count: 5_000).write(to: big)
        XCTAssertEqual(RepoVocabulary.readText(big, limit: 100)?.count, 100)
    }
}

final class ClaudePathTrustTests: XCTestCase {
    func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pv-trust-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        return dir
    }

    func testOverrideMustBeAProtectedRegularFile() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let good = dir.appendingPathComponent("claude")
        try "#!/bin/sh\n".write(to: good, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: good.path)
        XCTAssertNil(ClaudeLocator.overrideProblem(good.path))
        XCTAssertEqual(ClaudeLocator.locate(override: good.path)?.path, good.path)

        XCTAssertNotNil(ClaudeLocator.overrideProblem("relative/claude"))
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: good.path)
        XCTAssertNotNil(ClaudeLocator.overrideProblem(good.path), "world-writable program")
        XCTAssertNil(ClaudeLocator.locate(override: good.path), "a program anyone can edit never receives the key")
        try FileManager.default.setAttributes([.posixPermissions: 0o775], ofItemAtPath: good.path)
        XCTAssertNotNil(ClaudeLocator.overrideProblem(good.path), "group-writable program")

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: good.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: dir.path)
        XCTAssertNotNil(ClaudeLocator.overrideProblem(good.path), "folder anyone can write to")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        XCTAssertNotNil(ClaudeLocator.overrideProblem(dir.path), "a directory is not a program")
    }

    func testSettingsAreSavedPrivateAndALooseFileCannotNameTheProgram() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SettingsStore(url: dir.appendingPathComponent("PairVox/settings.json"))
        var settings = AppSettings()
        settings.claudePathOverride = "/opt/evil/claude"
        try store.save(settings)
        let attrs = try FileManager.default.attributesOfItem(atPath: store.url.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let folder = try FileManager.default.attributesOfItem(atPath: store.url.deletingLastPathComponent().path)
        XCTAssertEqual((folder[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual(store.load().claudePathOverride, "/opt/evil/claude", "a private file is honoured")
        try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: store.url.path)
        XCTAssertNil(store.load().claudePathOverride, "a world-writable settings file is not trusted to name the program")
    }

    func testUnknownWhisperModelIsReplacedByTheDefault() throws {
        let data = Data(#"{"whisperModel":"../../evil"}"#.utf8)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(decoded.whisperModel, VoiceCatalog.defaultWhisperModel)
    }
}
