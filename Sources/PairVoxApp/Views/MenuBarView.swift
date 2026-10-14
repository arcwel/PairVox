// SPDX-License-Identifier: Apache-2.0

import AppKit
import PairVoxCore
import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(model.project.map { "\($0.lastPathComponent) — \(model.statusLine)" } ?? "No project open")
        if model.sessions.count > 1 {
            Divider()
            ForEach(model.sessions) { s in
                Button {
                    model.switchTo(s.id)
                } label: {
                    let badge = s.needsAttention ? "  · needs OK" : (s.missedCount > 0 ? "  · \(s.missedCount) new" : (s.working ? "  · working" : ""))
                    Text((s.isActive ? "✓ " : "    ") + s.name + badge)
                }
            }
        }
        if model.snapshot.awaitingCatchUpChoice {
            Divider()
            Text("\(model.snapshot.missedMessages.count) new while you were away")
            Button("Play from the first") { model.catchUp(.fromFirstMissed) }
            Button("Play the last one") { model.catchUp(.lastMessage) }
            Button("Skip") { model.catchUp(.skip) }
        }
        if let pending = model.snapshot.pendingPermission {
            Divider()
            Text("\(riskLabel(pending.assessment.risk)): \(pending.assessment.summary)").lineLimit(3)
            if let reason = pending.assessment.reasons.first { Text(reason).lineLimit(2) }
            if !pending.assessment.fitsCompactSurface {
                // The menu cannot show a whole command or every reason, so anything long or risky is reviewed in the window.
                Button("Review in PairVox…") {
                    NSApp.activate(ignoringOtherApps: true)
                    NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
                }
            } else {
                Button("Allow") { model.approve(requestID: pending.request.requestID) }
            }
            Button("Deny") { model.deny(requestID: pending.request.requestID) }
        }
        let others = AppModel.sharedCross.inbox.others(than: model.activeSessionID?.uuidString)
        if !others.isEmpty {
            Divider()
            Text("Waiting in other projects").font(.caption)
            ForEach(others) { item in
                Text("\(item.projectName): \(item.summary)").lineLimit(2)
                if item.voiceApprovable && item.fitsCompactSurface {
                    Button("Allow in \(item.projectName)") { AppModel.sharedCross.approve(item) }
                } else {
                    Button("Open \(item.projectName)") { AppModel.sharedCross.open(item) }
                }
                Button("Deny in \(item.projectName)") { AppModel.sharedCross.deny(item) }
            }
        }
        Divider()
        Button(model.listeningMode == .muted ? "Unmute Microphone" : "Mute Microphone") { model.toggleMute() }
        Button("Stop Speaking") { model.stopSpeaking() }.disabled(!model.snapshot.isSpeaking)
        Button("Interrupt Claude") { model.interrupt() }.disabled(!model.snapshot.isClaudeWorking)
        Divider()
        Button("Show Mini Window") { openWindow(id: "mini"); NSApp.activate(ignoringOtherApps: true) }
        Button("Show PairVox") { model.showMainWindow(open: { openWindow(id: "main") }) }
        Button("Quit PairVox") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func riskLabel(_ risk: RiskLevel) -> String {
        switch risk {
        case .low: return "Low risk"
        case .medium: return "Review"
        case .high: return "High risk"
        }
    }
}
