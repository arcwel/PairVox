// SPDX-License-Identifier: Apache-2.0

import AppKit
import PairVoxCore
import PairVoxVoice
import SwiftUI

/// First-run checklist: Claude Code installed and signed in, microphone, models.
struct SetupView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Set up PairVox").font(.title.weight(.semibold))
            Text("PairVox talks to the Claude Code CLI installed on this Mac. It never sees your Claude password or tokens: you sign in to Claude Code yourself, in Anthropic's own sign-in flow.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            step(done: model.setup.claudeFound, title: "Claude Code is installed",
                 detail: model.setup.claudePath.map { "\($0)\(model.setup.cliVersion.map { " · \($0)" } ?? "")" }
                    ?? "Install it: `npm install -g @anthropic-ai/claude-code` or the native installer from Anthropic's docs.") {
                Button("Check Again") { Task { await model.refreshSetup() } }
                Link("Install Guide", destination: URL(string: "https://code.claude.com/docs/en/setup")!)
            }

            step(done: model.snapshot.authProblem == nil && model.setup.claudeFound,
                 title: model.settings.authKind == .subscription ? "Signed in to Claude Code" : "API key saved",
                 detail: authDetail) {
                if model.settings.authKind == .subscription {
                    Button("Open Terminal to Sign In") { model.openTerminalForLogin() }
                } else {
                    SettingsLink { Text("Add API Key…") }
                }
            }

            step(done: model.setup.microphone == .granted, title: "Microphone access",
                 detail: model.setup.microphone == .denied ? "Allow PairVox in System Settings → Privacy & Security → Microphone."
                                                           : "Needed so you can talk to Claude.") {
                if model.setup.microphone == .notDetermined {
                    Button("Allow") { Task { _ = await VoicePermissions.requestMicrophone(); await model.refreshSetup() } }
                } else if model.setup.microphone == .denied {
                    Button("Open Settings") { NSWorkspace.shared.open(VoicePermissions.microphoneSettingsURL) }
                }
            }

            step(done: model.whisperState == .ready || model.setup.speechRecognition == .granted,
                 title: "Speech recognition", detail: whisperDetail) {
                if model.setup.speechRecognition == .notDetermined {
                    Button("Allow Apple Speech") {
                        Task { _ = await VoicePermissions.requestSpeechRecognition(); await model.refreshSetup() }
                    }
                }
            }

            step(done: kokoroReady, title: "Natural voice (Kokoro)", detail: kokoroDetail, optional: true) {
                if case .failed = model.kokoroStatus { Button("Retry Download") { model.downloadKokoroNow() } }
                if case .missing = model.kokoroStatus { Button("Download (340 MB)") { model.downloadKokoroNow() } }
            }

            if let audioError = model.setup.audioError {
                Label(audioError, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }

            HStack {
                Spacer()
                Button("Done") {
                    dismiss()
                    if model.project == nil, model.setup.claudeFound { model.chooseProject() } else { model.restartSession() }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560)
    }

    private var authDetail: String {
        if let problem = model.snapshot.authProblem { return "Problem: \(problem.prefix(160))" }
        if model.settings.authKind == .subscription {
            return "In Terminal run `claude`, then `/login`, and finish signing in. PairVox will use that login."
        }
        return model.hasAPIKey ? "Using your Anthropic Console API key (stored in Keychain)." : "Add your own API key in Settings → Account."
    }

    private var whisperDetail: String {
        switch model.whisperState {
        case .ready: return "WhisperKit is ready (on-device)."
        case .loading(let m): return "\(m) Apple Speech is used meanwhile."
        case .failed(let e): return "WhisperKit failed (\(e)); using Apple Speech."
        case .notLoaded: return "WhisperKit will download on first use; Apple Speech is the fallback."
        }
    }

    private var kokoroReady: Bool {
        if case .ready = model.kokoroStatus { return true }
        return false
    }

    private var kokoroDetail: String {
        switch model.kokoroStatus {
        case .ready: return "Kokoro voice ready."
        case .downloading(let f): return "Downloading… \(Int(f * 100))%"
        case .verifying: return "Verifying download…"
        case .failed(let e): return "\(e) The system voice is used instead."
        case .missing: return "Optional. Until it's downloaded, the macOS system voice is used."
        }
    }

    @ViewBuilder
    private func step<Actions: View>(done: Bool, title: String, detail: String, optional: Bool = false,
                                     @ViewBuilder actions: () -> Actions) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : (optional ? "circle.dashed" : "circle"))
                .foregroundStyle(done ? .green : .secondary)
                .font(.title3)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(.init(detail)).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack { actions() }.padding(.top, 2)
            }
        }
    }
}
