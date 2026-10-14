// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation

public enum LinkError: Error, Equatable {
    case badFrame, replay, authFailed, unknownDevice, revoked, versionMismatch, closed
}

/// Keys and framing for the phone link. Every frame is authenticated and encrypted with a key derived from the
/// pairing secret, so trusting the tailnet is never what protects an approval.
public struct LinkKeys: Sendable {
    let send: SymmetricKey
    let receive: SymmetricKey

    /// `isHost` decides which of the two directional keys is used to send.
    public static func derive(psk: Data, clientNonce: Data, hostNonce: Data, isHost: Bool) -> LinkKeys {
        let salt = clientNonce + hostNonce
        func key(_ info: String) -> SymmetricKey {
            HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: psk), salt: salt,
                                   info: Data(info.utf8), outputByteCount: 32)
        }
        let c2h = key("pairvox-link v1 client-to-host"), h2c = key("pairvox-link v1 host-to-client")
        return isHost ? LinkKeys(send: h2c, receive: c2h) : LinkKeys(send: c2h, receive: h2c)
    }
}

/// Seals and opens frames: `seq (8 bytes, big endian) || ChaCha20-Poly1305(ciphertext || tag)`. The nonce is the
/// sequence number, and each direction has its own key, so a nonce is never used twice with one key. The receiver
/// accepts only the next expected sequence number: a replayed, reordered or dropped frame ends the connection.
public struct FrameCodec: Sendable {
    private let keys: LinkKeys
    private var sendSeq: UInt64 = 0
    private var receiveSeq: UInt64 = 0
    public static let maxFrameBytes = 1 << 20

    public init(keys: LinkKeys) { self.keys = keys }

    public mutating func seal(_ plaintext: Data) throws -> Data {
        guard plaintext.count <= Self.maxFrameBytes else { throw LinkError.badFrame }
        let seq = sendSeq
        sendSeq += 1
        let header = Self.bytes(seq)
        let box = try ChaChaPoly.seal(plaintext, using: keys.send, nonce: Self.nonce(seq), authenticating: header)
        return header + box.ciphertext + box.tag
    }

    public mutating func open(_ frame: Data) throws -> Data {
        guard frame.count >= 8 + 16, frame.count <= Self.maxFrameBytes + 8 + 16 else { throw LinkError.badFrame }
        let header = frame.prefix(8)
        let seq = header.reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        guard seq == receiveSeq else { throw LinkError.replay }
        let body = frame.dropFirst(8)
        let box = try ChaChaPoly.SealedBox(nonce: Self.nonce(seq), ciphertext: body.dropLast(16), tag: body.suffix(16))
        guard let plain = try? ChaChaPoly.open(box, using: keys.receive, authenticating: Data(header)) else { throw LinkError.authFailed }
        receiveSeq += 1
        return plain
    }

    static func bytes(_ v: UInt64) -> Data { Data((0..<8).map { UInt8((v >> (8 * (7 - UInt64($0)))) & 0xFF) }) }
    static func nonce(_ seq: UInt64) -> ChaChaPoly.Nonce {
        // A 96-bit nonce: four zero bytes, then the 64-bit sequence number.
        try! ChaChaPoly.Nonce(data: Data(repeating: 0, count: 4) + bytes(seq))
    }
}

/// The three-message handshake that proves both sides hold the pairing key before any application data flows.
public enum Handshake {
    public static let version = 1

    /// A proof that the sender holds the device key. It covers the protocol version and the device ID as well as
    /// both nonces, and uses a key derived only for proofs, separate from the session keys.
    public static func proof(psk: Data, role: String, first: Data, second: Data, deviceID: String = "", version: Int = Handshake.version) -> Data {
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: psk), salt: Data(),
                                         info: Data("pairvox-link v1 proof".utf8), outputByteCount: 32)
        let message = Data("\(role)|\(version)|\(deviceID)|".utf8) + first + second
        return Data(HMAC<SHA256>.authenticationCode(for: message, using: key))
    }

    public static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        a.count == b.count && zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    public static func randomBytes(_ n: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<n).map { _ in UInt8.random(in: 0...255, using: &generator) })
    }
}
