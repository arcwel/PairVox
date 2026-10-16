# Code audit, 2026-10-16: phone link, iPhone app, tools and release scripts

Scope: `git diff 1fbd4b6..HEAD` (commits 4f13668, 79f553d, a40ac43, c87dd75), plus the uncommitted sync-order fix, the publish log and the probe changes. Three independent read-only reviews (link core, iPhone app, tools and release) and a review of the uncommitted changes by the author. The experiment-branch work (early acknowledgement, early transcription) is not covered.

Method: every finding was checked against the code before it was acted on. Each fix has a test; the three reconnect-loop fixes were also mutation-checked (the fix removed, a test must fail).

## Link core

| # | Finding | Verdict | Disposition |
|---|---|---|---|
| 1 | `Reconnector.start()` left the old session open, and the old loop cleared the new loop's session when it ended | confirmed | Fixed: `start()` closes the old session; the loop clears `current` only while it is still the current one. Test `testStartWhileConnected…`; mutation caught |
| 2 | A nudge that arrived while a connection attempt was in flight was lost | confirmed | Fixed: the attempt runs as a cancellable task, a nudge cuts it short, and the next attempt starts at once. Two tests; mutations caught |
| 3 | `phones prune --stale` could remove a phone that was connected, and a phone paired before the stamp existed | confirmed | Fixed: the control reply carries `connected`, and prune never lists a connected phone. A phone already removed counts as done. Pre-stamp phones still count from the day they were paired (documented) |
| 4 | A handshake refusal is sent before any key is tried, so it is not authenticated | by design | Documented in the threat model: it can make a phone stop retrying and show a pair-again prompt, nothing more |
| 5 | A healthy idle Mac can be silent for 15 s, and sent nothing at all before it had published state | confirmed | Fixed: the phone's foreground limit is 25 s (was 15), and the host sends an idle heartbeat when it has no state. Test added |
| 6 | `TCPTransport.stateDescription` was written and read from different threads | confirmed | Fixed: guarded by the existing lock |
| 7 | Test gaps: wrong key not asserted to differ from a refusal; no test for a failed keep-alive ping or for fail-fast on a closed port | confirmed | Fixed: three assertions and tests added |
| 8 | Timing-dependent tests | confirmed | Fixed: polling instead of a fixed sleep. A racy final assertion in `LinkSoakTests` (the first snapshot is not always the newest) failed 2 runs in 5; it now reads until the marker arrives. 4 of 4 clean runs afterwards |

## iPhone app

| # | Finding | Disposition |
|---|---|---|
| 1 | Two pairings could run at once; the later failure overwrote a good state | Fixed: one at a time, buttons disabled meanwhile |
| 2, 3 | Other-project requests and the "confirm high risk" voice path were not gated on the link; Face ID results were not re-checked | Fixed: approvals need a live link and a fresh snapshot, and are re-checked after Face ID. The Mac enforced all of this already; this removes the confusing late refusals |
| 4 | A request card from before a drop became tappable again before the Mac confirmed anything | Fixed: `hasFreshSnapshot` |
| 5 | Old reconnector's queued state changes could overwrite the new one; stop and start were unordered | Fixed: a token per reconnector, and one task that stops then starts |
| 6 | A stuck connect never ended when its loop was cancelled | Fixed: `withTimeout` closes the transport when its caller is cancelled |
| 7 | A nudge did not shorten a stuck attempt | Fixed (see link core 2) |
| 8 | Misleading sentences ("Trying again" during pairing, wrong advice for a name lookup failure, stale detail text) | Fixed |
| 10 | `isPaired` read the Keychain in a view body; a launch while locked showed the pairing form and never connected | Fixed: cached, re-read when the app comes to the front |
| 11 | The privacy curtain does not cover presented sheets | Not changed: the curtain must show for the app-switcher snapshot, and the sheets (connection address, scanner) are low value |
| 12 | Scan result dialog could be dropped while the scanner sheet dismissed | Fixed: shown after the sheet has left |
| 13 | Port 0 to 1023 accepted by the form; first network report caused a reconnect; haptic style | Fixed |

## Tools and release scripts

| # | Finding | Disposition |
|---|---|---|
| 1, 2 | `soak.sh` and `replay.sh` reported success when any earlier suite passed; `replay.sh` selected no sweep tests; its example matched nothing | Fixed: the exit status needs `swift test` to succeed, tests to have run, and the final total to show no failure. `--explore` runs the sweeps |
| 3 | `make-appcast.sh` passed `--ed-key-file -` while the comment said the key came from the Keychain | Fixed: the flag is gone; also corrected the "tools missing" message |
| 4 | Every release would carry `CFBundleVersion` 1, so no update would ever look newer | Fixed: the commit count is stamped, and the dry run checks it |
| 5 | An unrecognised second argument to `release.sh` started a real release | Fixed: only `--dry-run` is accepted |
| 6 | The entitlement check could not fire in the dry run and did not exist in the real path | Fixed: the real path refuses `get-task-allow` and any unexpected entitlement before signing |
| 7, 8 | `pipefail` aborts and false negatives in the dry run | Fixed: stages tolerate "nothing found"; outputs are captured before matching |
| 9 | `prune` exited 1 for a phone already removed | Fixed |
| 10 | The "Check for Updates" menu item is evaluated once | Deferred until Sparkle is linked (documented) |
| 11 | Documentation gaps and mismatches | Fixed: RELEASE.md, README, CHANGELOG, threat model |

## Found by the author while tracing "text does not sync"

- The sync-order fix is correct: the phone used to receive the snapshot before the latest one.
- `switchTo` did not retarget the phone's engine or republish. After switching projects on the Mac, text typed on the phone went to the previous project's engine, and closing the active project left it pointing at a shut-down engine. Fixed in `AppModel.swift`.
- Text sent while no project was open went nowhere without a word. The phone now gets a notice.
- Added `link.submit` and `phoneLink.publish` log lines, so a sync problem can be read from the Mac's log.

## Not verified

- No runtime check of the iPhone changes: the iOS Simulator became unusable (CoreSimulator older than the new Xcode), so the phone app was compiled against the device SDK only. Earlier versions of the same screens were checked in the simulator.
- The idle heartbeat and the 25 s limit have not been exercised on a real phone.
- The speaker screech remains unexplained; playback recording is on for the next occurrence.
