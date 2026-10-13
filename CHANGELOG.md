# Changelog

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
