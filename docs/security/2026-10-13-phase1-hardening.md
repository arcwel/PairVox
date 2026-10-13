# PairVox security audit: phase1-hardening

Date: 2026-10-13. Profile: `standard`, full audit mode, whole repository in scope. Source: commit e510d39 on `phase1-hardening` plus the uncommitted working tree (separate-engines experiment, `MicrophoneCapture.swift`, `scripts/analyze-audio-log.py`). No prior runs exist for this repository.

## 1. Scope and limits

This run was source-only. The host cannot enforce the OS sandbox the audit method requires for running target code, so no PairVox code, build, test, or `claude` binary was executed. Every record is therefore `needs_validation`: the source paths are real and independently re-read, but each one depends on a fact that only running the code or checking a setting can settle.

- Budget: none set. About 62 agent invocations: 4 reconnaissance, 15 hunters (one discarded for returning malformed output and re-run), 5 coverage critics, 19 candidate verifiers, 19 final-record verifiers.
- Coverage: 36 ledger units across 5 hunting waves. 20 closed as covered with no candidate; 16 produced one or more of the 19 leads. The final-clean critic accepted no missing units and no reassignments.
- Companions used: desktop and local IPC, AI and LLM, supply chain and release. Excluded with reasons: memory safety (no C or C++), web protocol, client-side, cloud, RPC, resource exhaustion, data isolation (no matching surface).
- Not covered: deployed infrastructure, GitHub repository settings, the signing and notary secrets, the behavior of the pinned `claude` 2.1.296 binary, and the operating system's handling of Keychain items and URL schemes. These are the blockers behind the leads below.
- No Cloudflare product applies. PairVox is a native macOS app with no server, socket, URL scheme or web surface, so there is nothing for a Cloudflare scanner to reach.

## 2. Security posture

PairVox has no network listener and no remote attack surface. Its risk sits in one place: a model-driven permission gate. An opened repository can steer Claude through prompt injection, and the gate decides whether a human hears, sees and approves what runs. The controls are real: a risk policy with a click-only tier for high-risk requests, SHA-256 pins on the Kokoro model downloads, a redacting log writer, and a hardened, notarized release build. The leads show where those controls can be sidestepped, mainly by approval prompts that do not show the exact command, a risk classifier that defaults to low, and project config that Claude Code may load without going through the gate.

No confirmed vulnerability is claimed. 19 leads need one validation step each. Most of them can be settled with a unit test in the normal dev environment, and the plans below name the exact inputs.

## 3. Confirmed findings

None. See section 4 for the leads that need validation.

## 4. Needs validation

Ordered as a triage list for the owner (most direct route to an unapproved action first). This is not a severity ranking: needs-validation leads carry no severity.

