# PairVox for iPhone: PRD

| Field | Value |
|-------|-------|
| Status | Council reviewed, awaiting owner confirmation of open questions |
| Owner | Anthony Guidry |
| Date | 2026-10-13 |
| Version | 0.1 |

## 1. Summary
An iPhone app that talks to the PairVox Mac app over Tailscale. The Mac keeps running Claude Code and enforces every permission rule. The phone is the voice: it hears the person through earbuds, speaks Claude's replies, shows the transcript and approvals, and sends text and decisions back. First use is talking to a session that is already running on the Mac. The audience is the owner now and a few TestFlight testers later.

## 2. Problem
- **Who:** developers who already use PairVox on a Mac and want to keep a session going while away from the desk (walking, cooking, driving a short errand).
- **Pain:** a session needs a decision (an approval, a redirect) when the person is not at the Mac. Claude stalls until they return.
- **Current alternatives:** none that speak. Claude Code's own mobile options are text and run elsewhere; PairVox's Mac app needs the desk.
- **Evidence:** owner's stated need (roadmap v0.3). No user research yet (assumed).

## 3. Goals & Success Metrics
| Goal | Metric | Target | Timeframe |
|------|--------|--------|-----------|
| Hands-free session away from the Mac | Time from "Claude asked" to answered on the phone | under 15 s median | first TestFlight build |
| Nothing weaker than the Mac | Permission requests approved on the phone that the Mac would not allow by voice | 0 | always |
| Reliable link | Reconnect after phone sleep or network change | under 5 s, no lost request | first TestFlight build |
| Private | Bytes of audio leaving the phone | 0 | always |

North-star metric: sessions the owner steers from the phone for 10 minutes or more without touching the Mac.

## 4. Non-Goals
- Running Claude Code on the phone.
- Starting or switching projects from the phone (later).
- A public App Store launch (later, if at all).
- Android or web clients.
- Sending audio to the Mac or any server.

## 5. Users & Journeys
Persona: the owner, a developer with a Mac running PairVox and a phone with earbuds. Testers: two or three trusted developers.

Critical journey: the owner starts a task on the Mac, leaves, puts in earbuds, opens PairVox on the phone (already paired), hears "Claude is working on the login fix", says "tell it to skip the tests", hears an approval prompt for a file edit, says "yes", and later hears the summary. That moment, an approval answered from the street, is the "worth it" moment.

Pairing journey: the Mac shows a QR code (or a six-digit code); the phone scans or types it once; the Mac lists the phone and can revoke it.

## 6. Scope
### MVP (v1)
| # | Feature / job | Priority | Acceptance criteria |
|---|---------------|----------|---------------------|
| 1 | Pair by QR or six-digit code | P0 | One scan or code pairs a phone; code expires in 2 minutes and works once; Mac lists paired phones and revokes one; revoked phone is refused at the next connection |
| 2 | Encrypted connection over Tailscale | P0 | Every frame is encrypted and authenticated with the pairing key even though the tailnet is trusted; a different device on the tailnet cannot connect |
| 3 | Live transcript and replies | P0 | Phone shows the active project's transcript within 1 s of the Mac; reconnect replays missed events |
| 4 | Spoken replies on the phone | P0 | Replies are spoken on the phone with the same speech modes as the Mac; barge-in works |
| 5 | Voice input on the phone | P0 | On-device speech recognition; text sent to the Mac; typed input also works |
| 6 | Approvals with the Mac's rules | P0 | The Mac assesses each request and tells the phone what may be answered by voice; high-risk requests are click-only on the phone too; the phone cannot raise a request's voice-approvable flag |
| 7 | Background audio and lock-screen controls | P0 | Keeps listening and speaking with earbuds while locked; stop and mute from the lock screen |
| 8 | Disconnect behavior | P0 | A request pending when the phone drops stays pending; it is never auto-approved or denied; the Mac can still answer it. After 5 minutes it is re-presented on reconnect with its age, and needs a fresh answer |
| 9 | Mac companion mode | P0 | The Mac app hosts the link headlessly (menu-bar mode); one phone drives the active project |
| 10 | Notifications | P1 | Local push when Claude needs a decision and the app is in the background (via the open connection); remote push is later |
### Later
Start and switch projects from the phone; several phones; remote push when the connection is down (needs a relay); App Store release.

