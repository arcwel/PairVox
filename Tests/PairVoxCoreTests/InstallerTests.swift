// SPDX-License-Identifier: Apache-2.0

import Foundation
import XCTest
@testable import PairVoxCore

/// The one-click installer: what it may see (audit run 9: an allow-list, not the child's deny-list).
final class InstallerEnvironmentTests: XCTestCase {
    static let shell: [String: String] = [
        "PATH": "/opt/homebrew/bin:/usr/bin:/bin", "HOME": "/Users/dev", "TMPDIR": "/var/folders/x/", "USER": "dev",
        "LANG": "en_US.UTF-8", "LC_CTYPE": "UTF-8", "SSH_AUTH_SOCK": "/private/tmp/agent.sock", "DEVELOPER_DIR": "/Applications/Xcode.app",
        "SIGN_IDENTITY": "-", "https_proxy": "http://proxy:3128", "HTTPS_PROXY": "http://proxy:3128",
        "GITHUB_TOKEN": "ghp_x", "AWS_SECRET_ACCESS_KEY": "x", "OPENAI_API_KEY": "x", "ANTHROPIC_API_KEY": "x",
        "NODE_OPTIONS": "--require /tmp/x.js", "DYLD_INSERT_LIBRARIES": "/tmp/x.dylib", "GIT_SSH_COMMAND": "ssh -i ~/.ssh/other",
        "path": "/tmp/evil",
    ]

    func testOnlyWhatABuildNeedsGetsThrough() {
        let kept = InstallerEnvironment.filter(Self.shell)
        XCTAssertEqual(Set(kept.keys), ["PATH", "HOME", "TMPDIR", "USER", "LANG", "LC_CTYPE", "SSH_AUTH_SOCK", "DEVELOPER_DIR",
                                        "SIGN_IDENTITY", "https_proxy", "HTTPS_PROXY"])
        XCTAssertEqual(kept["PATH"], Self.shell["PATH"], "passed unchanged")
    }

    func testTokensTheChildFilterDoesNotKnowStayOut() {
        let child = ChildEnvironment.filter(Self.shell)
        for name in ["GITHUB_TOKEN", "AWS_SECRET_ACCESS_KEY", "OPENAI_API_KEY", "DYLD_INSERT_LIBRARIES"] {
            XCTAssertNotNil(child[name], "\(name): the deny-list passes it, which is why the installer has its own list")
            XCTAssertFalse(InstallerEnvironment.isAllowed(name), name)
        }
        XCTAssertFalse(InstallerEnvironment.isAllowed("path"), "names are matched exactly")
    }
}

/// `scripts/pv-install.sh --rollback` holds the previous copy to the rule a new build meets (audit run 9).
final class InstallerRollbackTests: XCTestCase {
    var tree: URL!

    override func setUpWithError() throws {
        #if !os(macOS)
        throw XCTSkip("codesign is macOS only")
        #else
        tree = FileManager.default.temporaryDirectory.appendingPathComponent("pv-rollback-\(UUID().uuidString)")
        let scripts = tree.appendingPathComponent("scripts"), dist = tree.appendingPathComponent("dist")
        for d in [scripts, dist] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        try FileManager.default.copyItem(at: repo.appendingPathComponent("scripts/pv-install.sh"), to: scripts.appendingPathComponent("pv-install.sh"))
        // The script sources the shared helpers.
        try FileManager.default.createDirectory(at: scripts.appendingPathComponent("lib"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: repo.appendingPathComponent("scripts/lib/common.sh"), to: scripts.appendingPathComponent("lib/common.sh"))
        #endif
    }

    override func tearDownWithError() throws {
        if let tree { try? FileManager.default.removeItem(at: tree) }
    }

    @discardableResult
    func run(_ exe: String, _ args: [String]) throws -> (status: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.currentDirectoryURL = tree
        p.environment = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// A tiny app bundle, ad-hoc signed (no team).
    func makeApp(_ name: String, broken: Bool = false) throws {
        let app = tree.appendingPathComponent("dist/\(name)")
        let macos = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: macos.appendingPathComponent("PairVox"))
        let plist = #"<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleExecutable</key><string>PairVox</string><key>CFBundleIdentifier</key><string>dev.pairvox.test</string></dict></plist>"#
        try plist.write(to: app.appendingPathComponent("Contents/Info.plist"), atomically: true, encoding: .utf8)
        let signed = try run("/usr/bin/codesign", ["-s", "-", "--force", app.path])
        XCTAssertEqual(signed.status, 0, "ad-hoc signing the test bundle")
        if broken {
            let h = try FileHandle(forWritingTo: macos.appendingPathComponent("PairVox"))
            h.seekToEndOfFile(); h.write(Data([0, 1, 2, 3])); try h.close()
        }
    }

    func rollback() throws -> (status: Int32, out: String) {
        try run("/bin/bash", [tree.appendingPathComponent("scripts/pv-install.sh").path, "--rollback", "--dry-run", "--json"])
    }

    func testAWholePreviousCopyWithTheSameTeamIsPutBack() throws {
        try makeApp("PairVox.app")
        try makeApp("PairVox.previous.app")
        let r = try rollback()
        XCTAssertEqual(r.status, 0, r.out)
        XCTAssertTrue(r.out.contains("Would reopen dist/PairVox.previous.app"), r.out)
    }

    func testAPreviousCopyWithABrokenSignatureIsRefused() throws {
        try makeApp("PairVox.app")
        try makeApp("PairVox.previous.app", broken: true)
        let r = try rollback()
        XCTAssertEqual(r.status, 1, r.out)
        XCTAssertTrue(r.out.contains("The previous build's signature is broken"), r.out)
    }

    func testAPreviousCopyWithoutTheInstalledTeamIsRefused() throws {
        // The installed app must carry a team; borrow one already on this Mac, read-only, through a link.
        let apps = (try? FileManager.default.contentsOfDirectory(atPath: "/Applications")) ?? []
        var teamApp: String?
        for name in apps.filter({ $0.hasSuffix(".app") }).sorted().prefix(25) {
            let p = Process(), pipe = Pipe()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            p.arguments = ["-dv", "/Applications/\(name)"]
            p.standardError = pipe; p.standardOutput = Pipe()
            try p.run()
            let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            p.waitUntilExit()
            if let line = text.split(separator: "\n").first(where: { $0.hasPrefix("TeamIdentifier=") }), !line.hasSuffix("not set") {
                teamApp = "/Applications/\(name)"; break
            }
        }
        guard let teamApp else { throw XCTSkip("no team-signed app in /Applications to stand in for the installed one") }
        try FileManager.default.createSymbolicLink(atPath: tree.appendingPathComponent("dist/PairVox.app").path, withDestinationPath: teamApp)
        try makeApp("PairVox.previous.app")
        let r = try rollback()
        XCTAssertEqual(r.status, 1, r.out)
        XCTAssertTrue(r.out.contains("The previous build is signed by team"), r.out)
    }
}
