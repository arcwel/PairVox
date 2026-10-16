# Threat model

PairVox lets you steer an agent that can edit files and run commands, by voice. Speech recognition makes mistakes, and other people or devices can make sound near your Mac. This document covers what can go wrong and what PairVox does about it.

## Assets

- Your source code and machine: the agent can edit files and run shell commands.
- Your Claude account or API key.
- Audio from your room.

## Trust boundaries

1. **Microphone → transcript.** Untrusted: misrecognition, background speech, TV or video audio, other people.
2. **Transcript → Claude Code.** Treated as your instruction, the same as typing it.
3. **Claude Code → tool execution.** Gated by Claude Code's own permission system and, when it asks, by PairVox's policy.
4. **Tool output and web content → Claude → speech.** Untrusted: prompt injection can make Claude say or request anything.
5. **The opened repository → the Claude child.** Untrusted: a downloaded repository can ship `.claude/settings*.json` (hooks, allow rules), `.mcp.json` and `CLAUDE.md`. PairVox starts the child with `--setting-sources user` unless you turn on “Load this project's own Claude Code settings”.

## Controls

| Risk | Control |
|---|---|
| A misheard “yes” approves something destructive | `PermissionPolicy` rates every request. A shell command is “low” only when it is a plain read-only command (`ls`, `git status`, `grep`, …); anything it does not recognize is at least “review”, and git global options such as `-C` are stripped before matching. Refusals (“don’t always allow”, “never ask again”) are parsed before approvals. High-risk requests can never be approved by voice: a spoken yes gets “please confirm on screen”. High risk covers recursive or forced `rm`, `git push`, `reset --hard`, `sudo`, piping a download into a shell, publishing, `launchctl`, writes outside the project, credentials and dotfiles, and anything Claude Code itself flags (`safetyCheck`, `default_to_no`, `requires_user_interaction`). |
| Background speech triggers actions | VAD needs about 180 ms of sustained speech above an adaptive noise floor. Yes/no answers are only recognized while a prompt is pending and only as short whole utterances; longer speech becomes feedback to Claude, never an approval. Push-to-talk and mute are one keystroke away. |
| TTS echo heard as user speech | Voice-processing I/O (Apple's echo canceller) plus a VAD threshold raised by 6 dB during playback. Barge-in can be turned off (half-duplex). If the user turns on spoken confirmation of high-risk requests, PairVox's own prompt contains the phrase that approves them, so speech the microphone hears can approve a high-risk request; the setting is off by default and says so. |
| Prompt injection asks for dangerous actions | The same permission gate applies whatever Claude says. Spoken prompts describe what will actually run, taken from the tool input and not from Claude's own `description` field. The on-screen card shows the whole command in a scrollable box. Requests are shown and spoken one at a time: a second request waits in a queue and never replaces the one on screen, and every button is bound to the request ID it was drawn for. “Always allow” applies Claude's suggestions to the session only. |
| Credential exposure | No login UI. `scripts/check-keychain-access.sh` reports which programs the Keychain lets read the saved key without a prompt. Subscription credentials never pass through PairVox. An API key is stored only in the Keychain (`kSecAttrAccessibleWhenUnlocked`), passed only to the child process environment, never written to settings or logs. |
| Leaking audio or transcripts | Speech recognition and synthesis run on-device. No telemetry. The only network traffic PairVox itself makes is model downloads, which for the Kokoro files are pinned by SHA-256 and loaded only after verification. The Whisper speech models and their tokenizers are downloaded by PairVox from Hugging Face at pinned commits and checked against pinned SHA-256 hashes before WhisperKit loads them (`scripts/pin-whisper-models.py` regenerates the pins). |
| Malicious model file | Kokoro's loader traps on malformed input, so files are hash-verified before loading. Whisper models are hash-pinned the same way (see above), and a file that does not match is deleted and refused. |
| A hung CLI blocks the app | Unsupported control requests are answered with an error immediately. Process exit is detected and reported; the next message resumes the session. |

| An AI explanation of a request misleads the approver | It is advice shown beside the real command and labeled as an AI summary, comes from a separate read-only call that cannot approve anything, treats the request as fenced data, and is never what is spoken as the approval prompt. |

## Not in scope / known limitations

- PairVox does not sandbox Claude Code. Use Claude Code's own settings (permission rules, sandboxing) for defence in depth.
- “Auto-approve read-only tools” is off by default and answers only plain read-only tools (never shell commands, never `ExitPlanMode`, never a file that looks sensitive). Reading files can still pull sensitive content into the conversation.
- Hands-free mode in a shared space is inherently riskier. Prefer push-to-talk there.
- The risk classifier is heuristic. Since audit run 2 it reads the program and subcommand as well as the text (long flags, `git -p push`, `/usr/bin/sudo`, pipe into an interpreter), but shell grammar is open-ended: it errs toward asking, and a folder shell grant refuses braces, backslashes, quote tricks, `cd` without a target and anything it cannot place. It is still not a security boundary on its own. See `docs/security/2026-10-13-audit-run-2.md`.

## Reporting

See [SECURITY.md](../SECURITY.md).

## Phone link (v0.3, off by default)

The Mac listens only when you switch it on, accepts connections only from Tailscale (and loopback) addresses, and lets a peer in only after a keyed handshake with a key created when you clicked Pair. Frames are encrypted and numbered; replays end the connection. The Mac, not the phone, decides what a spoken yes may approve. Phone keys on the Mac live in the Keychain in builds signed with a team identity (not in the phone list file); development builds, which have none, keep them in a separate private file (0600) because the Keychain would ask again after every rebuild (see `docs/DEV_ENVIRONMENT.md`; in those builds a same-user process can read the keys and can plant a phone without the Pair click, and `PAIRVOX_KEYSTORE=file` is ignored in team-signed builds), and a phone file carrying a key is trusted only once, on the first run. Before the handshake, the Mac tells a phone it will not talk to why (not paired, removed, or a different protocol version) so the phone stops retrying; device IDs are random 128-bit values, so this says nothing to a peer that does not already hold a phone's ID, and the pre-authentication rate limits still apply. A wrong key is not distinguished from a dropped connection. A refusal is not authenticated, because it is sent before any key is tried: anyone who can answer at the Mac's address could make a phone stop retrying and show its pair-again prompt, but nothing such a peer says can pair a phone, approve a request or read anything, and the phone tries once more each time the app comes to the front. The `pairvox-link` tool talks to the app over a private socket (0600, same-user only); it can start a pairing offer but pairing still needs your click. Known gaps: a six-digit pairing code could be guessed offline from a captured exchange (it still needs your Pair click); the link has not been fuzzed or independently audited.


Runs 3 and 4 of the audit cover the phone link, the iPhone app, cross-project approvals and the control channel: see `docs/security/2026-10-13-audit-run-3-phone-link.md` and `2026-10-13-audit-run-4-cross-project.md`.
