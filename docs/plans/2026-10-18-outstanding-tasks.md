# PairVox: outstanding tasks (2026-10-18, updated 2026-10-26)

**Update 2026-10-26.** The tests only the owner can run are in [2026-10-26-owner-test-checklist.md](2026-10-26-owner-test-checklist.md). Everything on `main` is installed on the Mac and on Noava17. No other branches or worktrees are left.

**Update 2026-10-25.** Two public pre-releases are out on GitHub: 0.1.0-beta.1 and 0.1.0-beta.2.
- **Shipped in beta.2.** Hands-free microphone sleep, click-only folder access, `scripts/release-assets.sh`, and the fixes from audit runs 8 and 9.
- **beta.1 should be replaced.** Its DMG carried the debug entitlement (docs/security/2026-10-25-audit-run-9/REPORT.md §6).
- **Gates passed.** Strix found nothing on `de91222` or `a3e5940`, and Gitleaks over the full history is clean.
- **Still open from the audits.** The self-declared Face ID claim in backlog 3.3, which would need device attestation (App Attest) to check. Done after beta.2: prompt-queue cleanup on cancel and exit (`PromptQueueCleanupTests`), the Mac's own timing floor for the phone's spoken answers (1.5 s; owner's choice, 2026-10-25: no Mac-side echo check, which would have refused a real "Allow" said right after the prompt), and a 30-minute limit on phone taps (`PhoneSpokenAnswerTests`). The five hunters' notes in run 9 §5 are done too: microphone sleep on the continuous clock with a 20-minute cap on unchanged phases (`MicHibernationTests`), echoes that are not answers dropped (`EngineApprovalTests`), an allow-list for the installer's environment (`InstallerEnvironmentTests`) and a signature and team check on `pv-install.sh --rollback` (`InstallerRollbackTests`).
- **The v0.1 checks.** Checks 2 to 4 still need the headset session on an installed build.
- **The Apple Developer Program.** Without the paid program the DMG stays ad-hoc and the iPhone build unsigned.

**Update 2026-10-24.** Check 5 now passes on branch `fix/v0.1-security-gate`, which is not merged or installed yet. HANDOFF is marked historical. What is left is the headset session (checks 2, 3, and the spoken "Allow" for check 4), done on a build installed from that branch.

**Later on 2026-10-24.** Two more branches sit on top of it.

- `feat/stability-a`:
  - Kokoro warm-up, for the slow first sentence (the likely check 2 failure).
  - Linear parsing of Claude's output (backlog 4.8).
  - Audit run 7 on the units run 6 deferred, with its fixes. These include the echo of "Allow" and dangling symlinks.
  - Lock-screen notifications on the phone.
- `feat/ease-of-use`:
  - The card says why a spoken answer did not count.
  - The health indicator, plus Settings, Health.
  - One-click update (`scripts/pv-install.sh`, and PairVox, Install Latest Build…).

**Evening of 2026-10-24.** All three branches are merged into `main` and pushed. The installed `dist/PairVox.app` is built from that code, installed with `scripts/pv-install.sh` (the app code is that of e81325d; 0805dac only fixed the install script). Launch check run ab0902eb on it passes: shortcuts at 1.2 s, audio engine at 1.7 s. The local branches `fix/v0.1-security-gate`, `feat/stability-a` and `feat/ease-of-use` hold nothing that is not on `main`. The headset session can be done on this build now.

Still open from the audits are the areas run 7's critic deferred (docs/security/2026-10-24-audit-run-7/REPORT.md §5), and backlog 3.3 for a modified phone.

This is the open work as of 2026-10-18, after PRs #1 to #5 were merged. The repository has one branch, `main` (98a3726), with no open PRs, other branches or worktrees. The installed app, `dist/PairVox.app`, is built from that commit. The previous build is kept as `dist/PairVox.previous.app`.

The rule from 2026-10-17 still holds: v0.1 is done when the five checks in [2026-10-17-v0.1-checks.md](2026-10-17-v0.1-checks.md) pass on the installed app. Code changes only when a check fails, and the check is measured again after the change.

## 1. The v0.1 checks

| # | Check | State | What is left |
|---|---|---|---|
| 1 | Launch | **Pass.** Run 50592ec9 on build 98a3726: shortcuts at 1.0 s, audio engine at 1.4 s, against a 5 s limit. | Nothing. |
| 2 | Voice session | **Not measured.** The few turns logged so far had first sound at 4.4 to 6.4 s, over the 3.5 s limit. | Owner: 10 questions with the headset. Then `scripts/v01-check.py`. |
| 3 | Approvals by voice (Mac) | **Not measured.** | Owner: `docs/MIC_TEST.md` parts 4 and 5. A spoken yes creates a file; a spoken yes does not run `git push`; a request from a second project is answered at a pause. |
| 4 | Phone | **Mostly pass.** It connects over Tailscale, switches projects, approves with a tap and Face ID, and speaks with the Mac's Kokoro voice. | Owner: say "Allow" on the phone for one real request. This has not been tested yet. |
| 5 | Security gates | **Pass** (2026-10-24). `security-audit` full mode: 8 leads, 7 fixed with regression tests, 1 accepted. `strix-qa` on Gemini: no findings. Reports in `docs/security/2026-10-24-audit-run-6/` and `docs/security/strix/2026-10-24-v0.1-gate.md`. | Nothing. Merged and installed on 2026-10-24 (see the evening update above). |

## 2. Known problems to look at only if a check fails

- **The first reply after a quiet spell is slow.** On 2026-10-18, Kokoro took 5.0 s to synthesize a 12-character first sentence, while later sentences ran at 0.1 to 0.5 times real time. This is the most likely reason check 2 will fail. Measure it over the 10-turn session before changing anything.
- **Early transcription (PR #5) was merged without being measured by voice.** It is on by default (Settings → `earlyTranscription`, 0.3 s tentative end). If check 2 shows cut-off words or wrong transcriptions, turn it off and measure again before suspecting anything else.
- **Earbud screech** (backlog 2.10). Two screeches were captured on 2026-10-16 with a build from before the audio fixes, and none since. Check 2 on earbuds will show whether it still happens.
- **The phone link closes when the app leaves the screen** (2026-10-18 log). This is expected on iOS, but it means the phone does not hear replies while locked. It is not a v0.1 check.

## 3. Owner actions (nobody else can do these)

1. A 20-minute session at the Mac with the headset: checks 2, 3 and the spoken "Allow" from check 4. See "What you do at the Mac" in the checks document.
2. ~~Install Docker Desktop for check 5.~~ Done: OrbStack runs Docker, and both gates ran on 2026-10-24.
3. Tell Claude when you are done. Claude runs `scripts/v01-check.py`, fills in the measured table, and fixes only what failed.

## 4. Docs that are out of date

- ~~`docs/HANDOFF.md`~~ Done 2026-10-24: marked historical, and CLAUDE.md now sends agents to this file and the checks document (backlog 0.4).
- `docs/plans/2026-10-16-hardening-task-list.md` records its progress in status paragraphs, not per row. Section 5 below lists what those paragraphs leave open.

## 5. Frozen backlog (after v0.1, or sooner only if it causes a failing check)

From [2026-10-16-hardening-task-list.md](2026-10-16-hardening-task-list.md). These are the rows that the document's status notes do not mark done. They have not been re-checked against the code one by one since then.

- **Approval gate:** 1.6 (shell writes to dotfiles rated high), 1.7 (advisor text on the re-prompt path). 1.8 (MCP tool prompts) was done in audit run 6.
- **From audit run 6 (2026-10-24):**
  - Five units were deferred and never reviewed: the echo path from PairVox's own prompt back into the microphone, non-Bash tool ratings, the child-output parser's cost, and hotkeys and the AppleScript launcher, plus a second pass on phone pairing.
  - The hardening notes in its REPORT.md §6 are also open.
- **Audio:** 2.6 (leveling after sanitize), 2.7 (voice processing chosen from the resolved route), 2.10 (screech root cause), 2.11 (latency, which is check 2), 2.12 (output-only starts, "microphone not authorized"), 2.13 (capture- and restart-path tests).
- **Phone link:** 3.3 (risky approvals from the phone need a check on the Mac), 3.7 (pairing limits counted for each phone), 3.9 (nonce fingerprint in the Pair dialog), 3.10 (fuzz the frame parser that runs before the handshake).
- **Session and logging:** 4.7 (owner and mode checks on the auto-located `claude`), 4.8 (`LineBuffer` scan cost, JSON depth cap), 4.9 (stale `.part` downloads, `mktemp` guards).
- **App layer:** 5.5 (permission card layout: fixed, not yet checked on screen), 5.6 (input level still shares the model), 5.7 (window, setup sheet and restore fixes), 5.8 (stderr capture decision), 5.9 (serialize `setActive`), 5.10 (21 capture warnings in `AppModel.swift`).
- **Tooling and docs:** 6.2 (bundle path and CDHash in `app.launch`), 6.4 (pin the CI container by digest), 6.5 (threat model corrections), 6.6 (CHANGELOG and RELEASE checklist).
- **Release:** 7.1 (MIC_TEST parts 1 to 5 on speakers and headset), 7.2 (security gates, which is check 5), 7.3 (soak test and release dry run). 7.4 (iPhone device test) has been covered by the 2026-10-18 phone tests.

## 6. CLI opportunities

| Command | What it does | Effort |
|---|---|---|
| `pv-install` | Builds the current commit into `dist-new/` and swaps it in, keeping the running build as `PairVox.previous.app`. After the relaunch it runs `scripts/launch-check.sh`. `--json`, `--dry-run`. | Small |
| `pv-consolidate` | Merges every PR whose CI is green at the tested head, deletes merged branches locally and on GitHub, removes leftover worktrees, and reports what remains. `--json`, `--dry-run`. | Medium |
