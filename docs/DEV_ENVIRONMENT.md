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
