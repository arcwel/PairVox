// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Output of `MarkdownSpeechParser`.
public enum SpeechPiece: Sendable, Equatable {
    /// Speakable prose with markdown removed. Not yet pronunciation-normalised.
    case text(String)
    /// End of a heading or list item: always a sentence boundary.
    case boundary
    /// Blank line between paragraphs.
    case paragraphBreak
    /// A heading starts a new section (closes the summary in summary mode).
    case sectionBreak
    case codeBlock(language: String?, code: String)
    case table(rows: Int)
}

/// Incremental markdown-to-speech parser. Feed it text deltas as they stream in;
/// it emits prose as early as possible (mid-line) while still recognising code
/// fences, headings, lists, tables, links and inline code.
public struct MarkdownSpeechParser: Sendable {
    private enum LineKind: Equatable { case undecided, prose, heading, listItem, fenceOpen, table, rule }

    private var atLineStart = true
    private var lineStartBuffer = ""
    private var lineKind: LineKind = .undecided
    private var lineHadContent = false

    // Fenced code
    private var inFence = false
    private var fenceMarker = ""
    private var fenceLanguage: String?
    private var fenceBody = ""
    private var fenceLine = ""

    // Tables
    private var tableRows = 0

    // Inline state
    private var inInlineCode = false
    private var inlineCode = ""
    private var inLinkText = false
    private var linkText = ""
    private var awaitingLinkParen = false
    private var inLinkURL = false
    private var linkURLDepth = 0
    private var pendingBang = false
    private var inTag = false
    private var pendingLT = false

    private var out: [SpeechPiece] = []
    private var textOut = ""

    /// Inline code longer than this is summarised instead of read.
    public var maxInlineCodeChars = 40

    public init() {}

    public mutating func feed(_ s: String) -> [SpeechPiece] {
        for ch in s { process(ch) }
        return drain()
    }

    /// Call at the end of a text block / turn.
    public mutating func finish() -> [SpeechPiece] {
        if inFence {
            if !fenceLine.isEmpty { fenceBody += fenceLine }
            emitCode()
        } else if atLineStart, !lineStartBuffer.isEmpty {
            process("\n")
        } else if !atLineStart {
            process("\n")
        }
        flushTable()
        closeInline()
        let pieces = drain()
        reset()
        return pieces
    }

    private mutating func reset() {
        self = MarkdownSpeechParser()
    }

    // MARK: Character processing

    private mutating func process(_ ch: Character) {
        if inFence { processFence(ch); return }
        if atLineStart { processLineStart(ch); return }
        if ch == "\n" { endLine(); return }
        if lineKind == .table || lineKind == .rule || lineKind == .fenceOpen {
            lineStartBuffer.append(ch)
            return
        }
        inline(ch)
    }

    private mutating func processFence(_ ch: Character) {
        if ch == "\n" {
            let trimmed = fenceLine.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(fenceMarker) && trimmed.allSatisfy({ $0 == fenceMarker.first }) {
                emitCode()
                inFence = false
                atLineStart = true
            } else {
                fenceBody += fenceLine + "\n"
            }
            fenceLine = ""
        } else {
            fenceLine.append(ch)
        }
    }

