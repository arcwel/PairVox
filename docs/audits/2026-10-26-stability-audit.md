# Stability audit and cleanup (2026-10-26)

This covers everything changed since 0.1.0-beta.1: 38 files and about 1,500 added lines in `Sources`, `ios` and `scripts`. Four independent reviewers on Sonnet, a different model from the author's, read the code by area: the conversation engine, the Mac app and voice input, the iPhone app and link, and the build and release scripts. They looked for hangs, crashes, leaks, stuck states and races, not security. Four more reviewers then read the same code for cleanup, each from one angle: code that repeats an existing helper, needless complexity, wasted work, and fixes made at the wrong depth.

Every finding was checked against the source before it was fixed. Each fix that changes behaviour has a regression test, and the main ones were confirmed to fail without the fix.

## Results

| Check | Result |
|---|---|
| Stability findings | 45 reported (iPhone 11, Mac 8, engine 10, scripts 12, plus 4 test gaps). 31 fixed, 14 left (below). |
| Full test suite | 594 tests, 5 skipped, 0 failures (Core 410, Link 116, Voice 68). One full run took 216 s; a pipe-timing test went 0.03 s over its 4 s bound while an iPhone build ran beside it, and passes in about 1 s on its own. |
| Soak (`scripts/soak.sh 120`) | Engine: 18,360 cycles (5,584 turns, 2,368 spoken approvals, 1,842 barge-ins, 232 restarts), memory flat after warm-up. Link storm: 3,000 snapshots to two phones. Link churn: 2,953 connect cycles, memory growth 5.5 MB. |
| Compiler warnings in changed files | All removed, on the Mac targets and the iPhone app. |

## What could hang, crash or get stuck, and is fixed

**iPhone**
- **Listening got stuck after a call, Siri, an alarm or a route change.** iOS stopped the engine under a running listen, so `stop()` returned early, the request never got its end of audio, and `listening` stayed on. Hands-free never restarted until the mic was tapped. Now:
  - `stop()` always ends the request.
  - The recognizer watches for interruptions and route changes, throws the listen away and tells the model, which resumes hands-free a second later.
  - The speaker also stops on an interruption, so "speaking" can no longer stick on and block listening.
- **A late callback from an earlier listen could end the next one.** Each listen now has a generation number, and stale callbacks are ignored. A failed engine start now tears down its tap and request.
- **The microphone-format check compared the format with itself.** It now reads the input format again after `prepare()`, so a route that changes in between is caught before the tap goes live.
- **One failed start muted the mic for good.** A start that fails right after a call or headset change is now retried once after 1.5 s. Session errors are logged instead of swallowed.
- **Smaller iPhone fixes:**
  - The failure counter resets on every cancel and ignores push-to-talk taps.
  - Share Logs no longer lists the log folder on every redraw.
  - The level meter is throttled to 15 Hz.
  - Old crash reports are written off the main thread, and only once each. Crash and hang reports are kept apart, five each.

**Conversation engine**
- **Rating a huge command could freeze the engine.**
  - The approval-gate lookup copied the rest of the command for every word, which is quadratic. Now each comparison sees only as many words as the longest rule.
  - The `ps e` check was a regular expression that backtracked quadratically on a long model-chosen word. It is now a plain character scan, and the duplicate pattern rule is gone.
  - Regression test: a 50,000-character word and a 20,000-word command are rated in well under a second.
- **An answer for another project left this one silent.** The reply stayed paused or held back until the next utterance. It now resumes.
- **A queued request outlived its turn.** It came back later as a fresh question for a request Claude Code no longer waits on. Ending a turn, a restart and a process exit now share one cleanup that clears the shown request, the queue, an armed "allow all" and the advice calls.
- **Advice calls kept running after their request was cancelled or the engine shut down.** They are now cancelled.
- **A second "allow all" did nothing when everything read out had gone stale.** It now says so. The readout no longer calls requests "high-risk" when the owner's gate setting is what holds them back.

**Mac app**
- **Microphone sleep:**
  - **Asleep straight after being turned back on.** The idle clock now restarts while the mic isn't listening hands-free (microphone off, unplugged, push-to-talk, no project, or sleep set to never).
  - **Asleep while a request card was being read**, so the spoken yes was lost. A waiting request now keeps the mic awake for as long as a spoken answer can count (five minutes).
  - **Asleep mid-utterance.** It no longer sleeps while an utterance is being captured.
