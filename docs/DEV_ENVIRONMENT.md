# Developing PairVox on this Mac

Read this before changing signing, key storage, the build process, or audio tests. Add a line to this file when you encounter a new environment-specific issue.

## Manual Steps Required

The following tasks cannot be automated due to macOS security constraints:

| Step | Reason |
|---|---|
| Answering macOS permission prompts (microphone, Keychain) | The OS requires manual user interaction. |
| Clicking Pair when a phone pairs | The security model requires a physical click on the Mac to authorize the phone. |
| Typing the Mac password | Password entry is never scripted for security. |

The following sections explain how to minimize these manual interruptions.

## Permission and Keychain Prompts After Rebuilds

**Cause**
macOS identifies an app by its code signature's designated requirement. An ad-hoc signature's requirement is the hash of that one binary, so every ad-hoc rebuild is a different application: the microphone permission is asked again (and `bootstrap` waits in that prompt until someone clicks: 31 s in one run, 3 hours in another, which looked like a hang), and the Keychain prompts for existing items.

**Fix (2026-10-16)**
`scripts/build-app.sh` signs with an `Apple Development` certificate when the keychain has one: it reads the team from the certificates and lets Xcode pick the valid copy (`security find-identity -v` also lists old copies Xcode rejects as "not valid for code signing", and `codesign` cannot tell them apart). The designated requirement is then `identifier "app.pairvox.PairVox" and ... certificate leaf = "Apple Development: ..."`, the same for every build, so the microphone grant is asked once per certificate and kept. Measured: first launch with the certificate asked once; the next rebuild registered its hotkeys at 1.2 s with no prompt. `SIGN_IDENTITY=-` forces ad-hoc. Builds signed this way run with the hardened runtime on macOS 27.0.1 (an earlier note that such a binary was killed at launch no longer holds).

**Testing History (2026-10-14)**
- Ad-hoc builds attempting to read items from previous builds: Resulted in read-blocking prompts.
- Using a self-signed local identity (`DraftFi Local Signing`): Still resulted in Keychain prompts across different builds.
- Using an `Apple Development` identity: killed at launch that day; works on 2026-10-16 (see above).

**PairVox Implementation**
- **Key Storage:** In development builds (ad-hoc, self-signed or `Apple Development`), phone keys are stored in `~/Library/Application Support/PairVox/phone-keys.json` (file permissions `0600`, directory `0700`). Builds signed for distribution (`Developer ID Application`, `Apple Distribution`) use the Keychain. The choice follows the certificate type, not the mere presence of a team: on 2026-10-16 the first `Apple Development`-signed local build looked in the Keychain, found no key for the paired phone and told it "revoked".
- **Configuration:** Use `PAIRVOX_KEYSTORE=file|keychain` to override the storage method. The default logic is defined in `DeviceKeyStores.automatic`.
- **Launch Behavior:** The app does not read the Keychain at launch. The saved-API-key check only requests attributes (which does not trigger a prompt); the actual key is only read when a session starts.
- **Threading:** The key store is read on a background thread so that a Keychain prompt cannot freeze the main UI.

**Security Trade-off**
In development builds, any process running as the same user can read the phone keys, and can also plant a new phone: it can write a key and a matching list entry, which skips the Pair click. Release builds keep the Keychain's per-app protection and ignore `PAIRVOX_KEYSTORE=file`. The key file is excluded from backups.

**Restoring Keychain usage in development**
Run a development build with `PAIRVOX_KEYSTORE=keychain`. Keys already in the file are not moved, so the phone has to pair again once. A distribution-signed build uses the Keychain and ignores the variable.

## Build and Restart

