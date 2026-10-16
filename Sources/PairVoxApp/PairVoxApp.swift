// SPDX-License-Identifier: Apache-2.0

import AppKit
import PairVoxCore
import SwiftUI

@main
struct PairVoxApp: App {
    @StateObject private var model = AppModel()

    init() {
        TTSProbe.runIfRequested()   // `--tts-probe`: a headless voice measurement, then exit
        // MLX and Metal report their failures on stderr and nowhere else; keep them next to the app's own log.
        let directory = DiagnosticsExporter.logDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        freopen(directory.appendingPathComponent("stderr.log").path, "a", stderr)
        // When launched as a bare executable (swift run / Xcode scheme) make sure
        // we still get a Dock icon, menu bar and key window.
        NSApplication.shared.setActivationPolicy(.regular)
        DispatchQueue.main.async { NSApplication.shared.activate(ignoringOtherApps: true) }
    }

    var body: some Scene {
        WindowGroup("PairVox", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 640, minHeight: 520)
        }
        .defaultSize(width: 860, height: 760)
        .commands {
            CommandGroup(after: .newItem) {
                Button(Shortcuts.of(.openProject).title) { model.chooseProject() }.shortcut(.openProject)
                Button(Shortcuts.of(.newSession).title) { model.newSession() }.shortcut(.newSession)
                Menu("Resume Earlier Session") {
                    let past = model.pastSessions
                    if past.isEmpty { Text("None found for this project") }
                    ForEach(past) { s in
                        Button("\(s.modified.formatted(date: .abbreviated, time: .shortened)) · \(s.preview)") { model.resumeSession(s.id) }
                    }
                }.disabled(model.project == nil)
                Button(Shortcuts.of(.focusInput).title) { model.focusInputField() }.shortcut(.focusInput)
                Divider()
                Button(Shortcuts.of(.nextProject).title) { model.switchToNextProject(1) }.shortcut(.nextProject)
                    .disabled(model.sessions.count < 2)
                Button(Shortcuts.of(.previousProject).title) { model.switchToNextProject(-1) }.shortcut(.previousProject)
                    .disabled(model.sessions.count < 2)
                Button(Shortcuts.of(.closeProject).title) { model.closeSession() }.shortcut(.closeProject)
                    .disabled(model.sessions.isEmpty)
                ForEach(Array(model.sessions.prefix(9).enumerated()), id: \.element.id) { index, session in
                    Button("Go to \(session.name)") { model.switchToProject(at: index) }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [.command, .option])
                }
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
            CommandGroup(after: .windowArrangement) {
                MiniWindowCommand()
            }
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { Updater.shared.checkForUpdates() }
                    .disabled(!Updater.shared.canCheck)
                    .help(Updater.shared.unavailableReason ?? "Looks for a newer PairVox.")
            }
            CommandGroup(replacing: .help) {
                Button(Shortcuts.of(.exportDiagnostics).title) { model.exportDiagnostics() }.shortcut(.exportDiagnostics)
                Button("Show Log Folder in Finder") { model.revealLogs() }
                Button("Play Audio Test") { model.playAudioTest() }
            }
        }

        Window("PairVox Mini", id: "mini") {
            MiniView()
                .environmentObject(model)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .windowLevel(.floating)

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

private struct MiniWindowCommand: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Show Mini Window") { openWindow(id: "mini") }.keyboardShortcut("m", modifiers: [.command, .option])
    }
}

extension AppModel {
    var menuBarSymbol: String {
        // A project in the background that is waiting on a decision shows in the menu bar too.
        if sessions.contains(where: { $0.needsAttention && !$0.isActive }) { return "exclamationmark.bubble" }
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
