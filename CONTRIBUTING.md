# Contributing to PairVox

Thanks for helping! A few guidelines keep the project healthy.

## Getting started

```bash
swift build && swift test          # engine + CLI, works on macOS and Linux
make xcode                         # macOS app in Xcode (needs `brew install xcodegen`)
swift run pairvox-cli --help       # terminal front-end against your real Claude Code
```

## Where things live

- Protocol or session logic → `Sources/PairVoxCore/Protocol`, `Session`. Add a test. If Claude Code's output changed, capture a new fixture with `pairvox-cli --raw-log file.jsonl`, sanitize paths, and add it under `Tests/PairVoxCoreTests/Fixtures`.
- What gets spoken and how → `Sources/PairVoxCore/Speech`. These are pure functions with fast tests. Please add a test for every pronunciation or markdown case you fix.
- Safety → `Sources/PairVoxCore/Policy`. Changes that loosen voice approvals need a clear rationale in the PR and tests showing the guardrail still holds.
- Audio, STT, TTS → `Sources/PairVoxVoice` (macOS only).
- UI → `Sources/PairVoxApp`.

## Rules

- **License:** contributions are accepted under Apache-2.0. Add `// SPDX-License-Identifier: Apache-2.0` to new source files.
- **No GPL or non-commercial dependencies or model weights** (see THIRD_PARTY_LICENSES.md).
- **No telemetry, analytics, or network calls** beyond the user's own Claude Code CLI and verified model downloads.
- **Never handle Claude.ai credentials.** PairVox must not read, store or forward Claude subscription tokens, and must not patch or wrap the `claude` binary's authentication. API keys live only in the Keychain.
- **Branding:** don't use Anthropic or Claude logos, and don't imply endorsement. Writing "Works with Claude Code" in plain text is fine.
- Keep `swift test` green on Linux. CI runs both Linux and macOS.

## Pull requests

Small, focused PRs with a short description of the user-visible change. For anything that changes how replies sound, include a before/after example of the spoken text.
