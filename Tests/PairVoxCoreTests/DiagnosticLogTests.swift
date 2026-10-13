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