## 7. UX Requirements
- Onboarding: scan the QR from the Mac; microphone and speech permissions explained before the system prompts.
- States: not paired, connecting, connected, Mac asleep or unreachable (say so in words, offer retry), session idle, working, waiting for a decision.
- Accessibility: WCAG 2.2 AA contrast, Dynamic Type, VoiceOver labels on every control, 44 pt targets.
- Trust: the approval card shows the full command and reasons, as on the Mac; high-risk is labeled and needs a tap.
- Recovery: unpair and re-pair from either side.

## 8. UI & Brand
iOS SwiftUI. Follows the Mac app's look and the house UI rules: sharp corners, flat cards, one accent, left-aligned, dense, no gradients, mono plus a distinct display font. Light and dark.

## 9. Technical Approach
- **Architecture:** the Mac runs the existing ConversationEngine and PermissionPolicy and exposes a host service. The phone connects as a remote front-end. Events flow Mac to phone (`EngineSnapshot` deltas, utterances to speak, pending requests with their assessment); commands flow phone to Mac (text, approve or deny with the request ID, interrupt, mute). The phone does not run the engine or the policy. This differs from the roadmap's `RemoteSessionBackend` sketch, which put the engine on the phone; it is kept on the Mac so that the gate lives in one place.
- **Stack:** Swift 6, SwiftUI for iOS 18, a shared Swift package for the wire types (extracted from PairVoxCore), Network.framework with TLS-PSK or Noise over TCP via the tailnet address, WhisperKit and Kokoro on-device, AVAudioSession `.playAndRecord` with `.allowBluetoothHFP`.
- **Data model:** PairedDevice (id, name, public key, createdAt, revoked), Frame (version, sequence, type, payload), replay window of recent events per project.
- **Integrations:** Tailscale (user-installed, not bundled); Keychain on both sides.
- **AI/LLM:** none new. The advisor stays on the Mac.
- **Security & privacy:** key pinning from the pairing exchange; per-frame AEAD; sequence numbers and a replay window; pairing code single use and short lived; revoke list checked on connect; the Mac refuses unknown devices without prompting; no audio over the link; transcripts over the link are the same text the Mac already holds. Approval commands carry a request ID and are rechecked by the Mac against its own queue and policy. Pairing is shown on the Mac only.
- **Scale & performance budgets:** one phone, one active project; under 1 s event latency on a normal tailnet; under 100 KB/s average.
- **Build vs. buy:** use Network.framework and a known handshake (Noise_XX via swift-noise or TLS 1.3 PSK) rather than designing a protocol; avoid a relay for v1.
- **Testing, observability, CI/CD, rollback:** protocol tests with a fake transport (Core), fuzz the frame parser, a loopback integration test of pair, connect, approve and replay; diagnostics log link state without content; TestFlight builds only from tags on main, with the same signing separation as the Mac release.

## 10. Business Model
None for v1 (personal tool with testers). Cost: Apple Developer Program fee for TestFlight (assumed already available or to be bought). No server cost because there is no relay.

## 11. Go-to-Market
N/A for v1: owner use and a handful of testers. Revisit if the Mac app is released publicly.

## 12. Competitive Landscape
| Alternative | Strength | Weakness | Our angle |
|-------------|----------|----------|-----------|
| Claude mobile app / Claude Code on the web | Official, no Mac needed | Not voice-first for local sessions, cannot drive the Mac session | Drives the Mac session already running, with local files and tools |
| Remote-control tools (SSH, Tailscale + terminal) | Full control | No voice, poor on a phone, no approval guardrails | Voice plus the same risk gate |
| Dictation into a chat app | Easy | No link to the running session | Direct |

