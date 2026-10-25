# Needs validation: PairVox audit run 6 (2026-10-24)

Source-grounded leads with an unresolved blocker. They carry no severity: each is a lead, not a confirmed vulnerability. The common blocker is that this run executed no target code. Each lead's `local` plan is a bounded unit test with dummy data.

## Phone pairing host allow-list accepts non-Tailscale hostnames via IPv6-prefix and leading-zero IPv4 forms

Fingerprint: `PairVoxLinkKit/PhoneCredentials.swift:isAllowedHost-ipv6-prefix-and-ipv4-leading-zero-accepted-as-tailnet`

PairingPayload.isAllowedHost is the only host check between a scanned or pasted pairvox://pair link and the phone opening a TCP connection. Its IPv6 branch returns true for any string that contains ':' and starts with 'fd7a:115c:a1e0:' without parsing an IPv6 address, and the character filter also allows letters, '.' and '-', so 'fd7a:115c:a1e0:x.attacker.example' passes (verified in source, not executed). The same function accepts leading-zero IPv4 octets ('100.070.0.1' passes the 64...127 range check as Int 70, but an inet_aton-style resolver would read 070 as octal 56, giving 100.56.0.1, outside 100.64.0.0/10). The host reaches NWEndpoint.Host(String), which falls back to a DNS name when the string is not a valid address literal. If the resolver looks the name up, the phone would pair with a server the attacker chose, which could answer with its own grant, after which dictated text, typed text and spoken answers go to that server and its replies are shown and spoken. Exploitation needs the user to scan or paste an attacker-supplied link and press Pair in a dialog that shows host:port; the allow-list is what is meant to make that safe. Impact is limited to the phone's own session with the attacker's server and does not reach the Mac or the user's real tailnet peer. The IPv4 octal variant additionally needs the attacker to control a public 100.x address outside the CGNAT range.

**Claimed root cause.** isAllowedHost validates the shape of the string instead of parsing a canonical IPv4 or IPv6 address and checking it against 100.64.0.0/10 and fd7a:115c:a1e0::/48, so a hostname that begins with the Tailscale IPv6 prefix, or an IPv4 literal with leading zeros, is accepted as a tailnet address and then passed to NWEndpoint.Host, which can treat it as a DNS name.

**Trace**

1. `ios/PairVoxPhone/Views.swift:93` (entrypoint, PairView QRScanner callback and pair() paste path): Attacker-controlled QR text or pasted link is passed to PairingPayload.parse; the result is shown in a 'Pair with host:port?' confirmationDialog.
2. `Sources/PairVoxLinkKit/PhoneCredentials.swift:79` (propagation, PairingPayload.parse): h= is accepted when isAllowedHost(host) is true; the only other checks are port >= 1024 and a 16-byte base64url secret.
3. `Sources/PairVoxLinkKit/PhoneCredentials.swift:98` (propagation, PairingPayload.isAllowedHost): if lower.contains(":") { return lower.hasPrefix("fd7a:115c:a1e0:") } accepts any ASCII letter/digit/dot/hyphen/colon string that starts with the prefix; line 94 converts octets with Int() so leading zeros pass the range check at line 96.
4. `ios/PairVoxPhone/PhoneModel.swift:114` (propagation, PhoneModel.pair): Second call to the same isAllowedHost before connecting; same result.
5. `Sources/PairVoxLinkKit/TCPTransport.swift:60` (sink, TCPTransport.connect): NWEndpoint.Host(host) opens a TCP connection to the accepted string; credentials are then stored (PhoneModel.swift line 130) and later speech text is sent to that endpoint.

**Evidence**

- `Sources/PairVoxLinkKit/PhoneCredentials.swift:89`: Character filter allows ASCII letters, digits, '.', '-' and ':' only, which 'fd7a:115c:a1e0:x.attacker.example' satisfies.
- `Sources/PairVoxLinkKit/PhoneCredentials.swift:94`: IPv4 branch uses Int() on up to 3-digit all-numeric parts, so '070' becomes 70; no leading-zero rejection.
- `Sources/PairVoxLinkKit/PhoneCredentials.swift:98`: IPv6 branch is a bare prefix test with no address parse, no hex-group check and no rejection of '.' or letters beyond hex.
- `Tests/PairVoxLinkTests/LinkTests.swift:805`: PhoneHostRuleTests covers the literal 'fd7a:115c:a1e0::1' and several bad hosts but no hostname starting with the IPv6 prefix and no leading-zero octet.
- `ios/PairVoxPhone/Views.swift:87`: The confirmation dialog only shows host:port and gives no signal that the host is outside the tailnet; the pairing proofs themselves do not authenticate the Mac to the phone before the grant, since the attacker's server supplies its own QR secret.

**Blockers**

