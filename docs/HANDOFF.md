# PairVox handoff (for Claude Code)

_Last updated: 2026-10-13. Author of this handoff: the Claude session that built v0.1._

This document is everything the next agent needs to take PairVox from "code complete, engine verified" to "shipping macOS app". Read top to bottom once, then work the task list in §6 in order.

---

## 1. What PairVox is

A native macOS app (v1; iOS later) that gives Claude Code a live voice loop like ChatGPT Advanced Voice or Gemini Live:

- **Listening:** hands-free (voice-activity detection) or hold-to-talk (⌃⌥Space).
- **Barge-in:** speak while it talks and it stops instantly. Speak while Claude works and the turn is interrupted and redirected.
- **Streaming speech:** replies are spoken as they stream (the first sentence plays while Claude is still writing).
- **Speech modes:** **full** (reads code line by line), **skip code** (describes code), **summary** (reads only the opening summary; "details" reads the rest).
- **Brainstorm** (Claude Code plan mode, no file changes) or **execute** mode.
- **Voice approvals** for tool permissions, with a risk policy: destructive actions always need a click.
- **On-device speech:** WhisperKit, with Apple Speech as fallback. **On-device voice:** Kokoro-82M via MLX, with the macOS system voice as fallback.
- **Auth:** the user's own `claude` CLI login (Claude subscription, the default) or the user's own API key (Keychain).
- Apache-2.0, open source, no telemetry. Owner: Anthony Guidry (SCOAEONGEO). Repo: https://github.com/arcwel/PairVox

## 2. Decisions already made (don't relitigate without the owner)

| Decision | Choice |
|---|---|
| Platform | **macOS first** (macOS 15+, Apple Silicon). iOS is backlog (§9). |
| Name | **PairVox**. Trademark/domain checks not done yet (owner task). |
| License | **Apache-2.0** |
| TTS | **Kokoro** (kokoro-ios + MisakiSwift G2P, no espeak/GPL), system voice fallback |
| STT | **WhisperKit** primary, **Apple Speech** fallback |
| Auth | **Subscription via user's own CLI login** default; **API key** option built in so the project can move to API-based use |
| Integration | Spawn the user's unmodified `claude` CLI in headless stream-json mode. **Not** MCP (wrong tool for this), **not** piggybacking on the Claude apps (no extension surface), **not** the Agent SDK in-process (SDK docs say products should use API keys; also Python/TS only). |

### Auth: the policy constraint

From https://code.claude.com/docs/en/legal-and-compliance (checked 2026-10-12):

- Third-party developers may **not** offer Claude.ai login, route requests through Free/Pro/Max credentials on behalf of users, or collect, store or intermediate Claude.ai credentials or session tokens.
- An end user signing in to the **unmodified Claude Code binary** with their own subscription is explicitly allowed.

PairVox therefore never touches credentials. It launches the user's own CLI, which uses its own login, and strips `ANTHROPIC_API_KEY` and `ANTHROPIC_AUTH_TOKEN` in subscription mode so a stray env var can't override the login.

Gray area: the docs don't explicitly bless a third-party app spawning `claude -p` with subscription auth. Anthropic said in Feb 2026 that personal use isn't changing and that businesses should use API keys. Keep PairVox free, local and personal-use. **Owner action:** email Anthropic before a public launch.

## 3. Current status

| Area | Status |
|---|---|
| Engine (`PairVoxCore`) | ✅ Done and tested: ~82 unit tests pass on Linux (Swift 6.0, strict concurrency). |
| CLI (`pairvox-cli`) | ✅ Done. Run end-to-end twice against real Claude Code 2.1.296. |
| Voice layer (`PairVoxVoice`) | ✅ Compiles on macOS 27 / Xcode 27 (§4). Reviewed twice. 🟡 Not yet exercised with a real mic or speakers. |
| App (`PairVoxApp`) | ✅ Builds as a real `.app` via XcodeGen/Xcode (§4). 🟡 **Never launched or clicked through**: P0. |
| Packaging | ✅ `project.yml` builds. 🟡 `scripts/build-app.sh` (ad-hoc signing) and `scripts/release.sh` (notarization) are not run yet. |
| CI | 🟡 `.github/workflows/ci.yml` (Linux and macOS jobs) and `release.yml`. First run happens on push. |
| Docs | ✅ README, ARCHITECTURE, PROTOCOL, THREAT_MODEL, ROADMAP, CONTRIBUTING, SECURITY, NOTICE, THIRD_PARTY_LICENSES |

