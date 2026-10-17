// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Lets only the project the user is in speak. While a project is in the background its speech is not played;
/// the engine still sees every utterance finish at once, so its state stays correct, and what it said is kept in its
/// transcript for the "catch me up" controls.
public final class GatedSpeechOutput: SpeechOutput, @unchecked Sendable {
    public let events: AsyncStream<SpeechOutputEvent>
    private let continuation: AsyncStream<SpeechOutputEvent>.Continuation
    private let inner: any SpeechOutput
    private let lock = NSLock()
    private var active: Bool
    private var inFlight: Set<Int> = []
    private var forwarder: Task<Void, Never>?

    public init(inner: any SpeechOutput, active: Bool = false) {
        self.inner = inner
        self.active = active
        var c: AsyncStream<SpeechOutputEvent>.Continuation!
        events = AsyncStream(bufferingPolicy: .unbounded) { c = $0 }
        continuation = c
        let stream = inner.events
        forwarder = Task { [weak self] in
            for await event in stream { self?.forward(event) }
        }
    }

    deinit { forwarder?.cancel() }

    public var isActive: Bool { lock.withLock { active } }

    private func forward(_ event: SpeechOutputEvent) {
        let pass: Bool = lock.withLock {
            switch event {
            case .started(let id): return active && inFlight.contains(id)
            case .finished(let id), .failed(let id, _): return inFlight.remove(id) != nil
            case .idle: return active
            }
        }
        if pass { continuation.yield(event) }
    }

    public func enqueue(_ utterance: Utterance) {
        let play: Bool = lock.withLock {
            if active { inFlight.insert(utterance.id) }
            return active
        }
        if play {
            inner.enqueue(utterance)
        } else {
            // Not this project's turn to speak: done, as far as the engine is concerned.
            continuation.yield(.finished(utterance.id))
            continuation.yield(.idle)
        }
    }

    @discardableResult
    public func stopAll() -> [Int] {
        let wasActive: Bool = lock.withLock {
            inFlight.removeAll()
            return active
        }
        return wasActive ? inner.stopAll() : []
    }

    public func setRate(_ rate: Double) { inner.setRate(rate) }

    public var supportsPause: Bool { inner.supportsPause }
    public func pause() { if isActive { inner.pause() } }
    public func resume() { if isActive { inner.resume() } }

    @discardableResult
    public func cancelQueued(_ ids: [Int]) -> [Int] {
        guard isActive else { return [] }
        let removed = inner.cancelQueued(ids)
        lock.withLock { for id in removed { inFlight.remove(id) } }
        return removed
    }

    /// Turns this project's voice on or off. Turning it off cuts any playback and tells the engine everything it
    /// had queued is finished, so it does not wait for audio that will never come.
    public func setActive(_ on: Bool) {
        let (changed, pending): (Bool, [Int]) = lock.withLock {
            let changed = active != on
            active = on
            let ids = Array(inFlight)
            if !on { inFlight.removeAll() }
            return (changed, on ? [] : ids)
        }
        guard changed, !on else { return }
        inner.stopAll()
        for id in pending { continuation.yield(.finished(id)) }
        continuation.yield(.idle)
    }
}
