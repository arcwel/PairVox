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
                Button(Shortcuts.of(.openProject).title) { model.chooseProject() }.shortcut(.openProject)
                Button(Shortcuts.of(.newSession).title) { model.newSession() }.shortcut(.newSession)
                Button(Shortcuts.of(.focusInput).title) { model.focusInputField() }.shortcut(.focusInput)
            }
            CommandMenu("Conversation") {
                Button(Shortcuts.of(.stopSpeaking).title) { model.stopSpeaking() }.shortcut(.stopSpeaking)
                Button(Shortcuts.of(.interrupt).title) { model.interrupt() }.shortcut(.interrupt)
                Button(model.listeningMode == .muted ? "Unmute Microphone" : "Mute Microphone") { model.toggleMute() }
                    .shortcut(.toggleMute)
                Divider()
                Button(Shortcuts.of(.repeatLast).title) { model.perform(.repeatLast) }.shortcut(.repeatLast)
                Button(Shortcuts.of(.readDetails).title) { model.perform(.readMore) }.shortcut(.readDetails)
                Button(Shortcuts.of(.readCode).title) { model.perform(.readCode) }.shortcut(.readCode)
                Button(Shortcuts.of(.faster).title) { model.changeSpeechRate(faster: true) }.shortcut(.faster)
                Button(Shortcuts.of(.slower).title) { model.changeSpeechRate(faster: false) }.shortcut(.slower)
                Divider()
                Button(Shortcuts.of(.speechFull).title) { model.setSpeechMode(.full) }.shortcut(.speechFull)
                Button(Shortcuts.of(.speechSkipCode).title) { model.setSpeechMode(.skipCode) }.shortcut(.speechSkipCode)
                Button(Shortcuts.of(.speechSummary).title) { model.setSpeechMode(.summary) }.shortcut(.speechSummary)
                Button(Shortcuts.of(.modeBrainstorm).title) { model.setConversationMode(.brainstorm) }.shortcut(.modeBrainstorm)
                Button(Shortcuts.of(.modeExecute).title) { model.setConversationMode(.execute) }.shortcut(.modeExecute)
                Divider()
                // Active only while Claude is asking. High-risk requests need a click on the card.
                Button("Allow") { model.approve() }.shortcut(.allow).disabled(!model.canApproveWithKeyboard)
                Button("Always Allow This Session") { model.approve(always: true) }.shortcut(.allowAlways)
                    .disabled(!model.canApproveWithKeyboard)
                Button("Deny") { model.deny() }.shortcut(.deny).disabled(model.snapshot.pendingPermission == nil)
            }
            CommandGroup(replacing: .help) {
                Button(Shortcuts.of(.exportDiagnostics).title) { model.exportDiagnostics() }.shortcut(.exportDiagnostics)
                Button("Show Log Folder in Finder") { model.revealLogs() }
                Button("Play Audio Test") { model.playAudioTest() }
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
