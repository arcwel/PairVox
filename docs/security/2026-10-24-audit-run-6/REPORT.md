# Security audit run 6: PairVox, full audit, quick profile (2026-10-24)

## 1. Run

| | |
|---|---|
| Mode | Full audit (all six phases), `quick` profile |
| Source | `fbcd1ed` (main), clean tree |
| Scope | Sources/, Package.swift, project.yml, scripts/, .github/, ios/, packaging/ |
| Reviewers | Claude Sonnet 5.5 for every recon agent, hunter, critic and verifier. The code was written by Opus-family sessions and the run was coordinated by Opus 5.5, which reviewed nothing itself |
| Budget | 24 agent invocations, 22 spent (4 recon, 6 hunters, 1 final critic, 11 verifiers) |
| Execution | Sandboxed source-and-local-only policy. **No target code ran**: macOS cannot enforce a memory or process limit on target code and no local Linux Swift image exists, so every check is source-only |
| Prior runs | Runs 2 to 5 left prose reports only (docs/security/), with no compatible ledger or findings file. Nothing was carried as a same-source confirmation |

**This is a partial pass.** A quick profile runs one hunter wave and one critic. The critic found four surfaces no unit covered and asked for a second pass on one unit. All five are recorded as deferred (section 7). Because no target code ran, no record could reach `confirmed`: every source-established defect is a `needs_validation` lead whose blocker is execution, with a bounded unit test as its resolution plan.

## 2. Posture

The phone link held up: no hunter found a way past the one-time pairing secret, the owner's Pair click or the PSK handshake, and the frame crypto (per-direction keys, strict sequence numbers, no plaintext fallback) is sound. Model downloads are hash-pinned and fail closed. Logs are redacted. The weak area is the approval gate: six of the eight leads are ways a voice-approvable request gets approved when it should not (a question counts as yes, a yes counts before the prompt plays, wrapped deletes and re-cased config paths escape the high-risk rating, MCP tools are approved by name only, and a shell grant covers `printenv`).

## 3. Confirmed findings

None. See section 1 for why no record could be confirmed in this run.

## 4. Confirmed finding detail

None.

## 5. Needs validation

No severity is assigned to these. Full trace, evidence and plan for each are in NEEDS-VALIDATION.md.

| Lead | Trace | Blocker | Local next step | Owner check |
|---|---|---|---|---|
| A question or loose phrase containing an approve word approves a waiting request | VoiceCommand.swift:193-205 → ConversationEngine.swift:303 (before the question branch at 313) → :876 | No target execution | Unit test: `parse("Is that okay?", awaitingPermission: true)` is not an approval; engine sends no response | None needed |
| A spoken yes counts for a request whose prompt has not played | ConversationEngine.swift:1221 → :270 → :871. EngineModels.swift:121 has no prompt-delivered state | No target execution | Engine test with a non-playing fake output: "sounds good" before the prompt starts sends no response | None needed |
| Wrapped or piped recursive deletes and quote-split `git push` are rated medium | PermissionPolicy.swift:249, :304, :335, :372 → ConversationEngine.swift:875 | No target execution | `BashRisk.classify` on `ls build \| xargs rm -rf`, `timeout 60 rm --recursive --force build`, `env -i rm --recursive --force build`, `sh -c '…'`, `env -i g"i"t push` is high | None needed |
| Shell commands reaching `~/.CLAUDE` or a re-cased PairVox folder are not high | PermissionPolicy.swift:625 → :542 → FolderGrants.swift:28 | Foundation's case behaviour on the owner's volume, no execution | `BashRisk.classify("cp a.json ~/.CLAUDE/settings.json")` is high | Volume is case-insensitive (default) |
| MCP and other tools are approved by name only | PermissionPolicy.swift:148-151 → PermissionCardView.swift:82 → OutboundMessage.swift:38 | Owner's MCP servers, no execution | `assess` of `mcp__mail__send_message` mentions the arguments or is not voice-approvable | List user-level MCP servers with send/post/delete tools |
| API key readable by an auto-approved `printenv` under a shell grant | AppModel.swift:208 → LaunchConfiguration.swift:99 → PermissionPolicy.swift:630 → FolderGrants.swift:71 | Whether Claude Code's Bash tool inherits the key, no execution | `assess` of `printenv` under a shell grant is not covered | Dummy key, ask claude to `printenv ANTHROPIC_API_KEY` |
| Phone host allow-list accepts `fd7a:115c:a1e0:`-prefixed names and leading-zero octets | Views.swift:93 → PhoneCredentials.swift:79, :98 → TCPTransport.swift:60 | iOS resolver behaviour, no execution | `isAllowedHost("fd7a:115c:a1e0:x.attacker.example")` and `("100.070.0.1")` are false | Simulator with a local test resolver |
| Pre-auth and pairing limits key on the source address, 127.0.0.1 behind `tailscale serve` | PhoneLinkModel.swift:118 → TCPTransport.swift:12 → LinkHost.swift:258 → Pairing.swift:164 | Tailscale forward behaviour, no execution | Same-peer fake transports exhaust the bucket | `lsof -nP -iTCP:47821` while the phone is connected |

