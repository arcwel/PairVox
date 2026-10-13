// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import PairVoxCore
import PairVoxVoice
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            VoiceSettings().tabItem { Label("Voice", systemImage: "waveform") }
            AccountSettings().tabItem { Label("Account", systemImage: "person.badge.key") }
            PronunciationSettings().tabItem { Label("Pronunciation", systemImage: "character.bubble") }
            AboutSettings().tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 560, height: 470)
    }
}

private struct GeneralSettings: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Picker("Read replies", selection: $model.settings.speechMode) {
                Text("Everything, including code").tag(SpeechMode.full)
                Text("Prose; describe code briefly").tag(SpeechMode.skipCode)
                Text("Summaries only (ask for details)").tag(SpeechMode.summary)
            }
            Picker("Start sessions in", selection: $model.settings.conversationMode) {
                Text("Brainstorm (plan mode, no changes)").tag(ConversationMode.brainstorm)
                Text("Execute").tag(ConversationMode.execute)
            }
            Picker("Narrate tool use", selection: $model.settings.verbosity) {
                Text("Quiet").tag(Verbosity.quiet)
                Text("Normal").tag(Verbosity.normal)
                Text("Every step").tag(Verbosity.detailed)
            }
            Toggle("Say “On it” while Claude starts working", isOn: $model.settings.acknowledgements)

            Section("Listening") {
                Picker("Microphone", selection: Binding(get: { model.settings.handsFree }, set: {
                    model.setListeningMode($0 ? .handsFree : .pushToTalk)
                })) {
                    Text("Hands-free (always listening)").tag(true)
                    Text("Push to talk (hold ⌃⌥Space)").tag(false)
                }
                Toggle("Let me interrupt by talking (barge-in)", isOn: $model.settings.bargeInEnabled)
                LabeledContent("End of turn after") {
                    HStack {
                        Slider(value: $model.settings.endOfTurnSilence, in: 0.4...2.0, step: 0.05)
                        Text(String(format: "%.2fs", model.settings.endOfTurnSilence)).monospacedDigit().frame(width: 48)
                    }
                }
                Text("Raise this if PairVox cuts you off mid-thought. With laptop speakers and no headphones, voice processing removes most echo; turn barge-in off if it interrupts itself.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Permissions") {
                Toggle("Auto-approve read-only tools (Read, Grep, Glob, search)", isOn: $model.settings.autoApproveLowRisk)
                Text("High-risk actions (deleting files, pushing, sudo, edits outside the project) always need a click, never just a spoken “yes”.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct VoiceSettings: View {
    @EnvironmentObject var model: AppModel

    static let kokoroVoices = ["af_heart", "af_bella", "af_nicole", "af_sarah", "af_sky", "af_nova", "am_michael",
                               "am_adam", "am_eric", "am_liam", "am_onyx", "bf_emma", "bf_isabella", "bm_george",
                               "bm_lewis", "bm_daniel"]
    struct WhisperChoice: Identifiable {
        let id: String
        let label: String
    }

    static let whisperModels = [
        WhisperChoice(id: "openai_whisper-base.en", label: "Base (fastest, ~150 MB)"),
        WhisperChoice(id: "openai_whisper-small.en", label: "Small (recommended, ~500 MB)"),
        WhisperChoice(id: "distil-whisper_distil-large-v3_turbo", label: "Large v3 Turbo (most accurate, ~1 GB)"),
    ]

    var body: some View {
        Form {
            Section("Speaking") {
                Picker("Voice engine", selection: $model.settings.synthesizer) {
                    Text("Automatic (Kokoro when ready)").tag(SynthesizerChoice.automatic)
                    Text("Kokoro").tag(SynthesizerChoice.kokoro)
                    Text("macOS system voice").tag(SynthesizerChoice.system)
                }
                Picker("Kokoro voice", selection: $model.settings.kokoroVoice) {
                    ForEach(Self.kokoroVoices, id: \.self) { v in Text(Self.label(v)).tag(v) }
                }
                Picker("System voice", selection: $model.settings.systemVoiceIdentifier) {
                    Text("Best available").tag(String?.none)
                    ForEach(SystemSynthesizer.englishVoices(), id: \.identifier) { v in
                        Text("\(v.name) (\(v.language))").tag(String?.some(v.identifier))
                    }
                }
                LabeledContent("Speed") {
                    HStack {
                        Slider(value: $model.settings.speechRate, in: 0.6...1.8, step: 0.05)
                        Text(String(format: "%.2f×", model.settings.speechRate)).monospacedDigit().frame(width: 48)
                    }
                }
                LabeledContent("Kokoro model") {
                    HStack {
                        Text(kokoroStatus).foregroundStyle(.secondary)
                        if case .missing = model.kokoroStatus { Button("Download") { model.downloadKokoroNow() } }
                        if case .failed = model.kokoroStatus { Button("Retry") { model.downloadKokoroNow() } }
                    }
                }
            }
            Section("Listening") {
                Picker("Recognition", selection: $model.settings.transcriber) {
                    Text("Automatic (WhisperKit, Apple fallback)").tag(TranscriberChoice.automatic)
                    Text("WhisperKit").tag(TranscriberChoice.whisperKit)
                    Text("Apple Speech").tag(TranscriberChoice.apple)
                }
                Picker("Whisper model", selection: $model.settings.whisperModel) {
                    ForEach(Self.whisperModels) { m in Text(m.label).tag(m.id) }
                }
                LabeledContent("Status") { Text(whisperStatus).foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
    }

    static func label(_ v: String) -> String {
        let accent = v.hasPrefix("b") ? "British" : "American"
        let gender = v.dropFirst().first == "f" ? "female" : "male"
        let name = v.split(separator: "_").last.map { $0.capitalized } ?? v
        return "\(name) — \(accent) \(gender)"
    }

    private var kokoroStatus: String {
        switch model.kokoroStatus {
        case .ready: return "Ready"
        case .downloading(let f): return "Downloading \(Int(f * 100))%"
        case .verifying: return "Verifying…"
        case .failed(let e): return e
        case .missing: return "Not downloaded"
        }
    }

    private var whisperStatus: String {
        switch model.whisperState {
        case .ready: return "Ready"
        case .loading(let m): return m
        case .failed(let e): return "Failed: \(e)"
        case .notLoaded: return "Not loaded"
        }
    }
}

private struct AccountSettings: View {
    @EnvironmentObject var model: AppModel
    @State private var keyField = ""

    var body: some View {
        Form {
            Section {
                Picker("Use", selection: $model.settings.authKind) {
                    Text("My Claude subscription (Claude Code login)").tag(AuthKind.subscription)
                    Text("My Anthropic API key").tag(AuthKind.apiKey)
                }
                .pickerStyle(.radioGroup)
                Text(model.settings.authKind == .subscription
                     ? "PairVox runs your own, unmodified Claude Code CLI, which uses the login you completed with Anthropic. PairVox never reads or stores your Claude credentials. Usage counts toward your plan's limits."
                     : "Your key is stored in the macOS Keychain and passed only to the Claude Code process. Usage is billed to your Anthropic Console account.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if model.settings.authKind == .subscription {
                Section("Claude Code login") {
                    Button("Open Terminal to Sign In") { model.openTerminalForLogin() }
                    Text("Run `claude`, type `/login`, and finish in your browser.").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Section("API key") {
                    if model.hasAPIKey {
                        LabeledContent("Saved key") {
                            HStack {
                                Text("•••••••• (in Keychain)")
                                Button("Remove", role: .destructive) { model.removeAPIKey() }
                            }
                        }
                    }
                    SecureField("sk-ant-…", text: $keyField)
                    Button(model.hasAPIKey ? "Replace Key" : "Save Key") {
                        model.saveAPIKey(keyField)
                        keyField = ""
                    }
                    .disabled(keyField.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            Section("Claude Code CLI") {
                LabeledContent("Detected") {
                    Text(model.setup.claudePath ?? "Not found").textSelection(.enabled).foregroundStyle(.secondary)
                }
                LabeledContent("Version") { Text(model.setup.cliVersion ?? "–").foregroundStyle(.secondary) }
                TextField("Custom path (optional)", text: Binding(get: { model.settings.claudePathOverride ?? "" },
                                                                  set: { model.settings.claudePathOverride = $0.isEmpty ? nil : $0 }))
                Button("Restart Session") { model.restartSession() }
            }
        }
        .formStyle(.grouped)
    }
}

private struct PronunciationSettings: View {
    @EnvironmentObject var model: AppModel
    @State private var word = ""
    @State private var spoken = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Teach PairVox how to say project words. Applied before speaking.")
                .font(.callout).foregroundStyle(.secondary)
            Table(model.settings.pronunciation.sorted(by: { $0.key < $1.key }).map { PronunciationRow(word: $0.key, spoken: $0.value) }) {
                TableColumn("Written", value: \.word)
                TableColumn("Spoken as", value: \.spoken)
                TableColumn("") { row in
                    Button(role: .destructive) {
                        model.settings.pronunciation.removeValue(forKey: row.word)
                    } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                }
                .width(30)
            }
            HStack {
                TextField("Written (e.g. kubectl)", text: $word)
                TextField("Spoken (e.g. cube control)", text: $spoken)
                Button("Add") {
                    model.settings.pronunciation[word] = spoken
                    word = ""
                    spoken = ""
                }
                .disabled(word.isEmpty || spoken.isEmpty)
            }
        }
        .padding()
    }
}

private struct PronunciationRow: Identifiable {
    var id: String { word }
    let word: String
    let spoken: String
}

private struct AboutSettings: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("PairVox").font(.title2.weight(.semibold))
            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")")
                .foregroundStyle(.secondary)
            Text("Open source under the Apache License 2.0. Works with Claude Code; not affiliated with or endorsed by Anthropic. “Claude” and “Claude Code” are trademarks of Anthropic.")
                .fixedSize(horizontal: false, vertical: true)
            Text("Speech: WhisperKit (MIT) · Apple Speech. Voice: Kokoro-82M (Apache-2.0) via kokoro-ios (MIT), MLX Swift (MIT), MisakiSwift (Apache-2.0).")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Privacy: audio is processed on this Mac. PairVox has no telemetry and sends nothing anywhere except through your own Claude Code CLI.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding()
    }
}
