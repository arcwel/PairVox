# PairVox: outstanding tasks (2026-10-18)

This is the open work as of 2026-10-18, after PRs #1 to #5 were merged. The repository has one branch, `main` (98a3726), with no open PRs, other branches or worktrees. The installed app, `dist/PairVox.app`, is built from that commit. The previous build is kept as `dist/PairVox.previous.app`.

The rule from 2026-10-17 still holds: v0.1 is done when the five checks in [2026-10-17-v0.1-checks.md](2026-10-17-v0.1-checks.md) pass on the installed app. Code changes only when a check fails, and the check is measured again after the change.

## 1. The v0.1 checks

| # | Check | State | What is left |
|---|---|---|---|
| 1 | Launch | **Pass.** Run 50592ec9 on build 98a3726: shortcuts at 1.0 s, audio engine at 1.4 s, against a 5 s limit. | Nothing. |
| 2 | Voice session | **Not measured.** The few turns logged so far had first sound at 4.4 to 6.4 s, over the 3.5 s limit. | Owner: 10 questions with the headset. Then `scripts/v01-check.py`. |
| 3 | Approvals by voice (Mac) | **Not measured.** | Owner: `docs/MIC_TEST.md` parts 4 and 5. A spoken yes creates a file; a spoken yes does not run `git push`; a request from a second project is answered at a pause. |
| 4 | Phone | **Mostly pass.** It connects over Tailscale, switches projects, approves with a tap and Face ID, and speaks with the Mac's Kokoro voice. | Owner: say "Allow" on the phone for one real request. This has not been tested yet. |
| 5 | Security gates | **Blocked.** Docker is not installed, so `strix-qa` cannot run. | Owner: install Docker Desktop. Then run `security-audit` (full mode) and `strix-qa` on a model that did not write the code, and file the reports under `docs/security/`. |

## 2. Known problems to look at only if a check fails

- **The first reply after a quiet spell is slow.** On 2026-10-18, Kokoro took 5.0 s to synthesize a 12-character first sentence, while later sentences ran at 0.1 to 0.5 times real time. This is the most likely reason check 2 will fail. Measure it over the 10-turn session before changing anything.
- **Early transcription (PR #5) was merged without being measured by voice.** It is on by default (Settings → `earlyTranscription`, 0.3 s tentative end). If check 2 shows cut-off words or wrong transcriptions, turn it off and measure again before suspecting anything else.
- **Earbud screech** (backlog 2.10). Two screeches were captured on 2026-10-16 with a build from before the audio fixes, and none since. Check 2 on earbuds will show whether it still happens.
- **The phone link closes when the app leaves the screen** (2026-10-18 log). This is expected on iOS, but it means the phone does not hear replies while locked. It is not a v0.1 check.

## 3. Owner actions (nobody else can do these)

1. A 20-minute session at the Mac with the headset: checks 2, 3 and the spoken "Allow" from check 4. See "What you do at the Mac" in the checks document.
2. Install Docker Desktop for check 5.
3. Tell Claude when you are done. Claude runs `scripts/v01-check.py`, fills in the measured table, and fixes only what failed.

## 4. Docs that are out of date

- `docs/HANDOFF.md` is dated 2026-10-13 and says the app had never been launched. Agents are told to read it first. Mark it historical and point to this file and the checks document (backlog 0.4).
- `docs/plans/2026-10-16-hardening-task-list.md` records its progress in status paragraphs, not per row. Section 5 below lists what those paragraphs leave open.

## 5. Frozen backlog (after v0.1, or sooner only if it causes a failing check)

From [2026-10-16-hardening-task-list.md](2026-10-16-hardening-task-list.md). These are the rows that the document's status notes do not mark done. They have not been re-checked against the code one by one since then.

- **Approval gate:** 1.6 (shell writes to dotfiles rated high), 1.7 (advisor text on the re-prompt path), 1.8 (MCP tool prompts).
- **Audio:** 2.6 (leveling after sanitize), 2.7 (voice processing chosen from the resolved route), 2.10 (screech root cause), 2.11 (latency, which is check 2), 2.12 (output-only starts, "microphone not authorized"), 2.13 (capture- and restart-path tests).
- **Phone link:** 3.3 (risky approvals from the phone need a check on the Mac), 3.7 (pairing limits counted for each phone), 3.9 (nonce fingerprint in the Pair dialog), 3.10 (fuzz the frame parser that runs before the handshake).
- **Session and logging:** 4.7 (owner and mode checks on the auto-located `claude`), 4.8 (`LineBuffer` scan cost, JSON depth cap), 4.9 (stale `.part` downloads, `mktemp` guards).
- **App layer:** 5.5 (permission card layout: fixed, not yet checked on screen), 5.6 (input level still shares the model), 5.7 (window, setup sheet and restore fixes), 5.8 (stderr capture decision), 5.9 (serialize `setActive`), 5.10 (21 capture warnings in `AppModel.swift`).
- **Tooling and docs:** 0.4 (HANDOFF), 6.2 (bundle path and CDHash in `app.launch`), 6.4 (pin the CI container by digest), 6.5 (threat model corrections), 6.6 (CHANGELOG and RELEASE checklist).
- **Release:** 7.1 (MIC_TEST parts 1 to 5 on speakers and headset), 7.2 (security gates, which is check 5), 7.3 (soak test and release dry run). 7.4 (iPhone device test) has been covered by the 2026-10-18 phone tests.

## 6. CLI opportunities

| Command | What it does | Effort |
|---|---|---|
| `pv-install` | Builds the current commit into `dist-new/` and swaps it in, keeping the running build as `PairVox.previous.app`. After the relaunch it runs `scripts/launch-check.sh`. `--json`, `--dry-run`. | Small |
| `pv-consolidate` | Merges every PR whose CI is green at the tested head, deletes merged branches locally and on GitHub, removes leftover worktrees, and reports what remains. `--json`, `--dry-run`. | Medium |