- Target execution was unavailable in this run (no enforceable sandbox), so the parser results were established from source only.
- Whether Network.framework / mDNSResponder on iOS resolves a name containing ':' inside a label is not observable from source and is decisive for the IPv6-prefix form.
- Whether the system resolver reads a leading-zero IPv4 literal as octal (and whether NWEndpoint.Host's own IPv4 parse rejects it first) is not observable from source and is decisive for the IPv4 form.

**Resolution plan**

- Local: Step 1 (parser, no network): in a throwaway Swift package or XCTest target that depends on PairVoxLinkKit, assert PairingPayload.isAllowedHost("fd7a:115c:a1e0:x.attacker.example") == false, isAllowedHost("100.070.0.1") == false, isAllowedHost("fd7a:115c:a1e0::1") == true, and PairingPayload.parse("pairvox://pair?h=fd7a:115c:a1e0:x.attacker.example&p=47821&s=AAAAAAAAAAAAAAAAAAAAAA") == nil. Expected today: the first, second and fourth assertions fail (true / true / non-nil). Step 2 (resolver, loopback only): in the iOS Simulator, with a local /etc/hosts-style test mapping or local resolver that maps the test name to 127.0.0.1 and a loopback listener fixture, call NWEndpoint.Host("fd7a:115c:a1e0:x.test") and getaddrinfo on it, and call inet_aton on "100.070.0.1"; record whether the name resolves and whether the octet is read as octal. Use only dummy names and loopback; no public domains. Proposed fix: parse with IPv4Address/IPv6Address (rejecting leading zeros and any non-address text in the ':' branch), compare the parsed bytes against 100.64.0.0/10 and fd7a:115c:a1e0::/48, otherwise require a strictly validated *.ts.net name with no ':'; add both strings to PhoneHostRuleTests as bad inputs.
- Owner-observed: Ask the owner to confirm on a test iPhone (iOS 18) whether the build shows the 'Pair with host:port?' dialog for a locally generated link with h=fd7a:115c:a1e0:x.test and whether connection attempts for that name produce DNS traffic on a lab resolver the owner controls; no traffic to real domains.

## Wrapped or piped recursive deletes and quote-obfuscated git push are rated medium and can be approved by a spoken yes

Fingerprint: `bashrisk/leading-program-only-wrapper-and-xargs-downgrade-high-risk`

BashRisk is meant to rate recursive or forced rm, sudo and git push as high risk, which keeps them off the voice path. The text rule for rm (PermissionPolicy.swift:249) needs a short flag followed by whitespace, so long flags such as --recursive and a trailing flag at the end of the string do not match. The structural pass (372-376, 380-396) only examines each segment's first program after skipping env, command, nohup, time, nice, exec, builtin, caffeinate and stdbuf by exact name (304, 335); the options of those wrappers (env -i) are not skipped, and timeout, xargs and sh -c are not looked through. By hand-tracing the code: 'ls build | xargs rm -rf', 'timeout 60 rm --recursive --force build', 'env -i rm --recursive --force build' and "sh -c 'rm --recursive --force build'" match only the medium rules 'Deletes files.' / 'Runs a nested shell'. 'env -i g"i"t push origin main' matches no text rule (the quote splits 'git') and the structural pass sees program '-i', so it falls through to the generic medium 'Not a recognized read-only command.' (631). None of these reasons is a network reason, and the narration does not collapse to 'a command' (ToolNarrator.commandSummary drops dash-words and keeps up to three words), so screenOnly stays false and voiceOK is true (PermissionPolicy.swift:160). The spoken prompt is only e.g. 'Claude wants to run ls build and 1 more step shown on screen' or 'Claude wants to run timeout 60 rm', and ConversationEngine.swift:875 then calls approvePending on a spoken yes. The same effect written as 'rm -rf build' or 'git push' would require a click. The affected boundary is the policy invariant that high-risk commands are never voice-approvable, with model output or repository content as the lower-trust source and a casual yes (or room audio) as the trigger. Corrections to the hunter record: the 'env -i rm -rf build' and 'timeout 5 sudo x' spellings are still caught by the text rules, so only long-flag, trailing-flag and quote-obfuscated variants slip through. Impact is bounded by the need for a spoken yes to a prompt that names the first program.

**Claimed root cause.** Risk is computed from the first program of each segment (after skipping a fixed list of wrapper names without their options) plus spelling-specific regexes. Wrappers with options, xargs, timeout and nested command strings are not unwrapped, so the structural findings for rm, sudo and git never see the real program, and the text rules miss long flags, a trailing flag and quote-split program names.

**Trace**

1. `Sources/PairVoxCore/Policy/PermissionPolicy.swift:117` (entrypoint, PermissionPolicy.assess (Bash)): The model-chosen command string from a can_use_tool request is classified by BashRisk.classify and narrated.
2. `Sources/PairVoxCore/Policy/PermissionPolicy.swift:335` (propagation, BashRisk.segments): The wrapper-skip loop drops only words that are exactly a listed wrapper name or look like VAR=value, so for 'env -i rm ...' the program becomes '-i', and for 'timeout 60 rm ...' or 'xargs rm -rf' it is 'timeout' or 'xargs'.
3. `Sources/PairVoxCore/Policy/PermissionPolicy.swift:372` (propagation, BashRisk.structuralFindings): The rm, sudo and git high-risk findings fire only when seg.program is rm, sudo or git, so a wrapped real program is not seen.
4. `Sources/PairVoxCore/Policy/PermissionPolicy.swift:160` (propagation, PermissionPolicy.assess): With risk medium and no network or undescribable reason, screenOnly is false and voiceOK is true.
5. `Sources/PairVoxCore/Conversation/ConversationEngine.swift:875` (sink, ConversationEngine.perform(.approve)): assessment.voiceApprovable is true for the medium, speakable result, so a spoken yes calls approvePending.

**Evidence**

- `Sources/PairVoxCore/Policy/PermissionPolicy.swift:249`: The high rule for rm requires '-[a-zA-Z]*[rRfF][a-zA-Z]*' followed by whitespace, so --recursive/--force and a flag at the end of the string do not match; only the medium rule at line 250 does.
- `Sources/PairVoxCore/Policy/PermissionPolicy.swift:304`: wrapperNames omits timeout, xargs, gtimeout, setsid and sh -c, and the options of listed wrappers (env -i, nice -n 5) are not skipped.
- `Sources/PairVoxCore/Policy/PermissionPolicy.swift:631`: A command that matches no rule falls back to medium, not high, so the unrecognized obfuscated 'git push' is voice-approvable.
- `Sources/PairVoxCore/Speech/ToolNarrator.swift:85`: commandSummary drops dash-words and keeps up to three words, so the readout does not collapse to 'a command' and does not force screen-only.
- `Tests/PairVoxCoreTests/SecurityHardeningTests.swift:145`: The regression list covers leading-program spellings only ('rm --recursive --force build', 'env FOO=1 git push', '/usr/bin/sudo rm x'); no test covers wrappers with options, xargs, timeout, sh -c or a quote-split program behind a wrapper.

**Blockers**

- Target execution was unavailable in this run (no enforceable memory or process limit for target code and no local Linux Swift image), so the levels were derived by hand-tracing the rules and not by calling BashRisk.classify or PermissionPolicy.assess.

**Resolution plan**

- Local: In Tests/PairVoxCoreTests/SecurityHardeningTests.swift add a test that, for each of 'ls build | xargs rm -rf', 'timeout 60 rm --recursive --force build', 'env -i rm --recursive --force build', "sh -c 'rm --recursive --force build'" and 'env -i g"i"t push origin main', asserts BashRisk.classify(c).level == .high (source predicts .medium, so the test should fail before a fix), then builds PermissionPolicy(projectRoot: "/Users/dev/app") and asserts assess(PermissionRequest(requestID: "r", toolName: "Bash", input: ["command": .string(c)])).voiceApprovable == false (source predicts true). Run with swift test --build-system native on macOS. A fix unwraps wrappers with their options, xargs, timeout and sh -c strings before the structural pass, matches long rm flags and a trailing flag, and treats an unresolvable program behind a wrapper as high or screen-only.

## Shell commands reaching ~/.CLAUDE or a re-cased PairVox settings folder may not be rated high

Fingerprint: `bashrisk/protected-folder-match-is-case-sensitive`

BashRisk.classify raises a command to high only when touchesProtectedFolder matches it. That function resolves each word with FolderScope.resolved and compares it to the protected folders (PairVox settings dir, Application Support/PairVox, ~/.claude) with == and hasPrefix, which are case-sensitive. FolderScope.resolved expands, standardizes and symlink-resolves but contains no case normalization. On the default case-insensitive macOS volume, ~/.CLAUDE/settings.json and '~/Library/Application Support/pairvox/settings.json' name the same files, so by source the command gets only the medium reasons ('Touches your home folder', 'looks sensitive', which isSensitivePath derives from a lower-cased copy), not the high 'Touches PairVox's own settings...' reason. A medium Bash request that is describable and does not reach the network stays voiceApprovable, so a spoken yes would approve something like 'cp a.json ~/.CLAUDE/settings.json' (Claude Code loads user-level settings, including hooks; PairVox's settings hold the consent store). The one fact source cannot settle is whether Foundation's resolvingSymlinksInPath (reached through FolderScope.resolved) returns the on-disk spelling for an existing path on the owner's volume; if it does, the existing-component case is canonicalized and only not-yet-existing tails remain case-sensitive. The same comparison is also used by isSensitivePath for Read, Glob and file-write targets, but those calls also use lower-cased needles for '/.claude' and 'application support/pairvox', so they remain high.

