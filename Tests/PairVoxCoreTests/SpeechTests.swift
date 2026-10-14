// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PairVoxCore

final class MarkdownSpeechParserTests: XCTestCase {
    func parseAll(_ s: String, chunked: Bool = false) -> [SpeechPiece] {
        var p = MarkdownSpeechParser()
        var out: [SpeechPiece] = []
        if chunked {
            for ch in s { out += p.feed(String(ch)) }
        } else {
            out += p.feed(s)
        }
        out += p.finish()
        return merge(out)
    }

    func merge(_ pieces: [SpeechPiece]) -> [SpeechPiece] {
        var merged: [SpeechPiece] = []
        for p in pieces {
            if case .text(let t) = p, case .text(let prev)? = merged.last {
                merged[merged.count - 1] = .text(prev + t)
            } else {
                merged.append(p)
            }
        }
        return merged
    }

    func text(_ pieces: [SpeechPiece]) -> String {
        pieces.compactMap { if case .text(let t) = $0 { return t }; return nil }.joined(separator: "|")
    }

    func testInlineMarkupIsStripped() {
        let pieces = parseAll("Use **`AuthService`** and see [the docs](https://x.com/a_(b)) now.")
        XCTAssertEqual(text(pieces).trimmingCharacters(in: .whitespaces), "Use AuthService and see the docs now.")
    }

    func testCodeFenceBecomesCodeBlock() {
        let md = "Here you go:\n\n```swift\nlet x = 1\nprint(x)\n```\nDone."
        let pieces = parseAll(md)
        XCTAssertTrue(pieces.contains(.codeBlock(language: "swift", code: "let x = 1\nprint(x)")))
        XCTAssertTrue(text(pieces).contains("Done."))
        XCTAssertFalse(text(pieces).contains("let x"))
    }

    func testStreamingCharByCharMatchesWholeInput() {
        let md = """
        # Plan

        1. Update `login.ts` to use the **new** token.
        2. Add tests:
        - unit
        - integration

        | a | b |
        |---|---|
        | 1 | 2 |

        ```ts
        const a = 1;
        ```
        That's it! ![diagram](x.png) <br> ok
        """
        XCTAssertEqual(parseAll(md, chunked: true), parseAll(md))
    }

    func testHeadingsAndListsEndSentences() {
        let pieces = parseAll("## Summary\n- first item\n- second item\n")
        XCTAssertEqual(pieces, [.sectionBreak, .text("Summary"), .boundary, .text("first item"), .boundary,
                                .text("second item"), .boundary])
    }

    func testOrderedListAndDecimal() {
        let pieces = parseAll("1. Bump to 3.5 seconds\n2) Ship")
        XCTAssertEqual(text(pieces), "Bump to 3.5 seconds|Ship")
    }

    func testTableIsSummarised() {
        let pieces = parseAll("Results:\n\n| a | b |\n|---|---|\n| 1 | 2 |\n| 3 | 4 |\n\nAfter.")
        XCTAssertTrue(pieces.contains(.table(rows: 3)))
        XCTAssertFalse(pieces.contains { if case .text(let t) = $0 { return t.contains("|") }; return false })
    }

    func testHorizontalRuleAndEmojiDropped() {
        let pieces = parseAll("Done ✅\n\n---\n\nNext 🚀 step")
        XCTAssertEqual(text(pieces).replacingOccurrences(of: "  ", with: " "), "Done |Next step ")
    }

    func testUnterminatedFenceStillEmitted() {
        let pieces = parseAll("```py\nprint(1)")
        XCTAssertEqual(pieces.last, .codeBlock(language: "py", code: "print(1)"))
    }

    func testLongInlineCodeSummarised() {
        let pieces = parseAll("Run `docker compose -f docker-compose.prod.yml up --build --remove-orphans` now")
        XCTAssertTrue(text(pieces).contains("a code snippet"))
    }

