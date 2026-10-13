// SPDX-License-Identifier: Apache-2.0

import Foundation
import PairVoxCore

/// Prints utterances to the terminal and, with `--say` on macOS, speaks them
/// with the built-in `say` command. Implements barge-in by killing `say`.
final class TerminalSpeechOutput: SpeechOutput, @unchecked Sendable {
    let events: AsyncStream<SpeechOutputEvent>
    private let continuation: AsyncStream<SpeechOutputEvent>.Continuation
    private let lock = NSLock()
    private var queue: [Utterance] = []
    private var current: Utterance?
    private var currentProcess: Process?
    private var generation = 0
    private var rate = 1.0
    private let useSay: Bool
    private let simulateAudio: Bool
    private let start = Date()

    init(useSay: Bool, simulateAudio: Bool) {
        self.useSay = useSay
        self.simulateAudio = simulateAudio
        var c: AsyncStream<SpeechOutputEvent>.Continuation!
        events = AsyncStream(bufferingPolicy: .unbounded) { c = $0 }
        continuation = c
    }

    func enqueue(_ utterance: Utterance) {
        lock.lock()
        queue.append(utterance)
        let idle = current == nil
        lock.unlock()
        if idle { startNext() }
    }

    @discardableResult
    func stopAll() -> [Int] {
        lock.lock()
        generation += 1
        var ids = queue.map(\.id)
        if let c = current { ids.insert(c.id, at: 0) }
        queue.removeAll()
        current = nil
        let p = currentProcess
        currentProcess = nil
        lock.unlock()
        if let p, p.isRunning { p.terminate() }
        if !ids.isEmpty { Term.dim("   [speech stopped]") }
        continuation.yield(.idle)
        return ids
    }

    func setRate(_ rate: Double) {
        lock.lock(); self.rate = rate; lock.unlock()
    }

    private func startNext() {
        lock.lock()
        guard current == nil, !queue.isEmpty else {
            let wasIdle = current == nil && queue.isEmpty
            lock.unlock()
            if wasIdle { continuation.yield(.idle) }
            return
        }
        let u = queue.removeFirst()
        current = u
        let gen = generation
        let r = rate
        lock.unlock()

        continuation.yield(.started(u.id))
        print(Term.format(u, elapsed: Date().timeIntervalSince(start)))

        if useSay, FileManager.default.isExecutableFile(atPath: "/usr/bin/say") {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            p.arguments = ["-r", String(Int(185 * r)), u.text]
            p.terminationHandler = { [weak self] _ in self?.finished(u, generation: gen) }
            lock.lock(); currentProcess = p; lock.unlock()
            do { try p.run() } catch { finished(u, generation: gen) }
        } else if simulateAudio {
            // ~2.9 words per second at rate 1.0
            let words = Double(u.text.split(separator: " ").count)
            let seconds = max(0.4, words / (2.9 * r))
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { [weak self] in
                self?.finished(u, generation: gen)
            }
        } else {
            finished(u, generation: gen)
        }
    }

    private func finished(_ u: Utterance, generation gen: Int) {
        lock.lock()
        guard gen == generation, current?.id == u.id else { lock.unlock(); return }
        current = nil
        currentProcess = nil
        lock.unlock()
        continuation.yield(.finished(u.id))
        startNext()
    }
}

enum Term {
    static let isTTY = isatty(STDOUT_FILENO) != 0

    static func color(_ code: String, _ s: String) -> String {
        isTTY ? "\u{1B}[\(code)m\(s)\u{1B}[0m" : s
    }

    static func dim(_ s: String) {
        print(color("2", s))
    }

    static func format(_ u: Utterance, elapsed: TimeInterval) -> String {
        let t = String(format: "%6.2fs", elapsed)
        switch u.kind {
        case .prose: return color("2", t) + " 🔊 " + u.text
        case .code: return color("2", t) + " 🔊 " + color("36", u.text)
        case .narration: return color("2", t) + " ⚙️  " + color("33", u.text)
        case .prompt: return color("2", t) + " ❓ " + color("1;35", u.text)
        case .notice: return color("2", t) + " ℹ️  " + color("34", u.text)
        case .ack: return color("2", t) + " 💬 " + color("2", u.text)
        }
    }
}
