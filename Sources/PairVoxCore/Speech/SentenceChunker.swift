// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Splits streaming prose into chunks a TTS engine can say naturally.
///
/// Latency matters most for the first chunk of a reply, so the first chunk may
/// be cut at a comma once enough text has arrived; later chunks wait for full
/// sentences. Chunks are capped so neural TTS stays within its token window.
public struct SentenceChunker: Sendable {
    public struct Config: Sendable {
        /// First chunk may split at a comma once the buffer reaches this many characters.
        public var firstChunkCommaSplit = 60
        /// Never emit a chunk shorter than this at a soft (comma) boundary.
        public var minSoftChunk = 24
        /// Force a split (at a comma or space) beyond this length.
        public var maxChunk = 220
        /// Colons/semicolons split once a chunk is at least this long.
        public var clauseSplit = 90
        public init() {}
    }

    public var config: Config
    private var buffer = ""
    public private(set) var emittedCount = 0

    static let abbreviations: Set<String> = [
        "mr", "mrs", "ms", "dr", "prof", "st", "vs", "etc", "e.g", "i.e", "eg", "ie", "fig", "approx", "inc", "ltd",
        "jr", "sr", "no", "vol", "cf", "al", "min", "max", "dept", "est",
    ]

    public init(config: Config = Config()) {
        self.config = config
    }

    public var pendingText: String { buffer }

    /// Resets the "first chunk" fast path (call at the start of each reply).
    public mutating func resetForNewReply() {
        emittedCount = 0
    }

    public mutating func append(_ text: String) -> [String] {
        buffer += text
        return extract()
    }

    /// A hard boundary (heading end, list item end, paragraph break): flush what we have.
    public mutating func boundary() -> [String] {
        var chunks = extract()
        let rest = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        buffer = ""
        if SentenceChunker.isSpeakable(rest) {
            chunks.append(rest)
            emittedCount += 1
        }
        return chunks
    }

    public mutating func flush() -> [String] {
        boundary()
    }

    private mutating func extract() -> [String] {
        var chunks: [String] = []
        while let cut = nextCut() {
            let chunk = String(buffer[..<cut]).trimmingCharacters(in: .whitespacesAndNewlines)
            buffer = String(buffer[cut...])
            if SentenceChunker.isSpeakable(chunk) {
                chunks.append(chunk)
                emittedCount += 1
            }
        }
        return chunks
    }

    /// Finds the end index (exclusive) of the next chunk in `buffer`, or nil to wait for more text.
    private func nextCut() -> String.Index? {
        let chars = Array(buffer)
        guard !chars.isEmpty else { return nil }

        var lastComma: Int?
        var lastSpace: Int?
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "." || c == "!" || c == "?" || c == "…" {
                // Skip closing quotes/brackets after the punctuation.
                var j = i + 1
                while j < chars.count, "\"'”’)]".contains(chars[j]) { j += 1 }
                if j >= chars.count { return nil } // need to see what follows
                if chars[j].isWhitespace {
                    if c != "." || !isAbbreviation(chars, dotAt: i) {
                        if i + 1 >= 2 || emittedCount > 0 { return index(j) }
                    }
                }
            } else if (c == ":" || c == ";"), i + 1 < chars.count, chars[i + 1].isWhitespace, i >= config.clauseSplit {
                return index(i + 1)
            } else if c == ",", i + 1 < chars.count, chars[i + 1].isWhitespace {
                lastComma = i + 1
            } else if c.isWhitespace {
                lastSpace = i
            }

            // First-chunk fast path: get audio going before the first sentence ends.
            if emittedCount == 0, i + 1 >= config.firstChunkCommaSplit, let comma = lastComma, comma >= config.minSoftChunk {
                return index(comma)
            }
            if i + 1 >= config.maxChunk {
                if let comma = lastComma, comma >= config.minSoftChunk { return index(comma) }
                if let space = lastSpace, space > 0 { return index(space) }
                return index(i + 1)
            }
            i += 1
        }
        return nil
    }

    private func index(_ offset: Int) -> String.Index {
        buffer.index(buffer.startIndex, offsetBy: offset)
    }

    private func isAbbreviation(_ chars: [Character], dotAt i: Int) -> Bool {
        var start = i
        while start > 0, !chars[start - 1].isWhitespace, chars[start - 1] != "(" { start -= 1 }
        let word = String(chars[start..<i]).lowercased()
        if word.isEmpty { return false }
        if SentenceChunker.abbreviations.contains(word) { return true }
        // Single initials like "J." (but not "I.")
        if word.count == 1, let ch = word.first, ch.isLetter, ch != "i" { return true }
        return false
    }

    static func isSpeakable(_ s: String) -> Bool {
        s.contains { $0.isLetter || $0.isNumber }
    }
}
