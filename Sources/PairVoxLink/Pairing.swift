// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation
import PairVoxLinkKit

public struct PairedDevice: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    /// The phone's secret key. With a key store it is kept there and left out of the file.
    public var psk: Data
    public var createdAt: Date
    public var revoked: Bool

    enum CodingKeys: String, CodingKey { case id, name, psk, createdAt, revoked }
    init(id: String, name: String, psk: Data, createdAt: Date, revoked: Bool) {
        self.id = id; self.name = name; self.psk = psk; self.createdAt = createdAt; self.revoked = revoked
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id); name = sanitizedDeviceName(try c.decode(String.self, forKey: .name))
        psk = (try? c.decode(Data.self, forKey: .psk)) ?? Data()
        createdAt = try c.decode(Date.self, forKey: .createdAt); revoked = try c.decode(Bool.self, forKey: .revoked)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(name, forKey: .name)
        if !psk.isEmpty { try c.encode(psk, forKey: .psk) }
        try c.encode(createdAt, forKey: .createdAt); try c.encode(revoked, forKey: .revoked)
    }
}

/// What the Mac shows to the person pairing: a QR payload or a six-digit code, valid once and briefly.
public struct PairingOffer: Sendable, Equatable {
    public enum Kind: Sendable { case qr, code }
    public var kind: Kind
    /// The text to put in the QR code, or the six digits.
    public var display: String
    var material: Data
    public var expires: Date
}

/// A phone name safe to show in the Accept dialog: no control or direction-override characters, at most 64
/// characters and 128 bytes, and never empty.
public func sanitizedDeviceName(_ raw: String) -> String {
    let banned = CharacterSet.controlCharacters.union(.newlines)
        .union(CharacterSet(charactersIn: "\u{200E}\u{200F}\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}\u{2066}\u{2067}\u{2068}\u{2069}\u{3164}\u{115F}\u{1160}\u{FFA0}\u{200B}\u{FEFF}\u{2800}\u{17B4}\u{17B5}"))
    var out = ""
    for ch in String(raw.unicodeScalars.filter { !banned.contains($0) }).prefix(64) {
        if (out + String(ch)).utf8.count > 128 { break }
        out.append(ch)
    }
    out = out.trimmingCharacters(in: .whitespaces)
    return out.isEmpty ? "Unnamed phone" : out
}

public enum PairingError: Error, Equatable { case noOffer, expired, wrongSecret, declined, burned, keyNotDestroyed }