    func testLessThanIsSpokenButTagsDropped() {
        XCTAssertTrue(text(parseAll("if a < b then <b>bold</b>")).contains("less than"))
        XCTAssertFalse(text(parseAll("if a < b then <b>bold</b>")).contains("<"))
    }
}

final class SentenceChunkerTests: XCTestCase {
    func testSplitsOnSentenceEndsOnlyAfterWhitespace() {
        var c = SentenceChunker()
        XCTAssertEqual(c.append("Version 3."), [])
        XCTAssertEqual(c.append("5 is out. It fixes"), ["Version 3.5 is out."])
        XCTAssertEqual(c.append(" bugs, e.g. the crash. Done"), ["It fixes bugs, e.g. the crash."])
        XCTAssertEqual(c.flush(), ["Done"])
    }

    func testFirstChunkCanSplitAtCommaForLatency() {
        var c = SentenceChunker()
        let first = c.append("I looked through the authentication module carefully, and the problem is that tokens expire early")
        XCTAssertEqual(first, ["I looked through the authentication module carefully,"])
        // Later chunks wait for sentence ends.
        XCTAssertEqual(c.append(", which breaks refresh, so users get logged out"), [])
    }

    func testMaxChunkForcesSplit() {
        var c = SentenceChunker()
        _ = c.append("Short. ")
        let long = String(repeating: "word ", count: 80)
        let chunks = c.append(long)
        XCTAssertFalse(chunks.isEmpty)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 221 })
    }

    func testQuotesAfterPunctuation() {
        var c = SentenceChunker()
        XCTAssertEqual(c.append("He said \"done.\" Then left."), ["He said \"done.\""])
    }

    func testSymbolsOnlyAreDropped() {
        var c = SentenceChunker()
        XCTAssertEqual(c.boundary(), [])
        _ = c.append("— ")
        XCTAssertEqual(c.boundary(), [])
    }
}

final class PronunciationTests: XCTestCase {
    let p = Pronunciation()

    func testFilesAndPaths() {
        XCTAssertEqual(p.speak("Open src/auth/LoginView.swift now"), "Open Login View dot swift now")
        XCTAssertEqual(p.speak("edit utils.ts,"), "edit utils dot T S,")
        XCTAssertEqual(p.speak("check .env"), "check dot env")
        XCTAssertEqual(p.speak("read and/or write"), "read and/or write")
    }

    func testIdentifiers() {
        XCTAssertEqual(Pronunciation.splitIdentifier("useEffect"), "use Effect")
        XCTAssertEqual(Pronunciation.splitIdentifier("HTTPServerError"), "HTTP Server Error")
        XCTAssertEqual(Pronunciation.splitIdentifier("snake_case_name"), "snake case name")
        XCTAssertEqual(Pronunciation.splitIdentifier("GitHub"), "GitHub")
        XCTAssertEqual(Pronunciation.splitIdentifier("iOS"), "iOS")
    }

    func testURLsHashesVersions() {
        XCTAssertEqual(p.speak("See https://github.com/foo/bar."), "See a link to github dot com.")
        XCTAssertEqual(p.speak("commit a1b2c3d4e5"), "commit a hash")
        XCTAssertEqual(p.speak("upgrade to v2.1.0"), "upgrade to version 2 point 1 point 0")
        XCTAssertEqual(p.speak("pi is 3.14"), "pi is 3.14")
        XCTAssertEqual(p.speak("fixes #123"), "fixes number 123")
    }

    func testSymbolsAndAbbreviations() {
        XCTAssertEqual(p.speak("A -> B, e.g. now"), "A to B, for example now")
        XCTAssertEqual(p.speak("the API and CLI"), "the A P I and C L I")
    }

    func testUserDictionaryWins() {
        let custom = Pronunciation(dictionary: ["PairVox": "pair vox", "k8s": "kates"])
        XCTAssertEqual(custom.speak("PairVox on k8s."), "pair vox on kates.")
    }
}

