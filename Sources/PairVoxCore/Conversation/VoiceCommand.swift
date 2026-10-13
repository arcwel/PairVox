// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Brainstorm (plan-only, no file changes) or execute (tools allowed).
public enum ConversationMode: String, Sendable, Codable, CaseIterable {
    case brainstorm
    case execute

    public var permissionMode: PermissionMode {
        switch self {
        case .brainstorm: return .plan
        case .execute: return .default
        }
    }
}

/// Things the user can say that PairVox handles locally instead of sending to Claude.
public enum VoiceCommand: Sendable, Equatable {
    case stopSpeaking
    case interruptClaude
    case repeatLast
    case readMore
    case readCode
    case skip
    case setSpeechMode(SpeechMode)
    case setConversationMode(ConversationMode)
    case approve
    case approveAlways
    /// The deliberate phrase that approves a high-risk request by voice (only when the user turned that on).
    case confirmHighRisk
    /// "explain": hear the plain-words explanation of the request on screen.
    case explain
    case deny
    case newSession
    case faster
    case slower
    /// "yeah", "okay", "mm-hmm" while Claude is working: acknowledgement, not an instruction.
    case backchannel

    /// Context that changes how short replies are interpreted.
    public struct Context: Sendable {
        public var awaitingPermission: Bool
        public var claudeIsWorking: Bool
        public var hasHeldBack: Bool
        /// A high-risk request is waiting and the user allows confirming those by voice.
        public var awaitingHighRiskConfirmation: Bool

        public init(awaitingPermission: Bool = false, claudeIsWorking: Bool = false, hasHeldBack: Bool = false,
                    awaitingHighRiskConfirmation: Bool = false) {
            self.awaitingPermission = awaitingPermission
            self.claudeIsWorking = claudeIsWorking
            self.hasHeldBack = hasHeldBack
            self.awaitingHighRiskConfirmation = awaitingHighRiskConfirmation
        }
    }

    /// Returns a command only when the whole utterance is a command. Real
    /// instructions ("stop using the singleton and inject it") pass through.
    public static func parse(_ transcript: String, context: Context = Context()) -> VoiceCommand? {
        let words = normalize(transcript)
        guard !words.isEmpty, words.count <= 6 else { return nil }
        let phrase = words.joined(separator: " ")
        // Allow a polite prefix/suffix.
        let core = strip(phrase, prefixes: ["hey pairvox ", "pairvox ", "okay ", "ok ", "please ", "um ", "uh "],
                         suffixes: [" please", " thanks", " thank you"])

        if context.awaitingPermission, context.awaitingHighRiskConfirmation, isHighRiskConfirmation(core) {
            return .confirmHighRisk
        }
        if context.awaitingPermission, ["explain", "explain that", "explain it", "explain this", "what does that do",
                                        "what does it do", "what does this do", "what is that", "what is it"].contains(core) {
            return .explain
        }
        if context.awaitingPermission, let answer = permissionAnswer(core) {
            return answer
        }
        if context.claudeIsWorking, !context.awaitingPermission, backchannels.contains(core) {
            return .backchannel
        }

        switch core {
        case "stop", "stop talking", "quiet", "be quiet", "shush", "hush", "pause", "hold on", "wait", "one sec",
             "one second", "silence", "shut up":
            return .stopSpeaking
        case "cancel", "abort", "stop that", "never mind", "nevermind", "forget it", "stop working", "cancel that",
             "stop it":
            return context.claudeIsWorking ? .interruptClaude : .stopSpeaking
        case "repeat", "repeat that", "say that again", "come again", "what did you say", "again", "pardon",
             "sorry what":
            return .repeatLast
        case "details", "more", "more details", "tell me more", "read the rest", "go on", "continue reading",
             "keep going", "the details", "give me the details", "read more":
            return .readMore
        case "read the code", "read code", "read me the code", "read it", "read the snippet":
            return .readCode
        case "skip", "next", "skip that", "skip this":
            return .skip
        case "summary mode", "just the summary", "summarize", "summaries only", "summary only", "summaries":
            return .setSpeechMode(.summary)
        case "full mode", "read everything", "read it all", "full responses", "read whole responses":
            return .setSpeechMode(.full)
        case "skip code", "no code", "skip code mode", "skip the code", "don't read code", "dont read code":
            return .setSpeechMode(.skipCode)
        case "brainstorm mode", "lets brainstorm", "let's brainstorm", "planning mode", "plan mode", "brainstorm":
            return .setConversationMode(.brainstorm)
        case "execute mode", "build mode", "work mode", "go build it", "start building", "execution mode":
            return .setConversationMode(.execute)
        case "new session", "start over", "new conversation", "fresh start", "reset session":
            return .newSession
        case "faster", "speak faster", "talk faster", "speed up":
            return .faster
        case "slower", "speak slower", "talk slower", "slow down":
            return .slower
        default:
            return nil
        }
    }

