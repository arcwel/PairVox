// SPDX-License-Identifier: Apache-2.0

import AppKit
import PairVoxCore
import SwiftUI

@main
struct PairVoxApp: App {
    @StateObject private var model = AppModel()

    init() {
        // When launched as a bare executable (swift run / Xcode scheme) make sure
        // we still get a Dock icon, menu bar and key window.
        NSApplication.shared.setActivationPolicy(.regular)
        DispatchQueue.main.async { NSApplication.shared.activate(ignoringOtherApps: true) }
    }

    var body: some Scene {
        WindowGroup("PairVox") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 640, minHeight: 520)
        }
        .defaultSize(width: 860, height: 760)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Open Project…") { model.chooseProject() }
                    .keyboardShortcut("o")
                Button("New Claude Session") { model.newSession() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
            }
            CommandMenu("Conversation") {
                Button("Stop Speaking") { model.stopSpeaking() }
                    .keyboardShortcut(".", modifiers: [.command])
                Button("Interrupt Claude") { model.interrupt() }
                    .keyboardShortcut(".", modifiers: [.command, .shift])
                Button(model.listeningMode == .muted ? "Unmute Microphone" : "Mute Microphone") { model.toggleMute() }
                    .keyboardShortcut("m", modifiers: [.command, .shift])
                Divider()
                Button("Repeat Last Reply") { model.perform(.repeatLast) }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Read the Details") { model.perform(.readMore) }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                Button("Read the Code") { model.perform(.readCode) }
                Divider()
                Picker("Speech", selection: Binding(get: { model.settings.speechMode }, set: { model.setSpeechMode($0) })) {
                    Text("Read everything").tag(SpeechMode.full)
                    Text("Skip code").tag(SpeechMode.skipCode)
                    Text("Summaries only").tag(SpeechMode.summary)
                }
                Picker("Mode", selection: Binding(get: { model.snapshot.conversationMode },
                                                  set: { model.setConversationMode($0) })) {
                    Text("Brainstorm (no changes)").tag(ConversationMode.brainstorm)
                    Text("Execute").tag(ConversationMode.execute)
                }
            }
        }

        Settings {
            SettingsView()
                .environmentObject(model)
        }

        MenuBarExtra {
            MenuBarView()
                .environmentObject(model)
        } label: {
            Image(systemName: model.menuBarSymbol)
        }
    }
}

extension AppModel {
    var menuBarSymbol: String {
        switch snapshot.phase {
        case .speaking: return "waveform"
        case .listening, .transcribing: return "mic.fill"
        case .thinking, .working: return "ellipsis.bubble"
        case .awaitingPermission: return "exclamationmark.bubble"
        case .needsSetup: return "exclamationmark.triangle"
        default: return listeningMode == .muted ? "mic.slash" : "bubble.left.and.bubble.right"
        }
    }
}