- `scripts/restart-app.sh`: Quits this checkout's PairVox, verifies the last Release build in `.build/xcode`, swaps it into `dist/` (the old app stays until the new copy has passed its signature check), reopens it and waits up to 15 seconds for it to start.
    - `--build`: Runs a full build before restarting (the app must be closed).
    - `--prune`: Removes every other `PairVox.app` and old `PairVoxPhone.app` under the repo (worktree builds, dry-run bundles, old device builds), unregistering each from Launch Services first so `open` cannot reach a stale copy; keeps `dist/`, the restart source and the newest phone build; then reports whether the running app's CDHash matches `dist/`. On its own it prunes without restarting; `--dry-run` lists what would go.
- `scripts/freeze-watch.sh LOGFILE`: every 5 seconds records the PairVox pid, the last log write and whether the control socket answers; when the process is alive but silent it takes a `sample` next to the log. Started on 2026-10-16 after two runs stopped logging mid-stats and were then force-quit; the trigger was not the build or worktree housekeeping (tested live).
    - `--dry-run`: Simulates the process without making changes.
    - `--json`: Outputs the result in JSON format.
- To compile without touching a running app, run `xcodegen generate` and then the `xcodebuild` line from `scripts/build-app.sh` (with its signing arguments): it writes to `.build/xcode`. The rest of that script replaces `dist/PairVox.app`.
- `pairvox-link doctor`: Diagnoses the phone link, Tailscale status, userspace forwarder, and online device status.
- `scripts/launch-check.sh [RUNID] [--json] [--max-seconds N]`: reads the newest launch from the log and exits 1 when the shortcuts registered later than N seconds (default 5: the launch waited, usually in a permission dialog) or the audio engine never started; the `engine.start.failed` error is printed when there is one. Run it after every restart.
- **Repository Path:** `/Users/anthonyguidry/HD Projects/PairVox`.
- **SwiftPM Cache Issues:** If SwiftPM reports errors regarding the module cache path, move `.build/arm64-apple-macosx/debug/ModuleCache` to a different location; this folder stores absolute paths from previous builds.

## Tests

- **Audio tests that start the real engine** (`PlaybackPauseTests`, `LatencyTimelineTests`, `AudioStopDeadlockTests`, parts of `AudioTrimTests`) skip when the engine cannot start. On 2026-10-16 the first `engine.start()` in the test process failed now and then with `kAudioHardwareUnspecifiedError` ('what') from `kAUStartIO` while the same code in a fresh process, and the app, started at once; nothing in the unified log, not the sandbox, not the running app, not any one file (bisected). `startAudioOrSkip` in `Tests/PairVoxVoiceTests/AudioTestSupport.swift` tries three times, half a second apart, before it skips. A run whose audio tests all skipped verified nothing about audio: read the skip counts.
- **A hung test run** (no output for minutes) was once a three-way deadlock in `AudioIO.stop()` between the output tap (`player.isPlaying`), the player queue and the engine lock, fixed by keeping the playing state in a flag the tap reads. `sample <pid>` on the `xctest` process shows where a hang is; `run-job status` reports the stall.
- **Engine lifecycle tests** (`AudioLifecycleTests`, 2026-10-16) drive the real engine through 100 concurrent `restart()` calls and forced configuration-change restarts, an injected start failure, a restart storm on a route without echo cancellation (the Bluetooth shape) and a converter that fails. They use internal knobs on `AudioIO` (`settleQuiet`, `settleMaxWait`, `restartRetryDelay`, `startFailureInjector`, `playbackConverterOverride`, `handleConfigurationChange(force:)`) so a restart waits milliseconds instead of the production second; they also skip through `startAudioOrSkip`. The stress test takes about a minute and ends the run with `fatalError` if the lifecycle deadlocks, like `AudioStopDeadlockTests`.
- **Restart loop valve:** `engine.restartLoop` with `action: voiceProcessingOff` after 3 restarts in 20 s with echo cancellation on, and `action: replayOff` after 4 on any route (Bluetooth, output-only). From then until the storm ends, a sentence a restart interrupts is finished and logged as `playback.dropped` with `reason: restartLoop` instead of being replayed from the start, and the user sees one message. `engine.started` carries `outRate` and `playerRate` so a 16 kHz call-mode headset shows in the log.

