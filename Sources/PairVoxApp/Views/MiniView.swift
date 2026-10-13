// SPDX-License-Identifier: Apache-2.0

import PairVoxCore
import SwiftUI

/// A small always-on-top window: is the voice listening, thinking or speaking, and which project is it in.
/// Enough to answer a permission request or catch up without bringing the whole app forward.
struct MiniView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    private var tint: Color {
        switch model.snapshot.phase {
        case .awaitingPermission: return .orange
        case .speaking: return .blue
        case .listening, .transcribing: return .green
        case .thinking, .working: return .purple
        case .needsSetup: return .red
        default: return model.listeningMode == .muted ? .gray : .green
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Rectangle().fill(tint).frame(width: 10, height: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.project?.lastPathComponent ?? "No project")
                        .font(.system(.caption, weight: .bold)).lineLimit(1)
                    Text(model.project == nil ? "Open a project" : model.statusLine)
                        .font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                if model.sessions.count > 1 {
                    Menu {
                        ForEach(model.sessions) { s in
                            Button(s.name + (s.needsAttention ? "  · needs OK" : s.missedCount > 0 ? "  · \(s.missedCount) new" : "")) {
                                model.switchTo(s.id)
                            }
                        }
                    } label: { Image(systemName: "rectangle.stack") }
                    .menuStyle(.borderlessButton).fixedSize().help("Switch project")
                }
                Button { model.toggleMute() } label: {
                    Image(systemName: model.listeningMode == .muted ? "mic.slash.fill" : "mic.fill")
                }
                .buttonStyle(.borderless).help(model.listeningMode == .muted ? "Unmute" : "Mute")
                Button { model.stopSpeaking() } label: { Image(systemName: "speaker.slash.fill") }
                    .buttonStyle(.borderless).disabled(!model.snapshot.isSpeaking).help("Stop speaking")
                Button { model.showMainWindow(open: { openWindow(id: "main") }) } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(.borderless).help("Open the full window")
            }
            if let pending = model.snapshot.pendingPermission {
                Divider()
                Text(pending.assessment.summary).font(.system(.caption, design: .monospaced)).lineLimit(2)
                HStack {
                    Button("Deny", role: .destructive) { model.deny(requestID: pending.request.requestID) }
                    Spacer()
                    if !pending.assessment.fitsCompactSurface {
                        Button(pending.assessment.risk == .high ? "High risk: review" : "Review") { model.showMainWindow(open: { openWindow(id: "main") }) }
                    } else {
                        Button("Allow") { model.approve(requestID: pending.request.requestID) }.buttonStyle(.borderedProminent)
                    }
                }.controlSize(.small)
            } else if model.snapshot.awaitingCatchUpChoice {
                Divider()
                Text("\(model.snapshot.missedMessages.count) new while you were away").font(.caption)
                HStack {
                    Button("Skip") { model.catchUp(.skip) }
                    Spacer()
                    Button("Play last") { model.catchUp(.lastMessage) }
                    Button("From first") { model.catchUp(.fromFirstMissed) }.buttonStyle(.borderedProminent)
                }.controlSize(.small)
            }
        }
        .padding(10)
        .frame(width: 330)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(Rectangle().stroke(Color.primary.opacity(0.45), lineWidth: 1))
    }
}