/// The Mac's list of paired phones and the one open pairing offer. Stored 0600; keys can be revoked at any time.
public actor PairingManager {
    private let url: URL?
    private let keys: DeviceKeyStore?
    private(set) var devices: [PairedDevice]
    private var offer: PairingOffer?
    private var failuresByPeer: [String: Int] = [:]
    private var totalFailures = 0
    /// A peer that sends this many wrong proofs is ignored for the rest of the offer.
    public static let maxFailures = 3
    /// Across every peer, this many wrong proofs burn the offer (12 guesses in a million for a six-digit code).
    public static let maxTotalFailures = 12
    public static let offerLifetime: TimeInterval = 120

    /// With a `keys` store, phone keys live there and the file holds only names and dates. A file written by an
    /// earlier version (keys inside) is converted on first load.
    ///
    /// With `deferKeys`, the key store is not read in `init` but on the first use, off the caller's thread. The
    /// Mac app uses this: the Keychain may show a permission prompt (a rebuilt app has a new code signature),
    /// and a prompt during `init` would freeze the app at launch.
    public init(storeURL: URL?, keys: DeviceKeyStore? = nil, deferKeys: Bool = false) {
        url = storeURL
        self.keys = keys
        devices = []
        if let storeURL, FileManager.default.fileExists(atPath: storeURL.path) {
            if let data = try? Data(contentsOf: storeURL), let list = try? JSONDecoder().decode([PairedDevice].self, from: data) { devices = list }
            else {
                // Unreadable: keep the bytes aside rather than overwrite them with the next pairing.
                let aside = storeURL.deletingLastPathComponent().appendingPathComponent("paired-phones.unreadable-\(Int(Date().timeIntervalSince1970)).json")
                try? FileManager.default.moveItem(at: storeURL, to: aside)
            }
        }
        if deferKeys, keys != nil { keysPending = true; return }
        if Self.attach(&devices, keys: keys) { try? Self.write(devices, to: storeURL, withKeysInFile: keys == nil) }
    }

    private var keysPending = false

    /// Reads the key store once, before anything looks at a phone's key.
    private func ensureKeys() {
        guard keysPending else { return }
        keysPending = false
        if Self.attach(&devices, keys: keys) { try? Self.write(devices, to: url, withKeysInFile: keys == nil) }
    }

    /// Fills each device's key from the key store. A file written by an earlier version (keys inside) is converted
    /// exactly once, on the first run with a key store; after that, a file entry that carries a key is not trusted
    /// at all, because only an Accept click on this Mac may create a phone. A phone whose key is missing from the
    /// key store stays in the list but cannot connect (a locked or unreadable Keychain must not erase pairings).
    private static func attach(_ devices: inout [PairedDevice], keys: DeviceKeyStore?) -> Bool {
        guard let keys else { return false }
        var changed = false
        let mayImport = !keys.legacyImportClosed
        for i in devices.indices {
            // Phone ids are UUIDs made by this app; a file cannot name anything else (such as another Keychain item).
            if UUID(uuidString: devices[i].id) == nil && !devices[i].revoked {
                devices[i].psk = Data(); devices[i].revoked = true; changed = true
                continue
            }
            if !devices[i].psk.isEmpty {
                if mayImport, !devices[i].revoked, (try? keys.setKey(devices[i].psk, for: devices[i].id)) != nil {
                    changed = true
                } else {
                    devices[i].psk = Data(); devices[i].revoked = true; changed = true   // planted or already revoked
                }
            } else if !devices[i].revoked, let k = keys.key(for: devices[i].id) {
                devices[i].psk = k
            }
        }
        keys.closeLegacyImport()
        return changed
    }

    public func pairedDevices() -> [PairedDevice] { ensureKeys(); return devices }

    public func createOffer(kind: PairingOffer.Kind, now: Date = Date()) -> PairingOffer {
        let made: PairingOffer
        switch kind {
        case .qr:
            let m = Handshake.randomBytes(16)
            made = PairingOffer(kind: .qr, display: m.base64EncodedString(), material: m, expires: now.addingTimeInterval(Self.offerLifetime))
        case .code:
            let digits = String(format: "%06d", Int.random(in: 0...999_999))
            made = PairingOffer(kind: .code, display: digits, material: Data(digits.utf8), expires: now.addingTimeInterval(Self.offerLifetime))
        }
        offer = made
        failuresByPeer = [:]
        totalFailures = 0
        return made
    }

    public func cancelOffer() { offer = nil }
    public func hasOpenOffer(now: Date = Date()) -> Bool { offer.map { now < $0.expires } ?? false }

    /// Checks the request against the open offer, asks the Mac's owner (`accept`), then issues a device key.
    /// Wrong proofs are counted per peer (three and that peer is ignored) and overall (twelve burn the offer). The offer works once.
    public func redeem(_ request: PairRequest, peer: String = "unknown", now: Date = Date(),
                       accept: @Sendable (String) async -> Bool) async throws -> PairGrant {
        ensureKeys()
        guard let current = offer else { throw PairingError.noOffer }
        guard now < current.expires else { offer = nil; throw PairingError.expired }
        // A peer that has already guessed wrong too often is ignored, without spending anyone else's chances.
        guard (failuresByPeer[peer] ?? 0) < Self.maxFailures else { throw PairingError.burned }
        guard request.name.utf8.count <= 512, request.clientNonce.count == 16 else { throw PairingError.wrongSecret }
        let expected = Data(HMAC<SHA256>.authenticationCode(for: Data("pair-request".utf8) + request.clientNonce + Data(request.name.utf8),
                                                            using: pairingKey(current.material)))
        guard Handshake.constantTimeEqual(expected, request.proof) else {
            failuresByPeer[peer, default: 0] += 1
            totalFailures += 1
            if totalFailures >= Self.maxTotalFailures { offer = nil; throw PairingError.burned }
            if failuresByPeer[peer]! >= Self.maxFailures { throw PairingError.burned }
            throw PairingError.wrongSecret
        }
        offer = nil   // one use, whatever the owner answers
        let shownName = sanitizedDeviceName(request.name)
        guard await accept(shownName) else { throw PairingError.declined }
        let device = PairedDevice(id: UUID().uuidString, name: shownName, psk: Handshake.randomBytes(32),
                                  createdAt: now, revoked: false)
        if let keys { try keys.setKey(device.psk, for: device.id) }
        devices.append(device)
        do { try persist() }
        catch {   // not saved, so not paired: nothing is left behind
            devices.removeAll { $0.id == device.id }
            keys?.removeKey(for: device.id)
            throw error
        }
        let plain = try JSONEncoder().encode(GrantContents(deviceID: device.id, psk: device.psk))
        let box = try ChaChaPoly.seal(plain, using: pairingKey(current.material), authenticating: request.clientNonce)
        return PairGrant(sealed: box.combined)
    }

    /// Marks a phone revoked. The block takes effect at once in memory even if saving fails; the error is thrown
    /// so the caller can tell the person that the block will not survive a restart.
    public func revoke(_ id: String) throws {
        ensureKeys()
        guard let i = devices.firstIndex(where: { $0.id == id }) else { return }
        devices[i].revoked = true
        let destroyed = keys?.removeKey(for: id) ?? true   // the key is destroyed, not only flagged
        devices[i].psk = Data()
        try persist()
        if !destroyed { throw PairingError.keyNotDestroyed }
    }

    public func activeDevice(_ id: String) -> PairedDevice? { ensureKeys(); return devices.first { $0.id == id && !$0.revoked && !$0.psk.isEmpty } }

    private func persist() throws { try Self.write(devices, to: url, withKeysInFile: keys == nil) }

    private static func write(_ devices: [PairedDevice], to url: URL?, withKeysInFile: Bool) throws {
        guard let url else { return }
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        let toWrite = withKeysInFile ? devices : devices.map { var d = $0; d.psk = Data(); return d }
        // The temporary file is created private, so nothing is readable by others, even briefly.
        let temp = dir.appendingPathComponent(".paired-\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temp.path, contents: try JSONEncoder().encode(toWrite),
                                             attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
    }
}
