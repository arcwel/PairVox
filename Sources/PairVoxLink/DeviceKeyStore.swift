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

/// Phone keys in one private file (0600, in a 0700 folder). For development builds: the Keychain trusts an app by
/// its code signature, and a build without a team identity gets a new signature on every build, so macOS asks again
/// after each one. This is how the keys were kept before the Keychain was used. Release builds use the Keychain.
public final class FileDeviceKeyStore: DeviceKeyStore, @unchecked Sendable {
    private let directory: URL
    private let lock = NSLock()
    private var closedThisSession = false
    private var keysFile: URL { directory.appendingPathComponent("phone-keys.json") }
    private var markerFile: URL { directory.appendingPathComponent("phone-keys.legacy-import-closed") }

    public init(directory: URL) {
        self.directory = directory
        removeStaleTemporaryFiles()
    }

    /// A crash between writing a temporary file and renaming it would leave a copy of every key behind.
    private func removeStaleTemporaryFiles() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasPrefix("phone-keys.") && name.hasSuffix(".tmp") {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    /// A missing file is an empty store. A file that cannot be read or decoded is moved aside (kept, not erased) and
    /// the store starts empty, so one damaged file cannot make the next write silently drop every other phone's key
    /// while destroying the evidence.
    private func load() -> [String: Data] {
        guard FileManager.default.fileExists(atPath: keysFile.path) else { return [:] }
        if let data = try? Data(contentsOf: keysFile), let raw = try? JSONDecoder().decode([String: String].self, from: data) {
            return raw.compactMapValues { Data(base64Encoded: $0) }
        }
        let aside = directory.appendingPathComponent("phone-keys.unreadable-\(Int(Date().timeIntervalSince1970)).json")
        try? FileManager.default.moveItem(at: keysFile, to: aside)
        return [:]
    }

    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // createDirectory leaves an existing folder as it is.
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    private func save(_ keys: [String: Data]) throws {
        try prepareDirectory()
        let data = try JSONEncoder().encode(keys.mapValues { $0.base64EncodedString() })
        let temp = directory.appendingPathComponent("phone-keys.\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            _ = try FileManager.default.replaceItemAt(keysFile, withItemAt: temp)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keysFile.path)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
        // Keys are not copied to Time Machine or other backups.
        var url = keysFile
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    public func key(for id: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return load()[id].flatMap { $0.count == 32 ? $0 : nil }
    }

    public func setKey(_ key: Data, for id: String) throws {
        lock.lock(); defer { lock.unlock() }
        var all = load()
        all[id] = key
        try save(all)
    }

    @discardableResult public func removeKey(for id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        var all = load()
        guard all.removeValue(forKey: id) != nil else { return true }
        return (try? save(all)) != nil
    }

    /// A marker that cannot be written still counts as closed for the rest of this run.
    public var legacyImportClosed: Bool {
        lock.lock(); defer { lock.unlock() }
        return closedThisSession || FileManager.default.fileExists(atPath: markerFile.path)
    }

    public func closeLegacyImport() {
        lock.lock(); defer { lock.unlock() }
        closedThisSession = true
        try? prepareDirectory()
        FileManager.default.createFile(atPath: markerFile.path, contents: Data("1".utf8), attributes: [.posixPermissions: 0o600])
    }
}

public enum DeviceKeyStores {
    /// Certificate names that mean a build was signed for distribution, so its Keychain items belong to an identity
    /// that does not change between builds. An `Apple Development` certificate is stable too, but a development
    /// build keeps the key file: the day local builds moved to that certificate, the first one looked in the
    /// Keychain, found no key for the paired phone and told it "revoked".
    static let distributionCertificatePrefixes = ["Developer ID Application:", "Apple Distribution:", "3rd Party Mac Developer Application:"]

    /// True when the running app is signed for distribution (see `distributionCertificatePrefixes`) with a team.
    public static func runningBuildIsDistributionSigned() -> Bool {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return false }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return false }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any],
              (dict[kSecCodeInfoTeamIdentifier as String] as? String)?.isEmpty == false,
              let leaf = (dict[kSecCodeInfoCertificates as String] as? [SecCertificate])?.first,
              let name = SecCertificateCopySubjectSummary(leaf) as String? else { return false }
        return isDistributionCertificate(name)
    }

    static func isDistributionCertificate(_ subjectSummary: String) -> Bool {
        distributionCertificatePrefixes.contains { subjectSummary.hasPrefix($0) }
    }

    /// The Keychain for a distribution-signed build, a private file otherwise. `PAIRVOX_KEYSTORE=keychain` forces the
    /// Keychain in a development build; nothing can force the file in a distribution build.
    public static func automatic(directory: URL, environment: [String: String] = ProcessInfo.processInfo.environment,
                                 isDistributionSigned: () -> Bool = runningBuildIsDistributionSigned) -> (store: DeviceKeyStore, name: String) {
        // A distribution build always uses the Keychain: an environment variable set by another process must not be
        // able to move its keys into a plain file.
        if isDistributionSigned() { return (KeychainDeviceKeyStore(), "keychain") }
        return environment["PAIRVOX_KEYSTORE"] == "keychain" ? (KeychainDeviceKeyStore(), "keychain") : (FileDeviceKeyStore(directory: directory), "file")
    }
}