    private mutating func processLineStart(_ ch: Character) {
        if ch == "\n" {
            let line = lineStartBuffer
            lineStartBuffer = ""
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flushTable()
                emit(.paragraphBreak)
                return
            }
            // A whole short line arrived before we could decide: decide now, then end it.
            decide(final: true, line: line)
            if inFence { return }
            if !atLineStart { endLine() }
            return
        }
        lineStartBuffer.append(ch)
        decide(final: false, line: lineStartBuffer)
    }

    /// Classifies the current line from its first characters.
    private mutating func decide(final: Bool, line: String) {
        let trimmed = String(line.drop(while: { $0 == " " || $0 == "\t" }))
        guard let first = trimmed.first else { return }

        func startProse(dropping prefixCount: Int, kind: LineKind) {
            flushIfLeavingTable(kind)
            lineKind = kind
            atLineStart = false
            lineHadContent = false
            lineStartBuffer = ""
            for c in trimmed.dropFirst(prefixCount) { inline(c) }
        }

        switch first {
        case "`", "~":
            let run = trimmed.prefix(while: { $0 == first })
            if run.count >= 3 {
                // Fence: wait for the full opening line to read the language.
                if final {
                    flushTable()
                    closeInline()
                    inFence = true
                    fenceMarker = String(run)
                    let lang = trimmed.dropFirst(run.count).trimmingCharacters(in: .whitespaces)
                    fenceLanguage = lang.isEmpty ? nil : String(lang.split(separator: " ").first ?? "")
                    fenceBody = ""
                    fenceLine = ""
                    atLineStart = true
                    lineStartBuffer = ""
                } else {
                    lineKind = .fenceOpen
                }
                return
            }
            if trimmed.count < 3 && trimmed.allSatisfy({ $0 == first }) && !final { return }
            startProse(dropping: 0, kind: .prose)

        case "#":
            let hashes = trimmed.prefix(while: { $0 == "#" })
            if trimmed.count == hashes.count && !final { return }
            if hashes.count <= 6, trimmed.dropFirst(hashes.count).first == " " {
                closeInline()
                emit(.sectionBreak)
                startProse(dropping: hashes.count + 1, kind: .heading)
            } else {
                startProse(dropping: 0, kind: .prose)
            }

        case "-", "*", "+", "_":
            if trimmed.count == 1 && !final { return }
            let rest = trimmed.dropFirst()
            if first != "_", rest.first == " " {
                // Could still be a rule like "- - -"; treat as list item unless the line is only markers.
                if rest.allSatisfy({ $0 == " " || $0 == first }) && !final { return }
                if rest.allSatisfy({ $0 == " " || $0 == first }) && trimmed.filter({ $0 == first }).count >= 3 {
                    lineKind = .rule; atLineStart = false; lineStartBuffer = ""; return
                }
                startProse(dropping: 2, kind: .listItem)
                return
            }
            if trimmed.allSatisfy({ $0 == first || $0 == " " }) {
                if !final { return }
                if trimmed.filter({ $0 == first }).count >= 3 {
                    lineKind = .rule; atLineStart = false; lineStartBuffer = ""; return
                }
            }
            startProse(dropping: 0, kind: .prose)

        case "0"..."9":
            let digits = trimmed.prefix(while: \.isNumber)
            let after = trimmed.dropFirst(digits.count)
            if after.isEmpty && !final { return }
            if let p = after.first, p == "." || p == ")" {
                if after.count == 1 && !final { return }
                if after.dropFirst().first == " " {
                    startProse(dropping: digits.count + 2, kind: .listItem)
                    return
                }
            }
            startProse(dropping: 0, kind: .prose)

        case "|":
            if !final {
                lineKind = .table
                return
            }
            // Separator rows (|---|---|) don't count as rows.
            let isSeparator = trimmed.allSatisfy { "|-: \t".contains($0) }
            if !isSeparator { tableRows += 1 }
            lineKind = .table
            atLineStart = true
            lineStartBuffer = ""

        case ">":
            startProse(dropping: trimmed.dropFirst().first == " " ? 2 : 1, kind: .prose)

        default:
            startProse(dropping: 0, kind: .prose)
        }
    }

    private mutating func flushIfLeavingTable(_ kind: LineKind) {
        if kind != .table { flushTable() }
    }

    private mutating func flushTable() {
        if tableRows > 0 {
            closeInline()
            emit(.table(rows: tableRows))
            tableRows = 0
        }
    }

    private mutating func endLine() {
        switch lineKind {
        case .table:
            // Lines decided as table mid-stream end here.
            let line = lineStartBuffer
            lineStartBuffer = ""
            let isSeparator = line.allSatisfy { "|-: \t".contains($0) }
            if !isSeparator { tableRows += 1 }
        case .rule, .fenceOpen:
            lineStartBuffer = ""
        case .heading, .listItem:
            closeInline()
            emit(.boundary)
        case .prose, .undecided:
            closeInline()
            // Soft wrap inside a paragraph reads as a space; a trailing colon reads as a pause.
            if textOut.hasSuffix(":") { emit(.boundary) } else { appendText(" ") }
        }
        lineKind = .undecided
        atLineStart = true
    }

    // MARK: Inline markdown

    private mutating func inline(_ ch: Character) {
        if inInlineCode {
            if ch == "`" {
                inInlineCode = false
                let code = inlineCode.trimmingCharacters(in: .whitespaces)
                appendText(code.count > maxInlineCodeChars ? "a code snippet" : code)
                inlineCode = ""
            } else {
                inlineCode.append(ch)
            }
            return
        }
        if inLinkURL {
            if ch == "(" { linkURLDepth += 1 }
            if ch == ")" {
                if linkURLDepth == 0 {
                    inLinkURL = false
                    appendText(linkText)
                    linkText = ""
                } else {
                    linkURLDepth -= 1
                }
            }
            return
        }
        if awaitingLinkParen {
            awaitingLinkParen = false
            if ch == "(" {
                inLinkURL = true
                linkURLDepth = 0
                return
            }
            appendText(linkText)
            linkText = ""
            // fall through and process `ch` normally
        }
        if inLinkText {
            if ch == "]" {
                inLinkText = false
                awaitingLinkParen = true
            } else if ch == "`" || ch == "*" {
                // markup inside link text: drop it
            } else {
                linkText.append(ch)
            }
            return
        }
        if inTag {
            if ch == ">" { inTag = false }
            return
        }
        if pendingLT {
            pendingLT = false
            if ch.isLetter || ch == "/" || ch == "!" {
                inTag = true
                return
            }
            appendText(" less than ")
        }
        if pendingBang {
            pendingBang = false
            if ch == "[" {
                // Image: speak its alt text.
                inLinkText = true
                linkText = ""
                return
            }
            appendText("!")
        }

        switch ch {
        case "`":
            inInlineCode = true
            inlineCode = ""
        case "[":
            inLinkText = true
            linkText = ""
        case "!":
            pendingBang = true
        case "<":
            pendingLT = true
        case "*":
            break // emphasis markers
        case "\\":
            break
        default:
            if isEmoji(ch) { return }
            appendText(String(ch))
        }
    }

    /// Flushes any half-open inline construct as plain text.
    private mutating func closeInline() {
        if inInlineCode {
            let code = inlineCode.trimmingCharacters(in: .whitespaces)
            appendText(code.count > maxInlineCodeChars ? "a code snippet" : code)
            inInlineCode = false
            inlineCode = ""
        }
        if inLinkText || awaitingLinkParen || inLinkURL {
            appendText(linkText)
            linkText = ""
            inLinkText = false
            awaitingLinkParen = false
            inLinkURL = false
        }
        if pendingBang { appendText("!"); pendingBang = false }
        pendingLT = false
        inTag = false
    }

    private func isEmoji(_ ch: Character) -> Bool {
        guard let scalar = ch.unicodeScalars.first else { return false }
        if scalar.isASCII { return false }
        return scalar.properties.isEmojiPresentation || (ch.unicodeScalars.count > 1 && scalar.properties.isEmoji)
    }

    // MARK: Output

    private mutating func appendText(_ s: String) {
        guard !s.isEmpty else { return }
        lineHadContent = true
        textOut += s
    }

    private mutating func emit(_ piece: SpeechPiece) {
        if !textOut.isEmpty {
            out.append(.text(textOut))
            textOut = ""
        }
        out.append(piece)
    }

    private mutating func emitCode() {
        closeInline()
        var body = fenceBody
        if body.hasSuffix("\n") { body.removeLast() }
        emit(.codeBlock(language: fenceLanguage, code: body))
        fenceBody = ""
        fenceLine = ""
        fenceLanguage = nil
    }

    private mutating func drain() -> [SpeechPiece] {
        if !textOut.isEmpty {
            out.append(.text(textOut))
            textOut = ""
        }
        // Merge adjacent text pieces.
        var merged: [SpeechPiece] = []
        for p in out {
            if case .text(let t) = p, case .text(let prev)? = merged.last {
                merged[merged.count - 1] = .text(prev + t)
            } else {
                merged.append(p)
            }
        }
        out.removeAll()
        return merged
    }
}
