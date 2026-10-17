// SPDX-License-Identifier: Apache-2.0

import Foundation

/// How much of each reply is spoken.
public enum SpeechMode: String, Sendable, Codable, CaseIterable {
    /// Read everything, including code, line by line.
    case full
    /// Read prose; describe code blocks briefly ("A 12-line Swift snippet").
    case skipCode
    /// Read only the opening summary of each reply; the rest is available on request.
    case summary

    public var spokenName: String {
        switch self {
        case .full: return "full"
        case .skipCode: return "skip code"
        case .summary: return "summary"
        }
    }
}

/// How chatty PairVox is about what Claude is doing.
public enum Verbosity: String, Sendable, Codable, CaseIterable {
    /// No tool narration.
    case quiet
    /// Throttled narration of tool use.
    case normal
    /// Narrate every tool call.
    case detailed
}

public struct Utterance: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, Codable {
        case prose, code, narration, prompt, notice, ack
    }

    public let id: Int
    public var text: String
    public var kind: Kind

    public init(id: Int, text: String, kind: Kind) {
        self.id = id
        self.text = text
        self.kind = kind
    }
}

/// A piece of the reply that was not spoken, for the transcript view.
public struct SkippedSegment: Sendable, Equatable, Codable {
    public enum Kind: String, Sendable, Codable { case code, table, detail }
    public var kind: Kind
    public var summary: String
}

/// Generates unique utterance IDs across planners.
public final class UtteranceIDs: @unchecked Sendable {
    private let lock = NSLock()
    private var next = 1
    public init() {}
    public func make() -> Int {
        lock.lock(); defer { lock.unlock() }
        let id = next
        next += 1
        return id
    }
}

/// Turns one assistant turn's stream of events into utterances, applying the
/// speech mode. Prose is chunked as it streams so the first words play while
/// Claude is still writing.
public struct SpeechPlanner: Sendable {
    public var mode: SpeechMode
    public var verbosity: Verbosity
    public var pronunciation: Pronunciation
    /// The most prose and code sentences read aloud in one turn; the rest is held back for "details". 0 means no limit.
    public var spokenLimit: Int

    private let ids: UtteranceIDs
    private var parser = MarkdownSpeechParser()
    private var chunker = SentenceChunker()
    private var narrator: ToolNarrator

    /// Summary mode: has the current text block's opening paragraph been spoken?
    private var summaryClosed = false
    private var proseSpokenInBlock = false

    /// Content not spoken in summary mode ("details").
    public private(set) var heldBack: [Utterance] = []
    /// Spoken readings of the turn's code blocks ("read the code").
    public private(set) var codeReadings: [Utterance] = []
    /// Everything that was queued for speech this turn ("repeat that").
    public private(set) var spokenThisTurn: [Utterance] = []
    public private(set) var skipped: [SkippedSegment] = []
    private var toolCount = 0
    private var spokenCount = 0
    private var limitHit = false

    public init(mode: SpeechMode, verbosity: Verbosity = .normal, pronunciation: Pronunciation = Pronunciation(),
                ids: UtteranceIDs = UtteranceIDs(), spokenLimit: Int = 0) {
        self.spokenLimit = max(0, spokenLimit)
        self.mode = mode
        self.verbosity = verbosity
        self.pronunciation = pronunciation
        self.ids = ids
        self.narrator = ToolNarrator(pronunciation: pronunciation, minInterval: verbosity == .detailed ? 0 : 4)
    }

    // MARK: Events

    public mutating func textDelta(_ text: String) -> [Utterance] {
        handle(parser.feed(text))
    }

    public mutating func textBlockEnded() -> [Utterance] {
        var out = handle(parser.finish())
        out += flushChunker()
        // Each assistant message gets its own summary in summary mode.
        summaryClosed = false
        proseSpokenInBlock = false
        chunker.resetForNewReply()
        return out
    }

    public mutating func toolUse(_ tool: ToolUse, now: Date = Date()) -> [Utterance] {
        guard verbosity != .quiet else { return [] }
        toolCount += 1
        // Flush any half sentence first so narration doesn't cut into it.
        var out = flushChunker()
        if let phrase = narrator.narrate(tool, now: now) {
            out.append(make(phrase, .narration))
        }
        return out
    }

