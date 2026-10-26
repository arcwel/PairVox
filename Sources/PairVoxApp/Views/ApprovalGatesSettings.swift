// SPDX-License-Identifier: Apache-2.0

import PairVoxCore
import SwiftUI

/// Settings, Approvals: which kinds of request take one spoken yes, two, or a tap, and named commands that differ.
struct ApprovalGatesSettings: View {
    @EnvironmentObject var model: AppModel
    @State private var newCommand = ""
    @State private var newGate = ApprovalGate.manual

    private var gates: Binding<ApprovalGates> { $model.settings.approvalGates }

    var body: some View {
        Form {
            Section {
                ForEach(ApprovalGate.allCases.reversed(), id: \.self) { g in
                    LabeledContent(g.title) { Text(g.explanation).foregroundStyle(.secondary) }
                }
                Text("A tap on the phone or a click on the Mac always works. High-risk requests (deleting files, pushing, sudo, edits outside the project) and commands PairVox cannot read out are always Manual, whatever is set here.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Gates") }

            Section {
                ForEach(CommandCategory.allCases, id: \.self) { category in
                    Picker(category.title, selection: Binding(
                        get: { gates.wrappedValue.gate(for: category) },
                        set: { gates.wrappedValue.categories[category] = $0 })) {
                        ForEach(ApprovalGate.allCases.reversed(), id: \.self) { Text($0.title).tag($0) }
                    }
                }
            } header: { Text("Kinds of request") }

            Section {
                Text("A command listed here uses its own gate instead of its kind's. \u{201C}gh\u{201D} covers every gh command, \u{201C}gh pr list\u{201D} only that one; the longest match wins. A command with several steps uses its strictest step.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(gates.rules) { $rule in
                    HStack {
                        TextField("Command", text: $rule.command).font(.body.monospaced()).labelsHidden()
                        Picker("Gate", selection: $rule.gate) {
                            ForEach(ApprovalGate.allCases.reversed(), id: \.self) { Text($0.title).tag($0) }
                        }
                        .labelsHidden().fixedSize()
                        Button(role: .destructive) { gates.wrappedValue.rules.removeAll { $0.id == rule.id } } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove \(rule.command)")
                        .accessibilityLabel("Remove \(rule.command)")
                    }
                }
                HStack {
                    TextField("Add a command, such as npm test", text: $newCommand).font(.body.monospaced()).labelsHidden()
                        .onSubmit(add)
                    Picker("Gate", selection: $newGate) {
                        ForEach(ApprovalGate.allCases.reversed(), id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                    Button("Add", action: add).disabled(!canAdd)
                }
            } header: { Text("Commands") }

            Section {
                Button("Restore Defaults") { gates.wrappedValue = ApprovalGates() }
                Text("Network commands and package installs are Manual, gh is Manual, everything else is Skip.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var trimmed: String { newCommand.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var canAdd: Bool {
        let words = CommandGateRule(command: trimmed, gate: newGate).words
        return !words.isEmpty && !gates.wrappedValue.rules.contains { $0.words == words }
    }

    private func add() {
        guard canAdd else { return }
        gates.wrappedValue.rules.append(CommandGateRule(command: trimmed, gate: newGate))
        newCommand = ""
    }
}
