// SPDX-License-Identifier: Apache-2.0

import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Runs the user's own, unmodified `claude` CLI as a subprocess in headless
/// stream-json mode and talks to it over stdin/stdout.
///
/// Both auth modes use this same backend; only the child environment differs
/// (see `LaunchConfiguration.environment()`).
public final class ClaudeCLISession: SessionBackend, @unchecked Sendable {
    public let events: AsyncStream<SessionEvent>
    private let continuation: AsyncStream<SessionEvent>.Continuation

    private let lock = NSLock()
    private var config: LaunchConfiguration
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var lineBuffer = LineBuffer()
    private var translator = EventTranslator()
    private var stderrTail = Data()
    private var currentSessionID: String?
    private var stoppedByUser = false
    private var requestCounter = 0
    /// Diagnostic hook: every raw stdout line (useful for logging/fixtures).
    public var rawLineObserver: (@Sendable (Data) -> Void)?

    public init(configuration: LaunchConfiguration) {
        self.config = configuration
        self.currentSessionID = configuration.resumeSessionID
        var cont: AsyncStream<SessionEvent>.Continuation!
        self.events = AsyncStream(bufferingPolicy: .unbounded) { cont = $0 }
        self.continuation = cont
        // Writing to a pipe whose reader died must not kill the app.
        signal(SIGPIPE, SIG_IGN)
    }

    deinit {
        process?.terminationHandler = nil
        if process?.isRunning == true { process?.terminate() }
        continuation.finish()
    }

    public var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return process?.isRunning ?? false
    }

    public var sessionID: String? {
        lock.lock(); defer { lock.unlock() }
        return currentSessionID
    }

    public var configuration: LaunchConfiguration {
        lock.lock(); defer { lock.unlock() }
        return config
    }

    // MARK: Lifecycle

    public func start() throws {
        lock.lock()
        defer { lock.unlock() }
        try startLocked()
    }

    private func startLocked() throws {
        if process?.isRunning == true { return }
        stoppedByUser = false
        var cfg = config
        if let sid = currentSessionID { cfg.resumeSessionID = sid }

        let p = Process()
        p.executableURL = cfg.executable
        p.arguments = cfg.arguments()
        p.environment = cfg.environment()
        p.currentDirectoryURL = cfg.workingDirectory

        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe

        lineBuffer = LineBuffer()
        translator = EventTranslator()
        stderrTail = Data()

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            if data.isEmpty {
                h.readabilityHandler = nil
                return
            }
            self?.handleStdout(data)
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            if data.isEmpty {
                h.readabilityHandler = nil
                return
            }
            self?.handleStderr(data)
        }
        p.terminationHandler = { [weak self] proc in
            self?.handleTermination(proc)
        }

        do {
            try p.run()
        } catch {
            throw SessionError.launchFailed(error.localizedDescription)
        }
        process = p
        stdinHandle = inPipe.fileHandleForWriting
    }

    public func stop() {
        lock.lock()
        stoppedByUser = true
        let p = process
        let stdin = stdinHandle
        stdinHandle = nil
        lock.unlock()
        // Closing stdin lets the CLI finish cleanly; terminate if it lingers.
        try? stdin?.close()
        if let p, p.isRunning {
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if p.isRunning { p.terminate() }
            }
        }
    }

    // MARK: Commands

    public func send(_ text: String) throws {
        lock.lock()
        defer { lock.unlock() }
        if process?.isRunning != true {
            try startLocked()
        }
        try writeLocked(OutboundMessage.userText(text))
    }

    public func interrupt() throws {
        lock.lock()
        defer { lock.unlock() }
        guard process?.isRunning == true else { return }
        translator.interruptPending = true
        try writeLocked(OutboundMessage.interrupt(requestID: nextRequestIDLocked("interrupt")))
    }

    public func respond(to request: PermissionRequest, decision: PermissionDecision) throws {
        lock.lock()
        defer { lock.unlock() }
        if case .deny(_, true) = decision { translator.interruptPending = true }
        try writeLocked(OutboundMessage.permissionResponse(for: request, decision: decision))
    }

    public func setPermissionMode(_ mode: PermissionMode) throws {
        lock.lock()
        defer { lock.unlock() }
        config.permissionMode = mode
        guard process?.isRunning == true else { return }
        try writeLocked(OutboundMessage.setPermissionMode(mode, requestID: nextRequestIDLocked("mode")))
    }

    public func setModel(_ model: String?) throws {
        lock.lock()
        defer { lock.unlock() }
        config.model = model
        guard process?.isRunning == true else { return }
        try writeLocked(OutboundMessage.setModel(model, requestID: nextRequestIDLocked("model")))
    }

    // MARK: Internals

    private func nextRequestIDLocked(_ prefix: String) -> String {
        requestCounter += 1
        return "pairvox-\(prefix)-\(requestCounter)"
    }

    private func writeLocked(_ data: Data) throws {
        guard let h = stdinHandle else { throw SessionError.notRunning }
        do {
            try h.write(contentsOf: data)
        } catch {
            throw SessionError.writeFailed(error.localizedDescription)
        }
    }

    private func handleStdout(_ data: Data) {
        lock.lock()
        let lines = lineBuffer.append(data)
        var events: [SessionEvent] = []
        var replies: [Data] = []
        let observer = rawLineObserver
        for line in lines {
            observer?(line)
            guard let msg = try? InboundMessage.parse(line: line) else { continue }
            switch msg {
            case .systemInit(let i):
                currentSessionID = i.sessionID
            case .result(let r) where !r.sessionID.isEmpty:
                currentSessionID = r.sessionID
            case .controlRequest(let req) where req.permission == nil:
                // Hooks, elicitation, dialogs: not supported by a voice client. Answer so the CLI never hangs.
                replies.append(OutboundMessage.controlError(requestID: req.requestID,
                                                            message: "PairVox does not support '\(req.subtype)' requests"))
            default:
                break
            }
            events += translator.translate(msg)
        }
        for reply in replies { try? writeLocked(reply) }
        lock.unlock()
        for e in events { continuation.yield(e) }
    }

    private func handleStderr(_ data: Data) {
        lock.lock()
        stderrTail.append(data)
        if stderrTail.count > 8192 { stderrTail = Data(stderrTail.suffix(8192)) }
        lock.unlock()
    }

    private func handleTermination(_ proc: Process) {
        lock.lock()
        // Flush any final partial line.
        var events: [SessionEvent] = []
        if let tail = lineBuffer.flush(), let msg = try? InboundMessage.parse(line: tail) {
            events += translator.translate(msg)
        }
        let tailText = String(decoding: stderrTail, as: UTF8.self)
        let wasStopped = stoppedByUser
        if process === proc {
            process = nil
            stdinHandle = nil
        }
        lock.unlock()
        for e in events { continuation.yield(e) }
        if !wasStopped || proc.terminationStatus != 0 {
            if EventTranslator.looksLikeAuthProblem(tailText) {
                continuation.yield(.authProblem(tailText.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
        }
        continuation.yield(.processExited(code: proc.terminationStatus, stderrTail: tailText))
    }
}
