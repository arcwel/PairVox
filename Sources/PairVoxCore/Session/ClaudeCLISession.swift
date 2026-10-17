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
    /// Every write to the child's stdin goes through here, in order and never under `lock`. A write blocks when the
    /// child is not reading stdin and its pipe is full; holding `lock` through that also stopped the stdout reader
    /// (which needs `lock`) while the child waited for its stdout to be read: a three-way stall nothing could break.
    private let writeQueue = DispatchQueue(label: "app.pairvox.cli.stdin")
    /// How long a finished process may keep its output open before `.processExited` is reported anyway (a tool's
    /// child process can inherit the pipe).
    static let outputDrainTimeout: TimeInterval = 2
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

        // The exit is reported only once both output streams have reached end-of-file (or a short time has passed):
        // the termination handler can run while the last lines, often the turn's `result`, are still unread, and
        // reporting the exit first made a turn that succeeded look like a crash.
        let drained = StreamsDrained(count: 2)
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            if data.isEmpty {
                h.readabilityHandler = nil
                drained.end(0)
                return
            }
            self?.handleStdout(data)
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            if data.isEmpty {
                h.readabilityHandler = nil
                drained.end(1)
                return
            }
            self?.handleStderr(data)
        }
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.global(qos: .userInitiated).async {
                drained.wait(timeout: Self.outputDrainTimeout)
                self?.handleTermination(proc)
            }
        }

        let log = DiagnosticLog.shared
        do {
            try p.run()
        } catch {
            log.log(.error, .session, "process.launch.failed", ["error": .string(error.localizedDescription)])
            throw SessionError.launchFailed(error.localizedDescription)
        }
        // Flags only: the arguments include the system prompt, and the environment can hold an API key.
        let flags = (p.arguments ?? []).filter { $0.hasPrefix("--") }.joined(separator: " ")
        log.log(.info, .session, "process.launched",
                ["pid": .int(Int(p.processIdentifier)), "exe": .string(cfg.executable.path), "flags": .string(flags),
                 "resume": .bool(cfg.resumeSessionID != nil), "cwd": .string(cfg.workingDirectory.path)])
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
        let handle: FileHandle?
        do {
            if process?.isRunning != true { try startLocked() }
            handle = stdinHandle
        } catch { lock.unlock(); throw error }
        lock.unlock()
        try write(OutboundMessage.userText(text), to: handle)
    }

    public func interrupt() throws {
        lock.lock()
        guard process?.isRunning == true else { lock.unlock(); return }
        translator.interruptPending = true
        let message = OutboundMessage.interrupt(requestID: nextRequestIDLocked("interrupt"))
        let handle = stdinHandle
        lock.unlock()
        try write(message, to: handle)
    }

    public func respond(to request: PermissionRequest, decision: PermissionDecision) throws {
        lock.lock()
        if case .deny(_, true) = decision { translator.interruptPending = true }
        let handle = stdinHandle
        lock.unlock()
        try write(OutboundMessage.permissionResponse(for: request, decision: decision), to: handle)
    }

    public func setPermissionMode(_ mode: PermissionMode) throws {
        lock.lock()
        config.permissionMode = mode
        guard process?.isRunning == true else { lock.unlock(); return }
        let message = OutboundMessage.setPermissionMode(mode, requestID: nextRequestIDLocked("mode"))
        let handle = stdinHandle
        lock.unlock()
        try write(message, to: handle)
    }

    public func setModel(_ model: String?) throws {
        lock.lock()
        config.model = model
        guard process?.isRunning == true else { lock.unlock(); return }
        let message = OutboundMessage.setModel(model, requestID: nextRequestIDLocked("model"))
        let handle = stdinHandle
        lock.unlock()
        try write(message, to: handle)
    }

    // MARK: Internals

    private func nextRequestIDLocked(_ prefix: String) -> String {
        requestCounter += 1
        return "pairvox-\(prefix)-\(requestCounter)"
    }

    /// Writes one message to the child's stdin, in order with every other write, without holding `lock`.
    private func write(_ data: Data, to handle: FileHandle?) throws {
        guard let h = handle else { throw SessionError.notRunning }
        try writeQueue.sync {
            do {
                try h.write(contentsOf: data)
            } catch {
                throw SessionError.writeFailed(error.localizedDescription)
            }
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
        let handle = stdinHandle
        lock.unlock()
        // Queued, not waited for: the reader must keep reading stdout even when stdin is full.
        if let handle, !replies.isEmpty {
            writeQueue.async { for reply in replies { try? handle.write(contentsOf: reply) } }
        }
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

/// Counts output streams reaching end-of-file, each at most once. Also used by `ProcessRunner`.
final class StreamsDrained: @unchecked Sendable {
    private let lock = NSLock()
    private var open: Set<Int>
    private let group = DispatchGroup()

    init(count: Int) {
        open = Set(0..<count)
        for _ in 0..<count { group.enter() }
    }

    func end(_ stream: Int) {
        lock.lock()
        let first = open.remove(stream) != nil
        lock.unlock()
        if first { group.leave() }
    }

    func wait(timeout: TimeInterval) { _ = group.wait(timeout: .now() + timeout) }
}
