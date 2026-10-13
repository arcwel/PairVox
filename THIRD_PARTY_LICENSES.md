# Third-party components

PairVox's own code is Apache-2.0. It uses the components below. None is GPL, LGPL, AGPL or non-commercial. The full license texts are in each package's repository (and in the resolved checkouts under `.build/checkouts` or Xcode's `SourcePackages`).

| Component | Used for | License | Source |
|---|---|---|---|
| WhisperKit (+ swift-transformers and friends via its manifest) | On-device speech recognition | MIT | https://github.com/argmaxinc/WhisperKit |
| OpenAI Whisper model weights (Core ML conversions by Argmax) | Speech recognition model, downloaded at runtime | MIT | https://huggingface.co/argmaxinc/whisperkit-coreml |
| kokoro-ios (KokoroSwift) | Kokoro TTS inference in Swift | MIT | https://github.com/mlalma/kokoro-ios |
| MisakiSwift | English grapheme-to-phoneme for Kokoro. **No espeak-ng (GPL) is used.** | Apache-2.0 | https://github.com/mlalma/MisakiSwift |
| MLXUtilsLibrary | `.npz` voice file reader | Apache-2.0 | https://github.com/mlalma/MLXUtilsLibrary |
| MLX Swift | GPU array runtime for Kokoro | MIT | https://github.com/ml-explore/mlx-swift |
| Kokoro-82M weights (`kokoro-v1_0.safetensors`) and voice styles (`voices.npz`) | Voice model, downloaded at runtime and SHA-256 verified | Apache-2.0 (weights by hexgrad); files redistributed via KokoroTestApp (MIT) | https://huggingface.co/hexgrad/Kokoro-82M · https://github.com/mlalma/KokoroTestApp |

Apple system frameworks (AVFoundation, Speech, SwiftUI, AppKit, CryptoKit, Security, UserNotifications, Carbon) are used under the Xcode and Apple SDK license terms.

## Checking licenses when you change dependencies

1. Resolve the package graph (`swift package resolve`) and review `Package.resolved` for every transitive package's `LICENSE`.
2. Reject GPL/LGPL/AGPL code and non-commercial model weights (for example XTTS-v2 or Fish Audio research-license weights) in anything shipped in the app bundle.
3. Check each model or voice file's own license, not just the repository it is downloaded from.
4. Update this file and `NOTICE`.
