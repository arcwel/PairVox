// SPDX-License-Identifier: Apache-2.0

import Foundation
import PairVoxCore

/// Counts how often views re-render and what makes them, and writes a `ui.storm` line when something fires more
/// than `stormPerSecond` times a second: the symptom of a view that invalidates itself on every frame, which looks
/// like a blank window that ignores clicks. Added 2026-10-16 after a project switch left the window empty with the
/// main thread spending four samples in five inside SwiftUI's graph update and nothing in the log to say why.
final class UITrace: @unchecked Sendable {
    static let shared = UITrace()
    static let stormPerSecond = 30
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    private var timer: DispatchSourceTimer?
    private let interval = 5.0

    /// Call from a view body or a setter: `UITrace.tick("ContentView.body")`.
    static func tick(_ name: String) { shared.record(name) }

    private func record(_ name: String) {
        lock.lock()
        counts[name, default: 0] += 1
        if timer == nil { startTimer() }
        lock.unlock()
    }

    private func startTimer() {
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        t.schedule(deadline: .now() + interval, repeating: interval)
        t.setEventHandler { [weak self] in self?.report() }
        t.resume()
        timer = t
    }

    private func report() {
        lock.lock()
        let snapshot = counts
        counts.removeAll()
        lock.unlock()
        guard !snapshot.isEmpty else { return }
        let limit = Int(Double(Self.stormPerSecond) * interval)
        var fields: [String: LogValue] = [:]
        for (k, v) in snapshot { fields[k] = .int(v) }
        if snapshot.values.contains(where: { $0 > limit }) {
            DiagnosticLog.shared.log(.warning, .app, "ui.storm", fields)
        } else {
            DiagnosticLog.shared.log(.debug, .app, "ui.rate", fields)
        }
    }
}
