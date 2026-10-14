// SPDX-License-Identifier: Apache-2.0

import Foundation
import Security

/// What a phone keeps after pairing: which Mac, and the key that proves this phone is the one that was paired.
public struct PhoneCredentials: Codable, Sendable, Equatable {
    public var deviceID: String
    public var psk: Data
    public var host: String
    public var port: UInt16
    public init(deviceID: String, psk: Data, host: String, port: UInt16) {
        self.deviceID = deviceID; self.psk = psk; self.host = host; self.port = port
    }
}

public protocol CredentialStore: Sendable {
    func load() -> PhoneCredentials?
    func save(_ credentials: PhoneCredentials) throws
    func delete()
}

public final class MemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: PhoneCredentials?
    public init(_ value: PhoneCredentials? = nil) { self.value = value }
    public func load() -> PhoneCredentials? { lock.lock(); defer { lock.unlock() }; return value }
    public func save(_ c: PhoneCredentials) throws { lock.lock(); value = c; lock.unlock() }
    public func delete() { lock.lock(); value = nil; lock.unlock() }
}

/// The key lives in the Keychain, readable only while the phone is unlocked, never synced to iCloud and never
/// restored onto another device.
public struct KeychainCredentialStore: CredentialStore {
    let service: String
    public init(service: String = "app.pairvox.phone") { self.service = service }

    private var base: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: "paired-mac", kSecAttrSynchronizable as String: false]
    }

    public func load() -> PhoneCredentials? {
        var query = base
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(PhoneCredentials.self, from: data)
    }

    /// Replaces the stored key in place, so a failed save never leaves the phone with no key at all.
    public func save(_ credentials: PhoneCredentials) throws {
        let data = try JSONEncoder().encode(credentials)
        let update = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(update)) }
        var item = base
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    public func delete() { SecItemDelete(base as CFDictionary) }
}

/// What the Mac's QR code carries: `pairvox://pair?h=<tailnet address>&p=<port>&s=<one-time secret>`.
public struct PairingPayload: Equatable, Sendable {
    public var host: String
    public var port: UInt16
    public var material: Data

    /// Parses the QR text. The host must look like an address or a name (no slashes or spaces), the port must be a
    /// real port, and the secret must be base64url text of the expected size.
    public static func parse(_ text: String) -> PairingPayload? {
        guard let comps = URLComponents(string: text), comps.scheme == "pairvox", comps.host == "pair" else { return nil }
        func value(_ name: String) -> String? { comps.queryItems?.first { $0.name == name }?.value }
        guard let host = value("h"), isAllowedHost(host), let p = value("p"), let port = UInt16(p), port >= 1024,
              let s = value("s") else { return nil }
        let b64 = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard let material = Data(base64Encoded: b64), material.count == 16 else { return nil }
        return PairingPayload(host: host, port: port, material: material)
    }

    /// The only places a phone may be told to pair with: a Tailscale address (100.64.0.0/10 or fd7a:115c:a1e0::/48),
    /// a MagicDNS name ending in .ts.net, or this device itself for testing. ASCII only, so a lookalike name cannot pass.
    public static func isAllowedHost(_ h: String) -> Bool {
        guard !h.isEmpty, h.count <= 253, h.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == ":") }) else { return false }
        let lower = h.lowercased()
        if lower == "localhost" || lower == "::1" { return true }
        let parts = lower.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count == 4, parts.allSatisfy({ !$0.isEmpty && $0.count <= 3 && $0.allSatisfy(\.isNumber) }) {
            let n = parts.compactMap { Int($0) }
            guard n.count == 4, n.allSatisfy({ (0...255).contains($0) }) else { return false }
            return (n[0] == 100 && (64...127).contains(n[1])) || n[0] == 127
        }
        if lower.contains(":") { return lower.hasPrefix("fd7a:115c:a1e0:") }
        let labels = lower.split(separator: ".", omittingEmptySubsequences: false)
        return lower.hasSuffix(".ts.net") && labels.count >= 3 && labels.allSatisfy { !$0.isEmpty && !$0.hasPrefix("-") && !$0.hasSuffix("-") }
    }
}
