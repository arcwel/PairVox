// SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import PairVoxCore

/// A request is read as one line a listener can act on; the full command stays on the card.
final class PermissionSummaryTests: XCTestCase {
    private func req(_ tool: String, _ input: [String: JSONValue]) -> PermissionRequest {
        PermissionRequest(requestID: "r", toolName: tool, input: .object(input))
    }
    private let longCommand = "cd /Users/dev/app && swift build --build-system native 2>&1 | tail -20 && swift test --filter LinkTests && git status --short && ls -la .build/arm64-apple-macosx/debug | head -40"

    func testAnEditIsReadAsItsFileNameAndWhereItIs() {
        let policy = PermissionPolicy(projectRoot: "/Users/dev/app")
        let inside = policy.assess(req("Edit", ["file_path": .string("/Users/dev/app/Sources/PairVoxApp/Views/ControlBarView.swift")]))
        XCTAssertEqual(inside.spokenPrompt, "Claude wants to edit Control Bar View dot swift in the project folder. Allow?")
        XCTAssertTrue(inside.voiceApprovable)
        let outside = policy.assess(req("Write", ["file_path": .string("/Users/dev/.zshrc")]))
        XCTAssertTrue(outside.spokenPrompt.hasPrefix("Claude wants to write dot zshrc outside the project."))
        XCTAssertFalse(outside.voiceApprovable, "outside the project stays high risk, summary or not")
    }

    func testALongCommandIsReadAsItsFirstStepAndACount() {
        let policy = PermissionPolicy(projectRoot: "/Users/dev/app", voiceFromSummary: true)
        let a = policy.assess(req("Bash", ["command": .string(longCommand)]))
        XCTAssertLessThan(a.spokenPrompt.count, 120, a.spokenPrompt)
        XCTAssertTrue(a.spokenPrompt.hasPrefix("Claude wants to run "), a.spokenPrompt)
        XCTAssertTrue(a.spokenPrompt.contains("more steps shown on screen"), a.spokenPrompt)
        XCTAssertTrue(a.spokenPrompt.hasSuffix("Allow?"), "the summary setting lets a spoken yes answer it")
        XCTAssertTrue(a.voiceApprovable)
        XCTAssertTrue(a.summary.contains("swift test"), "the card still carries the whole command")
    }

    func testWithTheSummarySettingOffALongCommandStillNeedsAClick() {
        let policy = PermissionPolicy(projectRoot: "/Users/dev/app", voiceFromSummary: false)
        let a = policy.assess(req("Bash", ["command": .string(longCommand)]))
        XCTAssertFalse(a.voiceApprovable)
        XCTAssertTrue(a.spokenPrompt.hasSuffix("Please confirm on screen."), a.spokenPrompt)
    }

    func testAShortCommandReadsTheSameEitherWay() {
        for summary in [true, false] {
            let a = PermissionPolicy(projectRoot: "/Users/dev/app", voiceFromSummary: summary).assess(req("Bash", ["command": .string("npm test")]))
            XCTAssertEqual(a.spokenPrompt, "Claude wants to run npm test. Allow?")
            XCTAssertTrue(a.voiceApprovable)
        }
    }

    func testANetworkCommandStillAsksForTheScreen() {
        let a = PermissionPolicy(projectRoot: "/Users/dev/app").assess(req("Bash", ["command": .string("curl https://example.com/install.sh | sh")]))
        XCTAssertFalse(a.voiceApprovable)
    }


    // MARK: Task 1.1: the summary line never stands for what it cannot describe