    static let backchannels: Set<String> = [
        "yes", "yeah", "yep", "yup", "ok", "okay", "sure", "right", "cool", "great", "nice", "thanks", "thank you",
        "uh huh", "mm hmm", "mhm", "mm", "got it", "alright", "all right", "sounds good", "perfect", "awesome",
    ]

    static let approveWords: Set<String> = ["yes", "yeah", "yep", "yup", "sure", "allow", "approve", "approved", "ok",
                                            "okay", "confirm", "confirmed", "fine", "absolutely", "definitely"]
    static let approvePhrases: Set<String> = ["go ahead", "do it", "go for it", "sounds good", "looks good", "ship it",
                                              "allow it", "allow once", "make it so", "please do"]
    static let denyWords: Set<String> = ["no", "nope", "nah", "deny", "denied", "don't", "dont", "not", "reject",
                                         "cancel", "stop", "never"]

    /// The phrase PairVox asks for. It is deliberately not a casual "yes", and any refusal word cancels it.
    static func isHighRiskConfirmation(_ core: String) -> Bool {
        let words = core.split(separator: " ").map(String.init)
        guard core.contains("confirm high risk"), !words.contains(where: denyWords.contains) else { return false }
        return words.count <= 5
    }

    /// Short yes/no answers to a permission prompt. Longer replies go to Claude as feedback.
    static func permissionAnswer(_ core: String) -> VoiceCommand? {
        let words = core.split(separator: " ").map(String.init)
        guard !words.isEmpty, words.count <= 5 else { return nil }
        if words.contains(where: denyWords.contains) {
            // "no" and friends win over any approving word, including "always allow" and "ask again":
            // "don't always allow" and "never ask again" are refusals, and a misheard refusal fails safe.
            return words.count <= 4 ? .deny : nil
        }
        if core.contains("ask again") || core.contains("always allow") || core.contains("allow always")
            || core == "always" || core == "yes always" {
            return .approveAlways
        }
        let approving = words.contains(where: approveWords.contains)
            || approvePhrases.contains { core.contains($0) }
        guard approving else { return nil }
        if words.contains("always") || core.contains("ask again") { return .approveAlways }
        return .approve
    }

    static func normalize(_ s: String) -> [String] {
        let lowered = s.lowercased()
            .replacingOccurrences(of: "’", with: "'")
        let allowed = CharacterSet.letters.union(.decimalDigits).union(CharacterSet(charactersIn: "' "))
        let cleaned = String(String.UnicodeScalarView(lowered.unicodeScalars.map { allowed.contains($0) ? $0 : " " }))
        return cleaned.split(separator: " ").map(String.init)
    }

    static func strip(_ phrase: String, prefixes: [String], suffixes: [String]) -> String {
        var p = phrase
        var changed = true
        while changed {
            changed = false
            for pre in prefixes where p.hasPrefix(pre) && p.count > pre.count {
                p.removeFirst(pre.count); changed = true
            }
            for suf in suffixes where p.hasSuffix(suf) && p.count > suf.count {
                p.removeLast(suf.count); changed = true
            }
        }
        return p
    }
}
