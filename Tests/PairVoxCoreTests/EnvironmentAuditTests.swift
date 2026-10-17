// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PairVoxCore

/// The report behind `pairvox-cli --env-audit` (task 4.1's audit row): names and reason groups, never a value.
final class EnvironmentAuditTests: XCTestCase {
    private static let secret = "sk-ant-value-that-must-never-print"

    private static let shell: [String: String] = [
        "ANTHROPIC_API_KEY": secret,
        "ANTHROPIC_BASE_URL": "http://localhost:4000",
        "CLAUDE_CODE_OAUTH_TOKEN": "oauth-value-that-must-never-print",
        "CLAUDECODE": "1",
        "CLAUDE_CONFIG_DIR": "/tmp/another-claude-home",
        "NODE_OPTIONS": "--require /tmp/evil.js",
        "SSL_CERT_FILE": "/tmp/attacker-ca.pem",
        "PATH": "/opt/homebrew/bin:/usr/bin",
        "HOME": "/Users/dev",
        "LANG": "en_US.UTF-8",
        "https_proxy": "http://proxy.corp.example:3128",
        "NO_PROXY": "localhost",
    ]

    func testEveryDeniedNameHasOneReasonGroup() {
        XCTAssertEqual(EnvironmentAudit.reason(for: "ANTHROPIC_BASE_URL"), .anthropic)
        XCTAssertEqual(EnvironmentAudit.reason(for: "anthropic_api_key"), .anthropic)
        XCTAssertEqual(EnvironmentAudit.reason(for: "CLAUDE_CODE_OAUTH_TOKEN"), .claudeCode)
        XCTAssertEqual(EnvironmentAudit.reason(for: "CLAUDECODE"), .claudeCode)
        XCTAssertEqual(EnvironmentAudit.reason(for: "CLAUDE_CONFIG_DIR"), .configDir)
        for name in ["NODE_OPTIONS", "NODE_EXTRA_CA_CERTS", "NODE_TLS_REJECT_UNAUTHORIZED", "NODE_USE_SYSTEM_CA",
                     "SSL_CERT_FILE", "SSL_CERT_DIR"] {
            XCTAssertEqual(EnvironmentAudit.reason(for: name), .nodeTLS, name)
        }
        XCTAssertNil(EnvironmentAudit.reason(for: "PATH"))
        XCTAssertNil(EnvironmentAudit.reason(for: "HTTPS_PROXY"), "a passed proxy has no drop reason")
        // Every name the deny-list claims gets a group, so the report never silently omits one.
        for name in ChildEnvironment.deniedNames { XCTAssertNotNil(EnvironmentAudit.reason(for: name), name) }
    }

    func testDroppedProxiesAndCountMatchTheFilter() {
        let audit = EnvironmentAudit(environment: Self.shell)
        XCTAssertEqual(audit.dropped.map(\.name), ChildEnvironment.droppedNames(in: Self.shell))
        XCTAssertEqual(audit.dropped.map(\.name), ["ANTHROPIC_API_KEY", "ANTHROPIC_BASE_URL", "CLAUDECODE",
                                                   "CLAUDE_CODE_OAUTH_TOKEN", "CLAUDE_CONFIG_DIR", "NODE_OPTIONS",
                                                   "SSL_CERT_FILE"])
        XCTAssertEqual(audit.proxies.map(\.name), ChildEnvironment.passedProxyNames)
        XCTAssertEqual(audit.proxiesSet, ["HTTPS_PROXY", "NO_PROXY"], "lowercase https_proxy counts as set")
        // PATH, HOME, LANG: the two proxies are reported separately.
        XCTAssertEqual(audit.forwardedCount, 3)
    }

    func testReportsNeverContainADroppedValue() {
        let audit = EnvironmentAudit(environment: Self.shell)
        for report in [audit.textReport(), audit.jsonReport()] {
            for (name, value) in Self.shell where ChildEnvironment.isDenied(name) {
                XCTAssertFalse(report.contains(value), "\(name)'s value leaked into the report")
            }
            XCTAssertTrue(report.contains("ANTHROPIC_API_KEY"))
            XCTAssertTrue(report.contains("CLAUDE_CONFIG_DIR"))
        }
        let text = audit.textReport()
        XCTAssertTrue(text.contains("ANTHROPIC_API_KEY") && text.contains("anthropic"))
        XCTAssertTrue(text.contains("CLAUDE_CODE_OAUTH_TOKEN") && text.contains("claude-code"))
        XCTAssertTrue(text.contains("config-dir") && text.contains("node/tls"))
        XCTAssertTrue(text.contains("HTTPS_PROXY  set"), text)
        XCTAssertTrue(text.contains("HTTP_PROXY   not set"), text)
        XCTAssertTrue(text.contains("Forwarded unchanged: 3 ordinary variables."), text)
    }

    func testJSONIsAStableObject() throws {
        let data = Data(EnvironmentAudit(environment: Self.shell).jsonReport().utf8)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["dropped", "proxiesSet", "forwardedCount"])
        let dropped = try XCTUnwrap(object["dropped"] as? [[String: String]])
        XCTAssertEqual(dropped.first, ["name": "ANTHROPIC_API_KEY", "reason": "anthropic"])
        XCTAssertEqual(dropped.map { Set($0.keys) }, Array(repeating: ["name", "reason"], count: 7))
        XCTAssertEqual(object["proxiesSet"] as? [String], ["HTTPS_PROXY", "NO_PROXY"])
        XCTAssertEqual(object["forwardedCount"] as? Int, 3)
        // Same input, same bytes: scripts can diff two runs.
        XCTAssertEqual(EnvironmentAudit(environment: Self.shell).jsonReport(),
                       EnvironmentAudit(environment: Self.shell).jsonReport())
    }

    func testCleanShellReportsNothingDropped() {
        let audit = EnvironmentAudit(environment: ["PATH": "/usr/bin", "HOME": "/Users/dev"])
        XCTAssertTrue(audit.dropped.isEmpty)
        XCTAssertTrue(audit.proxiesSet.isEmpty)
        XCTAssertEqual(audit.forwardedCount, 2)
        XCTAssertTrue(audit.textReport().contains("(none)"))
        XCTAssertTrue(audit.jsonReport().contains("\"dropped\" : [\n\n  ]") || audit.jsonReport().contains("\"dropped\" : []"),
                      audit.jsonReport())
    }
}
