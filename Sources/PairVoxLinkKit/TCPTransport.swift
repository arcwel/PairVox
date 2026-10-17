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

    /// The latest connection state in words ("connected", "connecting", "failed: ..."), for error messages. Written
    /// on the connection's queue and read from anywhere, so it is guarded by the same lock as `connectFailure`.
    public var stateDescription: String { lock.lock(); defer { lock.unlock() }; return state }
    private var state = "starting"
    /// The error behind a connection that could not be made (refused, no route). Reads and writes throw it instead
    /// of the cancellation that followed, so the caller can say what went wrong.
    private let lock = NSLock()
    private var connectFailure: NWError?

    public init(connection: NWConnection) {
        signal(SIGPIPE, SIG_IGN)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] update in
            guard let self else { return }
            self.lock.lock()
            switch update {
            case .ready: self.state = "connected"
            case .waiting(let e):
                // The framework would wait for the network to change and try again on its own, for as long as it
                // takes. The callers retry themselves, so a connection that cannot be made now fails now.
                self.state = "failed: \(e.localizedDescription)"
                self.connectFailure = e
                self.lock.unlock()
                connection.cancel()
                return
            case .failed(let e):
                self.state = "failed: \(e.localizedDescription)"
                if self.connectFailure == nil { self.connectFailure = e }
            case .preparing: self.state = "connecting"
            case .cancelled: if self.state == "connecting" || self.state == "starting" { self.state += " (cancelled)" }
            default: break
            }
            self.lock.unlock()
        }
        connection.start(queue: queue)
    }

    private func failure(or error: Error) -> Error {
        lock.lock(); defer { lock.unlock() }
        return connectFailure ?? error
    }

    public static func connect(host: String, port: UInt16) -> TCPTransport {
        TCPTransport(connection: NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp))
    }

    public func send(_ data: Data) async throws {
        guard data.count <= Self.maxMessage else { throw LinkError.badFrame }
        var length = UInt32(data.count).bigEndian
        let framed = Data(bytes: &length, count: 4) + data
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: framed, completion: .contentProcessed { [weak self] error in
                if let error { cont.resume(throwing: self?.failure(or: error) ?? error) } else { cont.resume() }
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
            connection.receive(minimumIncompleteLength: count, maximumLength: count) { [weak self] data, _, _, error in
                if let error { cont.resume(throwing: self?.failure(or: error) ?? error) }
                else if let data, data.count == count { cont.resume(returning: data) }
                else { cont.resume(throwing: self?.failure(or: LinkError.closed) ?? LinkError.closed) }
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

    /// `allow` sees the peer's address before anything is read; a refused peer is dropped at once. With `bindTo`
    /// the listener accepts connections only on that local address (the Mac's Tailscale address, or 127.0.0.1 for a
    /// userspace Tailscale forward), so the port is not open on Wi-Fi, Ethernet or a hotspot at all; without it, on
    /// every interface, and `allow` is the only gate.
    public init(port: UInt16 = 0, bindTo: String? = nil, allow: @escaping @Sendable (NWEndpoint.Host) -> Bool = { _ in true },
                onConnection: @escaping @Sendable (TCPTransport) -> Void) throws {
        let wanted: NWEndpoint.Port = port == 0 ? .any : NWEndpoint.Port(rawValue: port)!
        if let bindTo {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(bindTo), port: wanted)
            listener = try NWListener(using: parameters)
        } else {
            listener = try NWListener(using: .tcp, on: wanted)
        }
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
