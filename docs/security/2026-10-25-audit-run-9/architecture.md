# PairVox architecture summary (audit run 9, quick profile)

## 1. Product, principals, protected resources
PairVox is a single-owner macOS app that puts a voice loop around the owner's own `claude` CLI, plus an iPhone companion that connects over Tailscale (docs/ARCHITECTURE.md, docs/THREAT_MODEL.md:5-17). Protected resources: the owner's source tree and machine (Claude edits files and runs shell commands once a `can_use_tool` request is approved), the Claude login or API key, the per-phone link keys, and room audio.

Principals, lowest trust first:
- **Unpaired network peer** that can reach TCP 47821 (tailnet address, or loopback). It can send pre-auth frames and attempt pairing with the 16-byte QR secret (Sources/PairVoxLink/LinkHost.swift:257 `serve`, Pairing.swift).
- **Model output and repository content** shaping `can_use_tool` requests from the `claude` child (Sources/PairVoxCore/Protocol, Policy/PermissionPolicy.swift).
- **Anyone audible to the Mac microphone**: no speaker verification; spoken yes/no answers voice-approvable requests (Sources/PairVoxCore/Conversation/ConversationEngine.swift).
- **Paired phone** (holds a 32-byte PSK): submits text to Claude, interrupts, switches projects, approves or denies requests it was shown (LinkHost.swift:372-460).
- **Same-UID local process**: can use the 0600 control socket (`status`, `devices`, `remove`, `offer`) (Sources/PairVoxLink/LinkCommands.swift:55-127) and read Application Support files.
- **Owner at the Mac**: clicks Pair, approves anything.

## 2. Comparable baseline
The child wire format is Claude Code's own stream-json with `--permission-prompt-tool stdio` (docs/PROTOCOL.md). The phone link is a custom PSK protocol (HMAC proofs, HKDF, ChaCha20-Poly1305 with strict sequence numbers), not Noise or TLS.

## 3. Stack and execution limits
Swift 6 (Core) and Swift 5 mode (App, Voice), SwiftPM plus XcodeGen (project.yml, ios/project.yml). The Mac app is not sandboxed and has the audio-input and Apple Events entitlements. Dependencies are exact-pinned (Package.resolved). Kokoro and Whisper models are downloaded at runtime with SHA-256 pins (Sources/PairVoxVoice/ModelStore.swift, WhisperPins.swift). **This run executes no target code**: macOS cannot enforce a memory or process limit for target code and no local Linux Swift image exists, so every check is source-only.

## 4. Entry surfaces and key paths
- Phone link: TCP accept → peer-address filter (TailnetAddress.swift:13-23; loopback always passes) → pre-auth caps (3 per peer, 8 total, 10 s; LinkHost.swift:121-126, 259-266) → pairing (`redeem`, owner click via PairConfirmationPanel, PSK sealed to the phone, ACK in 10 s) or handshake (LinkCrypto.swift:68-89) → authenticated frames → `submitFromRemote`, `approve`, `spokenAnswer`, `switchProject` (LinkHost.swift:372-460, EngineLink.swift, Sources/PairVoxApp/Support/PhoneLinkModel.swift).
- Child: `can_use_tool` → `PermissionPolicy.assess` / `BashRisk` → FolderGrants / auto-approve → voice, click or phone answer → `approvePending(requestID:)`.
- Spoken input: transcript → spoken-answer parser → approval, denial or feedback; voice commands; folder-grant offers needing "confirm"; advisor text spoken aloud.
- Child launch: settings, project folder, `ClaudeLocator` path trust (ClaudeLocator.swift:49-63), `ChildEnvironment` deny-list (Session/ChildEnvironment.swift:30-47), `--setting-sources user` unless the owner trusts project config (LaunchConfiguration.swift:76), API key from Keychain into the child env only in API-key mode.
- Local files: settings.json (consents zeroed if not owner-private, Settings.swift:270-304), paired-phones.json, phone-keys.json (0600, development builds), logs, screech recordings, diagnostics bundles.
- iPhone: `pairvox://pair?h=&p=&s=` link or QR, Keychain-held PSK (PhoneCredentials.swift:34-101), Face ID before a tap approval (ios/PairVoxPhone/PhoneModel.swift:398-441).
- CI and release: .github/workflows/ci.yml and release.yml (actions pinned by SHA, `swift:6.0` container by tag), scripts/build-app.sh, release.sh, make-appcast.sh, restart-app.sh, packaging/homebrew.