final class CodeReaderTests: XCTestCase {
    func testDescriptions() {
        XCTAssertEqual(CodeReader.describe(language: "swift", code: "a\nb\nc"), "A 3-line Swift snippet.")
        XCTAssertEqual(CodeReader.describe(language: "bash", code: "npm run test"), "A command: npm run test.")
        XCTAssertEqual(CodeReader.describe(language: "diff", code: "-a\n+b"), "A 2-line diff.")
        XCTAssertEqual(CodeReader.describe(language: nil, code: "x"), "A one-line snippet.")
    }

    func testReadingIsSpeakableAndCapped() {
        let code = (1...40).map { "let value\($0) = compute(\($0)) // note" }.joined(separator: "\n")
        let chunks = CodeReader.read(language: "swift", code: code, maxLines: 6, linesPerChunk: 3)
        XCTAssertEqual(chunks.count, 3)
        XCTAssertTrue(chunks[0].contains("equals"))
        XCTAssertFalse(chunks[0].contains("("))
        XCTAssertEqual(chunks.last, "And 34 more lines.")
    }
}

final class ToolNarratorTests: XCTestCase {
    func testDescribesAndThrottles() {
        var n = ToolNarrator(minInterval: 4)
        let t0 = Date()
        XCTAssertEqual(n.narrate(ToolUse(id: "1", name: "Read", input: ["file_path": "/p/src/AuthService.swift"]), now: t0),
                       "Reading Auth Service dot swift.")
        XCTAssertNil(n.narrate(ToolUse(id: "2", name: "Grep", input: [:]), now: t0.addingTimeInterval(1)))
        XCTAssertEqual(n.narrate(ToolUse(id: "3", name: "Bash", input: ["command": "npm test -- --watch"]),
                                 now: t0.addingTimeInterval(5)), "Running npm test.")
        XCTAssertNil(n.narrate(ToolUse(id: "4", name: "Read", input: [:], isSubagent: true), now: t0.addingTimeInterval(20)))
    }
}

final class SpeechPlannerTests: XCTestCase {
    let reply = """
    I fixed the login bug by refreshing the token before it expires.

    Here's the change:

    ```swift
    func refresh() {
        token = try await api.refresh()
    }
    ```

    I also added a test in AuthTests.swift.
    """

    func run(_ mode: SpeechMode) -> (spoken: [Utterance], planner: SpeechPlanner) {
        var p = SpeechPlanner(mode: mode)
        var out: [Utterance] = []
        // Stream in small pieces like the real CLI.
        var i = reply.startIndex
        while i < reply.endIndex {
            let j = reply.index(i, offsetBy: 7, limitedBy: reply.endIndex) ?? reply.endIndex
            out += p.textDelta(String(reply[i..<j]))
            i = j
        }
        out += p.textBlockEnded()
        out += p.finishTurn(TurnResult(outcome: .success))
        return (out, p)
    }

    func testSkipCodeDescribesCode() {
        let (spoken, _) = run(.skipCode)
        let texts = spoken.map(\.text)
        XCTAssertEqual(texts.first, "I fixed the login bug by refreshing the token before it expires.")
        XCTAssertTrue(texts.contains("A 3-line Swift snippet."))
        XCTAssertFalse(texts.joined().contains("api"))
        XCTAssertEqual(texts.last, "I also added a test in Auth Tests dot swift.")
    }

    func testFullReadsCode() {
        let (spoken, _) = run(.full)
        XCTAssertTrue(spoken.contains { $0.kind == .code && $0.text.contains("refresh") && $0.text.contains("equals") })
    }

    func testSummaryHoldsBackDetail() {
        let (spoken, planner) = run(.summary)
        XCTAssertEqual(spoken.filter { $0.kind == .prose }.map(\.text),
                       ["I fixed the login bug by refreshing the token before it expires."])
        XCTAssertEqual(spoken.last?.kind, .prompt)
        XCTAssertFalse(planner.heldBack.isEmpty)
        XCTAssertTrue(planner.heldBack.contains { $0.text == "A 3-line Swift snippet." })
        XCTAssertFalse(planner.codeReadings.isEmpty)
    }

