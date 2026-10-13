// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A live Claude Code session. Implementations own a process (or, later, a
/// remote host for the iOS client) and publish `SessionEvent`s.
public protocol SessionBackend: AnyObject, Sendable {
    /// Events for the lifetime of this backend, across process restarts.
    var events: AsyncStream<SessionEvent> { get }
    var isRunning: Bool { get }
    var sessionID: String? { get }

    func start() throws
    /// Sends a user turn. Restarts (resuming the session) if the process died.
    func send(_ text: String) throws
    /// Interrupts the running turn. The session and its context stay alive.
    func interrupt() throws
    func respond(to request: PermissionRequest, decision: PermissionDecision) throws
    func setPermissionMode(_ mode: PermissionMode) throws
    func setModel(_ model: String?) throws
    func stop()
}

public enum SessionError: Error, Equatable, CustomStringConvertible {
    case claudeNotFound
    case launchFailed(String)
    case notRunning
    case writeFailed(String)

    public var description: String {
        switch self {
        case .claudeNotFound: return "Claude Code CLI not found. Install it and sign in, then try again."
        case .launchFailed(let m): return "Could not start Claude Code: \(m)"
        case .notRunning: return "The Claude Code session is not running."
        case .writeFailed(let m): return "Could not talk to Claude Code: \(m)"
        }
    }
}

/// Factory so the engine can open a fresh session ("new session" voice command).
public typealias SessionBackendFactory = @Sendable (_ resumeSessionID: String?) -> any SessionBackend
