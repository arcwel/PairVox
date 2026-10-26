// SPDX-License-Identifier: Apache-2.0

import Foundation

/// How a request may be approved by voice (owner, 2026-10-26). A tap on the phone or a click on the Mac always works.
public enum ApprovalGate: String, Codable, Sendable, CaseIterable, Comparable {
    /// One spoken yes.
    case skip
    /// A spoken yes, then PairVox reads back what will happen and asks once more.
    case auto
    /// No spoken answer counts: a tap or a click.
    case manual

    public var title: String {
        switch self {
        case .manual: return "Manual"
        case .auto: return "Auto"
        case .skip: return "Skip"
        }
    }

    public var explanation: String {
        switch self {
        case .manual: return "Tap or click to approve"
        case .auto: return "Say yes, hear what it does, say yes again"
        case .skip: return "Say yes once"
        }
    }

    /// Stricter gates sort higher: a command takes the strictest gate of its steps.
    public static func < (a: ApprovalGate, b: ApprovalGate) -> Bool { a.strictness < b.strictness }
    private var strictness: Int { self == .skip ? 0 : (self == .auto ? 1 : 2) }
}

/// The kinds of request a gate is chosen for in Settings.
public enum CommandCategory: String, Codable, Sendable, CaseIterable {
    /// Shell commands that reach another machine or service (gh, curl, ssh, git fetch, docker…).
    case network
    /// Installing packages, or downloading and running one (npm install, pip install, npx…).
    case install
    /// Every other shell command that is not high risk (builds, tests, git commit, mv…).
    case otherCommands
    /// Edits and new files inside the project folder.
    case fileEdits

    public var title: String {
        switch self {
        case .network: return "Commands that reach the network"
        case .install: return "Installing or downloading packages"
        case .otherCommands: return "Other commands"
        case .fileEdits: return "Editing files in the project"
        }
    }
}

/// A gate for one command, chosen by the user: `gh`, or `gh pr list` for just that subcommand.
public struct CommandGateRule: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    /// The program and, optionally, the words after it, as typed: "gh", "gh pr list", "npm test".
    public var command: String
    public var gate: ApprovalGate

    public init(id: UUID = UUID(), command: String, gate: ApprovalGate) {
        self.id = id
        self.command = command
        self.gate = gate
    }

    /// The command's words in lower case, without a directory on the program (`/usr/bin/gh` is `gh`). Lower case
    /// because the Mac's disk is: `GH pr list` runs gh.
    public var words: [String] {
        var w = command.lowercased().split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        if let first = w.first { w[0] = (first as NSString).lastPathComponent }
        return w
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        command = (try? c.decode(String.self, forKey: .command)) ?? ""
        gate = (try? c.decode(ApprovalGate.self, forKey: .gate)) ?? .manual   // an unreadable gate errs toward asking
    }
}

/// The owner's gates: one per category, and rules for named commands that override them.
public struct ApprovalGates: Codable, Sendable, Equatable {
    public var categories: [CommandCategory: ApprovalGate]
    public var rules: [CommandGateRule]

    public static let defaultCategories: [CommandCategory: ApprovalGate] = [
        .network: .manual, .install: .manual, .otherCommands: .skip, .fileEdits: .skip,
    ]
    /// GitHub's CLI is Manual by default (owner, 2026-10-26), named so it shows in the list and can be changed.
    public static let defaultRules = [CommandGateRule(command: "gh", gate: .manual)]

    public init(categories: [CommandCategory: ApprovalGate] = ApprovalGates.defaultCategories,
                rules: [CommandGateRule] = ApprovalGates.defaultRules) {
        self.categories = categories
        self.rules = rules
    }

    /// Every kind of request Manual and no rules: what a settings file other users could write falls back to, like
    /// every other standing consent (it never loosens anything the owner chose).
    public static let strictest = ApprovalGates(categories: Dictionary(uniqueKeysWithValues: CommandCategory.allCases.map { ($0, .manual) }), rules: [])

    public func gate(for category: CommandCategory) -> ApprovalGate {
        categories[category] ?? Self.defaultCategories[category] ?? .manual
    }

    /// The rule for words starting at the front of `step`: the longest that matches (`gh pr list` before `gh`), and
    /// of two as long, the stricter. Flags count as words, so `gh pr list` does not match `gh --repo x pr list`; that
    /// falls back to `gh`. Words are compared in lower case, the first without its folder.
    public func rule(at step: [String]) -> CommandGateRule? {
        let step = step.enumerated().map { $0.offset == 0 ? ($0.element.lowercased() as NSString).lastPathComponent : $0.element.lowercased() }
        return rules.filter { r in
            let w = r.words
            return !w.isEmpty && w.count <= step.count && Array(step.prefix(w.count)) == w
        }.max { ($0.words.count, $0.gate) < ($1.words.count, $1.gate) }
    }

    public func rule(program: String, args: [String]) -> CommandGateRule? { rule(at: [program] + args) }

    enum CodingKeys: String, CodingKey { case categories, rules }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Keyed by the category's name, so a file written by a later version with a category this one does not
        // know still loads; a missing category takes its default.
        // Values are read one by one: a value this version cannot read is Manual (errs toward asking) and does not
        // take the other categories with it.
        let raw = (try? c.decode([String: String].self, forKey: .categories)) ?? [:]
        var cats = Self.defaultCategories
        for (k, v) in raw { if let cat = CommandCategory(rawValue: k) { cats[cat] = ApprovalGate(rawValue: v) ?? .manual } }
        categories = cats
        rules = ((try? c.decode([CommandGateRule].self, forKey: .rules)) ?? Self.defaultRules).filter { !$0.words.isEmpty }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Dictionary(uniqueKeysWithValues: categories.map { ($0.key.rawValue, $0.value) }), forKey: .categories)
        try c.encode(rules, forKey: .rules)
    }
}
