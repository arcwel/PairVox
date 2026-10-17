// SPDX-License-Identifier: Apache-2.0

import Foundation

public enum Opening: Codable, Sendable {
    case hello(version: Int, deviceID: String, clientNonce: Data)
    case pair(PairRequest)
}
public struct Challenge: Codable, Sendable { public var hostNonce: Data; public var proof: Data
    public init(hostNonce: Data, proof: Data) { self.hostNonce = hostNonce; self.proof = proof } }
public struct Auth: Codable, Sendable { public var proof: Data
    public init(proof: Data) { self.proof = proof } }
public enum PairReply: Codable, Sendable { case grant(PairGrant); case failed(String) }

/// Sent in place of a `Challenge` when the Mac will not start a session with this phone: it is not paired, its key
/// was revoked, or it speaks another protocol version. The phone stops retrying and tells its owner, instead of
/// treating a silent close as a network problem. Nothing secret is disclosed: device IDs are random, and whether one
/// is paired is all this says.
public struct HandshakeRefusal: Codable, Sendable {
    public enum Reason: String, Codable, Sendable { case unknownDevice, revoked, versionMismatch }
    public var refused: Reason
    public init(_ reason: Reason) { refused = reason }

    public var error: LinkError {
        switch refused {
        case .unknownDevice: return .unknownDevice
        case .revoked: return .revoked
        case .versionMismatch: return .versionMismatch
        }
    }
}

