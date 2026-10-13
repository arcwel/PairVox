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
            ShortcutSettings().tabItem { Label("Shortcuts", systemImage: "keyboard") }
            DiagnosticsSettings().tabItem { Label("Diagnostics", systemImage: "stethoscope") }
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
                Toggle("Use the microphone", isOn: $model.settings.microphoneEnabled)
                Text("Turn off to play only. A Bluetooth headset then stays in its high-quality music mode instead of the narrower call mode that an open microphone forces. You can still type to Claude.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Separate microphone and speaker audio (experimental)", isOn: $model.settings.separateAudioEngines)
                Text("Captures and plays on independent audio paths, so a headset's microphone and speaker are not joined into one device. Try it if audio crackles or cuts out with a Bluetooth headset, and compare. No echo cancellation in this mode.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Echo cancellation and noise suppression", isOn: $model.settings.echoCancellation)
                Text("Lets you talk over PairVox on laptop speakers. If replies sound distorted or crackly, turn this off and use headphones or push to talk.")
                    .font(.caption).foregroundStyle(.secondary)
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
                Toggle("Explain each request in plain words, and let me ask questions about it", isOn: $model.settings.explainRequests)
                Text("A small separate Claude call, limited to reading files in the project, writes a short summary shown beside the real command and answers questions you ask before deciding. It is advice only and never approves anything. It counts toward your usage.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Allow confirming high-risk requests by voice", isOn: $model.settings.spokenHighRiskConfirmation)
                Text("Off by default: high-risk requests then need a click. When on, PairVox reads the request back and you can say “confirm high risk” instead. PairVox's own spoken prompt contains those words, so speech from your speakers that the microphone hears can approve a high-risk request. Use headphones, or leave this off in a shared room. Anything Claude Code says needs you at the screen still needs a click.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Load this project's own Claude Code settings, hooks and MCP servers", isOn: $model.settings.trustProjectConfiguration)
                Text("Off by default. A repository you downloaded can include settings that run commands or approve tools without asking you. Turn this on only for projects you wrote or trust. Your own Claude Code settings and MCP servers always load.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct VoiceSettings: View {
    @EnvironmentObject var model: AppModel

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
                Picker("Play through", selection: $model.settings.outputDeviceUID) {
                    Text("Automatic").tag(String?.none)
                    ForEach(AudioRoute.devices().filter(\.hasOutput)) { device in
                        Text("\(device.name)\(device.isBluetooth ? " (Bluetooth)" : "")").tag(String?.some(device.uid))
                    }
                }
                Text("Automatic uses your headset when it is also the microphone, so the speaker and microphone stay together. Choose a device here if macOS keeps switching between your headset and speakers.")
                    .font(.caption).foregroundStyle(.secondary)
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
            Section("Kokoro voice") {
                ForEach(VoiceCatalog.featured) { v in voiceRow(v) }
                DisclosureGroup("More voices") {
                    Picker("Voice", selection: Binding(
                        get: { VoiceCatalog.others.contains(model.settings.kokoroVoice) ? model.settings.kokoroVoice : "" },
                        set: { if !$0.isEmpty { model.settings.kokoroVoice = $0 } })) {
                        Text("Choose another…").tag("")
                        ForEach(VoiceCatalog.others, id: \.self) { Text(VoiceCatalog.label(for: $0)).tag($0) }
                    }
                    if VoiceCatalog.others.contains(model.settings.kokoroVoice) {
                        Button(model.previewingVoice == model.settings.kokoroVoice ? "Stop" : "Preview this voice") {
                            model.previewVoice(model.settings.kokoroVoice)
                        }
                        .disabled(!kokoroReady)
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

    private func voiceRow(_ v: KokoroVoiceInfo) -> some View {
        let selected = model.settings.kokoroVoice == v.id
        let playing = model.previewingVoice == v.id
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button { model.settings.kokoroVoice = v.id } label: {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle").imageScale(.medium)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Use \(v.name)")
            VStack(alignment: .leading, spacing: 2) {
                Text("\(v.name) · \(v.summary)").fontWeight(selected ? .semibold : .regular)
                Text(v.blurb).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(playing ? "Stop" : "Preview") { model.previewVoice(v.id) }
                .disabled(!kokoroReady)
        }
        .contentShape(Rectangle())
        .onTapGesture { model.settings.kokoroVoice = v.id }
    }

    private var kokoroReady: Bool {
        if case .ready = model.kokoroStatus { return true }
        return false
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

private struct ShortcutSettings: View {
    private var groups: [(String, [AppShortcut])] {
        var order: [String] = []
        for s in Shortcuts.all where !order.contains(s.group) { order.append(s.group) }
        return order.map { g in (g, Shortcuts.all.filter { $0.group == g }) }
    }

    var body: some View {
        Form {
            Section("Anywhere on your Mac") {
                ForEach(Shortcuts.global) { key in row(key.title, key.display) }
            }
            ForEach(groups, id: \.0) { group, items in
                Section(group) {
                    ForEach(items) { item in row(item.title, item.display) }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func row(_ title: String, _ keys: String) -> some View {
        LabeledContent(title) { Text(keys).monospaced().foregroundStyle(.secondary) }
    }
}

private struct DiagnosticsSettings: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section("Logs") {
                Toggle("Detailed logging", isOn: $model.settings.verboseLogging)
                Toggle("Include conversation text", isOn: $model.settings.logConversationText)
                Text("Logs record timings, audio events and decisions. They never include what you or Claude say unless the second switch is on. API keys, tokens, e-mail addresses and your home folder are always removed.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Record the audio PairVox plays", isOn: $model.settings.recordPlaybackAudio)
                Text("For tracking down crackle or static: saves what PairVox itself plays (not your microphone) to the log folder, up to 15 minutes per launch. It is audio of Claude's replies, so leave it off unless you are investigating a sound problem.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Share with someone reviewing a problem") {
                HStack {
                    Button("Export Diagnostics…") { model.exportDiagnostics() }
                    Button("Show Log Folder") { model.revealLogs() }
                }
                Text("Creates one zip on your Desktop with the logs and a snapshot of this Mac's audio setup. Nothing is uploaded; you choose where it goes. Shortcut: \(Shortcuts.of(.exportDiagnostics).display).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
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