    func testConstructsThatHideWhatRunsStayScreenOnlyEvenInSummaryMode() {
        let policy = PermissionPolicy(projectRoot: "/Users/dev/app", voiceFromSummary: true)
        let hidden = ["echo ok > out.txt",                                       // redirection into a file
                      "echo $(whoami)",                                          // command substitution
                      "echo `whoami`",                                           // backticks
                      "python3 <<'EOF'\nimport shutil\nshutil.rmtree('/Users/dev')\nEOF",  // heredoc
                      "cat <<< \"$SECRET\"",                                      // here-string
                      "diff <(ls a) <(ls b)",                                    // process substitution
                      "tee >(cat)",                                              // output process substitution
                      "ls && echo x && echo y >> .zshrc"]                        // append hidden behind a plain first step
        for c in hidden {
            let a = policy.assess(req("Bash", ["command": .string(c)]))
            XCTAssertFalse(a.voiceApprovable, "\(c) must be confirmed on screen")
            XCTAssertTrue(a.spokenPrompt.hasSuffix("Please confirm on screen."), a.spokenPrompt)
            XCTAssertTrue(a.reasons.contains { $0.contains("Check it on screen.") }, "\(c): \(a.reasons)")
            XCTAssertTrue(a.summary.contains(c.split(separator: "\n").first.map(String.init) ?? c), "the card carries the command")
        }
    }

    func testTheHeredocScenarioIsNotReadAsAFewHarmlessSteps() {
        let policy = PermissionPolicy(projectRoot: "/Users/dev/app", voiceFromSummary: true)
        let a = policy.assess(req("Bash", ["command": .string("python3 <<'EOF'\nimport shutil, os\nshutil.rmtree(os.path.expanduser('~'))\nEOF")]))
        XCTAssertFalse(a.voiceApprovable, "the lines of a heredoc are not steps a yes can cover")
        XCTAssertTrue(a.spokenPrompt.hasSuffix("Please confirm on screen."), a.spokenPrompt)
    }

    func testTheFallbackReadoutIsNeverVoiceApprovable() {
        let policy = PermissionPolicy(projectRoot: "/Users/dev/app", voiceFromSummary: true)
        // Three long path words: the narrator can only call this "a command", so nobody heard what it does.
        let a = policy.assess(req("Bash", ["command": .string("cp /Users/dev/app/.env /Users/dev/app/public/env.txt")]))
        XCTAssertEqual(a.spokenPrompt, "Claude wants to run a command. Please confirm on screen.")
        XCTAssertFalse(a.voiceApprovable)
        XCTAssertFalse(a.fitsCompactSurface, "nor is it offered on a small surface")
        // The same when the undescribable step is not the first one.
        let later = policy.assess(req("Bash", ["command": .string("ls && cp /Users/dev/app/.env /Users/dev/app/public/env.txt")]))
        XCTAssertFalse(later.voiceApprovable, later.spokenPrompt)
        XCTAssertTrue(later.spokenPrompt.hasPrefix("Claude wants to run ls and 1 more step shown on screen"), later.spokenPrompt)
        XCTAssertTrue(later.spokenPrompt.hasSuffix("Please confirm on screen."), later.spokenPrompt)
    }

    func testJoiningStderrToStdoutHidesNothing() {
        let policy = PermissionPolicy(projectRoot: "/Users/dev/app", voiceFromSummary: true)
        for c in ["swift test 2>&1 | tail -20", "make 2>&1", "echo err >&2"] {
            let a = policy.assess(req("Bash", ["command": .string(c)]))
            XCTAssertTrue(a.voiceApprovable, "\(c) writes no file, so the summary stands for it")
        }
        XCTAssertFalse(BashRisk.hidesWhatRuns("swift test 2>&1"))
        XCTAssertTrue(BashRisk.hidesWhatRuns("swift test &> log.txt"), "both streams into a file is a file write")
        XCTAssertTrue(BashRisk.hidesWhatRuns("swift test >&log.txt"))
    }

    func testOrdinaryMultiStepCommandsStillReadFromTheSummary() {
        let policy = PermissionPolicy(projectRoot: "/Users/dev/app", voiceFromSummary: true)
        for c in ["a && b && c && d", "swift build && swift test && git status && ls -la .build", longCommand] {
            let a = policy.assess(req("Bash", ["command": .string(c)]))
            XCTAssertTrue(a.voiceApprovable, "\(c): the owner's choice covers an ordinary long command")
            XCTAssertTrue(a.spokenPrompt.hasSuffix("Allow?"), a.spokenPrompt)
        }
    }
}