## 13. Risks & Mitigations
| Risk | Likelihood | Impact | Early signal | Mitigation |
|------|------------|--------|--------------|------------|
| A stolen or lent unlocked phone approves actions | Medium | High | Unexpected approvals in the Mac log | High-risk needs Face ID and a tap; revoke from the Mac; approvals logged with the device name |
| Anyone on the tailnet reaches the host | Medium | High | Unknown connection attempts | Pairing key required for every frame; reject silently; rate limit |
| Own speech or ambient audio approves a request | Medium | Medium | Approvals without a clear user utterance | Same filters as the Mac plus the tap for high risk; earbuds recommended |
| Background audio is rejected or killed by iOS | Medium | Medium | Session dies when locked | Prototype early with a real device; fall back to foreground-only |
| Protocol bugs allow replay or downgrade | Low | High | Fuzz failures | Versioned handshake, no fallback to plaintext, AEAD, replay window |
| Bluetooth headset call-mode audio quality | High | Low | Complaints about sound | Fix in the product, do not tell users to avoid Bluetooth |
| Mac sleeps | High | Medium | Phone cannot connect | Companion mode keeps the Mac awake while a phone is paired and a session is open; say "Mac is asleep" plainly |
Kill / pivot criteria: if background audio cannot stay alive on a locked iPhone in two prototype attempts, ship foreground-only and reconsider.

## 14. Milestones
| Milestone | Scope | Target date |
|-----------|-------|-------------|
| M0 Mac host module, pairing, encrypted frames, CLI test client (no phone, no mic) | Shared package, frame format, handshake, replay, fuzz | TBD |
| M0.5 Locked-phone background-audio prototype | Real device, 10 minutes locked | TBD |
| M1 Mac companion | Menu-bar host, pairing UI with accept click, revoke | TBD |
| M2 Phone shell | Pair, connect, transcript, typed input, approvals | TBD |
| M3 Voice | On-device recognition and speech, barge-in, background audio | TBD |
| M4 Hardening and TestFlight | Security audit of the link, lock-screen controls, notifications | TBD |

## 15. Assumptions
- Tailscale is installed and signed in on both devices (the owner already uses it).
- The owner has or will buy an Apple Developer team for TestFlight (not confirmed; HazzMate rulings say no paid team until told).
- Approvals use the Mac's rules (owner chose "same rules as the Mac"). High-risk requests on the phone need a deliberate tap; Face ID, Touch ID, the device passcode or a plain tap all count (owner ruling, 2026-10-13). The phone reports which it used and the Mac logs it.
- Engine stays on the Mac (technical decision by the author).
- Pairing offers both QR and six-digit code (owner chose both).
- A disconnected phone holds requests rather than denying them (suggestion accepted by the owner).
- Local notification only while connected; no relay.

## 16. Open Questions
| Question | Owner | Needed by |
|----------|-------|-----------|
| Is there a paid Apple team for TestFlight, and which Apple ID? | Anthony | M4 |
| ~~Face ID on high-risk~~ Decided: Face ID, Touch ID, passcode or tap | Anthony | done |
| Should the Mac keep itself awake while paired, or only while a session is open? | Anthony | M1 |
| Noise_XX or TLS 1.3 PSK for the link? | Engineering | M0 |

