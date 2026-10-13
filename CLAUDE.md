# CLAUDE.md: PairVox

PairVox is a native macOS voice front-end for Claude Code: you talk, it streams Claude's reply back as speech, you can interrupt (barge-in), and you can approve tool permissions by voice.

**Read `docs/HANDOFF.md` before doing anything.** It has the current status, what's verified and what isn't, the prioritized task list, and the gotchas.

## Commands

```bash
make build / make test           # = swift build/test, adding --build-system native on macOS (required, see HANDOFF §4)
swift test                        # on Linux; 82 tests, must stay green
swift run pairvox-cli --help      # terminal front-end, same engine, against the real `claude`
swift run pairvox-cli --say --metrics --model haiku   # spoken replies + latency numbers
brew install xcodegen && make xcode   # Xcode project for the real .app (needed for Kokoro/Metal)
make app                          # dist/PairVox.app (ad-hoc signed)
```

## Layout

- `Sources/PairVoxCore`: platform-independent engine (protocol, sessions, speech pipeline, policy, `ConversationEngine`). Swift 6 language mode. **Put all testable logic here.**
- `Sources/PairVoxCLI`: `pairvox-cli`.
- `Sources/PairVoxVoice`: macOS audio, STT and TTS (Swift 5 mode).
- `Sources/PairVoxApp`: SwiftUI app (Swift 5 mode). Compiled by both the SwiftPM `pairvox-app` dev target and the XcodeGen `PairVox` app target (`project.yml`).
- `Tests/PairVoxCoreTests`: includes `Fixtures/claude-2.1.296-session.jsonl`, a real CLI capture.

## Non-negotiable rules

1. **Never read, store, proxy or log Claude.ai credentials or session tokens.**
   - PairVox only spawns the user's own unmodified `claude` CLI, which uses its own login.
   - API keys live only in the Keychain (`KeychainStore`) and are passed via the child process environment.
   - Don't read `~/.claude` credentials, and don't add a "Sign in with Claude" UI. This is Anthropic policy: see `docs/HANDOFF.md` §Auth.
2. **High-risk permission requests must never be approvable by voice.** `PermissionPolicy` and the `.approve` guard in `ConversationEngine.perform` enforce this. Any change there needs tests.
3. **No GPL, AGPL or non-commercial dependencies or model weights. No telemetry.** Apache-2.0 project; add the SPDX header to new files.
4. **Don't use Claude or Anthropic names or logos in the product name or icon.** "Works with Claude Code" in plain text is fine.
5. Keep `swift test` green. Add a test for every engine or speech-pipeline bug you fix.