- **Running Tests:** `swift test --build-system native`. 
    - *Note:* MLX produces "Class ... is implemented in both" noise. Filter output using: `grep -E "error:|failed|Executed"`.
- **Feedback Detector Check:** To check for false positives in real speech, use: `PAIRVOX_SPEECH_SAMPLES=<folder of audio> swift test --filter testRealSpeechSamplesAreNotHowls`.

## Audio

- `scripts/audio-report.py [--since MINUTES] [--json]`: Summarizes the most recent run from the logs, providing counts and timings.
- **Feedback recordings:** if the microphone hears a loud single tone (a howl) while PairVox is speaking, PairVox saves two files in `~/Library/Logs/PairVox/`: `feedback-<run>-<n>-mic.caf` (what the microphone heard) and `-out.caf` (what PairVox played). Each holds the ten seconds that end 1.5 seconds after the howl was detected, and may contain speech. A howl while PairVox is silent saves nothing. At most five recordings per run, fifteen seconds apart; the newest ten files are kept; files are readable only by you. Turn it off in Settings, Logs. Check with `scripts/audio-report.py`.
- **Known Limitations:** 
    - `separate-engines` mode does not include echo cancellation.
    - Bluetooth headsets in call mode operate at 16 kHz.

## Testing the phone app without a phone (iOS Simulator)

Verified 2026-10-14: pairing, the permission card, a Face ID approval and automatic reconnect, all in the simulator.

- One-time: the iOS runtime (`xcodebuild -downloadPlatform iOS`, about 8 GB), then `xcrun simctl create "PairVox Test" com.apple.CoreSimulator.SimDeviceType.iPhone-17 com.apple.CoreSimulator.SimRuntime.iOS-27-0` and `xcrun simctl boot` it.
- Build the app **ad-hoc signed**: `xcodebuild -project ios/PairVoxPhone.xcodeproj -scheme PairVoxPhone -destination "id=<udid>" -derivedDataPath .build/ios-sim CODE_SIGN_IDENTITY="-" build`. An unsigned build (`CODE_SIGNING_ALLOWED=NO`) cannot use the iOS Keychain, so the phone never saves its credentials.
- A Mac's "Pair" click cannot be scripted while the screen is locked, and the test must not weaken that check. Use the stand-in host instead: stop the Mac app, run `.build/debug/pairvox-link-testhost --port 47821` (it prints a six-digit code, accepts the pairing by itself, listens on loopback only and plays a scripted permission request), pair the simulator with host `127.0.0.1`, then restart the Mac app with `scripts/restart-app.sh`.
- Face ID in the simulator: `xcrun simctl spawn <udid> notifyutil -s com.apple.BiometricKit.enrollmentChanged 1 && notifyutil -p com.apple.BiometricKit.enrollmentChanged`, tap Allow, then `notifyutil -p com.apple.BiometricKit_Sim.pearl.match`.
- The simulator does not suspend backgrounded apps, so a link survives the Home button there. Reconnect-on-foreground was tested by freezing the process (`kill -STOP <pid of PairVoxPhone>`), waiting for the host to drop the connection (approximately 40 seconds), and then resuming the process with `kill -CONT` followed by `xcrun simctl launch` to bring it to the foreground. Verified 2026-10-15: reconnected 0.4 seconds after coming to the front.
- Driving the simulator UI: screenshots from the control tool lag one action behind; `xcrun simctl io <udid> screenshot FILE` is current. Taps sent while the keyboard is animating are lost, so send one tap per call and wait a second between them. The pair form now has a Done key above the keypad and a Pair button in the title bar, so nothing needs scrolling. Typing `\b` sends the literal characters, not backspace; use the field's clear button.

## Replay harness (voice path without a microphone)

