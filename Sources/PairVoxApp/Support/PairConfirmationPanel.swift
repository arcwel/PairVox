// SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI

/// The "Pair this phone?" question as an ordinary window, not a modal alert. A modal alert runs its own event loop and
/// holds up everything else on the main thread (the control socket, the phone link, the whole interface) until
/// someone clicks, which can be a long time when nobody is at the Mac.
@MainActor
final class PairConfirmationPanel: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    private var continuation: CheckedContinuation<Bool, Never>?
    private var serial = 0
    /// The phone stops waiting after 130 seconds, so an unanswered question is withdrawn a little later.
    static let giveUpAfter: Double = 150

    /// True only if the person clicks Pair. Closing the window says no. A newer request replaces an older one that
    /// nobody answered (the phone that asked has usually given up by then).
    func ask(name: String, source: String) async -> Bool {
        finish(false)
        serial += 1
        let mine = serial
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            let view = PairConfirmationView(name: name, source: source) { [weak self] in self?.finish($0) }
            let controller = NSHostingController(rootView: view)
            let panel = NSPanel(contentViewController: controller)
            panel.title = "Pair a phone"
            panel.styleMask = [.titled, .closable]
            panel.level = .floating
            panel.isReleasedWhenClosed = false
            panel.delegate = self
            panel.center()
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            self.panel = panel
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.giveUpAfter * 1_000_000_000))
                if self?.serial == mine { self?.finish(false) }
            }
        }
    }

    private func finish(_ accepted: Bool) {
        guard let continuation else { return }
        self.continuation = nil
        let closing = panel
        panel = nil
        closing?.delegate = nil
        closing?.close()
        continuation.resume(returning: accepted)
    }

    func windowWillClose(_ notification: Notification) { finish(false) }
}

private struct PairConfirmationView: View {
    let name: String
    let source: String
    let decide: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Pair “\(String(name.prefix(64)))” with this Mac?")
                .font(.headline)
            Text("This phone will be able to read your conversations and answer permission requests. The pairing code was started from \(source). Only pair a phone that you are holding and whose name you recognize.")
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Don’t Pair") { decide(false) }
                    .keyboardShortcut(.cancelAction)
                Button("Pair") { decide(true) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .frame(width: 420)
    }
}