**Claimed root cause.** Protected-folder matching in BashRisk.touchesProtectedFolder (and patternCanReachProtectedFolder, which uses fnmatch without FNM_CASEFOLD) is a case-sensitive string comparison against canonically spelled folders, on a file system that is case-insensitive by default, and FolderScope.resolved does not itself canonicalize case.

**Trace**

1. `Sources/PairVoxCore/Policy/PermissionPolicy.swift:625` (entrypoint, BashRisk.classify): touchesProtectedFolder(original, projectRoot:) decides whether the model-supplied Bash command is raised to high risk.
2. `Sources/PairVoxCore/Policy/PermissionPolicy.swift:542` (propagation, BashRisk.touchesProtectedFolder.isProtected): folders.contains { resolved == $0 || resolved.hasPrefix($0 + "/") } compares the resolved word with the protected folders from PermissionPolicy.protectedFolders case-sensitively.
3. `Sources/PairVoxCore/Policy/FolderGrants.swift:28` (propagation, FolderScope.resolved): Expands tilde, standardizes, and symlink-resolves the existing prefix via URL.resolvingSymlinksInPath (line 39); no explicit case normalization.
4. `Sources/PairVoxCore/Conversation/ConversationEngine.swift:875` (sink, ConversationEngine.perform(.approve)): When the assessment is voiceApprovable (risk below high, not screen-only; PermissionPolicy.swift line 160), a spoken yes calls approvePending, so the medium-rated command runs.

**Evidence**