`Tests/PairVoxVoiceTests/ReplayHarness.swift` pushes synthetic or recorded 16 kHz audio through the real `VoiceInputController` (energy VAD, then a transcriber, then the real `ConversationEngine`). A simulated speaker plays the agent's reply and leaks it into the microphone at a chosen level (`Scenario.leakDB`). Speech comes from macOS voices (`say`), so it needs a Mac but no network and no models. The transcriber is a stand-in that hears the scenario's own words when the audio overlaps a user's speech and nothing otherwise, so the tests measure the detector and the engine, not Whisper.

- Run: `swift test --filter ReplayTests`. Exploration sweeps (they print tables of echo level against false triggers, and user level against barge-in) run with `PAIRVOX_REPLAY_EXPLORE=1 swift test --filter "ReplayExploreTests|ReplaySensitivityExplore"`.
- Measured with it (2026-10-14): a user needs to be about 10 dB above the echo to barge in; echo alone triggered 7 false barge-ins in 14 s at 26 dB down and 14 at 20 dB down before the VAD knew the playback level, and none after. Noise bursts of -46 dBFS and louder over speech still pause it, and it resumes in place (pauses equal resumes, nothing is discarded, nothing reaches Claude).
- Not covered: Whisper itself (a different test), real Bluetooth timing, and how a real room sounds.

## Soak and fault tests

- `PAIRVOX_SOAK_SECONDS=60 swift test --filter EngineSoakTests` runs thousands of mixed cycles (turns, long replies, barge-ins, approvals, interruptions, failures, new sessions) through a real engine with a fake Claude and speaker. Measured 2026-10-14: about 140 cycles per second, memory flat (+0.1 MB over 10 s), transcript capped at 600.
- `swift test --filter "LinkSoakTests|LinkFaultTests"`: connection churn and hostile clients, a snapshot storm with a phone that never reads, and a freeze, resume and kill of the real stand-in host process (`.build/debug/pairvox-link-testhost` must be built first; the fault test skips without it).
- Always run a test you suspect can hang with `timeout 120 swift test ...`: a hung test process (`xctest`) does not exit on its own.

## Where the time goes between you speaking and hearing an answer

Measured 2026-10-14 from 79 real voice turns, plus real probes (medians):

| Stage | Time | Notes |
|---|---|---|
| Silence wait before PairVox decides you are done | 0.65 s | `endOfTurnSilence` setting |
| Speech to text | 0.85 s | Whisper; scales with clip length |
| Claude's first text | about 2.0 s | `scripts/claude-latency-probe.py`: 2.0 s as PairVox runs it, 1.8 s with all hooks off, 2.1 s with thinking off, 2.0 s on Haiku. Settings do not move it; it is the model and API. |
| First sentence ready to first sound | was 0.8 s, now about 0.2 s | Kokoro's own silence (0.4 s before, 0.5 s after each sentence) and the acknowledgement holding the speaker. See `AudioTrim`. |

`PairVox --tts-probe "text|text"` prints a voice's lengths and silences. `LatencyTimelineTests` replays one turn on the real engine and speaker and measures when the answer becomes audible.

**Reproducing a corrupt sentence.** When a sentence comes out as noise the log has a `synth.corrupt` line (`cat: tts`, `lvl: error`) with the measurements (`peak`, `nonFinite`, `overRange`, `noisyWindows`, `highBand`, `frames`) and, by default, only the sentence's length (`chars`) and the first 16 hex characters of its SHA-256 (`sha256`): reply text stays out of the log and out of an exported diagnostics zip unless the user has opted in. To reproduce the fault you need the text, so switch on Settings → Diagnostics → "Include conversation text" before the next session, wait for the next `synth.corrupt`, and copy its `text` field into the probe: `PairVox.app/Contents/MacOS/PairVox --tts-probe "<the sentence>" --out /tmp/probe` renders it headless with the same voice and writes the audio and measurements. A hash from an earlier line can be matched afterwards: `printf '%s' "<the sentence>" | shasum -a 256 | cut -c1-16` equals its `sha256` field.