| # | Lead | Trace | Decisive unknown |
|---|---|---|---|
| 1 | Opening an untrusted repository lets its Claude Code project config run commands or pre-approve tools outside PairVox's approval gate | `Sources/PairVoxApp/AppModel.swift:124` to `Sources/PairVoxCore/Session/ClaudeCLISession.swift:81` | No OS-enforced sandbox is available on this host to run target code, so the claude CLI cannot be executed here |
| 2 | Auto-approve low-risk silently runs unmatched Bash commands and requires-user-interaction requests | `Sources/PairVoxCore/Conversation/ConversationEngine.swift:393` to `Sources/PairVoxCore/Conversation/ConversationEngine.swift:399` | Whether Claude Code actually issues a permission request to PairVox for an unmatched Bash command or for ExitPlanMode depends on the user's Claude Code permission configuration and cannot be read from this source tree |
| 3 | Bash risk classifier is a denylist that defaults to low, so high-impact commands can be voice-approved or auto-approved | `Sources/PairVoxCore/Protocol/InboundMessage.swift:354` to `Sources/PairVoxCore/Conversation/ConversationEngine.swift:395` | No OS-enforced sandbox is available on this host to execute target code. The rating of each evasion command comes from reading the regexes, not from running BashRisk.classify |
| 4 | Spoken Bash approval prompt reads the model-written description, not the command | `Sources/PairVoxCore/Protocol/InboundMessage.swift:351` to `Sources/PairVoxCore/Protocol/OutboundMessage.swift:38` | Whether a real Claude Code model can be steered by repository content into emitting a misleading Bash description for a command that BashRisk rates below high cannot be observed in a source-only review |
| 5 | Always-allow echoes the CLI's permission_suggestions without showing them, and they may persist to settings files | `Sources/PairVoxCore/Protocol/InboundMessage.swift:365` to `Sources/PairVoxCore/Protocol/OutboundMessage.swift:42` | Whether the CLI persists an addRules suggestion with destination localSettings to .claude/settings.local.json when it arrives via updatedPermissions on the stdio permission-prompt tool is CLI behaviour, not visible in this repository |
| 6 | Negated 'always allow' / 'ask again' phrases are parsed as an always-approve grant | `Sources/PairVoxCore/Conversation/ConversationEngine.swift:153` to `Sources/PairVoxCore/Protocol/OutboundMessage.swift:40` | Whether the CLI's permission_suggestions for a given request are session-only or a persistent rule depends on the claude binary and is not visible in this repository. This sets the impact |
| 7 | A single pending-permission slot lets an approval for one request apply to a later one | `Sources/PairVoxCore/Protocol/InboundMessage.swift:288` to `Sources/PairVoxCore/Protocol/OutboundMessage.swift:34` | Whether the claude CLI sends a second can_use_tool request before the first is answered (parallel tool calls) is external to this repository and not observable from source |
| 8 | New session and project reopen start Claude in a different permission mode than the brainstorm mode the UI and voice assurance show | `Sources/PairVoxCore/Conversation/VoiceCommand.swift:91` to `Sources/PairVoxCore/Session/LaunchConfiguration.swift:67` | The spawned child's actual --permission-mode argv and the assistant's resulting behavior have not been observed at runtime, because no OS-enforced sandbox is available on this host to run target code. Source reading already establishes the code path, so only runtime confirmation remains |
| 9 | Developer ID signing key sits unlocked in the keychain while tag-triggered builds run unpinned tools and macros | `.github/workflows/release.yml:10` to `.github/workflows/release.yml:47` | Repository tag rulesets, environment required reviewers, secret scoping, and who has write access are GitHub settings that cannot be seen in source |
| 10 | Same-user write to settings.json routes the Keychain-held Anthropic API key to an attacker-chosen executable | `Sources/PairVoxCore/Config/Settings.swift:175` to `Sources/PairVoxCore/Session/ClaudeCLISession.swift:78` | No OS-enforced sandbox is available on this host to run target code, so nothing was built or run |
| 11 | Permission card truncates the model-chosen Bash command at 6 lines, so the approver may not see everything that will run | `Sources/PairVoxCore/Policy/PermissionPolicy.swift:78` to `Sources/PairVoxApp/Views/PermissionCardView.swift:55` | SwiftUI .lineLimit(6) truncation, the visible ellipsis, and the card's real layout and height are runtime rendering behavior that cannot be observed from source |
| 12 | Menu-bar Allow approves any pending request, including high risk, from a 2-line summary with no risk label or reasons | `Sources/PairVoxApp/Views/MenuBarView.swift:14` to `Sources/PairVoxCore/Conversation/ConversationEngine.swift:192` | How MenuBarExtra renders long or multi-line Text, and whether the tail of the command is clipped, is runtime behavior that source cannot show |
| 13 | Audio played by PairVox (including the prompt's own 'Allow?') can be transcribed and accepted as a voice approval | `Sources/PairVoxVoice/VoiceInputController.swift:133` to `Sources/PairVoxCore/Conversation/ConversationEngine.swift:326` | No OS-enforced sandbox is available on this host to run target code, so the XCTest cannot be run here |
| 14 | Claude-authored markdown links open any URL scheme on click with attacker-chosen link text | `Sources/PairVoxApp/Views/TranscriptView.swift:54` to `Sources/PairVoxApp/Views/TranscriptView.swift:144` | No OS-enforced sandbox is available on this host to run target code, and building or running the app is out of bounds for a source-only check |
| 15 | Signed release build may resolve WhisperKit from the 'from: 1.1.0' range instead of the committed pin | `Package.swift:52` to `scripts/build-app.sh:40` | Whether Xcode applies the root Package.resolved to a local-package dependency graph is Xcode behaviour and cannot be seen from source |
| 16 | pairvox-cli prints child-controlled permission text to the terminal without stripping control characters | `Sources/PairVoxCore/Policy/PermissionPolicy.swift:78` to `Sources/PairVoxCLI/TerminalSpeechOutput.swift:109` | Whether a given terminal emulator honours the injected cursor and erase sequences, and how the rendered card looks, cannot be observed from source |
| 17 | Model text is passed to /usr/bin/say as a trailing argument without '--', so a leading '-' can act as a say option | `Sources/PairVoxCore/Speech/MarkdownSpeechParser.swift:183` to `Sources/PairVoxCLI/TerminalSpeechOutput.swift:78` | Exact option parsing of /usr/bin/say for a single glued argv element such as '-f<path>' or '-o<path>' on the target macOS version is not source-visible and needs execution of the system binary |
| 18 | Repo symlink can make the vocabulary scan read an unbounded file and exhaust PairVox memory | `Sources/PairVoxApp/AppModel.swift:216` to `Sources/PairVoxCore/Support/RepoVocabulary.swift:41` | No OS-enforced sandbox is available on this host, so target code (including String(contentsOf:) on a /dev/zero or very large target) cannot be run to observe memory growth and termination |
| 19 | Disabling auto-approve in Settings does not take effect on the running session | `Sources/PairVoxApp/Views/SettingsView.swift:72` to `Sources/PairVoxCore/Conversation/ConversationEngine.swift:395` | The stale-read path is established by source. What remains is how long a live engine typically persists before it is recreated, which sets real-world exposure, and a runtime check that the toggle-off path produces autoApproved=true in practice |

Full traces, evidence and validation plans are in `NEEDS-VALIDATION.md`.

## 5. Hardening notes

Collected from hunter reports; none changes a verdict.

- Auto-approve of 'low' includes ExitPlanMode and ToolSearch. Auto-approving ExitPlanMode lets the model leave the plan-only permission mode that the brainstorm mode relies on without an explicit user answer. Exclude ExitPlanMode from auto-approve and show the plan text.
- Read, Glob and Grep are low risk with no sensitive-path check. With auto-approve on, the model can read ~/.ssh or .env into the conversation, which the docs list as a known limitation. Apply isSensitivePath to read-only tools and raise it to high.
- isInsideProject normalizes with standardizingPath but does not resolve symlinks or expand '~'. A symlink inside the project that points outside is rated medium, and a path starting with '~/' is treated as relative to the project root.
- The default case rates every unknown tool, including MCP and Task tools, as medium and voice-approvable, and the spoken prompt reads only the tool name. Consider rating mcp__* tools as high or speaking their server name.
- Edit and Write prompts show and speak only the path. The content is not summarized, so a voice yes approves unseen content. This is documented as in-project medium risk.
- LineBuffer silently discards a pending line over 64 MiB. If that line is a can_use_tool request, the user is never prompted and the CLI waits for a reply. Send a control_error or an interrupt when droppedLines increments.
- ConversationEngine.setConversationMode ignores a failed set_permission_mode (try?) and still tells the user 'I won't change any files'. Report the failure.
- PermissionPolicy.readOnlyTools contains ExitPlanMode, so it is rated low risk and voice-approvable (and auto-approved if autoApproveLowRisk is on). Leaving plan mode then conflicts with the brainstorm state PairVox shows. This sits in the peer-owned PermissionPolicy unit.
- Spoken PairVox prompts and model-authored prose use the same TTS voice, so prose can imitate a permission prompt. Consider a distinct earcon or voice for real prompts.
- EventTranslator.looksLikeAuthProblem matches broad substrings ('401', 'oauth', 'authentication') in failure text, so a tool error can trigger the 'run claude and sign in' notice. Match specific error codes instead.
- AppModel.openTerminalForLogin (AppModel.swift:477-486) escapes only double quotes. Escape backslashes as well, and shell-quote the path (for example with `quoted form of`), or avoid AppleScript by launching Terminal with the path as an argument.
- Restrict claudePathOverride: require an absolute path to a regular file owned by the user or root and not group- or world-writable, or re-prompt when the value changes outside the Settings UI.
- Create settings.json with mode 0600 inside a 0700 directory, and verify ownership on load.
- ShellEnvironment.loginShellEnvironment merges the whole interactive login-shell env, including any ANTHROPIC_BASE_URL. In API-key mode, drop or confirm ANTHROPIC_BASE_URL and similar redirects so the key cannot be sent to an unexpected host.
- ClaudeLocator searches the login-shell PATH before the fixed install directories, so a user-writable earlier PATH entry wins. This is same-user trust, so show the resolved path in Setup (already done) and consider warning on user-writable locations.
- Notifier bodies (AppModel.swift:546,550) include the full Bash command or a prefix of the reply with no LogRedactor pass; scrub them, or show only a generic body when the command contains secret-like tokens.
- KeychainStore.saveAPIKey deletes the existing item before adding the new one; use SecItemUpdate, or add first and delete the old item on success, so a failed add does not lose the key.
- DiagnosticExporter copies playback-*.caf and the logs unscrubbed when the user opts into audio or conversation text. Warn at export time, and consider adding JWT, private-key-block and URL-credential patterns to LogRedactor.
- LogRedactor skips usernames shorter than 3 characters, and the zip is written to the Desktop (possibly iCloud-synced); consider writing it with 0600 permissions and revealing it in a private folder.
- Log directory and files are created with default permissions; set 0700 on the directory and 0600 on the files.
- ModelStore pins the Kokoro URLs to the mutable 'main' branch of mlalma/KokoroTestApp. The SHA-256 check fails closed, but an upstream change breaks the download. Use commit-SHA URLs.
- ModelStore.download has no byte cap on the stream. Cancel once totalBytesWritten exceeds RemoteFile.bytes.
- Failed or cancelled downloads leave UUID .part files in Models/Kokoro. Delete stale *.part files at the start of ensureKokoro.
- ModelStore.isPresent is a size-only check. The callers re-hash, so this is not a bypass, but the name suggests more than it checks.
- WhisperKit models are downloaded from Hugging Face with no pinned revision and no hash. Settings.whisperModel is an unvalidated String. Validate it against the SettingsView allowlist when loading settings, and pin a model repo revision if WhisperKitConfig supports one.
- The .gitignore has no entries for .env, *.p12, *.pem or *.key. Add them as a guard against accidental commits.
- The committed Package.resolved lacks swift-transformers, although THIRD_PARTY_LICENSES.md says it comes in via WhisperKit. Regenerate and recheck it against the full graph.
- Pin maxim-lobanov/setup-xcode, actions/checkout and softprops/action-gh-release to full commit SHAs. Replace brew install xcodegen with a pinned version.
- Scope contents: write to a separate publish job that downloads the DMG. Run the signing job with contents: read.
- Use a random keychain password via openssl rand, and delete the keychain in an `if: always()` cleanup step.
- Store the notary credentials through environment variables passed to the step, not by inline ${{ secrets.* }} interpolation inside the run: script.
- Add `git merge-base --is-ancestor $GITHUB_SHA origin/main` to the release job, and gate the secrets with an `environment: release`.
- In the Makefile, quote $(VERSION) in the release target.
- Bind keyboard and menu approvals to the displayed request ID: approvePending/approve(always:) should take the request ID and no-op if snapshot.pendingPermission differs, and approvePending should itself reject risk == .high for non-click callers; the risk check currently exists only in the voice path and in the menu's disabled state.
- ConversationEngine overwrites a single pendingPermission slot when a second permissionRequested arrives, without denying the first request; the first request's child call then stalls. Queue or auto-deny the superseded request.
- RepoVocabulary also feeds raw directory names (any characters, 3+ long) and file basenames into the Whisper prompt, so a repo can bias recognition toward chosen strings; restrict terms to identifier-shaped tokens.
- The RepoVocabulary directory walk is bounded by maxFiles only for source files; a repo with millions of directories or non-source files is still fully enumerated, so add a total entry cap.
- Playback recordings (playback-<runid>.caf) are never pruned and are included in the diagnostics export when enabled; consider an explicit expiry and file mode 0600.
- Fix for the candidate: make SessionBackendFactory take (resumeSessionID, permissionMode, model), have the engine pass config.conversationMode.permissionMode, and mirror snapshot.conversationMode into settings in AppModel.receive. Report a failed setPermissionMode instead of using try?.
- ConversationEngine.respondToPermission and the setPermissionMode write do not check the child's control_response for errors. A rejected mode change is therefore invisible.
- Switching to brainstorm does not clear or re-assess an already pending permission card, so a pending Write or Edit stays approvable after the user says brainstorm. This is user-initiated and low impact.
- AppModel.openProject sets project and records noteProjectOpened before the API-key check. A missing key leaves the UI with a project but no engine.
- The lastProject restore in bootstrap uses fileExists without checking that the path is a directory.
- Notifier posts the full 'Run: <command>' summary and the first 140 characters of the last reply as notification bodies. A command containing a token could show on a locked or shared screen, and the text is stored in Notification Center. Consider truncating the summary to a tool name plus a short basename, or omitting the body when the risk is not low.
- pairvox-cli --raw-log creates the file with default permissions (typically 0644) and follows symlinks, and the file holds unredacted child output. Create it with mode 0600 using open(O_CREAT|O_NOFOLLOW|O_APPEND, 0600) and warn that the log contains conversation and tool output.
- pairvox-cli prints model-chosen strings (permission summary prefix, tool text, reasons) to the terminal without stripping ANSI/control characters (Sources/PairVoxCLI/main.swift permission card and tool lines). Escape sequences in a repository-influenced command could overwrite or spoof the displayed permission card. Strip C0 and C1 control characters before printing.
- PermissionCardView header uses the model-supplied displayName for any tool, while risk and summary derive from toolName. Show the real toolName next to it.
- For default-case tools (MCP and unknown) the card and spoken prompt show only 'Use <name>', with no input, yet these are rated medium and so are voice-approvable. The policy is owned by a peer unit.
- The Always Allow button does not show which permission rule from the child's suggestions will be persisted. Peer unit: OutboundMessage allowAlways.
- The conversation mode set at runtime is not carried into the backend factory's captured launch config on newSession. This may make the UI show Brainstorm while a new child starts in default mode. The unit is owned by a peer (setConversationMode and newSession lifecycle). Include a regression test there.
- Escape is bound to Deny and Cmd+Return to Allow window-wide in PermissionCardView. Consider requiring the card to be key-focused or showing the request id.
- Sources/PairVoxCLI/main.swift:184 truncates the summary to 200 characters, so a dangerous tail of a long command is not shown to the operator. Show a length-elided marker or the full command in the CLI card.
- Sources/PairVoxVoice/Synthesis.swift: KokoroSynthesizer.load trusts that ModelStore verified the files and traps on a corrupt file. A swap between verification and load is a TOCTOU, owned by the ModelStore peer unit. Consider loading from a verified private copy or re-hashing immediately before load.
- Sources/PairVoxCLI/TerminalSpeechOutput.swift: say is passed u.text as a positional argument, so text starting with '-' could be parsed as an option. This is owned by the peer say-argv unit. Use '--' before the text.
- Pass --setting-sources user (or an explicit allowlist) and --strict-mcp-config for the spawned child, or show a one-time per-folder trust confirmation in openProject that names the .claude/settings*.json hooks and allow rules and .mcp.json found there.
- Scan the opened folder for .claude/settings.json, settings.local.json and .mcp.json at openProject and surface any hooks, allow rules or MCP servers in the UI before the child starts.
- Document repository-supplied Claude Code configuration as an input in docs/THREAT_MODEL.md, including that it can bypass the can_use_tool gate and the high-risk click-only rule.
- LaunchConfiguration.extraArguments is appended last and not validated; it is peer-owned (environment and extraArguments unit), but any caller that sets it could add --dangerously-skip-permissions. No current caller does.
- Sources/PairVoxApp/AppModel.swift:477-485 openTerminalForLogin: escape backslashes as well as quotes, and shell-quote the claude path (for example with `quoted form of` in AppleScript, or a single-quote wrapper that handles embedded single quotes) so installs under paths with spaces or backslashes work and no metacharacter is ever interpreted. This is not an exploitable boundary crossing today, because the only sources are a same-uid settings.json override or a PATH entry.
- Optional defense in depth: have openTerminalForLogin reject any claude path that contains control characters, backslashes or newlines before building the script. Also validate the child-reported session_id (for example, a UUID-shaped pattern) before storing it as currentSessionID.
- Sources/PairVoxVoice/Transcription.swift:59 builds WhisperKitConfig without pinning a revision, so the Core ML Whisper model bytes track the upstream Hugging Face main branch. If the project wants parity with the Kokoro pins, vendor or mirror a fixed revision (WhisperKitConfig modelRepo and a commit-specific endpoint or local modelFolder) and verify a SHA-256 manifest before load: true. Alternatively, say plainly in the docs that the Whisper weights are trust-on-first-download from the vendor.
- docs/THREAT_MODEL.md line 27 overstates the controls: it says all network traffic is hash-pinned and verified, but the WhisperKit download is not pinned by PairVox. Reword line 27 so it covers only the Kokoro files, and keep the residual-trust sentence at line 28.
- Package.swift uses WhisperKit from: 1.1.0 while Package.resolved holds an exact revision. Consider .upToNextMinor or an exact pin for release builds, so a fresh resolution without the lockfile cannot pull a newer WhisperKit that changes download defaults. This is covered by the peer Package.swift unit.

## 6. Positive source patterns

- Model downloads for Kokoro are pinned by size and SHA-256 and fail closed (`Sources/PairVoxVoice/ModelStore.swift`).
- High-risk requests cannot be approved by voice; the engine refuses at `ConversationEngine.swift:326-333`.
- Child arguments are passed as an argv array with no shell, and the stdout line buffer is capped at 64 MiB.
- `LogRedactor` scrubs keys and user paths from diagnostic logs, and conversation text and playback recording are opt-in.
- Release builds use hardened runtime and notarization; local ad-hoc builds are the only exception.

## 7. Coverage summary

Ledger units: 36. Covered: 20. Candidate (lead raised): 16. Blocked, deferred, out of scope: 0. Final critic result: stop, no gaps. The ledger and `findings.json` both pass their validators. This is a single-run, source-only result and does not claim the target is exhausted.
