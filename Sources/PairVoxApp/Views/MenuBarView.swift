// SPDX-License-Identifier: Apache-2.0

import AppKit
import PairVoxCore
import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Text(model.project.map { "\($0.lastPathComponent) — \(model.statusLine)" } ?? "No project open")
        if let pending = model.snapshot.pendingPermission {
            Divider()
            Text(pending.assessment.summary).lineLimit(2)
            Button("Allow") { model.approve() }
            Button("Deny") { model.deny() }
        }
        Divider()
        Button(model.listeningMode == .muted ? "Unmute Microphone" : "Mute Microphone") { model.toggleMute() }
        Button("Stop Speaking") { model.stopSpeaking() }.disabled(!model.snapshot.isSpeaking)
        Button("Interrupt Claude") { model.interrupt() }.disabled(!model.snapshot.isClaudeWorking)
        Divider()
        Button("Show PairVox") {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
        }
        Button("Quit PairVox") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
