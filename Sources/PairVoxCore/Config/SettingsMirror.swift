// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Which engine values are copied back into the app's general settings.
///
/// A voice command ("faster", "summary mode", "brainstorm mode") changes the speech rate, speech mode or conversation
/// mode inside the running engine, and the user expects the General settings to follow. A project's own overrides
/// must not: a project opened with "Summaries only" starts its engine in that mode, and copying that into General
/// would change every other project too (and write it to disk). So a value is copied only when it changed between two
/// snapshots of the same project, which is what a voice command does and what a project's starting values never do.
public enum SettingsMirror {
    /// The general settings after this snapshot, or nil when nothing should change. `previous` is the same project's
    /// snapshot before this one; pass nil for its first snapshot, which never changes anything.
    public static func apply(previous: EngineSnapshot?, current: EngineSnapshot, to settings: AppSettings) -> AppSettings? {
        guard let previous else { return nil }
        var out = settings
        if abs(current.speechRate - previous.speechRate) > 0.001, abs(current.speechRate - settings.speechRate) > 0.001 {
            out.speechRate = current.speechRate
        }
        if current.speechMode != previous.speechMode, current.speechMode != settings.speechMode {
            out.speechMode = current.speechMode
        }
        if current.conversationMode != previous.conversationMode, current.conversationMode != settings.conversationMode {
            out.conversationMode = current.conversationMode
        }
        return out == settings ? nil : out
    }
}
