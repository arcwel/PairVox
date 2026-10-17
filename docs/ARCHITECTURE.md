# Architecture

```
 ┌──────────────── PairVox.app (macOS) ─────────────────────────────────────────┐
 │                                                                               │
 │  Mic ─▶ AudioIO (AVAudioEngine + voice processing / AEC) ─▶ 16 kHz frames    │
 │            │                                                    │            │
 │            │ playback                                           ▼            │
 │            │                                   VoiceInputController          │
 │            │                                   (VAD, pre-roll, push-to-talk) │
 │            │                                                    │ samples    │
 │            │                                   FallbackTranscriber           │
 │            │                                   (WhisperKit ▸ Apple Speech)   │
 │            │                                                    │ text       │
 │            ▼                                                    ▼            │
 │  VoiceSpeechOutput ◀── utterances ── ConversationEngine (PairVoxCore) ──┐    │
 │  (Kokoro ▸ system voice,              • voice commands, barge-in        │    │
 │   pipelined synthesis)                • SpeechPlanner (modes)           │    │
 │                                       • PermissionPolicy                │    │
 │                                                    │ SessionBackend     │    │
 └────────────────────────────────────────────────────┼────────────────────┼────┘
                                                      ▼                    │
                              ClaudeCLISession: the user's own `claude` CLI
                              claude -p --input-format stream-json
                                        --output-format stream-json
                                        --include-partial-messages
                                        --permission-prompt-tool stdio
```

## Modules

**PairVoxCore**: pure Swift and Foundation. Builds and tests on Linux.

- `Protocol/`: the stream-json wire format (`InboundMessage`, `OutboundMessage`, `LineBuffer`, `JSONValue`). See [PROTOCOL.md](PROTOCOL.md).
- `Session/`
  - `ClaudeCLISession` spawns and drives the CLI, auto-resumes after a crash, and answers unsupported control requests so the CLI never hangs.
  - `EventTranslator` turns raw messages into `SessionEvent`s. Each piece of text is emitted once, even though Claude Code sends it both as deltas and as a full message.
  - `LaunchConfiguration` builds arguments and environment per auth mode.
- `Speech/`
  - `MarkdownSpeechParser` strips markdown incrementally, mid-line, as text streams in.
  - `SentenceChunker` cuts sentence-sized TTS chunks. The first chunk takes a fast path for latency.
  - `Pronunciation` handles file names, identifiers, URLs, versions and symbols.
  - `CodeReader` and `ToolNarrator` describe code and tool use.
  - `SpeechPlanner` applies the speech mode.
- `Policy/`
  - `PermissionPolicy` classifies each permission request by program and subcommand (`BashRisk`), decides what voice may approve, builds the spoken prompt (every step of a compound command, or screen-only), and limits auto-approve to read-only tools inside the project. High-risk requests need a click unless the owner switches on spoken confirmation.
  - `FolderGrants` holds the owner's standing folder permissions (edits, and a separate shell switch) and the checks that keep a command inside the folder.
- `Advisor/`: a separate, read-only `claude -p` call that explains a request in plain words and answers questions about it. Advice only; it never approves anything.
- `Session/SessionCatalog` lists earlier Claude Code sessions for resume.
- `Conversation/`
  - `ConversationEngine` (an actor) runs the whole loop: barge-in, redirect, summary/details, permissions, acknowledgements, latency metrics, and transcript snapshots for the UI.
  - `VoiceCommand` parses local commands (approvals, refusals, catch-up, project switch).
  - `GatedSpeechOutput` keeps background projects silent; `ProjectMatcher` resolves spoken project names.
  - `submitFromRemote` takes text from a paired phone: it is an instruction for Claude, never an answer to a waiting request.
  - `VoiceActivityDetector` is an energy VAD with an adaptive noise floor.

**PairVoxVoice** (macOS)

- `AudioIO` uses one `AVAudioEngine` with `setVoiceProcessingEnabled(true)`. The echo canceller then hears PairVox's own speech and removes it from the mic signal, which is what makes barge-in work on laptop speakers.
- `Transcription`: `WhisperKitTranscriber`, `AppleSpeechTranscriber` and `FallbackTranscriber`.
- `Synthesis`
  - `KokoroSynthesizer` runs on MLX and checks first that the Metal library exists, because MLX traps without it.
  - `SystemSynthesizer` uses `AVSpeechSynthesizer.write`, so system speech also goes through the echo-cancelled player.
  - `FallbackSynthesizer` picks between them.
