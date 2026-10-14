// SPDX-License-Identifier: Apache-2.0

import Foundation
import Network

/// Length-prefixed messages over a TCP connection (4-byte big-endian length, then the bytes). The tailnet carries
/// them; confidentiality and authenticity come from `FrameCodec`, not from this layer.
public final class TCPTransport: LinkTransport, @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "pairvox.link.tcp")
    public static let maxMessage = FrameCodec.maxFrameBytes + 64
    public var peer: String? {
        if case .hostPort(let host, _) = connection.endpoint { return "\(host)" }
        return nil
    }

    public init(connection: NWConnection) {
        signal(SIGPIPE, SIG_IGN)
        self.connection = connection
        connection.start(queue: queue)
    }

    public static func connect(host: String, port: UInt16) -> TCPTransport {
        TCPTransport(connection: NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp))
    }

    public func send(_ data: Data) async throws {
        guard data.count <= Self.maxMessage else { throw LinkError.badFrame }
        var length = UInt32(data.count).bigEndian
        let framed = Data(bytes: &length, count: 4) + data
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: framed, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            })
        }
    }

    public func receive() async throws -> Data {
        let header = try await read(4)
        let length = Int(header.reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
        guard length <= Self.maxMessage else { throw LinkError.badFrame }
        return length == 0 ? Data() : try await read(length)
    }

    private func read(_ count: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
                if let error { cont.resume(throwing: error) }
                else if let data, data.count == count { cont.resume(returning: data) }
                else { cont.resume(throwing: LinkError.closed) }
            }
        }
    }

    public func close() async { connection.cancel() }
}

/// Accepts phone connections and hands each to the host. Bound to the addresses the caller allows; nothing here
/// grants access, since every connection still has to complete the keyed handshake.
public final class TCPListener: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "pairvox.link.listener")
    public private(set) var port: UInt16 = 0

    /// `allow` sees the peer's address before anything is read; a refused peer is dropped at once.
    public init(port: UInt16 = 0, allow: @escaping @Sendable (NWEndpoint.Host) -> Bool = { _ in true },
                onConnection: @escaping @Sendable (TCPTransport) -> Void) throws {
        listener = try NWListener(using: .tcp, on: port == 0 ? .any : NWEndpoint.Port(rawValue: port)!)
        listener.newConnectionHandler = { connection in
            guard case .hostPort(let host, _) = connection.endpoint, allow(host) else { connection.cancel(); return }
            onConnection(TCPTransport(connection: connection))
        }
    }

    public func start() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let once = OneShot()
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready: if once.take() { self?.port = self?.listener.port?.rawValue ?? 0; cont.resume() }
                case .failed(let error): if once.take() { cont.resume(throwing: error) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    public func stop() { listener.cancel() }
}

/// True exactly once; makes sure a continuation is resumed a single time.
final class OneShot: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false
    func take() -> Bool { lock.lock(); defer { lock.unlock() }; if used { return false }; used = true; return true }
}