- `Sources/PairVoxCore/Policy/PermissionPolicy.swift:211`: protectedFolders returns FolderScope.resolved of the canonical spellings (SettingsStore dir, Library/Application Support/PairVox, ~/.claude).
- `Sources/PairVoxCore/Policy/PermissionPolicy.swift:221`: isSensitivePath lower-cases the path for its needles, so a Bash command gets only the medium 'looks sensitive' reason (line 621) while the folder check at line 230 stays case-sensitive.
- `Sources/PairVoxCore/Policy/PermissionPolicy.swift:160`: voiceOK = risk < .high && !screenOnly, so a medium describable command with no network reason stays voice-approvable.

**Blockers**

- Target execution was unavailable in this run (no enforceable sandbox on this Mac), so the behavior of Foundation's resolvingSymlinksInPath and the file system case rules on an existing re-cased path could not be observed.
- Whether the owner's volume is case-insensitive (the macOS default) and whether resolvingSymlinksInPath returns the on-disk spelling for an existing path is an environment fact not decidable from source.

**Resolution plan**

- Local: On a default case-insensitive APFS Mac, in a PairVoxCoreTests case using a temporary HOME-independent dummy setup where ~/.claude exists, call BashRisk.touchesProtectedFolder("cat ~/.CLAUDE/settings.json") and BashRisk.classify("cp a.json ~/.CLAUDE/settings.json", projectRoot: <temp dir>), and compare with the '~/.claude' spelling. Also assert the re-cased 'Application Support/pairvox' form. Source predicts false and level .medium for the re-cased form (true and .high for the canonical spelling). Do not write to the real folders; the test only classifies strings. A fix compares case-folded paths, or file identity via stat, on every comparison in touchesProtectedFolder, isSensitivePath and patternCanReachProtectedFolder (FNM_CASEFOLD).

## API key in the child environment is readable by an auto-approved 'printenv' under a shell folder grant

Fingerprint: `child-env/api-key-in-shell-tool-env-not-gated`

In API-key mode PairVox puts ANTHROPIC_API_KEY (and every other non-denied login-shell variable) into the claude child's environment. PairVox's command risk rules have no rule for environment disclosure. A bare 'printenv', 'env', 'printenv ANTHROPIC_API_KEY' or 'env | grep ANTHROPIC' is not in readOnlyCommands, so it rates medium ('Not a recognized read-only command.'). FolderScope.shellGrant does not treat that reason as disqualifying, and these commands contain no '$', backtick, path token, inline code or other rejected character. With a shell folder grant (allowShell) on the project, PermissionPolicy.assess therefore sets coveredByFolderGrant, and ConversationEngine answers .allow without asking the owner. If Claude Code's Bash tool inherits the child environment, a model steered by repository content can put the key into the model context and the local session transcript, and from there into speech, a project file written by another grant-covered redirection, or a later approved tool. PairVox itself does not speak or show the tool result (toolResult is ignored by the engine), so exposure depends on what the model then does. Without a grant the same command needs a voice or click approval at medium risk. The impact is bounded because the key already goes to Anthropic, the model already holds it if the CLI does not scrub the environment, and network commands remain excluded from grants; the gap is that the owner's shell grant silently covers a secret-reading command, contrary to the intent that nothing the model runs unseen can read the key.

**Claimed root cause.** The secret is handed to a child whose shell tool is model-directed, while BashRisk and FolderScope.shellDisqualifiers treat reading the environment as an ordinary medium-risk command and cover it with a folder grant. The documented control (key reaches only the child environment) does not account for the child running shell commands that print its own environment.

**Trace**

1. `Sources/PairVoxApp/AppModel.swift:208` (entrypoint, AppModel.openProject): In API-key mode the key is read from the Keychain (KeychainStore.readAPIKey) and put into AuthMode.apiKey (line 213) for the launch configuration.
2. `Sources/PairVoxCore/Session/LaunchConfiguration.swift:99` (propagation, LaunchConfiguration.environment()): ANTHROPIC_API_KEY is set after ChildEnvironment.filter; every other non-denied login-shell variable is forwarded unchanged.
3. `Sources/PairVoxCore/Session/ClaudeCLISession.swift:87` (propagation, ClaudeCLISession.startLocked): The environment becomes the claude process environment (p.environment = cfg.environment()), from which Claude Code starts its model-directed Bash tool.
4. `Sources/PairVoxCore/Policy/PermissionPolicy.swift:630` (propagation, BashRisk.classify): 'printenv' or 'env' matches no rule and is not in readOnlyCommands (isPlainReadOnly is false), so it is rated medium with reason 'Not a recognized read-only command.' (lines 630-633); isSensitivePath does not match 'printenv' or 'env' and the rule list has no environment-disclosure rule.
5. `Sources/PairVoxCore/Policy/FolderGrants.swift:71` (sink, FolderScope.shellGrant): That reason is not in shellDisqualifiers and the command has no '$', backtick, path token or inline code, so the grant covers it; PermissionPolicy.assess (line 180) sets coveredByFolderGrant and ConversationEngine (line 996) responds .allow without asking, for a command whose output includes the key.

**Evidence**

