# Remediation of the 2026-10-13 audit

Follow-up to [2026-10-13-phase1-hardening.md](2026-10-13-phase1-hardening.md). The audit was source-only because its host had no sandbox. This pass added one: `scripts/validate-claude-config.sh` runs the real `claude` 2.1.296 under `sandbox-exec` with no network, a dummy home and a dummy repository, and several leads were settled by measurement or by running the code.

## Measured

| Question | Result |
|---|---|
| Does `claude -p` run a repository's own hooks and MCP servers, with the arguments PairVox used? | **Yes.** With default arguments the repo's `SessionStart` hook ran and its `.mcp.json` server launched, with no prompt. Its `permissions.allow` rule was ignored ("workspace has not been trusted"). |
| Does `--setting-sources user` stop that? | **Yes.** Neither the hook nor the MCP server ran, and the user's own MCP server still launched. |
| Is `--strict-mcp-config` needed? | **No, and it is harmful**: it also stops the user's own MCP servers, so it was removed. |
| Does the release build honour the committed `Package.resolved`? | **Yes.** With the pin set to WhisperKit 1.1.0 while 1.1.1 existed, `xcodebuild` checked out 1.1.0. The lead was refuted; WhisperKit is pinned `exact:` as well. |
| Does `say` treat a leading `-` as an option? | **Yes.** `say '-5 degrees'` exits 1 ("invalid option"), and `say '-f/path'` reads the file aloud. `say -- '-5 degrees'` works. |
| Do the plugin and macro validation flags matter to the build? | **No.** The only plugins are `swift-argument-parser` command plugins that do not run in a build, and there are no macros. A full Release build succeeds without the flags. |
| Do the Whisper pins work end to end? | **Yes.** Download at the pinned commit, tamper detected and repaired, model and tokenizer loaded by WhisperKit from the pinned copy with no download of its own, and a transcription ran (`PAIRVOX_NETWORK_TESTS=1`). |

## The 19 leads

| Lead | Status | How |
|---|---|---|
| Spoken Bash prompt reads the model's description | Fixed | Spoken from the command; test |
| Bash risk defaults to low | Fixed | Low only for plain read-only commands; git global options stripped; tests |
| "Don't always allow" parsed as always-allow | Fixed | Refusals parsed first; test |
| One pending-permission slot | Fixed | Queue, request-ID bound buttons; tests |
| Own speech accepted as approval | **Accepted by design for high risk** | Spoken confirmation is a Settings toggle, off by default. When on, PairVox's own prompt contains the phrase "confirm high risk", so speech heard by the microphone can satisfy it, and Settings says so. It is not offered for requests Claude Code says need the screen. Low- and medium-risk voice approvals still have no echo filter |
| Always-allow persists unseen suggestions | Fixed | Every suggestion is applied to the session; test |
| `claudePathOverride` sends the API key to any program | Fixed | Override must be an absolute, regular, non-group/world-writable file owned by the user or root, in a folder not writable by everyone; `settings.json` saved 0600 in a 0700 folder and ignored for the override if loose; tests. The Keychain access question for the signed build was not measured |
| Markdown links open any scheme | Fixed | http, https and mailto only |
| `say` option injection | Fixed | `--`; measured |
| Release build ignores the lockfile | Refuted | Measured; WhisperKit also pinned exact |
| Signing key live during unpinned build and publish | Fixed in the workflow | Actions pinned to commits; XcodeGen pinned and checksummed; random keychain password, deleted in an `always()` step; secrets passed as env; tag must be on `main`; `build` (read-only, holds secrets) and `publish` (write, no secrets) split; `environment: release` added. **Owner must create the "release" Environment with required reviewers, move the secrets into it and add a tag ruleset**: those are repository settings |
| Repo symlink exhausts memory in the vocabulary scan | Fixed | Symlinks skipped, regular files only, reads capped; test with `/dev/zero` |
| New session ignores the mode the user switched to | Fixed | Mode re-applied to the new child and saved; test |
| Menu-bar Allow has no risk or reasons | Fixed | Shows risk and the first reason; high risk goes to the window |
| Permission card cuts the command at 6 lines | Fixed | Scrollable full command |
| Auto-approve ignores scope | Fixed | Plain read-only tools only; tests |
| Auto-approve toggle not applied live | Fixed | Setter; test |
| CLI prints control characters | Fixed | `Term.safe` on model text (no unit test: the CLI is an executable target) |
| Repo config bypasses the approval gate | Confirmed and fixed | `--setting-sources user` by default; Settings toggle to trust a project |

## Hardening notes handled

WhisperKit model and tokenizer pinning, exact WhisperKit version, `ExitPlanMode` never auto-approved, sensitive-file reads not auto-approved, LineBuffer and notice wording left as is.

## Still to do

- Run the Keychain check on the signed release build with a saved key (`scripts/check-keychain-access.sh --probe`). On this Mac with a dummy item created like the app's, the item trusted exactly one program and a second program (`security`) was held at an approval prompt.
- Hunter notes not acted on: notification bodies include commands, log and diagnostics file modes, the `.gitignore` guard entries, `KeychainStore` delete-then-add ordering.