- **Muting during push-to-talk left the key "held".** The release then cancelled another utterance's start time. That's fixed.
- **Switching project mid-sentence left the old project "hearing you".** That kept its microphone from ever sleeping. The old project is now told the utterance ended.
- **Smaller Mac fixes:**
  - The update log's file handle is closed.
  - Removing a command rule while its field is being edited no longer risks a stale row.
  - The toolbar keeps its normal look when the mic is awake.

**Scripts**
- **`pv-install` reported "not changed" after the new build had already been swapped in.** That happened when the new app did not open, and the old app was left closed. It now puts the old app back.
- **`build-app.sh` ignored a failed signature check.** It used `verify && echo`, which `set -e` doesn't stop on. It also deleted the old app before it knew the new one existed. Both are fixed.
- **`restart-app.sh` swap gap.** It deleted the old app before moving the new one in. It now moves the old one aside first, so `dist/` is never without an app. `build-app.sh` does the same.
- **`release.sh` real releases.** They now check for the hardened runtime before uploading to the notary service.
- **`pull-phone-logs.sh`:**
  - It looped for ever when `--device` or `--out` was the last argument.
  - Its `devicectl` calls had no time limit, and they could read the loop's input.
  - A failure's reason was thrown away.
- **`release-assets.sh`:**
  - It refuses to build when the version's tag points at another commit.
  - It refuses to build when a required report file is missing.
  - It builds into a work folder, so a failed run leaves the output folder empty.

## Cleanup

- **One copy instead of two:**
  - The Auto gate's read-back sentence and 60 s window, shared by the Mac and the phone. The wording is what keeps the phone from hearing back an answer word, so it must not drift.
  - The gate pickers in Settings.
  - The interruption parsing on the phone.
  - `json_escape` and the hardened-runtime check, now in `scripts/lib/common.sh`.
  - The "drop everything waiting" block in the engine.
- **Work done once instead of every time:**
  - The 37 shell-rating patterns are compiled once, not on every request.
  - A command is split into steps once per rating.
  - The phone log's patterns are compiled once.
- **The phone log scrubs what the Mac log scrubs:** GitHub tokens, AWS keys, Bearer tokens, `password=` and e-mail addresses.
- **Small tidy-ups:**
  - a duplicate "disarm allow all" line;
  - a redundant condition in the format check;
  - stranded doc comments;
  - a comment in `pull-phone-logs.sh` that no longer matched the code.

## Not done, and why

These are larger changes to the approval gate, or need on-device measurement. A gate change deserves its own reviewed change, not a cleanup pass.

- **Fold the answer checks into one function.** The "spoken answer begun before its question", "too old" and "my own voice" checks are written out per answer kind. A single `spokenAnswerAdmissible` function and one table of when each prompt started and ended would replace them. This is the biggest remaining simplification. It touches every spoken-approval path, so it needs its own change and its own security review.
- **Clear the waiting question when the request is cleared.** Ending a waiting question is still a call at each place that clears a request (about a dozen). A `didSet` on the pending request would make it automatic.
- **Phone text while a request waits.** It is still dropped. Giving phone text a start time, so the echo check covers it instead, needs a protocol change on both apps.
- **No watchdog for the "hearing you" and "transcribing" states.** They could stick if the voice layer's tasks arrived out of order. The reviewer rated this low and unlikely; it can be revisited if logs show it.
- **A prompt that fails to play still blocks spoken answers.** Spoken answers then need a click; nothing tells the user why.
- **Repeated "confirm" can stack Touch ID prompts.** Stacked prompts cannot approve twice.
- **Settings and shell rating cost:**
  - The approval-gate settings save on every keystroke.
  - Each step is still rated in full to find its kind.
  - Both cost a little CPU and nothing else.
- **Not shared yet:**
  - The phone log and the Mac log are still separate writers, because LinkKit cannot depend on Core.
  - The advice text uses its own sentence splitter rather than the speech chunker. The chunker knows abbreviations such as "e.g.", so an advisor sentence can be cut short.
  - The microphone states are still written out in six views instead of one `MicState`.
- **Script speed and leftovers:**
  - `pv-install` still verifies the same bundle's signature more than once.
  - The release build runs its iPhone archive after the Mac build instead of beside it.
  - `release-assets.sh` accepts a slightly narrower version format than `release.sh`.
