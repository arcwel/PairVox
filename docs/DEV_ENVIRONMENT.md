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

## Keychain Prompts After Rebuilds

**Cause**
The Keychain identifies apps by their code signature. Local builds use ad-hoc signing, where the signature is a hash of that specific binary. Because every build produces a new hash, the Keychain treats every rebuild as a different application and prompts for permission to access existing items.

**Testing History (2026-10-14)**
- Ad-hoc builds attempting to read items from previous builds: Resulted in read-blocking prompts.
- Using a self-signed local identity (`DraftFi Local Signing`): Still resulted in prompts across different builds.
- Using an `Apple Development` identity: The signed binary was killed at launch on this Mac, making it unusable for local development.

**PairVox Implementation**
- **Key Storage:** In builds without a team identity, phone keys are stored in `~/Library/Application Support/PairVox/phone-keys.json` (file permissions `0600`, directory `0700`). Release builds with a team identity use the Keychain.
- **Configuration:** Use `PAIRVOX_KEYSTORE=file|keychain` to override the storage method. The default logic is defined in `DeviceKeyStores.automatic`.
- **Launch Behavior:** The app does not read the Keychain at launch. The saved-API-key check only requests attributes (which does not trigger a prompt); the actual key is only read when a session starts.
- **Threading:** The key store is read on a background thread so that a Keychain prompt cannot freeze the main UI.

**Security Trade-off**
In development builds, any process running as the same user can read the phone keys, and can also plant a new phone: it can write a key and a matching list entry, which skips the Pair click. Release builds keep the Keychain's per-app protection and ignore `PAIRVOX_KEYSTORE=file`. The key file is excluded from backups.

**Restoring Keychain usage in development**
To use the Keychain during development, sign with a stable identity (such as a Developer ID certificate once a paid Apple team is available). When the build has a team identity, it will default to the Keychain automatically.

## Build and Restart

- `scripts/restart-app.sh`: Quits this checkout's PairVox, verifies the last Release build in `.build/xcode`, swaps it into `dist/` (the old app stays until the new copy has passed its signature check), reopens it and waits up to 15 seconds for it to start.
    - `--build`: Runs a full build before restarting (the app must be closed).
    - `--dry-run`: Simulates the process without making changes.
    - `--json`: Outputs the result in JSON format.
- To compile without touching a running app, run `xcodegen generate` and then the `xcodebuild` line from `scripts/build-app.sh` (with its signing arguments): it writes to `.build/xcode`. The rest of that script replaces `dist/PairVox.app`.
- `pairvox-link doctor`: Diagnoses the phone link, Tailscale status, userspace forwarder, and online device status.
- **Repository Path:** `/Users/anthonyguidry/HD Projects/PairVox`.
- **SwiftPM Cache Issues:** If SwiftPM reports errors regarding the module cache path, move `.build/arm64-apple-macosx/debug/ModuleCache` to a different location; this folder stores absolute paths from previous builds.

## Tests

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
- Driving the simulator UI: screenshots from the control tool lag one action behind; `xcrun simctl io <udid> screenshot FILE` is current. The numeric keypad has no Done key and hides the Pair button, so scroll the form up twice (wait four seconds each time) before tapping Pair.

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
