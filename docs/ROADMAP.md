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
