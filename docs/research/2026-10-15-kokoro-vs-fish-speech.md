# Kokoro vs Fish Speech for PairVox (2026-10-15)

Question from the owner: would Fish Speech be a better voice with less overhead in the app? Research by a Claude subagent with web access; measurements on this Mac (M5 Max, 48 GB) with `dist/PairVox.app --tts-probe`. Sources at the end.

## 1. What PairVox has now

**Engine.** Kokoro-82M (Apache-2.0 weights) through `KokoroSwift` (kokoro-ios 1.0.11, MIT) on MLX Swift 0.30.2, with MisakiSwift for G2P (no espeak-ng/GPL). The system voice (`AVSpeechSynthesizer`) is the fallback and the corrupt-audio recovery path.

- `Package.swift` lines 46-55: exact pins (kokoro-ios 1.0.11, mlx-swift 0.30.2, MLXUtilsLibrary 0.0.6); a newer mlx breaks Kokoro.
- `Sources/PairVoxVoice/Synthesis.swift`: `KokoroSynthesizer` (loads weights + `voices.npz` on a serial queue, warms up with "Ready.", checks the Metal library exists because MLX traps without it), `SystemSynthesizer`, `SynthesisRecovery`.
- `Sources/PairVoxVoice/ModelStore.swift`: downloads `kokoro-v1_0.safetensors` (327,115,152 B) and `voices.npz` (14,629,684 B), SHA-256 pinned. Installed: 326 MB in `~/Library/Application Support/PairVox/Models/Kokoro`.
- `Sources/PairVoxVoice/VoiceSpeechOutput.swift`: sentence pipeline, synthesizes 2 ahead, trims silence (`AudioTrim.swift`: 30 ms lead / 170 ms tail).
- Voices: fixed presets from `voices.npz` (`Sources/PairVoxCore/Config/VoiceCatalog.swift`); English only in this integration.
- Packaging: `dist/PairVox.app` is 75 MB; the MLX stack is the bulk (Cmlx.framework 37 MB). Hardened runtime, not sandboxed.

**Measured today** (`/usr/bin/time -l dist/PairVox.app --tts-probe`):

| text | audio ms | synth ms | RTF |
|---|---|---|---|
| "Okay." | 1450 (685 after trim) | 162 | 0.11 |
| "On it." | 1300 (643) | 91 | 0.07 |
| "Here is the first point about the module." | 2650 (2063) | 260 | 0.10 |
| 23-word sentence | 8075 (7783) | 1040 | 0.13 |

Whole run 5.24 s wall (process start + load + warm-up + 4 sentences; load and warm-up are roughly 3.5 s). Maximum resident set 510 MB. `peak memory footprint` reported 7.3 GB, read as MLX/Metal unified-memory allocations during warm-up, not steady-state RSS; unverified until measured with Instruments.

## 2. What Fish Speech is now

