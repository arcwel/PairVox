// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PairVoxCore

/// Task 4.1 of docs/plans/2026-10-16-hardening-task-list.md: the login shell's environment reaches the child only
/// after the deny-list in `ChildEnvironment`.
final class ChildEnvironmentTests: XCTestCase {
    private let exe = URL(fileURLWithPath: "/usr/local/bin/claude")
    private let dir = URL(fileURLWithPath: "/tmp/repo")

    /// Every variable the review found passing through, each with a value that would be harmful.
    private static let dropped: [String: String] = [
        "ANTHROPIC_BASE_URL": "http://localhost:4000",
        "ANTHROPIC_CUSTOM_HEADERS": "x-forward-to: attacker",
        "ANTHROPIC_API_KEY": "sk-ant-from-the-shell",
        "ANTHROPIC_AUTH_TOKEN": "token-from-the-shell",
        "ANTHROPIC_MODEL": "claude-something-else",
        "CLAUDE_CODE_OAUTH_TOKEN": "oauth-from-the-shell",
        "CLAUDE_CODE_USE_BEDROCK": "1",
        "CLAUDE_CODE_USE_VERTEX": "1",
        "CLAUDE_CODE_SESSION_ID": "parent-session",
        "CLAUDECODE": "1",
        "CLAUDE_CONFIG_DIR": "/tmp/another-claude-home",
        "NODE_OPTIONS": "--require /tmp/evil.js",
        "NODE_EXTRA_CA_CERTS": "/tmp/attacker-ca.pem",
        "NODE_TLS_REJECT_UNAUTHORIZED": "0",
        "NODE_USE_SYSTEM_CA": "1",
        "SSL_CERT_FILE": "/tmp/attacker-ca.pem",
        "SSL_CERT_DIR": "/tmp/attacker-cas",
    ]

    /// Ordinary variables and the proxy settings, which must survive the filter.
    private static let kept: [String: String] = [
        "PATH": "/opt/homebrew/bin:/usr/bin",
        "HOME": "/Users/dev",
        "SHELL": "/bin/zsh",
        "LANG": "en_US.UTF-8",
        "TERM": "xterm-256color",
        "EDITOR": "vim",
        "GIT_AUTHOR_NAME": "Dev",
        "HTTP_PROXY": "http://proxy.corp.example:3128",
        "HTTPS_PROXY": "http://proxy.corp.example:3128",
        "ALL_PROXY": "socks5://proxy.corp.example:1080",
        "NO_PROXY": "localhost,127.0.0.1",
        "https_proxy": "http://proxy.corp.example:3128",
    ]

    private var shell: [String: String] { Self.dropped.merging(Self.kept) { $1 } }

    private func environment(_ auth: AuthMode) -> [String: String] {
        LaunchConfiguration(executable: exe, workingDirectory: dir, auth: auth, baseEnvironment: shell).environment()
    }

    func testEveryDeniedVariableIsDroppedInSubscriptionMode() {
        let env = environment(.subscription)
        for (key, value) in Self.dropped {
            XCTAssertNil(env[key], "\(key) reached the child")
            XCTAssertFalse(env.values.contains(value), "the value of \(key) reached the child under another name")
        }
        XCTAssertNil(env["ANTHROPIC_API_KEY"], "subscription mode sets no key: the child uses its own login")
        XCTAssertTrue(env.keys.filter { $0.uppercased().hasPrefix("ANTHROPIC_") }.isEmpty, "\(env.keys.sorted())")
        XCTAssertTrue(env.keys.filter { $0.uppercased().hasPrefix("CLAUDE_CODE_") }.isEmpty, "\(env.keys.sorted())")
    }

    func testEveryDeniedVariableIsDroppedInAPIKeyModeAndOnlyTheKeychainKeyIsSet() {
        let env = environment(.apiKey("sk-ant-from-the-keychain"))
        for (key, value) in Self.dropped where key != "ANTHROPIC_API_KEY" {
            XCTAssertNil(env[key], "\(key) reached the child")
            XCTAssertFalse(env.values.contains(value), "the value of \(key) reached the child under another name")
        }
        XCTAssertEqual(env["ANTHROPIC_API_KEY"], "sk-ant-from-the-keychain", "the shell's key must not win over the Keychain's")
        XCTAssertEqual(env.keys.filter { $0.uppercased().hasPrefix("ANTHROPIC_") }, ["ANTHROPIC_API_KEY"],
                       "the key is the only ANTHROPIC_ variable the child sees: no base URL, no custom headers")
        XCTAssertNil(env["CLAUDE_CODE_OAUTH_TOKEN"], "the OAuth token is never forwarded, in either mode")
    }

    func testOrdinaryVariablesAndProxiesPassThrough() {
        for auth in [AuthMode.subscription, .apiKey("k")] {
            let env = environment(auth)
            for (key, value) in Self.kept where key != "PATH" {
                XCTAssertEqual(env[key], value, "\(key) was lost")
            }
            XCTAssertTrue(env["PATH"]?.hasPrefix("/usr/local/bin:") == true, "the CLI's own folder leads PATH: \(env["PATH"] ?? "")")
            XCTAssertTrue(env["PATH"]?.contains("/opt/homebrew/bin") == true)
        }
        for name in ChildEnvironment.passedProxyNames { XCTAssertFalse(ChildEnvironment.isDenied(name), name) }
    }

    func testTheDenyListIsCaseInsensitiveAndReportsWhatItDrops() {
        XCTAssertTrue(ChildEnvironment.isDenied("anthropic_base_url"))
        XCTAssertTrue(ChildEnvironment.isDenied("Claude_Code_Oauth_Token"))
        XCTAssertTrue(ChildEnvironment.isDenied("node_options"))
        XCTAssertFalse(ChildEnvironment.isDenied("ANTHROPIC"), "a bare prefix without the underscore is another name")
        XCTAssertFalse(ChildEnvironment.isDenied("CLAUDE_MD_PATH"), "only CLAUDE_CODE_* and CLAUDE_CONFIG_DIR are claimed")
        XCTAssertFalse(ChildEnvironment.isDenied("NODE_ENV"))
        XCTAssertEqual(ChildEnvironment.droppedNames(in: shell), Self.dropped.keys.sorted())
        XCTAssertEqual(ChildEnvironment.filter(Self.kept), Self.kept)
    }

    func testTheVersionCheckAndTheAdvisorUseTheSameFilter() {
        // `claude --version` and the advisor's one-shot call are started with the same filtered environment as the
        // session, so a token in the shell never reaches any child PairVox starts.
        let filtered = ChildEnvironment.filter(shell)
        XCTAssertNil(filtered["CLAUDE_CODE_OAUTH_TOKEN"])
        XCTAssertNil(filtered["ANTHROPIC_BASE_URL"])
        let advisor = ClaudeAdvisor(executable: exe, workingDirectory: dir, auth: .subscription, baseEnvironment: shell)
        let env = advisor.environment()
        XCTAssertNil(env["CLAUDE_CODE_OAUTH_TOKEN"])
        XCTAssertNil(env["ANTHROPIC_BASE_URL"])
        XCTAssertNil(env["ANTHROPIC_API_KEY"])
        XCTAssertEqual(env["HOME"], "/Users/dev")
    }
}
