# Threat model

PairVox lets you steer an agent that can edit files and run commands, by voice. Speech recognition makes mistakes, and other people or devices can make sound near your Mac. This document covers what can go wrong and what PairVox does about it.

## Assets

- Your source code and machine: the agent can edit files and run shell commands.
- Your Claude account or API key.
- Audio from your room.

## Trust boundaries

1. **Microphone → transcript.** Untrusted: misrecognition, background speech, TV or video audio, other people.
2. **Transcript → Claude Code.** Treated as your instruction, the same as typing it.
3. **Claude Code → tool execution.** Gated by Claude Code's own permission system and, when it asks, by PairVox's policy.
4. **Tool output and web content → Claude → speech.** Untrusted: prompt injection can make Claude say or request anything.

## Controls

| Risk | Control |
|---|---|
| A misheard “yes” approves something destructive | `PermissionPolicy` rates every request. High-risk requests can never be approved by voice: a spoken yes gets “please confirm on screen”. High risk covers recursive or forced `rm`, `git push`, `reset --hard`, `sudo`, piping a download into a shell, publishing, `launchctl`, writes outside the project, credentials and dotfiles, and anything Claude Code itself flags (`safetyCheck`, `default_to_no`, `requires_user_interaction`). |
| Background speech triggers actions | VAD needs about 180 ms of sustained speech above an adaptive noise floor. Yes/no answers are only recognized while a prompt is pending and only as short whole utterances; longer speech becomes feedback to Claude, never an approval. Push-to-talk and mute are one keystroke away. |
| TTS echo heard as user speech | Voice-processing I/O (Apple's echo canceller) plus a VAD threshold raised by 6 dB during playback. Barge-in can be turned off (half-duplex). |
| Prompt injection asks for dangerous actions | The same permission gate applies whatever Claude says. Spoken prompts describe what will actually run, taken from the tool input and not from Claude's prose. The on-screen card shows the full command. |
| Credential exposure | No login UI. Subscription credentials never pass through PairVox. An API key is stored only in the Keychain (`kSecAttrAccessibleWhenUnlocked`), passed only to the child process environment, never written to settings or logs. |
| Leaking audio or transcripts | Speech recognition and synthesis run on-device. No telemetry. The only network traffic PairVox itself makes is model downloads, which are pinned by SHA-256 and loaded only after verification. |
| Malicious model file | Kokoro's loader traps on malformed input, so files are hash-verified before loading. WhisperKit models come from Argmax's published repositories through WhisperKit. |
| A hung CLI blocks the app | Unsupported control requests are answered with an error immediately. Process exit is detected and reported; the next message resumes the session. |

## Not in scope / known limitations

- PairVox does not sandbox Claude Code. Use Claude Code's own settings (permission rules, sandboxing) for defence in depth.
- “Auto-approve read-only tools” is off by default. Reading files can still pull sensitive content into the conversation.
- Hands-free mode in a shared space is inherently riskier. Prefer push-to-talk there.
- The risk classifier is heuristic (regular expressions). It errs toward asking for a click, but it is not a security boundary on its own.

## Reporting

See [SECURITY.md](../SECURITY.md).
