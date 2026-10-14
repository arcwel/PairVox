// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation
import PairVoxLinkKit

public struct PairedDevice: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var psk: Data
    public var createdAt: Date
    public var revoked: Bool
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
        .union(CharacterSet(charactersIn: "\u{200E}\u{200F}\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}\u{2066}\u{2067}\u{2068}\u{2069}\u{3164}\u{115F}\u{1160}\u{FFA0}\u{200B}\u{FEFF}"))
    var out = ""
    for ch in String(raw.unicodeScalars.filter { !banned.contains($0) }).prefix(64) {
        if (out + String(ch)).utf8.count > 128 { break }
        out.append(ch)
    }
    out = out.trimmingCharacters(in: .whitespaces)
    return out.isEmpty ? "Unnamed phone" : out
}

public enum PairingError: Error, Equatable { case noOffer, expired, wrongSecret, declined, burned }

/// The Mac's list of paired phones and the one open pairing offer. Stored 0600; keys can be revoked at any time.
public actor PairingManager {
    private let url: URL?
    private(set) var devices: [PairedDevice]
    private var offer: PairingOffer?
    private var failuresByPeer: [String: Int] = [:]
    private var totalFailures = 0
    /// A peer that sends this many wrong proofs is ignored for the rest of the offer.
    public static let maxFailures = 3
    /// Across every peer, this many wrong proofs burn the offer (12 guesses in a million for a six-digit code).
    public static let maxTotalFailures = 12
    public static let offerLifetime: TimeInterval = 120

    public init(storeURL: URL?) {
        url = storeURL
        devices = []
        if let storeURL, FileManager.default.fileExists(atPath: storeURL.path) {
            if let data = try? Data(contentsOf: storeURL), let list = try? JSONDecoder().decode([PairedDevice].self, from: data) { devices = list }
            else {
                // Unreadable: keep the bytes aside rather than overwrite them with the next pairing.
                let aside = storeURL.deletingLastPathComponent().appendingPathComponent("paired-phones.unreadable-\(Int(Date().timeIntervalSince1970)).json")
                try? FileManager.default.moveItem(at: storeURL, to: aside)
            }
        }
    }

    public func pairedDevices() -> [PairedDevice] { devices }

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
        devices.append(device)
        try persist()
        let plain = try JSONEncoder().encode(GrantContents(deviceID: device.id, psk: device.psk))
        let box = try ChaChaPoly.seal(plain, using: pairingKey(current.material), authenticating: request.clientNonce)
        return PairGrant(sealed: box.combined)
    }

    /// Marks a phone revoked. The block takes effect at once in memory even if saving fails; the error is thrown
    /// so the caller can tell the person that the block will not survive a restart.
    public func revoke(_ id: String) throws {
        guard let i = devices.firstIndex(where: { $0.id == id }) else { return }
        devices[i].revoked = true
        try persist()
    }

    public func activeDevice(_ id: String) -> PairedDevice? { devices.first { $0.id == id && !$0.revoked } }

    private func persist() throws {
        guard let url else { return }
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        // The temporary file is created private, so the keys are never readable by others, even briefly.
        let temp = dir.appendingPathComponent(".paired-\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temp.path, contents: try JSONEncoder().encode(devices),
                                             attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
    }
}
