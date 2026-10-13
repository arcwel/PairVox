// SPDX-License-Identifier: Apache-2.0

import Carbon.HIToolbox
import SwiftUI

/// Every keyboard shortcut in one table. The menu bar, the Settings list and the global hotkey
/// registration all read from here, so they can't disagree.
struct AppShortcut: Identifiable {
    enum ID: String, CaseIterable {
        case openProject, newSession, focusInput
        case stopSpeaking, interrupt, toggleMute, repeatLast, readDetails, readCode, faster, slower
        case speechFull, speechSkipCode, speechSummary, modeBrainstorm, modeExecute
        case allow, allowAlways, deny
        case exportDiagnostics
    }

    let id: ID
    let title: String
    let key: KeyEquivalent
    let modifiers: SwiftUI.EventModifiers
    let group: String

    /// "⌘⇧." style label.
    var display: String {
        var out = ""
        if modifiers.contains(.control) { out += "⌃" }
        if modifiers.contains(.option) { out += "⌥" }
        if modifiers.contains(.shift) { out += "⇧" }
        if modifiers.contains(.command) { out += "⌘" }
        switch key {
        case .return: return out + "↩"
        case .delete: return out + "⌫"
        case .space: return out + "Space"
        default: return out + String(key.character).uppercased()
        }
    }
}

/// Hotkeys that work while another app is in front.
struct GlobalHotKey: Identifiable {
    enum ID: UInt32 { case pushToTalk = 1, stopSpeaking, toggleMute, interrupt }
    let id: ID
    let title: String
    let keyCode: Int
    let letter: String
    let carbonModifiers = UInt32(controlKey | optionKey)
    var display: String { "⌃⌥" + letter }
}

enum Shortcuts {
    private static func s(_ id: AppShortcut.ID, _ title: String, _ key: KeyEquivalent, _ mods: SwiftUI.EventModifiers = .command,
                          _ group: String) -> AppShortcut {
        AppShortcut(id: id, title: title, key: key, modifiers: mods, group: group)
    }

    static let all: [AppShortcut] = [
        s(.openProject, "Open Project…", "o", .command, "Project"),
        s(.newSession, "New Claude Session", "n", [.command, .shift], "Project"),
        s(.focusInput, "Type Instead of Talking", "l", .command, "Project"),

        s(.stopSpeaking, "Stop Speaking", ".", .command, "Conversation"),
        s(.interrupt, "Interrupt Claude", ".", [.command, .shift], "Conversation"),
        s(.toggleMute, "Mute or Unmute Microphone", "m", [.command, .shift], "Conversation"),
        s(.repeatLast, "Repeat Last Reply", "r", [.command, .shift], "Conversation"),
        s(.readDetails, "Read the Details", "d", [.command, .shift], "Conversation"),
        s(.readCode, "Read the Code", "c", [.command, .shift], "Conversation"),
        s(.faster, "Speak Faster", "]", .command, "Conversation"),
        s(.slower, "Speak Slower", "[", .command, "Conversation"),

        s(.speechFull, "Read Everything", "1", .command, "Speech"),
        s(.speechSkipCode, "Skip Code", "2", .command, "Speech"),
        s(.speechSummary, "Summaries Only", "3", .command, "Speech"),
        s(.modeBrainstorm, "Brainstorm (No Changes)", "b", .command, "Speech"),
        s(.modeExecute, "Execute", "e", .command, "Speech"),

        s(.allow, "Allow (not for high-risk actions)", .return, .command, "Permission prompt"),
        s(.allowAlways, "Always Allow This Session", .return, [.command, .shift], "Permission prompt"),
        s(.deny, "Deny", .delete, .command, "Permission prompt"),

        s(.exportDiagnostics, "Export Diagnostics…", "l", [.command, .shift], "Help"),
    ]

    static func of(_ id: AppShortcut.ID) -> AppShortcut { all.first { $0.id == id }! }

    static let global: [GlobalHotKey] = [
        GlobalHotKey(id: .pushToTalk, title: "Hold to talk", keyCode: kVK_Space, letter: "Space"),
        GlobalHotKey(id: .stopSpeaking, title: "Stop speaking", keyCode: kVK_ANSI_S, letter: "S"),
        GlobalHotKey(id: .toggleMute, title: "Mute or unmute microphone", keyCode: kVK_ANSI_M, letter: "M"),
        GlobalHotKey(id: .interrupt, title: "Interrupt Claude", keyCode: kVK_ANSI_I, letter: "I"),
    ]
}

extension View {
    func shortcut(_ id: AppShortcut.ID) -> some View {
        let s = Shortcuts.of(id)
        return keyboardShortcut(s.key, modifiers: s.modifiers)
    }
}
