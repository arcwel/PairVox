// SPDX-License-Identifier: Apache-2.0

import PairVoxCore
import PairVoxVoice
import SwiftUI

struct ControlBarView: View {
    @EnvironmentObject var model: AppModel
    @State private var typed = ""
    @FocusState private var typingFocused: Bool

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 14) {
                StatusOrbView(phase: model.snapshot.phase, level: model.inputLevel, muted: model.listeningMode == .muted)
                    .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: 2) {
                    Text(model.statusLine).font(.headline)
                    Text(detailLine).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }

                Spacer()

                PushToTalkButton()

                Button {
                    model.toggleMute()
                } label: {
                    Image(systemName: model.listeningMode == .muted ? "mic.slash.fill" : "mic.fill")
                }
                .accessibilityHint("\(model.listeningMode == .muted ? "Unmute" : "Mute") microphone (\(Shortcuts.of(.toggleMute).display), anywhere: ⌃⌥M)")

                Button {
                    model.stopSpeaking()
                } label: {
                    Image(systemName: "speaker.slash.fill")
                }
                .disabled(!model.snapshot.isSpeaking)
                .accessibilityHint("Stop speaking (\(Shortcuts.of(.stopSpeaking).display), anywhere: ⌃⌥S)")

                Button {
                    model.interrupt()
                } label: {
                    Image(systemName: "stop.fill")
                }
                .disabled(!model.snapshot.isClaudeWorking)
                .accessibilityHint("Interrupt Claude (\(Shortcuts.of(.interrupt).display), anywhere: ⌃⌥I)")
            }
            .controlSize(.large)

            HStack {
                TextField("Type instead of talking… (\(Shortcuts.of(.focusInput).display))", text: $typed)
                    .textFieldStyle(.roundedBorder)
                    .focused($typingFocused)
                    .onChange(of: model.focusInputTick) { typingFocused = true }
                    .onSubmit {
                        model.sendTyped(typed)
                        typed = ""
                    }
                    .disabled(model.project == nil)
            }
        }
        .padding(12)
    }

    private var detailLine: String {
        var parts: [String] = []
        parts.append(model.voice.transcriber.displayName)
        parts.append(model.voice.synthesizer.displayName)
        let usage = model.snapshot.usage
        if model.settings.authKind == .apiKey, usage.costUSD > 0 {
            parts.append(String(format: "$%.3f this session", usage.costUSD))
        } else if let five = usage.fiveHourUtilization {
            parts.append("5-hour limit \(Int(five * 100))%")
        }
        if let l = model.snapshot.lastLatency, let audio = l.firstAudio {
            parts.append(String(format: "first audio %.1fs", audio))
        }
        return parts.joined(separator: " · ")
    }
}

/// Press and hold to talk (works in any listening mode).
private struct PushToTalkButton: View {
    @EnvironmentObject var model: AppModel
    @GestureState private var pressing = false

    var body: some View {
        Label(model.pushToTalkActive ? "Listening" : "Hold to Talk", systemImage: "waveform")
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(model.pushToTalkActive ? Color.accentColor : Color.secondary.opacity(0.15), in: Capsule())
            .foregroundStyle(model.pushToTalkActive ? .white : .primary)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($pressing) { _, state, _ in state = true }
            )
            .onChange(of: pressing) { _, isPressing in
                model.pushToTalk(down: isPressing)
            }
            .accessibilityHint("Hold to talk. Works in any app: hold \(Shortcuts.pushToTalk(model.settings.pushToTalkKey).display)")
            .disabled(model.project == nil)
    }
}

struct StatusOrbView: View {
    let phase: EnginePhase
    let level: Float
    let muted: Bool

    private var color: Color {
        if muted { return .gray }
        switch phase {
        case .listening, .transcribing: return .accentColor
        case .speaking: return .purple
        case .thinking, .working: return .orange
        case .awaitingPermission: return .yellow
        case .needsSetup: return .red
        default: return .green
        }
    }

    var body: some View {
        // Map -60…-10 dBFS to 0…1 for a gentle pulse.
        let normalized = CGFloat(max(0, min(1, (level + 60) / 50)))
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let breathing: CGFloat = (phase == .thinking || phase == .working) ? 0.08 * CGFloat(sin(t * 4)) : 0
            let speaking: CGFloat = phase == .speaking ? 0.06 * CGFloat(sin(t * 9)) : 0
            let listen: CGFloat = phase == .listening ? normalized : 0
            let scale: CGFloat = 0.75 + 0.25 * listen + breathing + speaking
            ZStack {
                Circle().fill(color.opacity(0.18))
                Circle().fill(color.gradient).scaleEffect(scale)
                Image(systemName: muted ? "mic.slash.fill" : icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .accessibilityLabel(Text(phase.rawValue))
    }

    private var icon: String {
        switch phase {
        case .speaking: return "waveform"
        case .thinking, .working: return "ellipsis"
        case .awaitingPermission: return "hand.raised.fill"
        case .needsSetup: return "exclamationmark"
        default: return "mic.fill"
        }
    }
}
