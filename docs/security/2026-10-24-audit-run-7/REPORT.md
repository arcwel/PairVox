# Security audit run 7: the units run 6 deferred (2026-10-24)

## 1. Run

| | |
|---|---|
| Mode | Full audit, `quick` profile, scoped to the five units run 6 deferred |
| Source | Snapshot of `ac00462` (run 6 fixes included), read from a separate worktree so the fixes below could be written while it ran |
| Reviewers | Claude Sonnet 5.5: 5 hunters, 6 verifiers, 1 final critic (12 of 12 budgeted) |
| Execution | Source only, as in run 6: no target code ran |
| Prior run | Run 6 ledger (`docs/security/2026-10-24-audit-run-6/coverage-ledger.json`). Each unit here was a run 6 `deferred` unit |

**This is a partial pass.** No record could be confirmed without running code. The final critic named five more areas, recorded as deferred (section 5).

## 2. Posture

Two of the five units were clean: the hotkeys and Apple Events entitlement, and the iPhone pairing second pass. The run 6 host allow-list fix holds. The other three units produced six leads. Two matter most:

- A dangling symlink inside the project let a write go outside it under a folder grant without asking.
- The echo of a prompt's last word, "Allow", could come back as a yes with nobody speaking.

## 3. Leads (needs validation, no severity)

| Lead | Fingerprint |
|---|---|
| A dangling symlink inside the project is rated as a new file there, so a write through it is medium and covered by a folder grant | `policy/dangling-symlink-leaf-classified-inside-project-and-grant-covered` |
| The echo of "…Allow?" can come back as a one-word approval: echo handling stopped the instant playback ended | `voice/echo-tail-of-allow-prompt-approves-pending-request` |
| NotebookEdit is judged by `file_path`, but the tool writes `notebook_path` | `policy/notebookedit-file_path-shadows-notebook_path-in-classification` |
| WebFetch is approved on the host Foundation reads, which can differ from the host the fetch contacts (a backslash before `@`) | `policy/webfetch-spoken-host-from-foundation-parser-differs-from-fetch-host` |
| Repository file and folder names reach the recognizer prompt unfiltered, including names like "allow it" | `voice/repo-names-reach-whisper-prompt-unfiltered` |
| The speech markdown parser re-copies an undecided line for every character, which is quadratic on the engine actor | `markdown-speech-parser-line-start-requadratic-reclassify` |

The full trace, blockers and plan for each are in NEEDS-VALIDATION.md.

## 4. Remediation (branch `feat/stability-a`)

Each lead's local plan became a regression test, and every test passes.

| Lead | Fix | Test |
|---|---|---|
| Dangling symlink | `FolderScope.resolved` follows a link whose target does not exist yet, so the path is judged where a write would land. A loop of links is judged outside every folder | `AuditRun7Tests.testADanglingLinkIsJudgedWhereItWouldWrite` |
| Echo of "Allow" | (a) The microphone's echo handling stays on for 0.5 s after playback ends. (b) A spoken approval made of words from the last prompt doesn't count if it began while the prompt played or within 0.6 s after. PairVox says "If that was you, say yes." No prompt contains "yes", so a "yes" always counts | `EngineApprovalTests.testTheTailOfThePromptHeardBackIsNotAnApproval` |
| NotebookEdit | Every path a file-write request names must be inside the project. The tool's own field (`notebook_path` for NotebookEdit) goes on the card | `AuditRun7Tests.testNotebookEditIsJudgedByEveryPathItNames` |
| WebFetch host | A WebFetch address that isn't plain http(s) with a host and no backslash, `@`, user info or spaces is approved on screen only | `AuditRun7Tests.testAWebFetchAddressThatCanHideItsHostIsApprovedOnScreen` |
| Repository names | The recognizer only gets identifier-shaped names (letters, digits, `_`, `-`; 3 to 41 characters). Names that contain an answer word or an approval phrase are dropped. The Whisper prompt now keeps the highest-ranked terms, not the last ones | `AuditRun7Tests.testRepositoryNamesThatAnswerRequestsStayOutOfTheRecognizer` |
| Markdown parser | A line still undecided after 64 characters is classified at its newline, like a short line. The parser's output doesn't change | Existing `SpeechTests`, plus the new line-buffer tests below |

Changes made in the same build for the critic's areas, which were not reviewed by this audit:

- **"Always allow"** applies only Claude Code's `addRules` allow rules, each scoped to the session. A mode change (for an Edit, the CLI suggests `acceptEdits`, which would skip PairVox's risk check for every later edit), an added folder, and rule replacements or removals are dropped. The card offers "Always Allow" only when an allow rule is left. Test: `AuditRun7Tests.testAlwaysAllowNeverChangesTheModeOrAddsFolders`.
- **A high-risk tap from a phone with no passcode** is refused on the phone and on the Mac. The Mac can't verify the phone's claim, so this protects only an unmodified phone (backlog 3.3). Tests: `LinkTests.testApprovalRulesAreEnforcedByTheMac`, `CrossProjectPhoneTests`.
- **Phone own-echo.** The phone has no echo canceller. It now waits 0.6 s instead of 0.3 s after speaking before it listens again. It also ignores a short utterance made of words it just said that arrives within 2.5 s, and shows "Say yes, or tap Allow."
- **The Terminal login script** quotes the `claude` path for the shell. A path with a space used to fail. Test: `TerminalLoginTests`.

### Review of the fixes

A second Sonnet reviewer read the fix diff before it was committed. It found no path to a looser approval. It did find nine places where the fixes were too strict or misfired, and each is now fixed:

- A prompt that is cut off (a barge-in, which its own echo can cause, or a stop) now counts as ending at that moment. Before, it never counted as ended, so an "allow" ten seconds later was dropped as an echo.
- "Confirm high risk" and "allow all" are the phrases those prompts ask for, so they are exempt from the echo check.
- The phone measures its echo window from the end of the prompt itself, not of any speech.
- An `@` makes a WebFetch screen-only only when it is in the address's authority. `/@user/post` and `react@18` are fine.
- A name is kept out of the vocabulary only if it is made entirely of answer words. `NotFound`, `WaitGroup` and `CancelToken` stay.
- "Always allow" with no narrow rule left is a plain allow, reported as one, and the menu item is disabled.
- In half-duplex mode the skip-while-playing check follows playback exactly. Only the detector's echo allowance waits out the room.
- A relative dangling link inside a linked folder is resolved from the real folder.
- The notification's background task ends when iOS asks it to.

The parser change also had a hidden cost: `String.count` is O(n), so checking the 64-character limit with it was quadratic too. It now uses `utf8.count`, which is O(1). A 200,000-character table row went from 13 s to well under the test's 3 s limit.

All 501 tests pass.

## 5. Coverage

| State | Units |
|---|---|
| Covered | 2 |
| Candidate (leads produced) | 3 |
| Deferred by the final critic | 5 |

The deferred areas:

1. The phone's hands-free microphone and spoken answers (a defence was added, but the area was not reviewed).
2. The always-allow suggestion scope (narrowed, not reviewed).
3. The Mac-side check of phone tap approvals.
4. How the engine actor handles very long replies.
5. The Sparkle updater scaffold.

The final critic's result was not clean, so no claim of complete coverage is made.
