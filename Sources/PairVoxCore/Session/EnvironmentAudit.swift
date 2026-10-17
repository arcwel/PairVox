// SPDX-License-Identifier: Apache-2.0

import Foundation

/// What `ChildEnvironment` would do to a given environment, as names only: the report behind
/// `pairvox-cli --env-audit`. Values of dropped variables are never stored, so they cannot be printed.
public struct EnvironmentAudit: Equatable, Sendable {
    /// Why the deny-list removes a variable; the one-line group shown next to its name.
    public enum Reason: String, Equatable, Sendable, CaseIterable {
        /// `ANTHROPIC_*`: endpoint, headers, key, token and model overrides.
        case anthropic
        /// `CLAUDE_CODE_*` and `CLAUDECODE`: the OAuth token, the Bedrock and Vertex switches, nesting markers.
        case claudeCode = "claude-code"
        /// `CLAUDE_CONFIG_DIR`: another settings folder.
        case configDir = "config-dir"
        /// `NODE_*` and `SSL_CERT_*`: code loaded into the child, or TLS a proxy can read.
        case nodeTLS = "node/tls"
    }

    public struct Dropped: Equatable, Sendable {
        public var name: String
        public var reason: Reason
    }

    public struct Proxy: Equatable, Sendable {
        public var name: String
        /// True when the variable is set in either case (`HTTPS_PROXY` or `https_proxy`).
        public var isSet: Bool
    }

    /// Names the filter removes, sorted, each with its reason.
    public var dropped: [Dropped]
    /// The proxy variables that pass through, in `ChildEnvironment.passedProxyNames` order.
    public var proxies: [Proxy]
    /// Variables forwarded unchanged, not counting the proxy variables above.
    public var forwardedCount: Int

    public init(environment: [String: String]) {
        dropped = ChildEnvironment.droppedNames(in: environment).compactMap { name in
            Self.reason(for: name).map { Dropped(name: name, reason: $0) }
        }
        let upperKeys = Set(environment.keys.map { $0.uppercased() })
        proxies = ChildEnvironment.passedProxyNames.map { Proxy(name: $0, isSet: upperKeys.contains($0)) }
        let proxyNames = Set(ChildEnvironment.passedProxyNames)
        forwardedCount = ChildEnvironment.filter(environment).keys.filter { !proxyNames.contains($0.uppercased()) }.count
    }

    /// The reason group for a denied name; nil for a name the deny-list does not claim.
    public static func reason(for name: String) -> Reason? {
        guard ChildEnvironment.isDenied(name) else { return nil }
        let upper = name.uppercased()
        if upper.hasPrefix("ANTHROPIC_") { return .anthropic }
        if upper.hasPrefix("CLAUDE_CODE_") || upper == "CLAUDECODE" { return .claudeCode }
        if upper == "CLAUDE_CONFIG_DIR" { return .configDir }
        return .nodeTLS
    }

    /// The names of the proxies that are set, for the JSON report.
    public var proxiesSet: [String] { proxies.filter(\.isSet).map(\.name) }

    /// Human-readable report, one variable per line.
    public func textReport() -> String {
        var lines = ["Dropped before the child starts (names only):"]
        if dropped.isEmpty {
            lines.append("  (none)")
        } else {
            let width = dropped.map(\.name.count).max() ?? 0
            for d in dropped { lines.append("  \(d.name.padding(toLength: width, withPad: " ", startingAt: 0))  \(d.reason.rawValue)") }
        }
        lines.append("Proxy variables (pass through):")
        let width = proxies.map(\.name.count).max() ?? 0
        for p in proxies { lines.append("  \(p.name.padding(toLength: width, withPad: " ", startingAt: 0))  \(p.isSet ? "set" : "not set")") }
        lines.append("Forwarded unchanged: \(forwardedCount) ordinary variable\(forwardedCount == 1 ? "" : "s").")
        return lines.joined(separator: "\n")
    }

    /// Stable JSON object: `dropped` (name, reason), `proxiesSet`, `forwardedCount`. Keys are sorted.
    public func jsonReport() -> String {
        let object: [String: Any] = [
            "dropped": dropped.map { ["name": $0.name, "reason": $0.reason.rawValue] },
            "proxiesSet": proxiesSet,
            "forwardedCount": forwardedCount,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }
}