### Verified facts (live, Claude Code 2.1.296)

- **Interrupt:** stdin `{"type":"control_request","request_id":…,"request":{"subtype":"interrupt"}}` interrupts a running turn in **about 10 ms**. The session keeps its context, and the result is `error_during_execution` with `result: null`.
- **Permission prompts:** `--permission-prompt-tool stdio` delivers them as `control_request` `can_use_tool`. Answer with `control_response` (allow + `updatedInput`, or deny + `message`). Interrupting while a prompt is open produces a `control_cancel_request`.
- **Latency:** time to first token is **about 0.7 s on Haiku with a warm process**, and 5–6 s cold. The app launches the CLI when a project opens.
- **Re-sent messages:** `system/init` is re-sent every turn. Text arrives both as `stream_event` deltas and as a full `assistant` message; `EventTranslator` dedupes.
- Full protocol notes are in `docs/PROTOCOL.md`; the captured session is in `Tests/PairVoxCoreTests/Fixtures/`.

### Bugs already found and fixed (don't reintroduce)

- **Live runs:**
  - speech held forever after a spoken "yes"
  - "details" during streaming replayed one sentence and dropped the detail
  - summary mode leaked detail when a heading came without a blank line
  - "okay" or "yeah" while Claude worked interrupted the turn (now a backchannel)
  - latency metric mismatch
- **Review:**
  - `AudioIO.stop()` held a lock while `player.stop()` fired completions (deadlock)
  - `play()` on an engine the system had stopped (ObjC exception)
  - system voice could stall forever with no end marker (10 s timeout)
  - push-to-talk double-submit in hands-free mode
  - settings and engine echo loop
  - old session's `stopAll` cutting off the new session's audio
  - unsynchronized `choice` and `voice` fields
  - concurrent WhisperKit calls (now an `AsyncGate`)
  - Kokoro double download

## 4. First macOS compile result

`swift build --product pairvox-app` on the owner's Mac (macOS 27.0.1, Xcode 27.0, Swift 6.4, arm64):

**Result: ✅ it builds and runs.** Verified on the owner's Mac on 2026-10-13 (macOS 27.0.1, Xcode 27.0, Swift 6.4, Apple Silicon):

| Check | Result |
|---|---|
| `swift build --build-system native --product pairvox-app` | ✅ All targets compile with **0 errors**, including PairVoxVoice and PairVoxApp. About 30 warnings, all concurrency hygiene (see P2). |
| `swift test --build-system native` | ✅ **82/82 pass** on macOS |
| Xcode: `xcodegen generate`, then `xcodebuild -scheme PairVox` (unsigned Debug) | ✅ **BUILD SUCCEEDED**. The bundle contains `mlx-swift_Cmlx.bundle/.../default.metallib` (so Kokoro works) and KokoroSwift, MisakiSwift and MLX as embedded frameworks, plus the icon and Info.plist usage strings. |
| `pairvox-cli --model haiku` with the owner's **subscription login** | ✅ Real answer streamed. **First token 1.38 s, first utterance 1.48 s.** |
| GUI app launched | ❌ **Not yet**: nobody has clicked through it. This is the next task. |