## 5. Trust boundaries and strongest control
| Boundary | Strongest source-visible control |
|---|---|
| Network peer → paired session | QR secret (single use, 120 s, failure caps) + owner Pair click + PSK handshake; revocation re-checked per frame |
| Paired phone → approval | `LinkHost.approvalRefusal` (request must be shown on that connection, not truncated; voice path checks risk and age). `.tap` skips the risk checks and the `auth` field is phone-asserted (LinkMessages.swift ~75-77) |
| Model / repo → tool execution | PermissionPolicy risk rating; `.approve` guard keeps high-risk requests off voice; default case (MCP and other tools) is medium and voice-approvable (PermissionPolicy.swift:140-144) |
| Room audio → approval | Approval-word parser, 300 s staleness, high-risk needs a click unless the owner enables spoken confirmation |
| Repo → child configuration | `--setting-sources user` by default |
| Same-UID process → link | Socket 0600 + `getpeereid` UID check; pairing still needs the Pair click |
| Downloads → model load | SHA-256 and size pins checked after download and on load |

## 6. Starting paths
Sources/PairVoxLink, Sources/PairVoxLinkKit, Sources/PairVoxCore/{Policy,Conversation,Protocol,Session,Config,Advisor,Diagnostics}, Sources/PairVoxApp/{AppModel.swift,ProjectSession.swift,Support}, Sources/PairVoxVoice/{ModelStore,WhisperModelStore,WhisperPins,FeedbackCatcher}.swift, ios/PairVoxPhone, .github/workflows, scripts, packaging.

## 7. Prior coverage
Runs 2 to 5 (docs/security/2026-10-13-*, 2026-10-14-*) and docs/audits/2026-10-16-phone-link-and-tools-audit.md left prose reports only, with no compatible coverage-ledger.json or findings.json. Nothing is carried as a same-source confirmation; every unit is current work. Hardening backlog rows still open include 1.6, 1.7, 1.8 (approval gate), 3.3 (risky phone approvals need a Mac check), 3.7, 3.9, 3.10 (link), 4.7 to 4.9 (session and logging).

## 8. Companion selection
Selected: PROTOCOLS-RPC-AND-MESSAGING (custom link protocol and phone RPC), AI-AND-LLM (model-driven tool requests and spoken output), DESKTOP-MOBILE-AND-LOCAL-IPC (control socket, iPhone pairing link and app state), RESOURCE-EXHAUSTION-AND-AVAILABILITY (pre-auth listener), DATA-ISOLATION-AND-LIFECYCLE (logs, recordings, key files, revocation), SUPPLY-CHAIN-AND-RELEASE (model downloads, CI, release). Not selected: WEB-PROTOCOL-AND-AUTH and CLIENT-SIDE (no HTTP or browser surface), CLOUD-AND-DEPLOYMENT (no cloud deployment), MEMORY-SAFETY-AND-BINARY (no unsafe parsing found on input paths).

## 9. This run (audit run 9, pre-release of 0.1.0-beta.2)
Scoped to the code changed between `de91222` (what run 8 reviewed) and `a3e5940`. Read-only snapshot at /Users/anthonyguidry/security-audit-skill/PairVox/run-4/src; the original repository for `git diff de91222 a3e5940` is /Users/anthonyguidry/HD Projects/PairVox (read-only to you). What changed:
- **Run 8's fixes, never reviewed by a hunter** (commit 34b17fa): lock-screen Allow only for a request shown whole and voice-approvable (`RequestNotice.allowsLockScreenAnswer`, `DeviceAuth.notification`, `LinkHost.approvalRefusal`, `ios/PairVoxPhone/PhoneModel.swift answerFromNotification`); prompt bookkeeping in `ConversationEngine` (`pendingPromptIDs`, `speakPrompt`, `dropUnplayedPrompts`, the echo check for notices and every spoken approval, `isOwnPromptEcho` before the cross-project interceptor); `BashRisk` nested-shell (`nestedShellBody`, depth 3) and `ps e` rules; `RepoVocabulary.termPattern` anchoring; installer environment filter and team-ID check (`scripts/pv-install.sh`, `AppModel.installLatestBuild`), `scripts/restart-app.sh` own-user process match; `HealthModel` error cap.
- **Folder access offer** (commit 8e9222c): a spoken or typed yes no longer grants a folder unless `spokenHighRiskConfirmation` is on; then yes and confirm each need prompt timing, the echo check, a five-minute age limit (`GrantOffer.askedAt`, `isStale`) and the optional Touch ID second confirmation (`answerGrantOfferBySpeech`, `finishGrantConfirmation`).
- **Microphone sleep** (b013182): `MicHibernation` (Core) and `AppModel.checkMicSleep`/`putMicToSleep`/`wakeMicrophone`, a 5-second timer; asleep means `listeningMode = .muted`; push-to-talk wakes it; `PAIRVOX_START_MIC_ASLEEP=1` starts asleep. Settings `micSleepMinutes`. The intended control: a sleeping microphone hears nothing until the owner turns it on.
- **Release tooling**: `scripts/release-assets.sh` (builds DMG and unsigned .ipa, copies reports, writes SHA256SUMS; never uploads) and `pairvox-link-testhost` (loopback-only stand-in host, development tool).
Runs 6 to 8 (docs/security/2026-10-24-audit-run-6/, -7/, 2026-10-25-audit-run-8/) cover the rest; run 8's needs_validation records are current work here because their source changed. The repository is public.
