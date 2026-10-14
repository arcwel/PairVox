# Roadmap

## v0.1: macOS (this release)

- Voice loop with barge-in, redirect, and the speech modes (full, skip code, summary)
- Brainstorm (plan) and execute modes
- Subscription login and API-key auth
- WhisperKit speech recognition with Apple Speech as fallback
- Kokoro voice with the system voice as fallback
- Voice approvals behind a risk policy
- `pairvox-cli`

## v0.2: polish (next)

- [ ] Streaming partial transcripts in the UI while you speak (WhisperKit `AudioStreamTranscriber`)
- [ ] Silero VAD as an optional second-stage detector for noisy rooms
- [x] Per-project settings UI (Settings → Project: reply mode, start mode, model, extra listening words)
- [x] Configurable hold-to-talk shortcut (⌃⌥ plus Space, T, V, G or B, in Settings → Shortcuts)
- [x] A speech "earcon" when Claude starts working or finishes (off by default; Settings → General)
- [x] Session picker (File → Resume Earlier Session; lists the project's earlier sessions, only UUIDs are passed to `--resume`)
- [ ] Sparkle auto-updates

## v0.2a: approval-gate hardening (done 2026-10-13)

Fixes from the security audit (`docs/security/2026-10-13-phase1-hardening.md`), each with a regression test. These come first because folder grants and multi-project build on the gate.

- [x] Spoken Bash prompts come from the command, never Claude's `description`
- [x] Unrecognized shell commands are never "low"; git global options are normalized; interpreters and nested shells are flagged
- [x] Auto-approve answers only plain read-only tools, follows the Settings toggle on a running session, and never skips `ExitPlanMode` or sensitive files
- [x] Refusals ("don't always allow", "never ask again") are parsed before approvals
- [x] One request is shown and spoken at a time; later ones queue; buttons are bound to the request ID
- [x] "Always allow" is applied to the session only
- [x] A new session keeps the conversation mode the user switched to, and voice mode changes are saved
- [x] The child loads only user-level Claude Code settings unless "Load this project's own settings" is on. Confirmed by running `claude` 2.1.296 in a no-network sandbox (`scripts/validate-claude-config.sh`): with default arguments a repository's hook and MCP server both ran with no prompt; with `--setting-sources user` neither ran and the user's own MCP servers still loaded
- [x] Permission card shows the whole command; menu-bar Allow shows risk and sends high-risk requests to the window
- [x] Transcript links open web and mail links only; `say` gets `--`; CLI output strips control characters; repo scan skips symlinks and bounds reads
- [x] Audit follow-ups closed: repo-config behavior measured in a sandbox and fixed, release workflow split and pinned, Whisper models and tokenizers pinned by commit and hash, `claudePathOverride` and `settings.json` hardened (see `docs/security/2026-10-13-remediation.md`)
- [ ] Still open: whether PairVox's own speech heard by the microphone can approve a low- or medium-risk request (owner decision: allowed only through the spoken-confirmation toggle, not yet built), and the Keychain access check on the signed release build

## v0.2b: access control and multi-project (planned)

Added 2026-10-13. These build on the security audit in `docs/security/2026-10-13-phase1-hardening.md`; the audit leads named below should be settled first or alongside.

### Mini mode and menu bar

- [x] A small always-on-top mini window that shows only that voice is active (listening, thinking, speaking) and offers mute and stop.
- [x] A menu-bar-only mode with the same status and controls, no main window. The v0.3 companion reuses it.

### Approvals you can understand and question

- [x] **Approve all** for the prompts currently waiting, in one action, with the list shown first. (Card button, and by voice: "allow all" reads the list and the high-risk count first, a second "allow all" allows only what was read; skips high-risk and screen-only requests.)
- [x] **Plain-language summary** of every request ("Claude wants to rename 3 files in `src/`") shown and spoken in place of the raw command. The exact command stays one tap away.
  - The summary must be derived from the normalized tool input, never from Claude's own `description` field (audit lead: spoken prompt uses model description).
  - The card must show the full command, not a 6-line cut-off.
  - Built as a separate one-shot `claude -p` call (Haiku, tools limited to Read/Grep/Glob, user-level settings only) shown as "AI summary, check the command", with the deterministic spoken prompt unchanged. Voice: say "explain" to hear it; a spoken question ending in "?" while a request is pending goes to the advisor instead of counting as a refusal. Settings toggle: "Explain each request in plain words". Checked live with two real calls: it flagged a misleading model-written description.
- [x] **Ask before you approve.** While a request is pending, the user can ask questions about it ("what other files does this affect?", "could this delete files in the folder later?") and get an answer before deciding.
  - Answers come from a read-only side query that sees the pending request and the project, and cannot run tools or change the pending request.
  - An answer is advice only; the approval still has to come from the user.
- [x] Approvals bound to a request ID, with a queue instead of one pending slot (audit lead: pending slot overwritten).

### Folder-level approvals

- [x] Prompt once per project: "This project works in `~/Documents/project/x`. Allow Claude to edit all files within it?" Granting skips the per-request prompt for edits inside that folder and passes them straight to Claude.
- [x] **Double confirmation** to grant, with the exact folder path and what is and is not covered. The first time a grant is approved by voice, PairVox asks twice, and the second ask repeats the path and scope back.
- [x] **Shell commands are a separate toggle**, off by default, per folder grant. Turning it on needs its own double confirmation, and the user can switch it on or off at any time without removing the file-edit grant.
  - With it on, shell commands run with that folder as the working directory skip the per-request prompt.
  - Commands that reach outside the folder (absolute paths elsewhere, `cd ..`, network downloads piped to a shell) are not covered and still prompt. This relies on a stricter command check than the current denylist (audit lead: risk classifier defaults to low), so that check ships first.
- [x] Grants listed in Settings, each removable, with when it was granted and whether shell commands are on.
- [x] Scope limits, decided with the audit in mind:
  - file-edit grants cover the resolved folder only (symlinks resolved), not other folders
  - high-risk requests still need an explicit confirmation, even inside a granted folder. A confirmation can be a click or a deliberate spoken one: PairVox reads the plain-language summary back and requires a specific confirm phrase, not a casual "yes". Today high-risk requests cannot be approved by voice at all, so this changes the policy.
  - **Spoken confirmation is a settings toggle.** On: the user may confirm high-risk requests by voice. Off (the safer default): the user must click the button when prompted, and voice cannot approve them. The toggle applies to high-risk requests only; the lower-risk voice approvals keep their own behavior. The toggle is off by default. When it is on, the user has accepted that PairVox's own speech picked up by the microphone can satisfy the confirmation (audit lead: own TTS echo accepted as approval), so no echo filtering is required on that path. The setting's description must say this plainly, and the click path stays available either way.
  - grants are stored by resolved path, are not shared across projects, and never come from repo-supplied config (audit lead: repo config bypass)
  - Built: `FolderGrant` list in settings only; two-step offer by voice or banner; shell is a separate per-folder switch that asks twice; Settings shows when each was granted and removes it live. Edits are checked on fully resolved paths (a link inside the folder that leads elsewhere does not count). The shell check is a deliberately narrow heuristic: variables, command substitution, inline code, network, installs, absolute or `..` paths outside the folder, and sensitive files all still ask. Covered by `FolderGrantTests`.

### Multiple projects at once

- [x] Several projects open in one window, with a side menu of projects instead of one project per window.
- [x] Each project keeps its own session, mode, permission state and transcript.
- [x] **Switching with updates waiting.** If Claude has output in another project, the side menu marks it, and on switching the user gets audio controls: play from the first missed message, play the last message only, or skip. Choosing one makes that project the active conversation, and voice input goes to it.
- [x] Background projects do not speak on their own. They queue and notify.
  - Built: one `claude` process and engine per project (up to 8), a project list that appears with the second project and shows NEEDS OK / N NEW / WORKING, ⌘⌥1–9 and ⌘⌥[ ⌘⌥] to switch, "switch to project <name>" by voice (unambiguous matches only), open projects restored at launch. A `GatedSpeechOutput` per project keeps background projects silent. The one you left stops speaking at once and its replies are listed; on return a bar offers *Play from the first*, *Play the last one* or *Skip* (or say "catch me up", "play the last one", "skip"), then re-asks any request still waiting. Background projects raise notifications for requests and finished turns. Covered by `CatchUpTests` and `GatedSpeechOutputTests`.

## v0.2c: cross-project approvals (specified, not built)

Answer another project's request without leaving the conversation you are in. Spec and owner decisions: `docs/prd/cross-project-approvals-prd.md`.

- [ ] A1 Inbox model across projects, answers bound to the announced request and its project
- [ ] A2 Break detector and announcer (2 s quiet, after Claude's reply), settings, per-project mute, project-name option
- [ ] A3 Answer in place by voice; switch; ask-again rules
- [ ] A4 "Tell me more" overview (advisor with fallback)
- [ ] A5 Inbox UI (project list, menu bar, mini window) and phone parity
- [ ] A6 Voice for high risk and for requests marked "needs the screen" (separate switches), optional Mac second confirmation, phone second confirmation, security audit

## v0.3: iPhone client

PRD and council verdict: `docs/prd/pairvox-iphone-prd.md`. The engine and the permission gate stay on the Mac; the phone is a remote front-end.

- [x] M0: `PairVoxLink` host, pairing (QR or six-digit code, Mac-side accept, revoke), keyed handshake and encrypted frames, TCP transport, test client; approval rules enforced by the Mac (voice only if the Mac allows it, high risk needs a tap and Face ID, stale requests need a tap). Tested with no phone and no microphone
- [ ] M0.5: locked-phone background-audio prototype on a real iPhone
- [x] M1: Mac companion: Settings → Phone (off by default) starts a Tailscale-only listener, shows a QR code or six-digit code, asks you to click Pair for each new phone, lists and removes paired phones, and keeps the Mac awake while a phone is connected. High-risk requests need a deliberate tap on the phone (Face ID, Touch ID, passcode or plain tap). Built and launched; the screens were not yet checked by eye, and phone keys are stored in a 0600 file rather than the Keychain
- [x] M2/M3 (first cut): `ios/` SwiftUI app (QR or code pairing, transcript, approvals with Face ID/Touch ID/passcode/tap, on-device speech, spoken replies); builds for the iOS Simulator SDK, not yet run on a device. `PairVoxLinkKit` is the iOS-ready wire library
- [x] Audit run 3 of the phone link and app: `docs/security/2026-10-13-audit-run-3-phone-link.md`
- [ ] Device testing with the microphone, background audio on a locked phone, Keychain for phone keys on the Mac, TestFlight

The Mac keeps running Claude Code; the phone is a voice front-end.

- **Companion:** a menu-bar mode of PairVox.app that hosts sessions headlessly.
- **Transport:** WebSocket over the LAN (Bonjour discovery) or Tailscale.
  - End-to-end encrypted (Noise or TLS with key pinning).
  - Paired by QR code.
- **Remote backend:** a `RemoteSessionBackend` implementing the existing `SessionBackend` protocol, carrying `SessionEvent`s and commands. The engine, planner and policy are reused unchanged.
- **Voice on the phone:** speech recognition and Kokoro run on-device; only text crosses the network.
- **iOS specifics:**
  - background audio, route changes (AirPods), call interruptions
  - lock-screen controls
  - push notifications for permission prompts
- **Approvals on the phone:** high-risk approvals need a tap with Face ID.

## Open questions

- Anthropic's terms for third-party tools using subscription logins may change. PairVox keeps the protocol layer behind `SessionBackend` so it can adapt (for example to an official SDK transport) without touching the voice code.