- `VoiceSpeechOutput` synthesizes up to two sentences ahead of playback and stops within one buffer.
- `ModelStore` downloads Kokoro and verifies its pinned SHA-256 hashes.

**PairVoxLinkKit** (macOS and iOS): the wire library shared by the Mac and the phone. Encrypted, numbered frames (`FrameCodec`), the keyed handshake, message types, the phone-side `LinkClient`, `TCPTransport`, and the phone's Keychain credential store. Has no dependency on `PairVoxCore`.

**PairVoxLink** (macOS): the Mac side of the phone link. `LinkHost` serves paired phones and enforces every approval rule itself; `PairingManager` handles QR pairing (a 16-byte one-time secret, also usable as a pasted link), the Accept step and revocation; `TailnetAddress` limits who may even start a handshake; `EngineLink` maps engine state to what the phone sees. See [prd/pairvox-iphone-prd.md](prd/pairvox-iphone-prd.md) and the Phone link section of [THREAT_MODEL.md](THREAT_MODEL.md).

**PairVoxApp**: SwiftUI views and `AppModel` (one engine per open project, the project list, mini window and menu bar), plus the Keychain (API key), Carbon hotkeys (hold-to-talk, key configurable), notifications and `PhoneLinkModel` (Settings → Phone).

**ios/PairVoxPhone**: the iPhone app (SwiftUI): pairs, shows the transcript, speaks replies, listens with on-device recognition, and answers requests. Built from `ios/project.yml` with XcodeGen.

**PairVoxCLI**: `pairvox-cli`, the same engine with a terminal I/O shim (`say` on macOS).

## Latency strategy

Claude's thinking and tool use dominate; TTS is rarely the bottleneck. PairVox hides the wait:

1. **Warm process.** Claude Code is launched when a project opens. Measured first-token time for a warm process on Haiku is about 0.7 s; a cold start takes several seconds.
2. **Streamed speech.** The markdown parser and chunker emit the first sentence while the reply is still streaming. The first chunk may split at a comma after about 60 characters.
3. **Pipelined TTS.** The next sentence is synthesized while the current one plays.
4. **No dead air.**
   - If nothing has been said 1.2 s after you finish, PairVox says a short acknowledgement ("On it.").
   - Tool calls are narrated, throttled to one every 4 s ("Reading login dot T S.").
5. **Summary-first replies.** `SystemPrompts.voice` asks Claude to open each reply with one or two plain sentences, which also powers summary mode.

`TurnLatency` records time to first token, first utterance and first audio. The CLI prints them with `--metrics`.

## Barge-in, in detail

When the VAD has detected 180 ms of speech:

1. `engine.userStartedSpeaking()` stops audio immediately and remembers what was unsaid.
2. While you are talking, new speech from Claude is held.
3. Your transcript arrives, and one of four things happens:
   - **Empty or noise:** speech resumes where it stopped.
   - **A command:** it is handled. "go on" resumes, "stop" discards the rest, "summary mode" switches mode and resumes.
   - **A permission prompt is pending:** a short answer approves or denies; a longer one denies with your words as feedback.
   - **Anything else:** the remainder is dropped. If Claude is still working, the turn is interrupted with a `control_request` `interrupt` (verified to take about 10 ms on CLI 2.1.296, with the session kept) and your new message is sent.

## Testing

`swift test` runs about 80 tests on macOS or Linux:

- **Fixture replay:** a real, sanitized Claude Code 2.1.296 stream-json capture (text, Write permission, interrupt mid-stream, interrupt during a permission prompt) is replayed through the translator.
- **Subprocess tests:** a fake `claude` shell script exercises process plumbing, the auth environment and resume.
- **Engine tests:** fakes cover barge-in, redirect, voice approvals (including the high-risk guard), summary/details, repeat, auth and crash handling.
- **Speech pipeline tests:** markdown streaming is checked char-by-char against whole-input parsing, plus chunking and pronunciation.
