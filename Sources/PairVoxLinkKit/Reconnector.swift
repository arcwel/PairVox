// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Keeps one link up: connects, runs the session until it ends, then tries again after a wait that doubles up to a
/// cap. A nudge (the app coming back to the front, the network coming back) ends the wait at once, and while
/// connected it runs `check`, so a link that died while the phone was asleep is replaced without waiting for the
/// keep-alive to notice. The phone app drives it; nothing here knows about UI or the network.
public actor Reconnector<Session: Sendable> {
    public struct Policy: Sendable {
        public var firstDelay: TimeInterval
        public var maxDelay: TimeInterval
        public init(firstDelay: TimeInterval = 1, maxDelay: TimeInterval = 15) {
            self.firstDelay = firstDelay; self.maxDelay = maxDelay
        }
    }

    public enum State: Sendable {
        case stopped
        case connecting
        case connected
        /// The last attempt or session ended with `error`; the next attempt comes after `retryIn` seconds unless nudged.
        case waiting(retryIn: TimeInterval, error: any Error)
        /// An attempt failed in a way retrying cannot fix (`isPermanent`). No more attempts until a nudge.
        case gaveUp(error: any Error)
    }

    private let policy: Policy
    private let connect: @Sendable () async throws -> Session
    private let run: @Sendable (Session) async throws -> Void
    private let check: @Sendable (Session) async -> Void
    private let close: @Sendable (Session) async -> Void
    private let isPermanent: @Sendable (any Error) -> Bool
    private let onState: @Sendable (State) -> Void

    private var generation = 0
    private var loop: Task<Void, Never>?
    private var sleeper: Task<Void, Never>?
    private var nudged = false
    private var current: Session?

    /// `connect` must fail on its own within a bounded time (close its transport on a timeout); `run` returns or
    /// throws when the session is over; `check` runs on a nudge while connected and should end a dead session;
    /// `close` releases a session; `isPermanent` says which connect errors mean "stop trying" (the Mac refused this
    /// phone) rather than "try again later"; `onState` reports each change.
    public init(policy: Policy = Policy(),
                connect: @escaping @Sendable () async throws -> Session,
                run: @escaping @Sendable (Session) async throws -> Void,
                check: @escaping @Sendable (Session) async -> Void = { _ in },
                close: @escaping @Sendable (Session) async -> Void,
                isPermanent: @escaping @Sendable (any Error) -> Bool = { _ in false },
                onState: @escaping @Sendable (State) -> Void) {
        self.policy = policy; self.connect = connect; self.run = run; self.check = check; self.close = close
        self.isPermanent = isPermanent; self.onState = onState
    }

    public var session: Session? { current }

    /// Starts (or restarts) the loop. Any earlier loop is ended and its session is closed.
    public func start() {
        endLoop()
        gaveUp = false
        generation += 1
        let mine = generation
        // The old loop is usually blocked inside `run` on a read that ignores cancellation, so its session is closed
        // here; closing is what frees it. The loop then finds that it is no longer current and leaves `current` alone.
        let old = current
        current = nil
        loop = Task { [weak self] in
            if let old, let self { await self.closeOld(old) }
            await self?.runLoop(mine)
        }
    }

    private func closeOld(_ s: Session) async { await close(s) }

    /// Ends the loop and closes the session. `onState` gets `.stopped`.
    public func stop() async {
        endLoop()
        if let s = current { current = nil; await close(s) }
        onState(.stopped)
    }

    /// Something changed that may make a connection possible or may have broken the current one. Waiting ends now
    /// and the delay starts over; a live session gets `check`; a loop that gave up tries once more.
    public func nudge() async {
        if let s = current { await check(s); return }
        if gaveUp { start(); return }
        nudged = true
        // An attempt that is in flight (maybe stuck on a dead route) is cut short so the next one starts now; a wait
        // in progress is ended.
        connectTask?.cancel()
        sleeper?.cancel()
    }

    private var gaveUp = false
    private var connectTask: Task<Session, any Error>?

    private func endLoop() {
        generation += 1
        loop?.cancel(); loop = nil
        sleeper?.cancel(); sleeper = nil
    }

    private func runLoop(_ mine: Int) async {
        var delay = policy.firstDelay
        while !Task.isCancelled, generation == mine {
            // A nudge that arrives while this attempt is in flight must survive a failure of the attempt: the app
            // came back to the front or the network changed, so the next try should not sit out the full delay.
            nudged = false
            onState(.connecting)
            let failure: any Error
            do {
                // The attempt runs as its own task so a nudge can cancel it; cancelling this loop cancels it too.
                let dial = connect
                let attempt = Task { try await dial() }
                connectTask = attempt
                let s: Session
                do { s = try await withTaskCancellationHandler { try await attempt.value } onCancel: { attempt.cancel() } }
                catch { connectTask = nil; throw error }
                connectTask = nil
                guard generation == mine else { await close(s); return }
                current = s
                nudged = false
                delay = policy.firstDelay
                onState(.connected)
                do { try await run(s); failure = LinkError.closed } catch { failure = error }
                // A newer loop (start() was called) has its own session; this one must not touch `current`.
                if generation == mine { current = nil }
                await close(s)
            } catch {
                failure = error
                if isPermanent(error) {
                    guard generation == mine else { return }
                    gaveUp = true
                    onState(.gaveUp(error: error))
                    return
                }
            }
            if Task.isCancelled || generation != mine { return }
            if !nudged { onState(.waiting(retryIn: delay, error: failure)) }   // a cut-short attempt has nothing to report
            if nudged { delay = policy.firstDelay }          // nudged during the attempt: try again now, backoff starts over
            else {
                await wait(delay)
                if generation != mine { return }
                delay = nudged ? policy.firstDelay : min(delay * 2, policy.maxDelay)
            }
        }
    }

    private func wait(_ seconds: TimeInterval) async {
        let t = Task<Void, Never> { _ = try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
        sleeper = t
        await t.value
        sleeper = nil
    }
}

/// Runs `body`, closing the transport and throwing `LinkError.closed` if it has not finished after `seconds`. A read
/// that is stuck only ends when its connection does, so cancellation alone would not free it.
public func withTimeout<T: Sendable>(_ seconds: Double, closing transport: LinkTransport,
                                     _ body: @escaping @Sendable () async throws -> T) async throws -> T {
    // If the caller is cancelled (a reconnect loop being stopped or nudged) while `body` is stuck on a read, the
    // group would wait for that read forever: closing the transport is what ends it. This handler fires only for
    // the caller's own cancellation, not for the group cancelling its timer after `body` finished.
    try await withTaskCancellationHandler {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                await transport.close()
                throw LinkError.closed
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    } onCancel: {
        Task { await transport.close() }
    }
}