- `Sources/PairVoxCore/Policy/FolderGrants.swift:61`: shellDisqualifiers lists network, home-folder, sensitive-file, nested-shell, push and recursive-delete reasons only; nothing for reading the environment.
- `Sources/PairVoxCore/Policy/PermissionPolicy.swift:488`: readOnlyCommands lacks env and printenv, which yields the medium 'Not a recognized read-only command.' rating that the grant accepts. 'env' is also in wrapperNames (line 304), so a bare 'env' leaves an empty program name.
- `Sources/PairVoxCore/Policy/PermissionPolicy.swift:180`: Bash requests at medium risk that shellGrant covers become coveredByFolderGrant.
- `Sources/PairVoxCore/Conversation/ConversationEngine.swift:996`: A request with coveredByFolderGrant is answered .allow immediately and logged as 'Allowed by your folder access', with no prompt.
- `docs/THREAT_MODEL.md:27`: States that the key is passed only to the child process environment; it does not discuss the child's shell tool printing it.

**Blockers**

- Whether the installed Claude Code Bash tool inherits ANTHROPIC_API_KEY from the claude process (or scrubs it, for example through a subprocess-env-scrub option) is a property of the claude binary, not visible in this repository.
- Target execution was unavailable in this run (no enforceable sandbox), so the rating and grant outcome for 'printenv' and 'env' were established from source reading only and have not been observed.

**Resolution plan**

- Local: Add a bounded unit test in Tests/PairVoxCoreTests (dummy data only, no network, no real key), modelled on FolderGrantTests: create a temp project folder, build PermissionPolicy(projectRoot: <temp>, grants: [FolderGrant(path: <temp>, allowShell: true)]), and for each command in ['printenv', 'env', 'printenv ANTHROPIC_API_KEY', 'env | grep ANTHROPIC'] build a PermissionRequest for tool Bash with that command and call policy.assess. Assert coveredByFolderGrant is false and that the request is not covered by the grant. The test should fail on the current source. Run with 'make test'.
- Owner-observed: Owner-observed, with a dummy value only: export ANTHROPIC_API_KEY=sk-ant-dummy-not-real, run the installed claude with the same arguments PairVox uses in a scratch folder, and ask it to run 'printenv ANTHROPIC_API_KEY' through its Bash tool; note whether the dummy value is returned. Separately, in the Mac app with a throwaway project folder and a shell folder grant, observe whether a request for that command runs without a prompt (the transcript shows 'Allowed by your folder access'). Do not use a real key.

## Pre-auth and pairing limits key on the TCP source address, which is 127.0.0.1 for every remote phone in the supported userspace-Tailscale (loopback forward) mode

Fingerprint: `link-host-preauth-peer-key-collapses-behind-loopback-forward`

LinkHost caps unauthenticated connections at 3 per peer and 8 total, and PairingManager ignores a peer after 3 wrong pairing proofs (and burns the offer after 12 wrong proofs from all peers combined). The per-peer limits use TCPTransport.peer, the connection's source address. In userspace-Tailscale mode PairVox binds to 127.0.0.1 and the owner runs `tailscale serve --bg --tcp PORT tcp://127.0.0.1:PORT`; if the forward does not preserve the remote address (not provable from the repository), every remote tailnet client connects from 127.0.0.1 and shares one per-peer bucket, as does any local process in every mode. One low-privilege peer could then hold the 3 per-peer pre-auth slots (each held up to the 10 s pre-auth timeout, reconnecting at once) so the paired phone's connection is closed silently, or spend the 3-failure per-peer budget with wrong proofs during an open offer so a genuine phone's valid proof is rejected with PairingError.burned until the owner creates a new offer. Source review also shows the practical gain over the existing design is small: the global caps (8 pre-auth slots, 12 pairing failures) can already be spent by a handful of distinct tailnet peers, so the collapse mainly lowers the number of cooperating peers needed from about 3-4 to 1. No confidentiality or integrity impact; availability of the phone link and of pairing only, recoverable by the owner (wait out the 10 s window or create a new offer). Reachability is limited to tailnet members the owner's ACLs allow, or same-machine processes, who can already disrupt the app. Severity is low at most.

**Claimed root cause.** The per-peer accounting key is the transport-level source address, which does not identify the remote party when connections arrive through a local proxy (tailscale serve) or from local processes. Nothing keys the limits on a stronger identity, and there is no global rate limit on connection churn.

**Trace**

1. `Sources/PairVoxApp/Support/PhoneLinkModel.swift:118` (entrypoint, PhoneLinkModel.apply(enabled:port:)): Listener is bound to the tailnet address or 127.0.0.1 (userspace Tailscale fallback, lines 95-99) and the allow filter (TailnetAddress.isAllowedPeer) accepts any loopback peer; every accepted connection goes to host.serve.
2. `Sources/PairVoxLinkKit/TCPTransport.swift:12` (propagation, TCPTransport.peer): peer is the NWConnection remote host only, i.e. the immediate TCP source: 127.0.0.1 for a connection relayed by a local forward or opened by a local process.
3. `Sources/PairVoxLink/LinkHost.swift:258` (propagation, LinkHost.serve(_:)): peerKey = transport.peer; the connection is refused when preAuthByPeer[peerKey] >= 3 (line 259) and the slot stays held until the auth frame or the 10 s timeout.
4. `Sources/PairVoxLink/Pairing.swift:164` (sink, PairingManager.redeem(_:peer:now:accept:)): failuresByPeer[peer] >= maxFailures (3) throws burned before the proof is checked, and wrong proofs increment the per-peer and global counters (lines 168-173), so a shared peer key lets one party exhaust the genuine phone's budget.

