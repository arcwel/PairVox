# Changelog

## Unreleased

- The "Pair this phone?" question is a regular window instead of a modal alert. The modal alert froze the whole app (phone link, command-line control, interface) until someone clicked. A newer request replaces one nobody answered, and an unanswered window withdraws itself after 150 seconds.
- A pairing code created with `pairvox-link` now expires on screen like one created in Settings.
- `pairvox-link-testhost`: a stand-in for the Mac side that auto-accepts pairing, for testing the phone app in the simulator. It is not part of the app.
- New app icon: an orange prompt chevron and three voice bars on near-black, flat colors, replacing the purple gradient. Eleven concepts and the generator are in `docs/icon-concepts/`; `scripts/make-app-icon.sh` turns any of them into the app's icon set.
- Talking over PairVox no longer makes it repeat itself. Speech now pauses in place when you start talking. If what you said turns out to be nothing (a cough, noise, an echo of its own voice) it carries on from the exact spot instead of discarding the sentence and reading it again. A bare "okay" does the same. Anything you mean for PairVox still stops it, as before. A stuck transcription cannot leave it paused: speech resumes after 12 seconds.
- While speech is paused, no new sentence is synthesized, so the transcriber has the GPU to itself. In the mic test, one decode took 4.8 s while speech was queued behind it.
- Long replies are read in part. After 15 sentences (Settings, Speech, Long replies: read everything, 10, 15 or 25) the rest is held and PairVox says "That's the first part. Say details to hear the rest." The full text stays on screen.

- Pairing: the phone now waits up to 130 seconds (it gave up after 15, before you could click Pair on the Mac) and shows that it is waiting. The phone confirms that it received its key; a Mac that gets no confirmation removes the phone again, so a failed attempt no longer leaves a phone on the list. The phone app must be updated together with the Mac app.

- Development builds no longer ask for Keychain access after every rebuild: phone keys live in a private file in builds without a team identity, and in the Keychain in signed builds. The app no longer reads the Keychain at launch, and the key store is read off the main thread.
- Screech recording: when the microphone hears a loud single tone while PairVox is speaking, the last ten seconds of microphone and playback audio are saved to the log folder (private files, newest ten kept, switch in Settings, Logs).
- New tools: `scripts/restart-app.sh` (swap in the last build and reopen), `pairvox-link doctor` (checks Tailscale, the forward and the link), and `docs/DEV_ENVIRONMENT.md` (notes on this Mac's build and signing quirks).
- `scripts/audio-report.py` reports echo cancellation as on or off with the reason, and lists captured screech recordings.

- Several projects at once with a project list, per-project sessions, catch-up controls and background silence; mini window and menu-bar-only mode.
- Folder-level approvals (edits, and a separate shell switch), each with a two-step confirmation, listed and removable in Settings.
- Plain-language request summaries and questions (a separate read-only advisor), "allow all" by voice, and an optional spoken confirmation for high-risk requests (off by default).
- Approval gate hardened after two security audits: commands classified by program and subcommand, full-command spoken prompts, read scope limits, protected settings, safer refusals. Reports in `docs/security/`.
- Settings: configurable hold-to-talk key, per-project overrides, optional start/finish sounds; File → Resume Earlier Session.
- Phone link (off by default): Mac host over Tailscale with QR or code pairing, encrypted frames and Mac-enforced approvals; `PairVoxLinkKit`; first iPhone app in `ios/`.
- Cross-project approvals: one inbox of every waiting request, a spoken heads-up at a break in the conversation, "approve", "deny", "tell me more" or "switch" answered in place for the request just announced, an approvals tray in the project list and menu bar, per-project mute, and the same inbox on the phone.
- Voice for high risk: separate off-by-default switches for high-risk requests (phrase plus the project name for another project) and for requests Claude Code marks as needing the screen (confirmed twice); optional Touch ID or password after the phrase on the Mac; the phone adds Face ID, Touch ID or the passcode.
- `pairvox-link` command-line tool (status, pair, phones list/remove) and a private control socket; phone keys on the Mac now live in the Keychain.
- Phone link setup guide `docs/PHONE_LINK_SETUP.md`: Tailscale access rule for TCP 47821, userspace Tailscale forward, troubleshooting.
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