    /// Ends the turn. Returns final utterances (remaining prose, "say details" hint).
    public mutating func finishTurn(_ result: TurnResult) -> [Utterance] {
        var out = handle(parser.finish())
        out += flushChunker()
        switch result.outcome {
        case .success:
            if mode == .summary, !heldBack.isEmpty {
                out.append(make("There's more detail. Say “details” to hear it.", .prompt))
            } else if limitHit, !heldBack.isEmpty {
                out.append(make("That's the first part. Say “details” to hear the rest.", .prompt))
            }
        case .interrupted:
            break
        case .failed(let message):
            let short = message.count > 120 ? "Something went wrong." : "Something went wrong: \(message)"
            out.append(make(short, .notice))
        }
        return out
    }

    /// Text spoken once a fresh turn begins with no speech yet (filler).
    public func acknowledgement(seed: Int) -> String {
        let options = ["On it.", "Okay.", "Sure.", "Got it.", "Let me look."]
        return options[abs(seed) % options.count]
    }

    /// Called after the held-back detail has been read.
    public mutating func clearHeldBack() {
        heldBack.removeAll()
    }

    // MARK: Internals

    private mutating func handle(_ pieces: [SpeechPiece]) -> [Utterance] {
        var out: [Utterance] = []
        for piece in pieces {
            switch piece {
            case .text(let t):
                out += route(chunker.append(t))
            case .boundary:
                out += route(chunker.boundary())
            case .paragraphBreak, .sectionBreak:
                out += route(chunker.boundary())
                if mode == .summary, proseSpokenInBlock { summaryClosed = true }
            case .codeBlock(let lang, let code):
                out += route(chunker.boundary())
                out += codeBlock(language: lang, code: code)
            case .table(let rows):
                out += route(chunker.boundary())
                let desc = "There's a table with \(rows) \(rows == 1 ? "row" : "rows") on screen."
                skipped.append(SkippedSegment(kind: .table, summary: desc))
                if (mode == .summary && summaryClosed) || overLimit() {
                    heldBack.append(make(desc, .prose, record: false))
                } else {
                    out.append(make(desc, .prose))
                    spokenCount += 1
                }
            }
        }
        return out
    }

    private mutating func flushChunker() -> [Utterance] {
        route(chunker.flush())
    }

    private mutating func route(_ chunks: [String]) -> [Utterance] {
        var out: [Utterance] = []
        for raw in chunks {
            let spoken = pronunciation.speak(raw)
            guard SentenceChunker.isSpeakable(spoken) else { continue }
            if mode == .summary && summaryClosed || overLimit() {
                heldBack.append(make(spoken, .prose, record: false))
            } else {
                out.append(make(spoken, .prose))
                proseSpokenInBlock = true
                spokenCount += 1
            }
        }
        return out
    }

    private mutating func codeBlock(language: String?, code: String) -> [Utterance] {
        let description = CodeReader.describe(language: language, code: code)
        skipped.append(SkippedSegment(kind: .code, summary: description))
        let reading = CodeReader.read(language: language, code: code, pronunciation: pronunciation)
        codeReadings += reading.map { make($0, .code, record: false) }

        if mode != .summary, overLimit() {
            heldBack.append(make(description, .code, record: false))
            return []
        }
        switch mode {
        case .full:
            let spoken = [make(description, .code)] + reading.map { make($0, .code) }
            spokenCount += spoken.count
            return spoken
        case .skipCode:
            spokenCount += 1
            return [make(description, .code)]
        case .summary:
            if summaryClosed {
                heldBack.append(make(description, .code, record: false))
                return []
            }
            return [make(description, .code)]
        }
    }

    /// True once this turn has used up its spoken sentences. From then on everything is held back.
    private mutating func overLimit() -> Bool {
        guard spokenLimit > 0, spokenCount >= spokenLimit else { return false }
        limitHit = true
        return true
    }

    private mutating func make(_ text: String, _ kind: Utterance.Kind, record: Bool = true) -> Utterance {
        let u = Utterance(id: ids.make(), text: text, kind: kind)
        if record { spokenThisTurn.append(u) }
        return u
    }
}
