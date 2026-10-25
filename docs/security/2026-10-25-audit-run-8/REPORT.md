# Pre-release security pass: audit run 8, Strix and a history scan (2026-10-25)

The repository is public. This pass covered the code merged after the v0.1 gates ran (builds A and B, `ac00462..de91222`). It also re-ran the pentest on current `main` and scanned all git history for secrets.

## 1. Results

| Check | Result |
|---|---|
| `security-audit`, run 8 (quick, scoped to `ac00462..de91222`, Sonnet reviewers, source only) | 5 leads, all fixed with regression tests. Nothing confirmed, since no target code ran. No lead let a high-risk request be approved by voice. |
| `strix-qa` on Gemini, current `main` (`de91222`) | No finding at any severity, across 18 coverage areas. Run `pairvox-main-de91222_391c`, $2.08. |
| Gitleaks v8.21.2, all history (86 commits) | No secrets. The 159 default-rule hits are all `msg_…` message IDs in the recorded CLI session fixture. `.gitleaks.toml` now allows only that shape, and with it the scan reports no leaks. |
| Tests | 512 pass (5 skipped, 0 failures) with every run 8 fix in, and the iPhone app builds. |

## 2. Audit run 8

- **Scope.** Five units, each covering code changed in builds A and B:
  - the iPhone lock-screen approvals
  - the one-click installer
  - the health indicator and its fixes
  - the approval-gate changes
  - the input-handling changes
- **Method.** The units were read from a frozen worktree of `de91222`. Five hunters, five verifiers and one final critic took 11 of the 14 agents budgeted.
- **Results.** The installer and health units were clean. The other three produced the five leads below. The critic named two more areas reached by the echo fixes (§5).

## 3. Leads (needs validation, no severity)

| Lead | Fingerprint |
|---|---|
| The lock-screen notification offered Allow for a request it cut to 160 characters, or one the Mac kept to the screen. The answer claimed a passcode check the phone never made. | `ios/lockscreen-allow-offered-on-partially-shown-or-screen-only-request` |
| The echo notice "If that was you, say yes." ended in an approval word, and the echo check covered only prompts. | `ConversationEngine/own-echo-recovery-notice-ends-with-yes` |
| Any prompt starting to play opened the answer window for the pending request, including an earlier request's leftover prompt. | `ConversationEngine/prompt-heard-set-by-stale-prompt` |
| The environment rule missed a nested shell (`sh -c 'env'`) and `ps` with the e flag. | `BashRisk/environment-disclosure-misses-nested-shell-and-ps` |
| The vocabulary filter's `$` let a name with a trailing newline through. | `RepoVocabulary.admissible.termPattern-trailing-line-terminator` |

Two of these, the echo notice and the stale prompt, were mistakes in the run 7 fixes themselves. Run 7's report said "no prompt contains yes, so a yes always counts". That was true of prompts, but the notice it added said "yes".

## 4. Fixes (each with a regression test)

| Lead | Fix | Test |
|---|---|---|
| Lock-screen Allow | Allow is offered only for a request shown whole (160 characters or less), not high risk, not cut by the link, not needing the screen and not kept to the screen by the Mac. The answer is marked `DeviceAuth.notification`, and the Mac holds it to the same rule plus the five-minute age limit. Forget removes delivered banners. | `RequestNoticeTests`, `testTheMacHoldsALockScreenAnswerToTheLockScreenRule` |
| Echo notice | The notice now reads "That sounded like my own voice. If it was you, answer again." It contains no answer word. The echo check now covers notices as well as prompts, and every kind of spoken approval. | `testTheEchoNoticeCannotItselfApprove` |
| Stale prompt | Only a prompt spoken for the request now waiting can open its answer window. A decided request's unplayed prompt is removed from the queue. | `testAStalePromptDoesNotCountAsTheNextRequestsQuestion` |
| Nested shell and ps | The text a shell is given with `-c` (alone or in a group such as `-lc`) is rated as a command of its own. `ps` with the e or E flag is high risk. | `AuditRun8PolicyTests` |
| Vocabulary newline | The pattern is anchored with `\A…\z`. | `AuditRun8VocabularyTests` |

The critic's two areas, also fixed in this pass:

- **Announcements.** The echo check runs before the cross-project interceptor, so "approve" from an announcement, heard back, never answers another project's request. Test: `testAnAnnouncementHeardBackIsNotAnAnswerToIt`.
- **Phone echo.** The phone's check now covers everything the phone plays, including the Mac's mirrored "…Allow?", not only the prompts it says itself.

Hardening from the hunters, done in the same pass:

- The installer gets the filtered environment the `claude` child gets, not the full login shell. It refuses to replace a team-signed app with a build that has no team.
- `restart-app.sh` looks only at the current user's processes.
- The health rows cap Claude's error text at 160 characters.

## 5. Coverage and what remains

| State | Units |
|---|---|
| Covered | 2 |
| Candidate (leads produced) | 3 |
| Deferred by the final critic | 2 |

The two deferred units are the phone's spoken answers and the cross-project announcement answers. Both were fixed as described above, but neither was reviewed by a hunter. The Mac still has no timing check of its own for a spoken answer sent by the phone.

Open from earlier runs:

- the units run 7 deferred (its REPORT.md §5)
- backlog 3.3: the phone's Face ID claim is self-declared, so a modified phone can still approve what an unmodified one could by tap

The installer builds and installs whatever the configured upstream branch holds. That is its purpose, but the confirmation dialog does not list the incoming commits.

## 6. Personal details in the public repository

These are not secrets, and the owner can decide what to do about them:

- Five early commits are authored as `aguidry@arcwel.ai`. That email stays in public history unless history is rewritten.
- About ten files under `docs/security/` contain the owner's home folder path, in audit metadata and Strix logs.