- **Models in the current repo** (README read 2026-10-15): only **Drama 3** (35B MoE, 3B active, released 13 Oct 2026 as v3.0.0-beta) and **S2-Pro** (4B slow-AR + 0.4B fast-AR, released Mar 2026 as v2.0.0-beta). S1/S1-mini/1.5 are no longer in the README.
- **Requirements** (speech.fish.audio/install): "Linux and WSL"; Drama 3 needs an NVIDIA GPU with >= 48 GB (FP8) and does not run on CPU, Apple MPS or ROCm; S2-Pro needs >= 24 GB GPU or CPU; `--compile` is not supported on macOS. Python 3.12 + PyTorch. No macOS install path is documented any more (the MPS work was 2024-era).
- **Weights and sizes.** S2-Pro: safetensors 4.99 + 4.14 GB, codec 1.87 GB, about 11 GB; RTF 0.195 and about 100 ms TTFA on one H200. S1-mini: 0.5B params, model.pth 1.74 GB (pickle) + codec 1.87 GB, gated. fish-speech-1.5: CC-BY-NC-SA-4.0, superseded.
- **Licensing.** Code + Drama 3 weights: Fish Audio Community License v1.0 (13 Oct 2026): commercial use only while annual revenue < USD 500k, must display "Built with Fish Audio", revocable. **S2-Pro weights: Fish Audio Research License**: research/non-commercial only; any revenue-generating product needs a separate written license. **S1-mini and 1.5 weights: CC-BY-NC-SA-4.0.** Net: no Fish weight can be shipped in a revenue-generating Mac app without a negotiated license, and even a free app must carry the attribution.
- **Apple Silicon ports.** No official MLX/CoreML/Swift path. **mlx-audio-swift** (MIT) has a `FishSpeech` model targeting `mlx-community/fish-audio-s2-pro-8bit` (6.72 GB on disk); Swift API `TTS.loadModel`, `generate(text:refAudio:refText:)`; no audio streaming in Swift; the package tracks `main` with no releases. Community measurements on M-series Macs: RTF about 3.7-3.8, about 23 s cold load, process peak 15-17 GB on a 24 GB Mac mini. 4-bit MLX conversions decode to noise. S1-mini GGUF exists but runs only through a Python app, not llama.cpp.
- **No published Apple Silicon RTF from Fish for any model.** The only Mac figures are community ones, and they are about 30x worse than Kokoro's measured RTF here.

**Fish Audio hosted API.** `s2.1-pro` and `s2-pro`: $15 per million UTF-8 bytes (a PairVox day of 50 turns at 2,000 characters is about $0.045). WebSocket streaming, about 300-500 ms modes. Python/JS SDKs only; URLSession from Swift is straightforward. Privacy policy (effective 28 Aug 2024): inputs kept "as long as needed", may be shared with service, analytics, advertising and business partners; no zero-retention option mentioned. For PairVox every Claude reply (code, file names, repository content) would leave the Mac, against `docs/THREAT_MODEL.md` ("Speech recognition and synthesis run on-device").

## 3. Comparison

| | Kokoro (today) | Fish S2-Pro via mlx-audio-swift | Fish S1-mini (PyTorch/MPS or GGUF) | Fish Audio API |
|---|---|---|---|---|
| Model on disk | 342 MB, hash-pinned | 6.72 GB (8-bit) | about 3.6 GB (.pth) / 1-2 GB GGUF | 0 |
| Runtime memory | 510 MB RSS measured | 15-17 GB peak reported | unknown on Mac | about 0 |
| Binary/deps | about 43 MB MLX frameworks, 4 pinned SwiftPM deps | + mlx-audio-swift (tracks `main`) + newer mlx-swift that breaks kokoro-ios pins | Python 3.12 + PyTorch beside the app, or a user-installed server | URLSession only |
| Latency to first audio | 90-260 ms synth for a short sentence; about 0.2 s sentence-ready-to-sound after trim | RTF about 3.7: a 2 s sentence takes about 7 s; 23 s cold load | unverified; `compile` unsupported on macOS | 300-500 ms + network |
| Quality | good, slightly flat; English presets; occasional corrupt sentence (recovery exists) | best open-weight quality, 83 languages, emotion tags, cloning | S1-era quality, 13 languages | S2.1-pro, top of leaderboards |
| Offline | yes | yes | yes | no |
| Streaming | no (sentence pipelining suffices) | not in the Swift port | upstream yes | yes |
| Voice cloning | no | yes | yes | yes |
| License for shipping | Apache-2.0 weights, MIT code | Research License: non-commercial, attribution | CC-BY-NC-SA-4.0 | commercial OK; pay per byte |
| Packaging | done; Metal-shader build quirk | large download; mlx-swift version conflict | Python runtime notarization pain, or an external process | trivial |
| Maintenance | single-maintainer package, exact pins | single-maintainer package, no tags | upstream dropped S1-mini from docs | vendor API; S1 retired after 16 months |

## 4. Recommendation

**Stay on Kokoro as the default. Do not port to Fish Speech on-device.**

