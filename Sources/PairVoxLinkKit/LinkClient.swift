// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The phone's side of the link, without any UI. The iOS app and the test client both use it.
public actor LinkClient {
    private let transport: LinkTransport
    private var codec: FrameCodec

    private init(transport: LinkTransport, codec: FrameCodec) { self.transport = transport; self.codec = codec }

    /// Connects with a paired device's key. Throws if the Mac does not know the device or the keys differ.
    public static func connect(over transport: LinkTransport, deviceID: String, psk: Data) async throws -> LinkClient {
        let cNonce = Handshake.randomBytes(16)
        try await transport.send(try JSONEncoder().encode(Opening.hello(version: Handshake.version, deviceID: deviceID, clientNonce: cNonce)))
        let challenge = try JSONDecoder().decode(Challenge.self, from: try await transport.receive())
        guard Handshake.constantTimeEqual(challenge.proof, Handshake.proof(psk: psk, role: "host", first: cNonce, second: challenge.hostNonce, deviceID: deviceID)) else {
            throw LinkError.authFailed
        }
        try await transport.send(try JSONEncoder().encode(Auth(proof: Handshake.proof(psk: psk, role: "client", first: challenge.hostNonce, second: cNonce, deviceID: deviceID))))
        let keys = LinkKeys.derive(psk: psk, clientNonce: cNonce, hostNonce: challenge.hostNonce, isHost: false)
        return LinkClient(transport: transport, codec: FrameCodec(keys: keys))
    }

    /// Pairs a new phone with the secret from the Mac's QR code or six-digit code.
    public static func pair(over transport: LinkTransport, material: Data, deviceName: String) async throws -> (deviceID: String, psk: Data) {
        let request = PairingClient.request(material: material, deviceName: deviceName)
        try await transport.send(try JSONEncoder().encode(Opening.pair(request)))
        guard case .grant(let grant) = try JSONDecoder().decode(PairReply.self, from: try await transport.receive()),
              let opened = PairingClient.open(grant, material: material, request: request) else { throw LinkError.authFailed }
        return opened
    }

    public func send(_ message: ClientMessage) async throws {
        try await transport.send(try codec.seal(try JSONEncoder().encode(message)))
    }

    public func receive() async throws -> HostMessage {
        try JSONDecoder().decode(HostMessage.self, from: try codec.open(try await transport.receive()))
    }

    public func close() async { await transport.close() }
}
