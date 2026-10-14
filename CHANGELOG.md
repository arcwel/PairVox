# Changelog

## Unreleased

- Several projects at once with a project list, per-project sessions, catch-up controls and background silence; mini window and menu-bar-only mode.
- Folder-level approvals (edits, and a separate shell switch), each with a two-step confirmation, listed and removable in Settings.
- Plain-language request summaries and questions (a separate read-only advisor), "allow all" by voice, and an optional spoken confirmation for high-risk requests (off by default).
- Approval gate hardened after two security audits: commands classified by program and subcommand, full-command spoken prompts, read scope limits, protected settings, safer refusals. Reports in `docs/security/`.
- Settings: configurable hold-to-talk key, per-project overrides, optional start/finish sounds; File → Resume Earlier Session.
- Phone link (off by default): Mac host over Tailscale with QR or code pairing, encrypted frames and Mac-enforced approvals; `PairVoxLinkKit`; first iPhone app in `ios/`.
- Specs: `docs/prd/pairvox-iphone-prd.md` and `docs/prd/cross-project-approvals-prd.md`.

## 0.1.0 (unreleased)

First public version.

- macOS app: hands-free or hold-to-talk voice conversation with Claude Code.
- Barge-in (interrupt by talking) on speakers or headphones, using voice-processing echo cancellation.
- Redirect: speaking while Claude works interrupts the turn (stdin `interrupt` control request) and sends the new instruction.
- Speech modes: full, skip code, summary (with "details" on request).
- Brainstorm (plan mode) and execute modes.
- Voice approvals for permission prompts, with a risk policy so destructive actions always need a click.
- Auth: your Claude subscription through your own Claude Code CLI login, or your own API key stored in the Keychain.
- WhisperKit speech recognition with Apple Speech fallback. Kokoro-82M voice with system-voice fallback; Kokoro model downloads are SHA-256 verified.
- `pairvox-cli` terminal front-end with latency metrics.
- Verified against Claude Code 2.1.296.