**Evidence**

- `Sources/PairVoxApp/Support/PhoneLinkModel.swift:168`: serveCommand documents the loopback forward `tailscale serve --bg --tcp PORT tcp://127.0.0.1:PORT` as the supported way to use userspace Tailscale; line 99 sets userspaceTailscale for it.
- `Sources/PairVoxLink/TailnetAddress.swift:16`: isAllowedPeer always passes loopback, so the address filter does not distinguish remote clients behind the forward.
- `Tests/PairVoxLinkTests/LinkTests.swift:658`: Existing tests exercise per-peer failure counts only with distinct synthetic peer strings (100.1.1.1, 100.2.2.2), not with a shared peer.

**Blockers**

- Target execution was unavailable in this run (no enforceable sandbox), so the shared-bucket behavior was not exercised.
- Whether `tailscale serve --tcp` presents the connection to the local listener from 127.0.0.1 (no PROXY protocol), and which tailnet members the owner's ACLs let reach the port, depends on the Tailscale version and tailnet policy and is outside the repository.

**Resolution plan**

- Local: Bounded unit test in Tests/PairVoxLinkTests using the existing in-memory transport fakes (dummy data, no network, no sockets): (1) give three fake transports the same `peer` string "127.0.0.1" that never send a frame, start serve() on each, then start serve() on a fourth with the same peer and assert it is closed without being read; confirm a transport with peer "100.2.2.2" is still accepted. (2) createOffer(), call redeem(badRequest, peer: "127.0.0.1") three times (expect wrongSecret, wrongSecret, burned), then redeem(validRequest, peer: "127.0.0.1") and assert PairingError.burned, while redeem(validRequest, peer: "100.2.2.2") on a fresh offer succeeds. A pass confirms the shared-bucket logic only, not the Tailscale topology.
- Owner-observed: On the owner's Mac in userspace-Tailscale mode, with the phone link on and the real phone connected, ask the owner to run `netstat -an -p tcp | grep 47821` (or `lsof -nP -iTCP:47821`) and note whether the established connection's foreign address is 127.0.0.1 or a 100.x tailnet address (the PairVox log does not record the peer address, so the OS socket table is the observation). Also have the owner read the tailnet ACL policy to list which devices can reach port 47821 on the Mac. Do not send test traffic.

## MCP and other tools are approved by name only, with no arguments shown or spoken

Fingerprint: `policy/unrecognized-tool-approval-omits-arguments`

Every tool that is not Read-class, WebFetch, a file-write tool or Bash (all MCP tools, Task, Agent and any future tool) reaches the default case of PermissionPolicy.assess: medium risk, voice-approvable, summary 'Use <name>', spoken 'Claude wants to use <name>. Allow?'. The on-screen permission card renders only assessment.summary and reasons, and no app view renders request.input. A spoken yes or a click therefore approves an MCP call (for example send, post or delete) whose arguments (recipient, body, target), shaped by model output or tool-result content, nobody was shown, and the response returns the full original input as updatedInput. 'Always Allow (this session)' extends the approval to later calls of that tool when the CLI supplies suggestions. Repository-level MCP servers are not loaded by default (--setting-sources user), so the reachable tools are the owner's own user-level MCP servers. The same gap was already noted in docs/security/2026-10-13-phase1-hardening.md (lines 60 and 104). The optional AI explanation (RequestAdvisor) is the only place the serialized input is used, and it is model-written and off the approval path.

**Claimed root cause.** The approval object shown or spoken for unrecognized tools is only the tool name, while the handler executes the complete argument object, and the default case is rated medium and so remains voice-approvable.

**Trace**

1. `Sources/PairVoxCore/Protocol/InboundMessage.swift:351` (entrypoint, PermissionRequest.init(requestID:body:)): tool_name and input arrive from the claude child as shaped by model output and tool content.
2. `Sources/PairVoxCore/Policy/PermissionPolicy.swift:148` (propagation, PermissionPolicy.assess default case): risk is medium, summary is 'Use <name>', and the spoken prompt carries the name only; voiceApprovable stays true because risk < .high and screenOnly is false.
3. `Sources/PairVoxApp/Views/PermissionCardView.swift:82` (propagation, PermissionCardView.summaryText): The card shows pending.assessment.summary and the reasons list only; request.input is not rendered anywhere in the app views.
4. `Sources/PairVoxCore/Protocol/OutboundMessage.swift:38` (sink, OutboundMessage.permissionResponse): The allow response carries the complete original request.input as updatedInput, so the child runs the tool with the arguments the owner never saw.

**Evidence**

- `Sources/PairVoxCore/Policy/PermissionPolicy.swift:151`: summary = "Use \(name)" with no input, and no reason is added for unknown tools.
- `Sources/PairVoxCore/Conversation/ConversationEngine.swift:1404`: ToolSummary.describe lists arguments for Read, Bash, Grep, Glob, WebSearch and WebFetch but has no MCP case, so the transcript label for an MCP tool is also name only.
- `Sources/PairVoxCore/Advisor/RequestAdvisor.swift:60`: The only consumer of the serialized request input is the optional AI explanation, which is model-written and not part of the approval gate.
- `docs/security/2026-10-13-phase1-hardening.md:104`: A prior audit already recorded that default-case tools show 'Use <name>' with no input yet are voice-approvable.

