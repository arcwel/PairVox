// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// A text field that edits a local draft and hands the text over only on Return or when focus leaves.
///
/// A plain `TextField(text:)` on macOS writes on every keystroke. For the Claude path that ran `claude --version` and
/// opened a "file does not exist" alert after the second character; for a comma-separated list the field re-rendered
/// from the parsed value and swallowed the comma just typed, so a second word could not be entered.
struct CommitTextField: View {
    let title: String
    /// The stored value, as text.
    let value: String
    /// Called with the draft when it is committed and differs from `value`.
    let commit: (String) -> Void

    @State private var draft = ""
    @State private var editing = false
    @FocusState private var focused: Bool

    var body: some View {
        TextField(title, text: $draft)
            .focused($focused)
            .onSubmit(send)
            .onAppear { draft = value }
            .onChange(of: value) { _, newValue in if !editing { draft = newValue } }
            .onChange(of: focused) { _, isFocused in
                editing = isFocused
                if !isFocused { send() }
            }
    }

    private func send() {
        if draft != value { commit(draft) }
    }
}
