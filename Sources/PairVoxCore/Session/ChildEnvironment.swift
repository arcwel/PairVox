// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Which variables of the user's login shell reach the spawned `claude` (the session and the advisor call).
///
/// The login shell's environment is read once (`ShellEnvironment.loginShellEnvironment`) so the child finds
/// node and the CLI. The same environment can carry variables that change where the child sends its
/// credentials, which credentials it uses, or what code runs inside it, and a line in `.zshrc` is easy to
/// forget. The child therefore starts from a filtered copy. Dropped:
///
/// - `ANTHROPIC_*`: `ANTHROPIC_BASE_URL` and `ANTHROPIC_CUSTOM_HEADERS` would send the Keychain key to another
///   endpoint; `ANTHROPIC_API_KEY` and `ANTHROPIC_AUTH_TOKEN` would override the auth mode the user chose; the
///   model variables are replaced by PairVox's own model setting. In API-key mode `LaunchConfiguration` sets
///   `ANTHROPIC_API_KEY` after the filter, and that is the only `ANTHROPIC_*` variable the child ever sees.
/// - `CLAUDE_CODE_*` and `CLAUDECODE`: `CLAUDE_CODE_OAUTH_TOKEN` is a credential PairVox must not forward in
///   either mode (the child uses its own login); the Bedrock and Vertex switches change the endpoint; the
///   session markers would make the child think it is nested in another Claude Code.
/// - `CLAUDE_CONFIG_DIR`: would point the child at another settings folder (other hooks, MCP servers and
///   credentials).
/// - `NODE_OPTIONS`, `NODE_EXTRA_CA_CERTS`, `NODE_TLS_REJECT_UNAUTHORIZED`, `NODE_USE_SYSTEM_CA`, `SSL_CERT_FILE`,
///   `SSL_CERT_DIR`: load code into the child or let a proxy read its TLS traffic.
///
/// Kept, on purpose: the proxy variables (`HTTP_PROXY`, `HTTPS_PROXY`, `ALL_PROXY`, `NO_PROXY`, and lowercase).
/// A user behind a proxy has no other way to reach the API, and with the TLS variables above dropped a proxy
/// sees the TLS tunnel to `api.anthropic.com`, not the key. Everything else (`PATH`, `HOME`, locale, editor,
/// git settings) passes through unchanged.
public enum ChildEnvironment {
    /// Prefixes no variable from the shell may carry (compared in upper case).
    static let deniedPrefixes = ["ANTHROPIC_", "CLAUDE_CODE_"]

    /// Exact names dropped (compared in upper case).
    static let deniedNames: Set<String> = [
        "CLAUDECODE", "CLAUDE_CONFIG_DIR",
        "NODE_OPTIONS", "NODE_EXTRA_CA_CERTS", "NODE_TLS_REJECT_UNAUTHORIZED", "NODE_USE_SYSTEM_CA",
        "SSL_CERT_FILE", "SSL_CERT_DIR",
    ]

    /// Proxy variables that pass through; listed so the audit output can say so.
    public static let passedProxyNames = ["HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY"]

    /// True when a variable of this name is never handed to the child.
    public static func isDenied(_ key: String) -> Bool {
        let upper = key.uppercased()
        if deniedNames.contains(upper) { return true }
        return deniedPrefixes.contains { upper.hasPrefix($0) }
    }

    /// The environment without the denied variables.
    public static func filter(_ environment: [String: String]) -> [String: String] {
        environment.filter { !isDenied($0.key) }
    }

    /// The names in `environment` the filter removes, sorted, for the setup audit (`pairvox-cli --env-audit`).
    public static func droppedNames(in environment: [String: String]) -> [String] {
        environment.keys.filter(isDenied).sorted()
    }
}