## 6. Hardening and positive patterns

Hardening notes from hunters and verifiers (not findings):

- **Phone tap approvals skip every risk check, and the phone's Face ID claim is self-declared** (LinkHost.swift:449, LinkMessages.swift:80-82). Accepted in writing in audit run 4 and open as backlog 3.3. A Mac-side confirmation for high-risk phone approvals would close it.
- WebFetch is medium and can be approved by voice, while a Bash command that reaches the network needs a click.
- Grep and Glob without a path read `.env` without asking.
- `.git/hooks` is missing from the list of sensitive paths.
- The second "allow all" does not check again whether the requests have gone stale.
- Raw advisor text is spoken when a request is asked again (backlog 1.7).
- An offer of folder access never expires.
- Log folder and playback recordings use default permissions (protected only by `~/Library` being 0700). Playback recordings are never pruned.
- `ClaudeLocator` does not apply owner and mode checks to a PATH-discovered `claude` (backlog 4.7), and `openTerminalForLogin` escapes only double quotes in its AppleScript.
- The pairing key is used for both the HMAC and the AEAD, with no separate subkeys.
- The legacy key import does not check that keys are 32 bytes.
- `servePairing` revokes devices by set difference instead of by id.
- Release workflow does not require a green CI run for the tagged commit. The CI container `swift:6.0` is pinned by tag, not digest (backlog 6.4). `-onlyUsePackageVersionsFromResolvedFile` would make the Xcode build's lockfile use explicit.
- `KeychainStore.saveAPIKey` deletes before adding, so a failed add loses the old key.

Positive patterns:

- The stream-json writer cannot be split into extra control messages.
- The child's argv never passes through a shell.
- The settings file is distrusted when it is not owner-private.
- Revoked phones cannot be revived from a restored list.
- Whisper pins use immutable commits and refuse path traversal.

## 7. Coverage

| State | Units |
|---|---|
| Covered | 5 |
| Candidate (leads produced) | 7 |
| Deferred | 5 |
| Blocked | 0 |

Deferred by the final critic (`quick_profile_final_critic`):

1. The echo path: whether PairVox's own spoken prompts ("…Allow?", "Say confirm high risk") or model prose can come back through the microphone as an approval when echo cancellation is off or fails.
2. `PermissionPolicy.assess` for the tools other than Bash: when a Read is approved on its own, how writes to files are rated, and WebFetch.
3. The child output parser's cost: `LineBuffer` is quadratic on many short lines, `JSONValue` has no depth limit (backlog 4.8).
4. Hotkeys, notifications, the Terminal AppleScript launcher and the Apple Events entitlement.
5. A second pass on the iPhone pairing unit.

Rejected after independent verification, kept so later runs do not repeat them: `foldergrant/shell-grant-bare-token-symlink-escape` (a shell grant already runs repository scripts, so the symlink route adds no capability), `phone-link/text-delivered-to-active-project-not-shown-project` (documented design; the owner's own text, no boundary crossed), `scripts/build-app.sh:release-build-resolves-transitive-spm-deps-outside-committed-Package.resolved` (refuted by the repository's own 2026-10-13 measurement).

Final critic result: not clean (four missing units and one reassignment, all deferred). No claim of complete coverage is made.
