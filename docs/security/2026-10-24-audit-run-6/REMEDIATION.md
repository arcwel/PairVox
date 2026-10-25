# Audit run 6: remediation (2026-10-24)

The audit (REPORT.md in this folder) reviewed commit `fbcd1ed` without running any code. It left eight `needs_validation` leads. In each, the defect is clear from the source, and running a test is the missing step. The fixes below were made afterwards on branch `fix/v0.1-security-gate`. For each lead, the audit's own local plan became a regression test. All of those tests pass, and so does the rest of the suite (485 tests, 5 skipped, 0 failures, `make test` on macOS 27).

The fixes were written by the same model family that wrote the code. The audit itself was done by a different model. The Strix pentest (docs/security/strix/) ran on Gemini against the fixed source.

## Fixed

| Lead | Fix | Regression test |
|---|---|---|
| A question containing an approve word ("Is that okay?", "Should I allow it") approved a waiting request | `VoiceCommand.isQuestion` recognises a question by a trailing "?" or a question opening (is, should, can, what, how…; "do it" and "will do" are still answers). A question is never an approval, an always-allow, a high-risk confirmation or an approve-all, on the Mac or from the phone. The engine sends it to the advisor, or, with no advisor, treats it as feedback as before. | `SpokenAnswerTests.testQuestionsAreNeverApprovals`, `AdvisorEngineTests.testAQuestionWithAnApprovingWordIsAskedNotApproved` |
| A spoken yes counted for a request whose prompt had not played | The engine records when the user started talking (VAD) and when the request's spoken prompt began. A spoken approval, high-risk confirmation or approve-all counts only if speech began after the prompt started. Otherwise it is not counted, and the prompt plays if it is not already queued. Typed text and clicks carry no speech start and are unchanged. | `EngineApprovalTests.testASpokenYesBegunBeforeThePromptPlayedDoesNotCount`, `testTypedAnswersAreNotHeldBackByThePrompt` |
| Wrapped or piped recursive deletes (`xargs rm -rf`, `timeout 60 rm --recursive`, `env -i rm …`, `sh -c '…'`) and quote-split `git push` rated medium | Wrappers (`env`, `nice`, `timeout`, `gtimeout`, `xargs`, `setsid`, …) are skipped together with their options and values before the program is judged. The rm rule matches long and short recursive or forced flags anywhere after `rm`, including as the last word. | `AuditRun6PolicyTests.testWrappedAndPipedDeletesAndPushesAreHighRisk` |
| `printenv` under a shell folder grant could print the API key without a prompt | Printing the environment (`printenv`, bare `env`, `export -p`, bare `set`, `declare -x`, `/proc/*/environ`, any mention of `ANTHROPIC_API_KEY` or `ANTHROPIC_AUTH_TOKEN`) is high risk. A folder grant never covers a high-risk command. | `AuditRun6PolicyTests.testPrintingTheEnvironmentIsHighAndNeverCoveredByAShellGrant` |
| Shell commands reaching `~/.CLAUDE` or a re-cased PairVox folder were not high | Protected-folder matching ignores case, both for resolved paths and for wildcard patterns. On a case-sensitive volume this can only make PairVox ask more often, never less. | `AuditRun6PolicyTests.testProtectedFoldersMatchWhateverTheCase` |
| MCP and other tools were approved by name only | The permission card summary lists the tool's arguments (`key: value`, each cut to 80 characters, 400 in total). MCP tools (`mcp__*`) are approved on screen only, not by voice (backlog 1.8). Other unrecognised tools keep the voice path and show their arguments. | `AuditRun6PolicyTests.testMCPToolsShowTheirArgumentsAndAreApprovedOnScreen` |
| The phone's host allow-list accepted `fd7a:115c:a1e0:x.attacker.example` and leading-zero octets | Addresses are parsed, not matched by shape. Anything with a colon must be a real IPv6 address inside `fd7a:115c:a1e0::/48` (or `::1`). Four numbers must form a dotted IPv4 address with no leading zeros. Every other host must be a well-formed `.ts.net` name. | `PhoneHostRuleTests.testNamesShapedLikeTailnetAddressesAreRefused` |

## Review of the fixes

A Sonnet reviewer read the fix diff before it was committed. It found no way to approve a high-risk request by voice, but it did find gaps in the fixes. Those changes are listed here, each with a test:

- The app and the CLI send typed text through `userStartedSpeaking`, so a typed yes was being held back by the prompt rule as well. Typed text now says it is typed (`userStartedSpeaking(typed: true)`), and the test goes through that path.
- `{}` in `xargs -I {}` was stripped to nothing, which hid the program that followed it from the structural check (`xargs -I {} /usr/bin/sudo id {}`). The `{}` placeholder is now kept. A lone `{` opening a group is still dropped.
- The environment rule matched `python3 -m venv env` and `grep ANTHROPIC_API_KEY Sources`, but missed `/usr/bin/env`, `env -0`, `env 2>&1`, `pr''intenv`, bare `export`, `declare -p` and `compgen -e`. It now matches only in command position, and a structural check catches the respellings.
- Questions that open with a filler word ("well is that okay", "tell me is it okay", "do you think that's okay") still approved. Leading fillers are now skipped, and "do you/we/I…" counts as a question.
- The argument preview gives each key an equal share of the space and ends with "+N more fields", so a long body cannot push `to` off the card.
- The folder-access offer applies the same rule: a yes must start after its question started playing.

The Strix run (docs/security/strix/2026-10-24-v0.1-gate.md) reviewed the code as it was before these review changes.

## Accepted, with the reason

| Lead | Why it stays |
|---|---|
| A request that arrived while its project was in the background has no played prompt, so the first spoken yes after switching to it is not counted and the prompt plays | Fails safe: one extra yes. |
| Pre-auth and pairing limits are counted per source address, which is 127.0.0.1 for every phone behind `tailscale serve` | Availability only, and the owner can recover (wait 10 s, or make a new pairing code). The global caps already let a handful of tailnet peers do the same. Reaching the port needs a tailnet member allowed by the owner's ACLs, or a process on the Mac. Tracked as backlog 3.7, which also covers clearing a burnt offer. |

## Rejected by the verifiers (no change)

- `foldergrant/shell-grant-bare-token-symlink-escape`: a shell grant already runs repository scripts (`make`, `python3 script.py`), so a symlinked `cat` adds no capability. The grant's wording still overstates what it limits. That is hardening, not a fix for this release.
- `phone-link/text-delivered-to-active-project-not-shown-project`: by design the phone follows the Mac's active project. The text cannot approve anything and crosses no boundary.
- `scripts/build-app.sh:release-build-resolves-transitive-spm-deps-outside-committed-Package.resolved`: refuted by the repository's own 2026-10-13 measurement.

## Still open from this audit

- The five units the final critic deferred (REPORT.md §7) were not reviewed. The most important is the echo path: whether PairVox's own spoken prompt can come back through the microphone as an approval when echo cancellation is off.
- Backlog 3.3 (phone tap approvals skip every risk check, and the phone's Face ID claim is self-declared) was accepted in writing in audit run 4 and remains open.
