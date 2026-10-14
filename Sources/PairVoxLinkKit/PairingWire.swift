// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation

public struct PairRequest: Codable, Sendable, Equatable {
    public var name: String
    public var clientNonce: Data
    public var proof: Data
    public init(name: String, clientNonce: Data, proof: Data) { self.name = name; self.clientNonce = clientNonce; self.proof = proof }
}

/// What the Mac sends back after its owner clicks Accept: the device's permanent key, sealed so only someone who
/// knew the offer can read it.
public struct PairGrant: Codable, Sendable, Equatable {
    public var sealed: Data
    public init(sealed: Data) { self.sealed = sealed }
}

/// Sent by the phone once it has opened and kept its key. A Mac that does not get it removes the phone again, so a
/// phone that gave up before the owner clicked Pair does not stay on the list with a key it never received.
public struct PairAck: Codable, Sendable, Equatable {
    public var ack = true
    public init() {}
}

public struct GrantContents: Codable { public var deviceID: String; public var psk: Data
    public init(deviceID: String, psk: Data) { self.deviceID = deviceID; self.psk = psk } }

/// The shared key for one pairing exchange, derived from the offer's secret.
public func pairingKey(_ material: Data) -> SymmetricKey {
    HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: material), salt: Data("pairvox-pairing".utf8),
                           info: Data("v1".utf8), outputByteCount: 32)
}

/// The phone's half of pairing.
public enum PairingClient {
    public static func material(fromCode digits: String) -> Data { Data(digits.utf8) }
    public static func material(fromQR payload: String) -> Data? { Data(base64Encoded: payload) }

    public static func request(material: Data, deviceName: String) -> PairRequest {
        let nonce = Handshake.randomBytes(16)
        let mac = HMAC<SHA256>.authenticationCode(for: Data("pair-request".utf8) + nonce + Data(deviceName.utf8),
                                                  using: pairingKey(material))
        return PairRequest(name: deviceName, clientNonce: nonce, proof: Data(mac))
    }

    /// Opens the grant; nil if it was not sealed with this offer's key.
    public static func open(_ grant: PairGrant, material: Data, request: PairRequest) -> (deviceID: String, psk: Data)? {
        guard let box = try? ChaChaPoly.SealedBox(combined: grant.sealed),
              let plain = try? ChaChaPoly.open(box, using: pairingKey(material), authenticating: request.clientNonce),
              let contents = try? JSONDecoder().decode(GrantContents.self, from: plain) else { return nil }
        return (contents.deviceID, contents.psk)
    }
}

