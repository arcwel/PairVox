# Security audit run 9: pre-release pass for 0.1.0-beta.2 (2026-10-25)

This pass covers the code changed after audit run 8 reviewed `de91222`, up to `a3e5940`. That range includes:

- run 8's own fixes (commit `34b17fa`), which no reviewer had read
- folder access made click-only (`8e9222c`)
- microphone sleep and the release tooling (`b013182`)

## 1. Results

| Check | Result |
|---|---|
| `security-audit`, run 9 (quick, scoped to `de91222..a3e5940`, Sonnet reviewers, source only) | 6 leads from 5 hunters, each kept as needs-validation by an independent verifier. None was rejected, and none could be confirmed, because no target code ran. All 6 are fixed on `main` with regression tests. |
| Published v0.1.0-beta.1 DMG, signature read (no code ran) | The app carries `com.apple.security.get-task-allow` and has no hardened runtime (`flags=0x2(adhoc)`). This settles the open question in the release-script lead: the beta.1 download can be debugged by any process of the same user. |
| `strix-qa` on Gemini, `a3e5940` | No finding at any severity, run `pairvox-main-a3e5940_297a`, $2.65, complete. It recorded only 5 surfaces and lists 11 gaps (§5). |
| Gitleaks v8.21.2, all history | No leaks in 90 commits. |
| Tests | 536 pass (5 skipped, 0 failures) with every run 9 fix in. |

## 2. Scope and method

Five units, one hunter each, all reading a frozen copy of `a3e5940`:

| Unit | Outcome |
|---|---|
| Approval gate: run 8's echo and prompt fixes, folder-access offer, cross-project interceptor | 2 leads |
| Shell policy: nested-shell rating, the `ps e` rule, the vocabulary filter | 2 leads |
| iPhone lock-screen answers | 1 lead |
| Microphone sleep | Covered, no lead (hardening notes taken, §4) |
| Release and install scripts | 1 lead |

Then 6 verifiers (one per lead) and one final coverage critic: 12 agents, within the budget of 12. Run 8's five records were current work here because their source had changed. The units above re-read their fixes, and no fix was found broken.

## 3. Leads (needs validation, no severity)

| Lead | Fingerprint |
|---|---|
| The start of a spoken answer was one shared slot. A second utterance, or a blip shorter than 0.3 s, could leave a transcript with no start. An answer with no start was treated as typed text, so it skipped the prompt-timing and echo checks. | `ConversationEngine.swift:speechStartedAt-single-slot-loses-timing-for-spoken-approvals` |
| A second "allow all" was not tied to the readout, and approved every armed request, even one that had gone stale since the readout. | `ConversationEngine.swift:approveAllWaiting-second-confirmation-unbound-to-readout-and-age` |
| `env` after a wrapper (`nice env`, `timeout 5 env`) was rated medium, so a folder shell grant allowed it without asking. | `PermissionPolicy.swift/environment-print-hidden-behind-wrapper-program` |
| The `ps e` rule checked only the first argument in command position. `ps -ax -E` and `nice ps eww` were rated medium and could be covered by a folder shell grant. | `PermissionPolicy.swift/ps-environment-rule-first-arg-and-command-position-only` |
| Lock-screen Allow counted characters, not lines. A short command spread over several lines could hide its end on the lock screen. | `ios-lockscreen-allow-body-length-not-display-bound` |
| The ad-hoc DMG came from the dry-run path, which only reported `get-task-allow` and had no hardened-runtime check. | `release-assets/unsigned-dmg-skips-release-entitlement-and-hardened-runtime-gate` |

Two of these reach run 8's fixes: the `ps` rule (an incomplete fix) and the shared start slot (run 7 and 8's timing checks depended on it). The DMG lead is the only one with an observed result, read from the published file.

## 4. Fixes (each with a regression test)

| Lead | Fix | Test |
|---|---|---|
| Speech start slot | The voice layer records each utterance's start and passes it with that utterance's transcript or failure. The engine keeps the starts of utterances still on their way. A caller that passes none gets the oldest start, which can only make the check stricter. A blip drops the newest. Typed text is marked as typed (`submit(_:typed:)`) instead of being inferred from a missing start. | `AuditRun9EngineTests` (two utterances, a blip, each transcript timed by its own start) |
| Allow all | Arming clears the answer window, so only the readout opens it, and the second "allow all" must begin after the readout started. Only armed requests that are still fresh are allowed. | `testTheSecondAllowAllMustFollowTheReadout`, `testARequestThatWentStaleSinceTheReadoutIsNotAllowed` |
| Wrapped `env` | `BashRisk.segments` remembers the wrappers it skipped, and an empty program after `env` is high. | `AuditRun9PolicyTests` |
| `ps` flags | A structural rule rates `ps` high when any word has the e or E flag, however `ps` is reached. | `AuditRun9PolicyTests` (32 assertions failed before the fix) |
| Lock-screen lines | Allow needs one plain line: no line break, control or direction-override character. The Mac applies the same rule to a lock-screen answer. | `testALockScreenAllowNeedsOnePlainLine` |
| DMG signature | `build-app.sh` re-signs an ad-hoc app with the hardened runtime and explicit entitlements, which drops `get-task-allow`. The only addition is `com.apple.security.cs.disable-library-validation`, which the frameworks need without a Team ID. The dry run in `release.sh` now fails on `get-task-allow` or a missing hardened runtime, and `release-assets.sh` relies on it. The test build passed the dry run and ran normally when opened. | `scripts/release.sh --dry-run` checks; manual launch on 2026-10-25 |

Hardening from the hunters, done in the same pass:

- **Mute and push-to-talk.** Muting clears the 0.35 s pre-roll and stops it filling while muted, so push-to-talk after a mute no longer sends audio heard while muted. Muting also cancels an early transcription and resets the voice detector.
- **Microphone sleep.** Holding the push-to-talk key on a sleeping microphone records only while it is held, and no longer switches the microphone back to always-listening.
- **`release-assets.sh`.** It refuses a tree with uncommitted changes (`--allow-dirty` for testing), takes `--strix-run`, and its header now says that `--signed` builds into `dist/`.

## 5. Coverage and what remains

| State | Units |
|---|---|
| Covered | 1 |
| Candidate (leads produced) | 4 |
| Deferred by the final critic | 2 |

The deferred units are:

- **The phone's spoken answers.** The Mac does no timing or echo check of its own on a `.spokenAnswer`. Run 8's critic deferred this too.
- **Prompt-queue cleanup.** A cancelled, ended or replaced request's unplayed prompt is dropped only when a request is answered. The new tests do not cover the other paths.

Strix lists as unexamined: argument injection, authentication, business logic, path traversal, RCE and semantic confusion, plus six agents that recorded nothing. This audit covered business logic and injection by hand for the changed code. As before, there was no live attack on the phone link (backlog 3.10).

Still open from earlier runs:

- backlog 3.3 (the phone's Face ID claim is self-declared, and a tap has no age limit)
- the units run 7 deferred

Not taken this run (hunters' notes):

- a monotonic clock for microphone sleep
- an upper limit on how long a hung "working" phase keeps the microphone awake
- dropping echo-matched utterances instead of sending them to Claude
- an allow-list rather than a deny-list for the installer's environment
- a team check on `pv-install.sh --rollback`

## 6. The published 0.1.0-beta.1

The beta.1 DMG on GitHub has the debugger-attach entitlement and no hardened runtime. Anyone who installed it should replace it with 0.1.0-beta.2. Its release notes now say so.
