// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PairVoxCore

final class DiagnosticLogTests: XCTestCase {
    private func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pairvox-log-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func lines(_ log: DiagnosticLog) -> [[String: Any]] {
        log.flush()
        return log.files().reversed().flatMap { url -> [[String: Any]] in
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            return text.split(separator: "\n").compactMap {
                (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
            }
        }
    }

    func testWritesOneJSONObjectPerLine() {
        let log = DiagnosticLog()
        log.configure(.init(directory: tempDir()))
        log.log(.info, .audio, "engine.start", ["rate": 24000, "vp": true, "route": "Speakers", "gain": 0.5])
        let out = lines(log)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0]["ev"] as? String, "engine.start")
        XCTAssertEqual(out[0]["cat"] as? String, "audio")
        XCTAssertEqual(out[0]["run"] as? String, log.runID)
        let f = out[0]["f"] as? [String: Any]
        XCTAssertEqual(f?["rate"] as? Int, 24000)
        XCTAssertEqual(f?["vp"] as? Bool, true)
        XCTAssertEqual(f?["route"] as? String, "Speakers")
    }

    func testLevelFilterDropsQuieterLines() {
        let log = DiagnosticLog()
        log.configure(.init(directory: tempDir(), minLevel: .warning))
        log.log(.debug, .app, "noise")
        log.log(.info, .app, "also noise")
        log.log(.error, .app, "kept")
        XCTAssertEqual(lines(log).map { $0["ev"] as? String }, ["kept"])
    }

    func testConversationTextIsOnlyALengthByDefault() {
        let log = DiagnosticLog()
        log.configure(.init(directory: tempDir()))
        log.log(.info, .engine, "user.said", ["text": log.content("open the secret project")])
        let f = lines(log).first?["f"] as? [String: Any]
        XCTAssertEqual(f?["text"] as? String, "<23 chars>")
    }

    func testConversationTextIsLoggedWhenOptedIn() {
        let log = DiagnosticLog()
        log.configure(.init(directory: tempDir(), includeContent: true))
        log.log(.info, .engine, "user.said", ["text": log.content("hello there")])
        let f = lines(log).first?["f"] as? [String: Any]
        XCTAssertEqual(f?["text"] as? String, "hello there")
    }

    /// Task 4.6: a corrupt sentence is identified in the log without quoting reply text, unless the user opted in.
    func testCorruptSentenceIsOnlyALengthAndAHashByDefault() {
        let log = DiagnosticLog()
        log.configure(.init(directory: tempDir()))
        let sentence = "The reconnect loop no longer loses a nudge that arrives while an attempt is in flight."
        log.log(.error, .tts, "synth.corrupt", ["id": 7, "peak": 1e33].merging(log.contentFingerprint(sentence)) { $1 })
        let f = lines(log).first?["f"] as? [String: Any] ?? [:]
        XCTAssertNil(f["text"], "reply text must not be in the log: \(f)")
        XCTAssertEqual(f["chars"] as? Int, sentence.count)
        XCTAssertEqual(f["sha256"] as? String, String(TextDigest.sha256Hex(sentence).prefix(16)))
        XCTAssertEqual((f["sha256"] as? String)?.count, 16)
        XCTAssertEqual(f["id"] as? Int, 7, "the other fields are kept")
        XCTAssertFalse(lines(log).description.contains("reconnect"), "no word of the sentence anywhere on the line")
    }

    func testCorruptSentenceIsTheTextWhenOptedIn() {
        let log = DiagnosticLog()
        log.configure(.init(directory: tempDir(), includeContent: true))
        let sentence = "Okay, the tests pass."
        log.log(.error, .tts, "synth.corrupt", log.contentFingerprint(sentence))
        let f = lines(log).first?["f"] as? [String: Any] ?? [:]
        XCTAssertEqual(f["text"] as? String, sentence)
        XCTAssertNil(f["sha256"])
        XCTAssertNil(f["chars"])
        // Long enough for a whole corrupt sentence to be reproduced, which the 400-character default would cut.
        let long = String(repeating: "word ", count: 200)
        XCTAssertEqual(log.contentFingerprint(long)["text"], .string(long))
    }

    func testSHA256MatchesTheStandardVectors() {
        XCTAssertEqual(TextDigest.sha256Hex(""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(TextDigest.sha256Hex("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        // Two blocks: the 56-byte message whose padding spills into a second block.
        XCTAssertEqual(TextDigest.sha256Hex("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
                       "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
        // Multi-byte characters are hashed as UTF-8.
        XCTAssertEqual(TextDigest.sha256Hex("héllo"), "3c48591d8d098a4538f5e013dfcf406e948eac4d3277b10bf614e295d6068179")
    }

    func testSecretsAndPersonalDetailsAreScrubbedEvenWhenContentIsOn() {
        let log = DiagnosticLog()
        let redactor = LogRedactor(homeDirectory: "/Users/jane", userName: "janedoe")
        log.configure(.init(directory: tempDir(), includeContent: true), redactor: redactor)
        log.log(.info, .app, "x", ["a": "key sk-ant-api03-abcdefghijklmnop in /Users/jane/Projects",
                                   "b": "mail me at jane.doe@example.com", "c": "ANTHROPIC_API_KEY=hunter2hunter2",
                                   "d": "Authorization: Bearer abcdef0123456789abcdef", "e": "janedoe logged in"])
        let f = lines(log).first?["f"] as? [String: Any] ?? [:]
        let joined = f.values.compactMap { $0 as? String }.joined(separator: " | ")
        for secret in ["sk-ant-api03", "/Users/jane", "jane.doe@example.com", "hunter2", "abcdef0123456789abcdef", "janedoe"] {
            XCTAssertFalse(joined.contains(secret), "leaked \(secret): \(joined)")
        }
        XCTAssertTrue(joined.contains("~/Projects"))
        XCTAssertTrue(joined.contains("<email>"))
    }

    func testRotationKeepsABoundedNumberOfFiles() {
        let log = DiagnosticLog()
        log.configure(.init(directory: tempDir(), maxFileBytes: 600, maxFiles: 3))
        for i in 0..<60 { log.log(.info, .app, "event.\(i)", ["pad": .string(String(repeating: "x", count: 40))]) }
        log.flush()
        let files = log.files()
        XCTAssertLessThanOrEqual(files.count, 3)
        XCTAssertGreaterThan(files.count, 1)
        // The newest event is always in the current file; the oldest lines were dropped.
        let all = lines(log).compactMap { $0["ev"] as? String }
        XCTAssertTrue(all.contains("event.59"))
        XCTAssertFalse(all.contains("event.0"))
    }

    func testNoDirectoryIsASilentNoOp() {
        let log = DiagnosticLog()
        log.log(.error, .app, "nowhere")
        log.flush()
        XCTAssertTrue(log.files().isEmpty)
    }

    func testConcurrentWritersProduceOnlyWholeLines() {
        let log = DiagnosticLog()
        log.configure(.init(directory: tempDir()))
        DispatchQueue.concurrentPerform(iterations: 8) { t in
            for i in 0..<50 { log.log(.info, .audio, "t\(t).\(i)") }
        }
        XCTAssertEqual(lines(log).count, 400)
    }
}
