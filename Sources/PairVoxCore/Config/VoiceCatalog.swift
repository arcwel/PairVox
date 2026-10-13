// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The Kokoro voices PairVox offers up front. Kokoro ships more voicepacks, and the
/// settings still list them all, but four distinct choices are easier to pick from.
public struct KokoroVoiceInfo: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let accent: String
    public let gender: String
    public let blurb: String

    public var isBritish: Bool { id.hasPrefix("b") }
    public var summary: String { "\(accent) \(gender)" }
}

public enum VoiceCatalog {
    public static let defaultVoiceID = "af_heart"

    /// Two American and two British voices, one female and one male in each accent.
    public static let featured: [KokoroVoiceInfo] = [
        KokoroVoiceInfo(id: "af_heart", name: "Heart", accent: "American", gender: "female",
                        blurb: "Warm and clear. The default."),
        KokoroVoiceInfo(id: "am_michael", name: "Michael", accent: "American", gender: "male",
                        blurb: "Steady and conversational."),
        KokoroVoiceInfo(id: "bf_emma", name: "Emma", accent: "British", gender: "female",
                        blurb: "Crisp and measured."),
        KokoroVoiceInfo(id: "bm_george", name: "George", accent: "British", gender: "male",
                        blurb: "Deep and unhurried."),
    ]

    /// Every voicepack in Kokoro v1.0 that PairVox can speak with, for the "more voices" list.
    public static let allIDs: [String] = [
        "af_heart", "af_bella", "af_nicole", "af_sarah", "af_sky", "af_nova", "af_alloy", "af_aoede", "af_jessica",
        "af_kore", "af_river", "am_michael", "am_adam", "am_eric", "am_liam", "am_onyx", "am_echo", "am_fenrir",
        "am_puck", "bf_emma", "bf_isabella", "bf_alice", "bf_lily", "bm_george", "bm_lewis", "bm_daniel", "bm_fable",
    ]

    public static func info(for id: String) -> KokoroVoiceInfo? {
        featured.first { $0.id == id }
    }

    /// The voices outside the featured four, for the secondary list.
    public static var others: [String] {
        let featuredIDs = Set(featured.map(\.id))
        return allIDs.filter { !featuredIDs.contains($0) }
    }

    /// "Heart — American female" for featured voices, a derived label for the rest.
    public static func label(for id: String) -> String {
        if let v = info(for: id) { return "\(v.name) — \(v.summary)" }
        let accent = id.hasPrefix("b") ? "British" : "American"
        let gender = id.dropFirst().first == "f" ? "female" : "male"
        let name = id.split(separator: "_").last.map { $0.capitalized } ?? id
        return "\(name) — \(accent) \(gender)"
    }

    /// What a voice says when the user taps Preview.
    public static func sampleLine(for id: String) -> String {
        let name = info(for: id)?.name ?? id.split(separator: "_").last.map { $0.capitalized } ?? "your voice"
        return "Hi, I'm \(name). I'll read Claude's replies out loud. Say stop any time and I will."
    }
}
