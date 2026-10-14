# Security audit run 5: development key store, screech recording, tools (2026-10-14)

Scoped audit of only the code added since commit b5a40c9: the file-based phone key store and its automatic selection, the deferred key read in `PairingManager`, the attribute-only API key check, the screech recording (`FeedbackCatcher`), `scripts/restart-app.sh`, `pairvox-link doctor`, `scripts/audio-report.py` and the docs. Three independent reviewers read the diff and the touched files without running anything. I checked each finding against the source before fixing it. Nothing in this run was executed against the live app except the fixes' own tests, and the real restart through the new script.

Profile: scoped, source review plus unit tests. Marked partial: no hunter wave beyond the three, no second verifier per finding, no run against a real howl.

## Fixed (each has a regression test unless noted)

| Finding | Severity | Fix |
|---|---|---|
| `PAIRVOX_KEYSTORE=file` honoured in a team-signed build, so another process could move a release build's keys into a plain file | Medium | A team-signed build always uses the Keychain. The variable can only force the Keychain in other builds |
| A damaged `phone-keys.json` made the next `setKey` silently drop every other phone's key | Medium | The damaged file is moved aside (kept) and the store starts empty, as `PairingManager` does for its own file |
| Existing key folder kept loose permissions. Temp file left holding keys on failure or crash. Replaced file's mode unproven | Low | Folder set to 0700 on every save, file to 0600 after replace, temp file removed on failure and at start. Key file excluded from backups |
| A marker that could not be written left the legacy-import window open on every launch | Low | The window counts as closed for the rest of the run |
| Screech recording saved the user's speech for any loud pure tone (whistle, alert) even when PairVox was silent | Medium (privacy) | A recording needs PairVox's own output to have been audible in the last three seconds |
| Recordings were world-readable (0644), never pruned, and could not be switched off | Medium (privacy) | Files 0600, folder 0700, newest ten kept, a Settings switch (Logs), and turning it off clears the buffers and cancels a pending write |
| One quiet frame reset the detector, so a pulsing howl was missed | Medium | Leaky score: a howl frame adds two, any other frame subtracts one |
| Copying the whole ring under the audio lock. The output ring allocated under it | Medium | One copy per ring segment. The ring is built before the lock is taken |
| File-name collisions between recorders. A failed save used up a slot and still logged success | Low | Process-wide serial in the name. A failed save frees the slot and logs `feedback.saveFailed` |
| Ring size from a zero sample rate would trap; DC term counted in the tonality total. Windowed samples written over the input | Low | Rate guard. Total excludes bin 0. Separate buffer |
| `restart-app.sh` deleted the working app before checking the new one; `pgrep -f` matched loosely. Fixed 3 s start check. No JSON on failure | Medium | Verify first, copy beside and swap, anchored match on this checkout's binary, 15 s start poll, JSON on every exit, osascript error reported |
| `doctor`: every error said "not running". No timeout on `tailscale`. Any forward target counted as healthy. Control characters in names printed raw | Low | Distinct errors, 5 s watchdog, forward must point at `127.0.0.1:<port>`, control characters stripped |
| Docs said the recording needed PairVox to be speaking (it did not) and misdescribed the file contents | Medium (false statement) | Behaviour fixed to match. Docs corrected |

## Accepted, with the reason

| Finding | Why it stays |
|---|---|
| In a development build a process running as the same user can read the phone keys and can plant a phone (write a key and a list entry) without the Pair click | The cost of keeping the Keychain out of development builds, chosen by the owner so that rebuilding never needs a click at the Mac. Release builds keep the Keychain and ignore the file override. Recorded in `THREAT_MODEL.md` and `docs/DEV_ENVIRONMENT.md` |
| A failed legacy key import revokes the phone | One-time, recoverable by pairing again |
| The key read blocks one actor thread while a Keychain prompt is open | Off the main thread, so the app stays usable. Only matters in release builds, which prompt once |
| A phone listed as paired but without a key in the file store cannot connect. The UI does not say why | A UI follow-up, listed in the roadmap |
| Rings are not time-aligned with each other beyond their end points. The recorded "microphone" is what the app hears after conversion | Enough to listen to the screech |

## Not tested

No real feedback howl has passed through the detector. Its thresholds are an estimate checked against synthetic tones and synthesized speech. The next real screech will show whether they need tuning.