**Blockers**

- Target execution was unavailable in this run, so the assess() output for an MCP request was not observed; the source prediction is summary 'Use <name>' and voiceApprovable true.
- Whether the owner has side-effecting MCP servers configured at user level (and whether the owner has a user-level allow rule that would already skip the prompt) is a deployment fact outside the repository.

**Resolution plan**

- Local: Add a test in PermissionSummaryTests (Tests/PairVoxCoreTests) that builds PermissionRequest(toolName: "mcp__mail__send_message", input: ["to": "x@example.invalid", "body": "dummy"]) with a dummy project root, calls PermissionPolicy(...).assess(request), and asserts that summary and spokenPrompt mention the arguments (or that voiceApprovable is false). Source predicts summary == 'Use mcp__mail__send_message' (or displayName), spokenPrompt without 'x@example.invalid', and voiceApprovable == true. Run it with the Linux/native swift test only inside the approved sandbox.
- Owner-observed: Ask the owner to list the MCP servers in their user-level Claude Code settings (claude mcp list --scope user, or the mcpServers key in ~/.claude.json) and name any with send, post, write or delete tools; then, with a dummy server and a harmless tool, make Claude call it in a PairVox session and note whether the permission card and spoken prompt show the call's arguments. No traffic to any real service is needed.

## A question or loose phrase containing an approve word approves a waiting request

Fingerprint: `voice/spoken-approval-grammar-accepts-questions-and-contained-words`

VoiceCommand.permissionAnswer treats any utterance of five words or fewer that contains an approve word (yes, ok, okay, sure, fine, allow, approve, confirm, definitely, absolutely, and others) or an approve phrase as a substring as an approval, and the bare word 'always' as always-allow. ConversationEngine.process dispatches that parsed command before it reaches the branch that sends a spoken question about the pending request to the advisor. So 'Is that okay?', 'Should I allow it?' or 'sure, what does that do' (all five words or fewer, no refusal word) approve the request on screen, and 'always' alone approves it with the CLI's suggested session rules, when the request is voice-approvable and fresh (300 s). The same parser backs the phone's spokenAnswer (LinkHost.swift:381-384) and cross-project announcement replies. The engine comment at line 312 says a question is 'never taken as a refusal', but a question that contains an approve word is taken as a yes. 'Should I confirm high risk' (five words) also satisfies isHighRiskConfirmation when the owner enabled spoken confirmation. Bounding controls seen in source: requires a pending request that has been announced (catch-up not open), a refusal word anywhere cancels it, high-risk and non-voice-approvable requests are refused on this path, stale requests are refused. Anyone audible can already say 'yes' by design, so the added impact is mainly an unintended approval of a medium-risk request when the owner (or room audio) asks a question, not a new principal gaining authority.

**Claimed root cause.** The approval grammar is an any-word match over a short utterance instead of a closed set of whole-utterance answers, and the question-detection branch in process() runs after command dispatch, so it never sees utterances the grammar already accepted.

**Trace**

1. `Sources/PairVoxCore/Conversation/ConversationEngine.swift:247` (entrypoint, ConversationEngine.submit): A transcript from the microphone (any audible speaker) or typed text enters the engine.
2. `Sources/PairVoxCore/Conversation/VoiceCommand.swift:193` (propagation, VoiceCommand.permissionAnswer): With awaitingPermission true, 'is that okay' has no refusal word and 'okay' is in approveWords, so the result is .approve; 'always' alone returns .approveAlways (line 202). parse() calls it at line 100 after only the explain list is checked.
3. `Sources/PairVoxCore/Conversation/ConversationEngine.swift:303` (propagation, ConversationEngine.process): The parsed command is performed and process returns at line 306, before the question-for-advisor check at line 313 is reached.
4. `Sources/PairVoxCore/Conversation/ConversationEngine.swift:876` (sink, ConversationEngine.perform(.approve)): For a fresh, voiceApprovable request, approvePending sends behavior allow (or allow with session rules for .approveAlways) to the claude child.

**Evidence**

- `Sources/PairVoxCore/Conversation/VoiceCommand.swift:205`: approving = words.contains(where: approveWords.contains) || approvePhrases.contains { core.contains($0) }, bounded only by a word count of 5 (line 195) and the refusal-word check (line 196).
- `Sources/PairVoxCore/Conversation/ConversationEngine.swift:313`: The question branch (text.hasSuffix("?") routed to askAboutPending) sits after the command dispatch at line 303 and only handles questions that contain no approve word; the existing test (AdvisorTests.swift:122-132) uses 'Is this safe?', which has none.
- `Sources/PairVoxCore/Conversation/VoiceCommand.swift:201`: core == "always" returns .approveAlways, which applies the CLI's suggested rules to the session.
- `Sources/PairVoxLink/LinkHost.swift:384`: The phone's spokenAnswer path uses the same VoiceCommand.spokenAnswer parser, so the loose grammar is shared.

**Blockers**

- Target execution was unavailable in this run (no enforceable sandbox), so the parse result and the engine response were established from source only; no observed local result exists.

**Resolution plan**