1. **Licensing.** Every downloadable Fish weight today is non-commercial or usable only under a revenue-capped, revocable community license with mandatory branding (Drama 3, which cannot run on a Mac anyway). Kokoro is Apache-2.0.
2. **Overhead is about 20x and latency about 30x worse.** 6.7 GB model, 15+ GB peak memory and RTF about 3.7 on Apple Silicon versus 342 MB, 0.5 GB RSS and RTF about 0.1 measured here. PairVox's budget is about 2 s from Claude's first token; a sentence that takes 7 s to synthesize is unusable.
3. **No sane embedding path.** The only Swift route is mlx-audio-swift on `main` with a newer mlx-swift than kokoro-ios tolerates; the PyTorch route means shipping or requiring Python/torch next to a notarized app.
4. S1-mini, the model that made Fish interesting for small devices, is gated, pickled, non-commercial, dropped from the current README, and has no Swift/MLX port.

**Hybrid worth doing (small, optional):** a `fishAudio` case in `SynthesizerChoice` (`Sources/PairVoxCore/Config/Settings.swift`) backed by a `FishAudioSynthesizer: SpeechSynthesizing` that calls the hosted API (model `s2.1-pro`, key in `KeychainStore`, off by default, with an explicit "the text of every reply leaves your Mac" notice and a threat-model update). It fits the `VoiceSpeechOutput` pipeline without touching Kokoro, gives cloning and 83 languages to those who want it, and costs cents. Measure its real TTFA before promising anything; keep Kokoro + system voice as the offline path.

**Better uses of the same effort inside Kokoro:** warm Kokoro earlier (load is about 3.5 s); check whether the 7.3 GB "peak footprint" is a warm-up cache that `MLX.GPU.set(cacheLimit:)` can cap; surface more of the 54 voice presets. If quality ever becomes the blocker, re-evaluate mlx-audio-swift's smaller models (Kokoro is also in there) rather than Fish.

## 5. Not verified

- Fish's own Apple Silicon latency for any model (none published; Mac RTF numbers are community reports from unnamed machines).
- Whether current fish-speech `main` still loads S1-mini checkpoints, and S1-mini RTF/memory on MPS.
- Fish Audio API data retention for API input text (the policy is from 2024 and generic; "zero data retention is enterprise-only" comes from third-party reviews).
- The 7.3 GB "peak memory footprint" line for PairVox's probe versus 510 MB RSS.
- mlx-audio-swift's S2-Pro memory/speed in Swift (its README states none; Python-side figures were used).
- Whether "Built with Fish Audio" applies to a free, non-revenue build under the Research License (the text requires attribution regardless).

## Sources

https://github.com/fishaudio/fish-speech · https://github.com/fishaudio/fish-speech/blob/main/LICENSE · https://github.com/fishaudio/fish-speech/releases · https://speech.fish.audio/install/ · https://speech.fish.audio/inference/ · https://huggingface.co/fishaudio/s2-pro · https://huggingface.co/fishaudio/s2-pro/blob/main/LICENSE.md · https://huggingface.co/fishaudio/openaudio-s1-mini/tree/main · https://huggingface.co/fishaudio/s1-mini · https://huggingface.co/fishaudio/fish-speech-1.5 · https://pypi.org/project/fish-speech/ · https://docs.fish.audio/developer-guide/getting-started/changelog · https://docs.fish.audio/developer-guide/models-pricing/pricing-and-rate-limits · https://docs.fish.audio/developer-guide/best-practices/real-time-streaming · https://fish.audio/privacy · https://github.com/Blaizzy/mlx-audio-swift · https://github.com/Blaizzy/mlx-audio-swift/blob/main/Sources/MLXAudioTTS/Models/FishSpeech/README.md · https://huggingface.co/mlx-community/fish-audio-s2-pro-8bit · https://github.com/groxaxo/fish-s2-pro-mlx-local-deploy · https://github.com/gapul/dotfiles/pull/653 · https://github.com/xorbitsai/inference/pull/5551 · https://huggingface.co/calcuis/openaudio-gguf · https://github.com/mlalma/kokoro-ios · https://huggingface.co/hexgrad/Kokoro-82M
