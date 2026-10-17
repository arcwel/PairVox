// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A message-oriented, ordered connection. The protocol never depends on how bytes travel, so tests use memory
/// and the app uses TCP over the tailnet.
public protocol LinkTransport: Sendable {
    /// Where the peer connected from (an address), used to count pairing failures per source. Nil when unknown.
    var peer: String? { get }
    func send(_ data: Data) async throws
    func receive() async throws -> Data
    func close() async
}

/// Two connected in-memory ends, for tests.
public final class MemoryTransport: LinkTransport, @unchecked Sendable {
    public var peer: String? { "memory" }
    private let incoming: AsyncStream<Data>
    private let outgoing: AsyncStream<Data>.Continuation
    private let ownContinuation: AsyncStream<Data>.Continuation
    private var iterator: AsyncStream<Data>.Iterator

    private init(incoming: AsyncStream<Data>, own: AsyncStream<Data>.Continuation, outgoing: AsyncStream<Data>.Continuation) {
        self.incoming = incoming; self.ownContinuation = own; self.outgoing = outgoing
        self.iterator = incoming.makeAsyncIterator()
    }

    public static func pair() -> (MemoryTransport, MemoryTransport) {
        var ca: AsyncStream<Data>.Continuation!, cb: AsyncStream<Data>.Continuation!
        let a = AsyncStream<Data> { ca = $0 }, b = AsyncStream<Data> { cb = $0 }
        return (MemoryTransport(incoming: a, own: ca, outgoing: cb), MemoryTransport(incoming: b, own: cb, outgoing: ca))
    }

    public func send(_ data: Data) async throws { outgoing.yield(data) }

    public func receive() async throws -> Data {
        // One reader per transport, so the iterator needs no lock.
        guard let next = await iterator.next() else { throw LinkError.closed }
        return next
    }

    public func close() async { outgoing.finish(); ownContinuation.finish() }
}
