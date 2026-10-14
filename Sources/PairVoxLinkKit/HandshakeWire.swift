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