- Local: In Tests/PairVoxCoreTests (dummy data only), add a test. Step 1: for each of "Is that okay?", "Should I allow it", "sure what does that do" and "always", assert VoiceCommand.parse(text, context: .init(awaitingPermission: true)) is nil or not .approve/.approveAlways (source predicts .approve, and .approveAlways for 'always'). Step 2: reuse the AdvisorTests harness (makeEngine(advisor: FakeAdvisor()), submit("Fix it"), backend.emit(edit("A")), settle()), then submit("Is that okay?") and assert backend.responses is empty and the advisor answer path ran (source predicts one allow response and no advisor call). Run with swift test --build-system native --filter on the new test, in a sandboxed environment.

## A spoken yes counts for a request whose prompt has not been played yet

Fingerprint: `voice/spoken-approval-not-bound-to-delivered-prompt`

showPermission publishes snapshot.pendingPermission at once and only queues the spoken prompt (force: true bypasses the barge-in hold, not the playback queue), behind any prose already queued from the same turn. process() sets VoiceCommand.Context.awaitingPermission whenever pendingPermission is non-nil (only catchUpOpen suppresses it), and permissionAnswer() then parses any utterance of five words or fewer that contains an approve word or phrase ('okay', 'yeah sure', 'sounds good', 'go ahead') as .approve. A reply to Claude's preceding sentence that is transcribed after the request arrived, or spoken while the prompt is still queued, can therefore approve a voice-approvable (low or medium risk) request the owner has not yet been told about. The same 'okay' would otherwise be a harmless backchannel (VoiceCommand.swift:103 applies only when no request is awaiting). perform(.approve) checks only catchUpOpen, staleness (an upper age bound of 300 s) and voiceApprovable; it never checks that the prompt utterance has started. Source-visible mitigations: the request is shown on screen at once, high-risk requests are not voice-approvable, and the exposure needs an owner (or someone audible) to say an approving short phrase in that window. The prompt-injection amplification (model prose invites the reply, then the request follows) is plausible from source but not observed. Execution was unavailable, so the ordering is source-derived only.

**Claimed root cause.** PendingPermission carries no 'prompt delivered' state and no lower time bound, so the voice-approval gate checks request age and risk but not that the owner heard this request before answering.

**Trace**

1. `Sources/PairVoxCore/Conversation/ConversationEngine.swift:994` (entrypoint, ConversationEngine.handleSession(.permissionRequested)): A can_use_tool request from the child (shaped by model output and repository content) is assessed; if not folder-granted or auto-approved it becomes a PendingPermission and is passed to showPermission.
2. `Sources/PairVoxCore/Conversation/ConversationEngine.swift:1221` (propagation, ConversationEngine.showPermission): snapshot.pendingPermission is set immediately; the prompt is only queued through speak(force: true), behind earlier queued prose, and may not start before an answer arrives.
3. `Sources/PairVoxCore/Conversation/ConversationEngine.swift:270` (propagation, ConversationEngine.process): awaitingPermission is true as soon as pendingPermission is non-nil (only catchUpOpen suppresses it), so VoiceCommand.parse maps 'okay' or 'sounds good' to .approve via permissionAnswer.
4. `Sources/PairVoxCore/Conversation/ConversationEngine.swift:871` (sink, ConversationEngine.perform(.approve)): Only isStale and assessment.voiceApprovable are checked before approvePending sends allow to the child; nothing consults startedIDs or the prompt utterance id.

**Evidence**

- `Sources/PairVoxCore/Conversation/ConversationEngine.swift:856`: The only 'not announced yet' guard is guard !catchUpOpen; startedIDs (line 75, set at 1122) is consulted only by dropCourtesyLinesBeforeSubstance (line 1292), never by the approval path.
- `Sources/PairVoxCore/Conversation/EngineModels.swift:121`: PendingPermission has request, assessment, explanation, questions and receivedAt, with no announced or prompt-id field; isStale (line 137) is an upper age bound only.
- `Sources/PairVoxCore/Conversation/VoiceCommand.swift:100`: With awaitingPermission, permissionAnswer(core) accepts up to five words containing an approve word (approveWords line 154: 'okay', 'sure', 'yeah' and others) or approve phrase (line 156: 'sounds good', 'go ahead'); the backchannel branch at line 103 applies only when no request is awaiting.
- `Sources/PairVoxCore/Conversation/ConversationEngine.swift:278`: A paused barge-in is committed by the approving utterance, so the queued prompt is dropped to interruptedRemainder rather than played before the approval is applied.

**Blockers**

- Target execution was unavailable in this run (no enforceable sandbox for target code), so the ordering (prose queued before the prompt, an answer arriving before the prompt starts) was not observed.

**Resolution plan**

- Local: In Tests/PairVoxCoreTests/EngineApprovalTests.swift (FakeOutput in EngineTests.swift does not auto-play; playNext() is manual): submit 'Fix it'; backend.emit(.textDelta or the project's equivalent event, 'I will update the config.') so prose is queued; backend.emit(edit("A","a.swift")); await settle(); assert output.queue contains the .prompt utterance and no .started event was yielded for it; then await engine.submit("sounds good") and await settle(). Assert backend.responses.count. Source predicts one .allow response for request A before the prompt was ever started (the defect); the desired behaviour is no response and a repeated prompt. Repeat with submit("okay") and with a pausable FakeOutput after userStartedSpeaking() to cover the barge-in path. A fix records the prompt utterance id in PendingPermission and counts spoken answers only after that utterance's .started event.