## Council Deliberation
### Phase 1: Assessments
- **Contrarian** (§6.6, §13): The phone is a remote approver for a tool that runs shell commands. A lent or stolen unlocked phone, or a paired phone left in a bag with "yes" heard from a podcast, is the new attack surface. §6.8 says a pending request survives a disconnect, but nothing says what happens when the phone reconnects hours later: a stale request approved by reflex. Tailnet trust is weak: any device on a shared tailnet can reach the port.
- **First-Principles** (§9): The real constraint is that two things must never leave the Mac: the permission decision and the audio. The phone needs only text in, text out, and a way to say "yes to request R". Keeping the engine on the Mac is correct. A custom protocol is not required: authenticated, encrypted frames over one TCP stream suffice, and Noise_XX with a pinned key from the pairing step is the smallest design that does not trust the network.
- **Expansionist** (§6, §14): Once the host service exists, the same link carries a watch app, CarPlay-style audio, or a second Mac. But the biggest leverage is cheap: the host service makes PairVox testable without the microphone (the owner's Mac has none), because a phone or a test client can drive the engine.
- **Outsider** (§1, §5): It is unclear why the phone must speak at all rather than just notify. The pitch only holds if background audio works on a locked phone; that single iOS capability decides whether the product is "voice" or "a text client with notifications". Everything else in the scope list is ordinary.
- **Executor** (§14, §15): Milestones have no dates and the Apple team is unconfirmed (HazzMate rulings say no paid team). On-device Whisper plus Kokoro on an iPhone is the heavy part; the MLX Kokoro path used on the Mac may not run on iOS as-is. The Mac currently has no headless "host" mode; the engine is wired to AppModel. The first milestone should therefore be Mac-side: extract the host.

### Phase 2: Peer review
- The Contrarian's stale-request concern is correct and under-specified; the Executor's point that Face ID is only an assumption in §15 is correct and should be decided now, since it changes the approval flow.
- The Outsider overstates "notify only": the owner explicitly chose voice and earbuds, so the test is the background-audio prototype, not removing voice.
- The Expansionist's watch and CarPlay ideas are noise for v1; only the test-client benefit is real and cheap.
- The Executor underestimates the protocol risk: fuzzing and replay design are on the critical path for a link that can approve shell commands.
- First-Principles claims Noise is the smallest design; TLS 1.3 PSK is equally small with Network.framework support and fewer third-party dependencies. The choice should be made by what Apple's framework supports without a new dependency.

### Phase 3: Decision matrix
| Option | Feasibility and effort | Risk | Upside | Key assumptions |
|---|---|---|---|---|
| A. Engine on Mac, phone as remote front-end (PRD) | Medium; needs a headless host | Lowest: one gate | High; also enables testing without a mic | Background audio works; Tailscale present |
| B. Engine on phone, remote SessionBackend (old roadmap) | High; policy duplicated | High: gate on an unlocked phone | Medium | Phone always online |
| C. Notifications only, no voice | Low | Low | Low | Owner would accept it (he chose voice) |
| D. Phone streams audio to Mac | Medium | Medium: privacy, bandwidth | Medium | Good link |

### Phase 4: Chairman's verdict
**Verdict:** Go on option A, with changes to the PRD before M1.
**Core rationale:** it keeps the permission gate and the audio decisions in one place, matches the owner's answers, and the Mac-side host is independently valuable. The decisive unknown is iOS background audio on a locked phone, so it is tested first, before the protocol.
**Required changes (folded into the PRD):**
1. Add a stale-request rule: a request older than 5 minutes when the phone reconnects is re-presented with its age and needs an explicit new answer; spoken "yes" does not answer a request the phone has not just re-read aloud.
2. Decide Face ID now: required for high-risk on the phone (a safety floor above the Mac's click), because a phone is the device most likely to be unlocked and handed over.
3. Add a prototype milestone M0.5 for locked-phone background audio before any protocol work.
4. Pairing: reject pairing codes on a tailnet address that is not the Mac's own interface; show the phone's name on the Mac and require a click on the Mac to accept every new pairing.
5. Protocol choice defaults to TLS 1.3 with a pre-shared key from pairing (no new dependency) unless Noise is shown to be needed.
6. The first deliverable is the Mac host plus a command-line test client, so the link can be built and tested with no phone and no microphone.
**The Final Move:** extract the engine-facing host into a `PairVoxHost` module with a loopback test client, with pairing and an encrypted frame format, and show a test that pairs, connects, approves a low-risk request, and is refused when revoked. Success: that test passes in CI with no audio hardware.


## Revision Log
| Date | Change | Reason |
|------|--------|--------|
| 2026-10-13 | v0.1 drafted after two interview rounds | Start of v0.3 |
| 2026-10-13 | M0 built (Sources/PairVoxLink, 11 tests incl. real-socket loopback) | Council's final move |
| 2026-10-13 | v0.2: stale-request rule, Face ID decided, background-audio prototype first, Mac-click pairing, TLS-PSK default, Mac host plus CLI test client first | Council verdict |