Fixed to get here (already committed):
- **Exact dependency pins.** With `from:` ranges, SwiftPM resolved mlx-swift 0.32 and MLXUtilsLibrary 0.0.7, and KokoroSwift then failed with `no such module 'MLXFast'`. The pins are now kokoro-ios **1.0.11**, mlx-swift **0.30.2** and MLXUtilsLibrary **0.0.6** (Kokoro's own exact pins). `Package.resolved` is committed.

⚠️ **Build-system caveat.** SwiftPM's default (new) build system rejects the graph: `MLX … is linked as a static library by 'KokoroSwift-product' and 'MisakiSwift-product'`. Both upstream products are `.dynamic` and each embeds MLX.
- **Xcode** handles it by turning those products into shared frameworks, so the app build is fine.
- **Command-line SwiftPM** needs `--build-system native`, which is deprecated. CI and the Makefile now pass it on macOS.
- **Proper fix (P2):** upstream a change to kokoro-ios and MisakiSwift (drop `type: .dynamic` or depend on a shared MLX product), or fork-pin them.

## 5. Architecture in one screen

```
Mic → AudioIO (AVAudioEngine + voice processing/AEC, 16 kHz frames)
    → VoiceInputController (VAD, 350 ms pre-roll, push-to-talk)
    → FallbackTranscriber (WhisperKit ▸ Apple Speech) → text
    → ConversationEngine.submit()  [actor, PairVoxCore]
         ├ VoiceCommand.parse (local commands, yes/no, backchannels)
         ├ ClaudeCLISession (SessionBackend) ⇄ `claude -p … stream-json`
         ├ EventTranslator → SessionEvent
         ├ SpeechPlanner (MarkdownSpeechParser → SentenceChunker → Pronunciation; modes)
         └ PermissionPolicy (risk; voice-approvable?)
    → VoiceSpeechOutput (Kokoro ▸ system voice, synthesizes 2 ahead) → AudioIO player
UI: AppModel (@MainActor ObservableObject) observes EngineSnapshot (AsyncStream, newest-only).
```

Key files to read first, in this order:
1. `Sources/PairVoxCore/Conversation/ConversationEngine.swift`
2. `Sources/PairVoxCore/Session/ClaudeCLISession.swift`
3. `Sources/PairVoxCore/Speech/SpeechPlanner.swift`
4. `Sources/PairVoxApp/AppModel.swift`
5. `Sources/PairVoxVoice/AudioIO.swift`

`docs/ARCHITECTURE.md` has the long version, including how barge-in resolves.

## 6. Task list (do in order)

### P0: make it build and run

1. ~~Fix compile errors~~ ✅ Done (§4). `swift build --build-system native` and the Xcode build both succeed.
2. ~~Run tests on macOS~~ ✅ 82/82.
3. **Build the signed local app:** run `scripts/build-app.sh` (XcodeGen is already installed on the owner's Mac). Check that it prints "MLX Metal library embedded" and that `dist/PairVox.app` launches.
4. **Launch and walk the setup checklist:**
   - CLI detected
   - mic and speech permissions prompt (Info.plist usage strings)
   - WhisperKit model download progresses
   - Kokoro download is SHA-256 verified and the voice switches from system to Kokoro
5. **Get both CI jobs green on GitHub.** The macOS job runs `swift test --build-system native` and builds the XcodeGen project unsigned. Runner Xcode versions may lag Xcode 27; if the macOS job fails on toolchain, pin `xcode-version`.

### P1: manual QA (owner's Mac; record findings in an issue)

Use a scratch git repo as the project. Check each of these:
- [ ] Hands-free: ask "What does this project do?" The first audio arrives in under 2 s after you stop talking (warm session). Check the HUD in the control bar ("first audio").
- [ ] **Barge-in on laptop speakers:** while it talks, say "stop". It must stop within ~0.3 s and must **not** stop itself from its own echo. If it self-interrupts, tune `VoiceActivityDetector.Config.playbackPenaltyDB` (6 dB) and `startThresholdDB` (12 dB). Test with headphones too.
- [ ] Redirect: while Claude works, say a new instruction. The turn is interrupted (transcript shows "Interrupted") and the new one runs.
- [ ] Permission by voice: "create hello.txt with hi" → prompt spoken → "yeah go ahead" → file created and the reply is spoken.
- [ ] High risk: ask it to `rm -rf build` (create a `build` folder first). A spoken "yes" must be refused ("needs a click"); the on-screen Allow works.
- [ ] Modes: say "summary mode", ask a long question, then "details". Then "skip code" (code described) and "full mode" (code read).
- [ ] "brainstorm mode": ask it to change a file. It plans and doesn't edit (plan mode).
- [ ] Hold ⌃⌥Space from another app: push-to-talk works globally.
- [ ] Plug or unplug headphones mid-sentence: no crash, and audio continues on the new route. This exercises the `AudioIO` restart path.
- [ ] API-key mode: Settings → Account → API key. Session restarts; `claude` reports API-key usage (the transcript header shows the model).
- [ ] Not signed in: (temporarily, e.g. a fresh `HOME`) the setup sheet appears with "Open Terminal to Sign In".

### P2: known gaps and polish

- [ ] **Remove the need for `--build-system native`** (see the §4 caveat): upstream PRs to kokoro-ios and MisakiSwift, or vendored forks.
- [ ] **NSLock in async code:** `noasync` warnings in `VoiceStack.prepareKokoro`, `WhisperKitTranscriber.load` and `transcribe`, and `KokoroSynthesizer.synthesize`. Switch to `lock.withLock {}`.
- [ ] **`AudioIO.schedule` race:** a tiny window remains between the `engine.isRunning` check and `player.play()`. Consider routing all player calls through one serial queue.
- [ ] `VoiceInputController`: show **partial transcripts** while the user speaks (WhisperKit `AudioStreamTranscriber`) in the control bar.
- [ ] Release builds (`scripts/release.sh`) bump `CFBundleShortVersionString` with PlistBuddy, but `project.yml` also has `MARKETING_VERSION`; unify them.
- [ ] Per-project settings UI. `AppSettings.projectPreferences` already exists, with no UI.
- [ ] Configurable hotkey (`HotKeyCenter.register(keyCode:modifiers:)` already takes parameters).
- [ ] Session picker / resume. `LaunchConfiguration.resumeSessionID` already exists.
- [ ] Earcons for "Claude started" and "Claude finished".
- [ ] Sparkle updates.
- [ ] Optional Silero VAD (MIT, Core ML) as a second stage for noisy rooms.

### P3: launch

- [ ] **Owner:** name, trademark and domain checks for "PairVox"; Developer ID certificate; notary credentials; repository secrets listed at the top of `release.yml`.
- [ ] Tag `v0.1.0` and let the release workflow build, sign, notarize and publish the DMG. Then fill in `packaging/homebrew/pairvox.rb` (owner tap).
- [ ] **Owner:** email Anthropic about the subscription-auth use case (§2).

## 7. Gotchas

- **Kokoro needs Metal shaders.** Plain `swift build`/`swift run` doesn't compile MLX's `.metal` files. `MLXRuntime.metalLibraryAvailable()` detects that, and the app falls back to the system voice instead of trapping. Use Xcode, `make app` or `make xcode` to hear Kokoro.
- **Kokoro's loader traps on a bad file** (`try!` in `WeightLoader`). That's why `ModelStore` pins SHA-256 for both files and verifies before loading. Don't skip verification.
- **Dependency pins:** kokoro-ios ≥1.0.10 pins `mlx-swift` exactly (0.30.x) and `MLXUtilsLibrary` 0.0.6. Don't raise MLXUtilsLibrary to 0.0.7 (needs newer mlx, and removes `BenchmarkTimer` that Kokoro uses). WhisperKit's GitHub repo was renamed (`argmax-oss-swift`); the old URL redirects.
- **The app is not sandboxed,** by design: it spawns the user's CLI. That rules out the Mac App Store; distribute a notarized DMG and Homebrew cask.
- **GUI apps don't get the shell PATH.** `ShellEnvironment.loginShellEnvironment()` runs the login shell to get it, and `ClaudeLocator` checks the usual install paths (`~/.claude/local`, `~/.local/bin`, Homebrew, npm).
- **Two places compile the app sources:** the SwiftPM dev target `pairvox-app` (embeds Info.plist via `-sectcreate`, so mic permission works with `swift run`) and the XcodeGen target. Keep both building.
- **Interrupted results:** `EventTranslator` treats `error_during_execution` with null result and `[ede_diagnostic]`-only errors as interrupted. `interruptPending` is the primary signal.
- **Swift modes:** Core is Swift 6 strict concurrency; Voice and App are Swift 5 mode. Keep platform-independent logic in Core so it's tested on Linux.

## 8. How to verify changes

- `swift test`, always.
- **Protocol changes:** capture a fresh session with `swift run pairvox-cli --raw-log /tmp/s.jsonl --model haiku`. Sanitize the paths (see how `claude-2.1.296-session.jsonl` was sanitized), add it as a fixture, and add a replay test.
- **Speech-pipeline changes:** add cases to `SpeechTests.swift`, including the char-by-char streaming equivalence.
- **Engine behavior:** add to `EngineTests.swift` using `FakeBackend` and `FakeOutput`.
- **Audio changes:** manual QA (§6 P1); there is no automated audio test.

## 9. iOS (backlog, design ready)

The Mac app becomes a session host. The iPhone runs WhisperKit and Kokoro locally and talks to the Mac over WebSocket:
- Bonjour or Tailscale
- end-to-end encrypted, paired by QR code
- `RemoteSessionBackend` implements the existing `SessionBackend`, so the engine is reused unchanged.
- High-risk approvals need Face ID.

Details are in `docs/ROADMAP.md`.

## 10. Repo conventions

- SPDX header `// SPDX-License-Identifier: Apache-2.0` on every source file.
- Small commits with descriptive messages. CI must be green before merging.
- Planning docs the owner keeps outside the repo: the "Claude Voice" project plan (`claude-code-voice-plan.md`).
