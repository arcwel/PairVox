// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PairVoxCore

final class SessionCatalogTests: XCTestCase {
    func testListsNewestFirstWithFirstUserMessageAndSkipsOddNames() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("pv-claude-\(UUID().uuidString)")
        let project = FileManager.default.temporaryDirectory.appendingPathComponent("pv-proj-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let dir = home.appendingPathComponent("projects").appendingPathComponent(SessionCatalog.folderName(for: FolderScope.resolved(project.path)))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home); try? FileManager.default.removeItem(at: project) }
        let old = UUID().uuidString, new = UUID().uuidString
        let line = { (text: String) in
            #"{"type":"summary"}"# + "\n" + #"{"type":"user","message":{"role":"user","content":"\#(text)"}}"# + "\n"
        }
        try line("fix the login bug").write(to: dir.appendingPathComponent("\(old).jsonl"), atomically: true, encoding: .utf8)
        try line("add dark mode").write(to: dir.appendingPathComponent("\(new).jsonl"), atomically: true, encoding: .utf8)
        try line("sneaky").write(to: dir.appendingPathComponent("--dangerous-skip.jsonl"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: dir.appendingPathComponent("\(old).jsonl").path)
        let found = SessionCatalog.recent(for: project.path, claudeHome: home)
        XCTAssertEqual(found.map(\.id), [new, old])
        XCTAssertEqual(found.first?.preview, "add dark mode")
        XCTAssertFalse(SessionCatalog.isValidSessionID("--dangerous-skip"))
    }
}
