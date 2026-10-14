// SPDX-License-Identifier: Apache-2.0

import Foundation
import Security

/// Where the Mac keeps each paired phone's secret key. The list of phones (names, dates) is a plain file; the keys
/// themselves live here, so a copy of that file is not enough to impersonate a phone.
public protocol DeviceKeyStore: Sendable {
    func key(for deviceID: String) -> Data?
    func setKey(_ key: Data, for deviceID: String) throws
    /// Returns false if the key could not be destroyed.
    @discardableResult func removeKey(for deviceID: String) -> Bool
    /// Set once, after the first load with a key store. From then on a phone file that carries a key inside is
    /// never trusted: only an Accept click on this Mac creates a phone.
    var legacyImportClosed: Bool { get }
    func closeLegacyImport()
}

public final class MemoryDeviceKeyStore: DeviceKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [String: Data] = [:]
    private var closed = false
    public init() {}
    public var legacyImportClosed: Bool { lock.lock(); defer { lock.unlock() }; return closed }
    public func closeLegacyImport() { lock.lock(); closed = true; lock.unlock() }
    public func key(for id: String) -> Data? { lock.lock(); defer { lock.unlock() }; return keys[id].flatMap { $0.count == 32 ? $0 : nil } }
    public func setKey(_ key: Data, for id: String) throws { lock.lock(); keys[id] = key; lock.unlock() }
    @discardableResult public func removeKey(for id: String) -> Bool { lock.lock(); keys[id] = nil; lock.unlock(); return true }
}

/// macOS Keychain, one generic-password item per phone. Available after the first unlock so the link can start
/// at login, never synced to iCloud, never moved to another Mac.
public struct KeychainDeviceKeyStore: DeviceKeyStore {
    let service: String
    public init(service: String = "app.pairvox.mac.paired-phones") { self.service = service }

    private func base(_ id: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: id, kSecAttrSynchronizable as String: false]
    }

    public func key(for id: String) -> Data? {
        var q = base(id)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let key = out as? Data, key.count == 32 else { return nil }
        return key
    }

    public func setKey(_ key: Data, for id: String) throws {
        let update = SecItemUpdate(base(id) as CFDictionary, [kSecValueData as String: key] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(update)) }
        var item = base(id)
        item[kSecValueData as String] = key
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    @discardableResult public func removeKey(for id: String) -> Bool {
        let status = SecItemDelete(base(id) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// The marker lives under its own service name, so no phone id from a file can ever name it.
    private var markerQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service + ".state",
         kSecAttrAccount as String: "legacy-import-closed", kSecAttrSynchronizable as String: false]
    }
    /// Only a plain "not found" leaves the one-time import open; any other answer (locked, denied, error) counts as closed.
    public var legacyImportClosed: Bool { SecItemCopyMatching(markerQuery as CFDictionary, nil) != errSecItemNotFound }
    public func closeLegacyImport() {
        var item = markerQuery
        item[kSecValueData as String] = Data("1".utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }
}
