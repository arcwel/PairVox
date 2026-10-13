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
- [ ] Per-project settings UI (overrides already exist in `ProjectPreferences`)
- [ ] Configurable hold-to-talk shortcut
- [ ] A speech "earcon" when Claude starts working or finishes
- [ ] Session picker (resume earlier Claude Code sessions by ID)
- [ ] Sparkle auto-updates

## v0.2b: access control and multi-project (planned)

Added 2026-10-13. These build on the security audit in `docs/security/2026-10-13-phase1-hardening.md`; the audit leads named below should be settled first or alongside.

### Mini mode and menu bar

- [ ] A small always-on-top mini window that shows only that voice is active (listening, thinking, speaking) and offers mute and stop.
- [ ] A menu-bar-only mode with the same status and controls, no main window. The v0.3 companion reuses it.

### Approvals you can understand and question

- [ ] **Approve all** for the prompts currently waiting, in one action, with the list shown first.
- [ ] **Plain-language summary** of every request ("Claude wants to rename 3 files in `src/`") shown and spoken in place of the raw command. The exact command stays one tap away.
  - The summary must be derived from the normalized tool input, never from Claude's own `description` field (audit lead: spoken prompt uses model description).
  - The card must show the full command, not a 6-line cut-off.
- [ ] **Ask before you approve.** While a request is pending, the user can ask questions about it ("what other files does this affect?", "could this delete files in the folder later?") and get an answer before deciding.
  - Answers come from a read-only side query that sees the pending request and the project, and cannot run tools or change the pending request.
  - An answer is advice only; the approval still has to come from the user.
- [ ] Approvals bound to a request ID, with a queue instead of one pending slot (audit lead: pending slot overwritten).

### Folder-level approvals

- [ ] Prompt once per project: "This project works in `~/Documents/project/x`. Allow Claude to edit all files within it?" Granting skips the per-request prompt for edits inside that folder and passes them straight to Claude.
- [ ] **Double confirmation** to grant, with the exact folder path and what is and is not covered.
- [ ] Grants listed in Settings, each removable, with when it was granted.
- [ ] Scope limits, decided with the audit in mind:
  - covers file edits inside the resolved folder only (symlinks resolved), not shell commands, network, or other folders
  - high-risk requests still need a click
  - grants are stored by resolved path, are not shared across projects, and never come from repo-supplied config (audit lead: repo config bypass)

### Multiple projects at once

- [ ] Several projects open in one window, with a side menu of projects instead of one project per window.
- [ ] Each project keeps its own session, mode, permission state and transcript.
- [ ] **Switching with updates waiting.** If Claude has output in another project, the side menu marks it, and on switching the user gets audio controls: play from the first missed message, play the last message only, or skip. Choosing one makes that project the active conversation, and voice input goes to it.
- [ ] Background projects do not speak on their own. They queue and notify.

## v0.3: iPhone client

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