    func testSummaryClosesAtHeadingWithoutBlankLine() {
        var p = SpeechPlanner(mode: .summary)
        var out = p.textDelta("SQLite is the better default for this.\n## Setup\nIt needs no server.\n")
        out += p.textBlockEnded()
        XCTAssertEqual(out.map(\.text), ["SQLite is the better default for this."])
        XCTAssertEqual(p.heldBack.map(\.text), ["Setup", "It needs no server."])
    }

    func testFirstUtteranceArrivesBeforeReplyEnds() {
        var p = SpeechPlanner(mode: .skipCode)
        let early = p.textDelta("Sure. I'll start with the parser")
        XCTAssertEqual(early.map(\.text), ["Sure."])
    }

    func testQuietVerbosityHasNoNarration() {
        var p = SpeechPlanner(mode: .skipCode, verbosity: .quiet)
        XCTAssertEqual(p.toolUse(ToolUse(id: "1", name: "Read", input: [:])), [])
    }

    func testFailureIsSpoken() {
        var p = SpeechPlanner(mode: .skipCode)
        let out = p.finishTurn(TurnResult(outcome: .failed("Overloaded")))
        XCTAssertEqual(out.map(\.text), ["Something went wrong: Overloaded"])
    }
}

final class SpokenReplyLimitTests: XCTestCase {
    private let reply = "One here. Two here. Three here. Four here. Five here. Six here. "

    func testRepliesOverTheLimitAreReadInPartAndTheRestIsHeld() {
        var planner = SpeechPlanner(mode: .skipCode, spokenLimit: 3)
        var spoken = planner.textDelta(reply)
        spoken += planner.textBlockEnded()
        spoken += planner.finishTurn(TurnResult(outcome: .success))
        let sentences = spoken.filter { $0.kind == .prose }.map(\.text)
        XCTAssertEqual(sentences, ["One here.", "Two here.", "Three here."])
        XCTAssertEqual(planner.heldBack.map(\.text), ["Four here.", "Five here.", "Six here."])
        XCTAssertTrue(spoken.contains { $0.kind == .prompt && $0.text.contains("first part") })
    }

    func testNoLimitReadsEverythingAndSaysNothingExtra() {
        var planner = SpeechPlanner(mode: .skipCode)
        var spoken = planner.textDelta(reply)
        spoken += planner.textBlockEnded()
        spoken += planner.finishTurn(TurnResult(outcome: .success))
        XCTAssertEqual(spoken.filter { $0.kind == .prose }.count, 6)
        XCTAssertTrue(planner.heldBack.isEmpty)
        XCTAssertFalse(spoken.contains { $0.kind == .prompt })
    }

    func testCodeAfterTheLimitIsHeldToo() {
        var planner = SpeechPlanner(mode: .skipCode, spokenLimit: 2)
        var spoken = planner.textDelta("Intro one. Intro two.\n\n```swift\nlet x = 1\n```\n\nAfter the code.\n")
        spoken += planner.textBlockEnded()
        spoken += planner.finishTurn(TurnResult(outcome: .success))
        XCTAssertEqual(spoken.filter { $0.kind == .prose || $0.kind == .code }.count, 2)
        XCTAssertTrue(planner.heldBack.contains { $0.kind == .code })
        XCTAssertTrue(planner.heldBack.contains { $0.text.contains("After the code") })
    }

    func testSummaryModeKeepsItsOwnPrompt() {
        var planner = SpeechPlanner(mode: .summary, spokenLimit: 50)
        var spoken = planner.textDelta("The summary sentence.\n\nMore detail follows here.\n")
        spoken += planner.textBlockEnded()
        spoken += planner.finishTurn(TurnResult(outcome: .success))
        XCTAssertTrue(spoken.contains { $0.text.contains("There's more detail") })
        XCTAssertFalse(spoken.contains { $0.text.contains("first part") })
    }
}
