# Security audit run 4: cross-project approvals, voice for high risk, control channel, key store (2026-10-13)

Scope: `Sources/PairVoxCore/Conversation/CrossProject.swift` and the engine hooks around it (utterance interceptor, spoken confirmation of anything a plain yes may not approve, the separate switch for requests Claude Code marks as needing the screen, optional second confirmation), `CrossProjectController` and the approvals tray (app, source only), the phone rules in `LinkHost` for voice approvals and for requests in other projects, the `pairvox-link` tool and its control socket, and the move of phone keys on the Mac into the Keychain. Same sandbox and evidence rules as runs 2 and 3. The Unix-socket server could not be run in the sandbox (it denies socket binding), so socket behaviour was read as source and then exercised once against the real app on this Mac.

Three hunters worked in parallel (cross-project rules; control socket, CLI and key store; then a regression pass on the fixes). Every confirmed finding was reproduced by the agent that reported it, and each fix has a regression test.

## Findings and fixes

| Finding | Sev | Fix |
|---|---|---|
| A live announcement swallowed ordinary speech meant for the current project: "okay" or "yes" approved the other project's request; "stop", "no" or any short sentence with a refusal word denied it and never reached Claude | Medium | The app stops intercepting while the active project has its own request or folder question open; unrelated speech ends the 20-second binding; "stop" and "wait" are never answers; the deny/approve grammar is limited to short forms |
| A planted `paired-phones.json` with a key inside was imported as a trusted phone with no Accept click, and a shell `cp` into the file was only medium risk | Medium | Inline keys are imported once, on the first run with the Keychain store; afterwards a file entry carrying a key is blanked and revoked; a phone with no Keychain key stays listed but cannot connect. A shell command that names PairVox's settings folder or `~/.claude` by any spelling (`~`, `$HOME`, escaped spaces, quotes) is now high risk |
| The 300 s voice age limit applied to "approve" but not to "confirm high risk" for another project | Low | One age check over every voice approval |
| On the phone, a request's age restarted when the Mac switched projects (the request changed identity) | Low | Requests are keyed by project and request id with a stable active-project id |
| The sentence filter for model-written speech let "confirm high risk <3-word project name>" through, and the announcement grammar accepts it | Low | Any sentence containing the phrase, or that the announcement grammar would accept, is dropped before speech |
| Turning the Mac's voice switches off did not reach the phone until the next engine update | Low | The phone is updated when a setting changes |
| `pairvox-link pair` could silently replace the owner's open pairing offer, and the Accept dialog showed only the phone's name | Low | The command refuses while an offer is open; the dialog says where the code was started (Settings or the command line) |
| Control socket: one slow client blocked all others | Hardening | Each connection is handled on its own with a 2-second deadline; the folder is forced to 0700 |
| Phone names loaded from disk were not cleaned; a failed save after pairing left a half-paired phone; a Keychain delete failure on removal was ignored; announcements said "Approved"/"Denied", words the announcement grammar itself accepts; the project name was spoken even when that setting was off | Hardening | Names cleaned on load (and braille blank added); pairing rolls back on a failed save; removal reports a failed key deletion; confirmations reworded; the name setting is honoured everywhere |

## Second pass on the fixes

A fresh hunter attacked the fixes above and broke two of them. Both are fixed with tests.

| Finding | Sev | Fix |
|---|---|---|
| The one-time-import marker lived in the same Keychain namespace as phone keys, so a planted file naming a phone `legacy-import-closed` made the marker the "key" (a known one-byte value) and bypassed the Accept click | Medium | The marker has its own Keychain service; phone ids must be UUIDs; a Keychain value counts as a key only if it is 32 bytes; any Keychain answer other than "not found" counts as closed |
| The protected-folder rating for shell commands missed globs (`~/.cl*`), `cd` followed by relative paths, `sh -c '...'`, and relative paths through a repository symlink | Medium | Patterns are expanded for real and checked; `cd` changes what later relative words mean; quoted command lines are read recursively; relative words are resolved against the project with symlinks followed |
| A shell folder grant auto-approved a glob through a repository symlink into `~/.claude` (`cp evil.json l?k/settings.json`) | High | The shell grant refuses `*` and `?` as well |
| The model-text filter missed the phrase with punctuation between the words ("confirm, high risk") | Low | Words are normalised first; "confirm" within three words of "high risk" is dropped |
| An inbox with a duplicate request id would crash the app; the busy flag lagged the engine and ignored catch-up and held-back questions | Hardening | Duplicates handled; the flag comes from the active project's own state and covers those questions |

Not fixed, by decision: a same-user process that can delete the first-run marker from the login Keychain (needs a real Keychain test), and the phone's unverifiable "tap" and device-authentication claims (known).

## Accepted or open

- **Echo of PairVox's own speech** (spoken prompts, announcements, advisor text) heard by the microphone is still possible when voice for high risk is on. You accepted this trade-off for the Mac; the phone's second confirmation (Face ID, Touch ID or passcode) is claimed by the phone and cannot be checked by the Mac. This needs a test on real hardware.
- **A same-user process** can still talk to the control socket (it can start a pairing offer if none is open). Pairing still needs your click on the Mac, and the dialog now says the code came from the command line.
- **Project folder names** are chosen by whoever made the repository. A folder called "yes" or "approve" makes the first spoken words of an announcement look like an answer.
- **Not run:** the Accept dialog, the Touch ID/password prompt, the approvals tray and menu-bar section, and anything involving the microphone.
- This is a scoped, source-first audit with sandboxed evidence, not a claim of complete coverage; the link has not been fuzzed.
