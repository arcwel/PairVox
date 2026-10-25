# Needs validation: PairVox audit run 9 (2026-10-25)

Source-grounded leads, no severity; no target code ran in the audit. Each one is fixed on `main` with a regression test (REPORT.md §4).

## Second 'allow all' can approve an armed request that has gone stale since it was read out

Fingerprint: `ConversationEngine.swift:approveAllWaiting-second-confirmation-unbound-to-readout-and-age`

A first spoken 'allow all' with several requests waiting reads them and arms their ids (approveAllArmed); a second 'allow all' approves them. At the first call the code keeps only fresh, voice-approvable requests, but the armed set records only ids. Nothing clears it with time, only a different utterance does. At the second call the code recomputes `eligible` (fresh and voice-approvable) only to run an `isEmpty` guard, then passes the whole armed id set to approveAllWaiting(requestIDs:), which re-checks only id membership and voiceApprovable. If the head request has passed Announcer.staleAfter (300 s) between the two utterances while at least one later-queued request is still fresh, the guard passes and the stale head is allowed by voice, which the single-request path (:913) and the arming step refuse. Source also shows a weaker variant: the second utterance is gated by answerPrecedesPrompt(for: head), which compares against the head request's promptHeardAt, not the readout's start, so a second 'allow all' begun before the readout starts playing is accepted. This is limited: once the readout starts, its text contains 'allow all' and isOwnPromptEcho rejects a matching utterance; it needs the owner (or a room voice) to say 'allow all' twice with no other speech in between; every id is a medium-risk voice-approvable request the user could approve one by one, high-risk ones are excluded; and a room speaker can already reach the same result by saying both phrases promptly. Likely low severity: an inconsistency in a freshness and informed-confirmation control, not a new authority.

**Claimed root cause.** The armed state (approveAllArmed) stores only request ids. It stores neither the arming time nor the readout's start, and the confirming step re-applies freshness only as a non-empty check on the recomputed list, not as a filter on the armed ids. approveAllWaiting(requestIDs:) filters by id and voiceApprovable only.

**Trace**

1. `Sources/PairVoxCore/Conversation/ConversationEngine.swift:931` (entrypoint, ConversationEngine.perform(.approveAllWaiting), first call): Spoken 'allow all' (room audio or owner) is parsed; the head and queued requests are filtered by voiceApprovable and !isStale (:936); approveAllArmed is set to their ids (:947) and the readout is queued with speakPrompt (:953).
2. `Sources/PairVoxCore/Conversation/ConversationEngine.swift:316` (propagation, ConversationEngine.submit): The armed set is cleared only when an utterance parses to something other than .approveAllWaiting; elapsed time never clears it.
3. `Sources/PairVoxCore/Conversation/ConversationEngine.swift:942` (propagation, ConversationEngine.perform(.approveAllWaiting), second call): Recomputed `eligible` (:936) only feeds the isEmpty guard (:937); `if let armed = approveAllArmed` then passes the full armed id set to approveAllWaiting without intersecting it with `eligible` or re-checking age.
4. `Sources/PairVoxCore/Conversation/ConversationEngine.swift:736` (sink, ConversationEngine.approveAllWaiting(requestIDs:)): eligible() is ids.contains(requestID) && voiceApprovable only; sendDecision(.allow) is issued for every matching queued request and respondToPermission(.allow) for the head, with no isStale check, so a request older than 300 s is allowed by voice.

**Blockers**

- Target execution was unavailable in this run (no enforceable sandbox for target code), so the outcome comes from source only.
- Impact is bounded to medium-risk voice-approvable requests and needs two or more requests waiting with the head aging past 300 s between two uninterrupted 'allow all' utterances; whether this matters is a product judgement on how much the stale and readout rules are meant to hold for a repeated allow-all.

**Resolution plan**

- Local: Add an XCTest beside the allow-all tests in Tests/PairVoxCoreTests/EngineApprovalTests.swift using the settable FakeClock (dummy data only, typed submit so answerSpokenAt is nil). Steps: submit 'Do the work'; set clock to T0; emit edit('A','a.swift'); settle; advance clock 200 s; emit edit('B','b.swift'); settle; advance 50 s (A is 250 s old, B 50 s); submit 'allow all' and assert backend.responses is empty (armed A and B); advance 100 s (A is 350 s old and stale, B is 150 s old and fresh); submit 'allow all' again; settle. Invariant to assert: A is not in backend.responses (a request older than Announcer.staleAfter is not allowed by voice). Source predicts A and B are both allowed, so the assertion fails and shows the defect. Optionally add a variant asserting that a second 'allow all' submitted before any FakeOutput .started event for the readout utterance does not approve; source predicts it does, so this variant is expected to fail only if typed text is treated as unconstrained timing, and is secondary.

## Spoken-approval timing and own-echo checks use a single shared speech-start slot that can be overwritten or cleared before the right transcript is processed

Fingerprint: `ConversationEngine.swift:speechStartedAt-single-slot-loses-timing-for-spoken-approvals`

Spoken approvals (yes, always, confirm high risk, allow all, and the folder-offer yes and confirm) are gated on when the answer's speech began: an answer begun before the request's prompt started is ignored, and one that matches PairVox's own prompt while it plays is ignored as an echo. The begin time is one optional Date shared by all utterances. Each VAD speech start overwrites it, and process() and transcriptionFailed() consume or clear it. VoiceInputController starts a separate unordered Task for each VAD start and each segment's transcription, so pairing between a segment and its start time is not preserved. If a second segment starts, or a sub-0.3 s blip calls transcriptionFailed(), before an earlier segment's transcript is submitted, one of two things happens. The earlier transcript is stamped with the later segment's (possibly post-prompt) start time, or it arrives with answerSpokenAt == nil. answerBeganBeforePrompt and isOwnPromptEcho both read nil as typed text and return false, so both checks are skipped and the answer is counted. Source supports this fully. It was not executed. The affected approvals are limited to voice-approvable (medium-risk) requests, high-risk requests when the owner enabled spoken confirmation, and folder grants with spokenHighRiskConfirmation on. The practical result is that a reply meant for something else, or PairVox's own prompt heard back, can approve a request the owner has not yet heard. No new principal is involved: a voice in the room already counts after the prompt plays, so the added exposure is the lost timing gate. It also needs a coincident second segment or a click or cough blip.

**Claimed root cause.** Timing provenance for a spoken answer is a single mutable slot (speechStartedAt) rather than a value carried with each utterance. userStartedSpeaking overwrites it, process() and transcriptionFailed() reset it, and VoiceInputController runs the start, the transcription and the submit for each VAD segment in independent Tasks, so segment-to-transcript pairing is not preserved. A nil value is read as the deliberate typed-text case, so losing the value turns off the checks instead of failing closed.

**Trace**

1. `Sources/PairVoxVoice/VoiceInputController.swift:213` (entrypoint, VoiceInputController.handle): Every VAD speech start spawns Task { await engine.userStartedSpeaking() }, even while an earlier segment is still being transcribed. The call is not ordered against the other segments' tasks.
2. `Sources/PairVoxCore/Conversation/ConversationEngine.swift:180` (propagation, ConversationEngine.userStartedSpeaking): speechStartedAt = typed ? nil : now() overwrites the single slot unconditionally.
3. `Sources/PairVoxVoice/VoiceInputController.swift:239` (propagation, VoiceInputController.finishUtterance): Each segment runs its own Task. A blip under 0.3 s calls engine.transcriptionFailed() (line 244), which clears the slot (ConversationEngine.swift:259). Other segments call engine.submit(text) (line 262) when their transcription finishes, in any order.
4. `Sources/PairVoxCore/Conversation/ConversationEngine.swift:287` (propagation, ConversationEngine.process): answerSpokenAt = answersPermissions ? speechStartedAt : nil; speechStartedAt = nil. The first transcript to arrive takes the latest start time, and the next one gets nil.
5. `Sources/PairVoxCore/Conversation/ConversationEngine.swift:1306` (propagation, ConversationEngine.answerBeganBeforePrompt): guard let spoken = answerSpokenAt else { return false }: a nil time is never 'before the prompt'. isOwnPromptEcho (line 1284) returns false for a nil spokenAt too; process passes answerSpokenAt at line 335.
6. `Sources/PairVoxCore/Conversation/ConversationEngine.swift:903` (sink, ConversationEngine.perform(.approve/.approveAlways/.confirmHighRisk/.approveAllWaiting)): With both checks skipped, a spoken yes reaches approvePending for a voice-approvable, non-stale request (line 918). confirm high risk approves a high-risk one when the owner enabled it (lines 964-974). yes and confirm advance and finish a folder grant via answerGrantOfferBySpeech (line 1320).

**Blockers**

- Target execution was unavailable in this run (no enforceable sandbox for target code), so the mis-pairing and nil-time behaviour were established from source only.
- Whether real room audio or speaker echo produces a second VAD segment or a sub-0.3 s blip close enough in time depends on the VAD, echo cancellation and Whisper latency. That is not observable from source and sets the realistic likelihood.

**Resolution plan**

- Local: Add a bounded XCTest in Tests/PairVoxCoreTests using FakeBackend, FakeOutput and the settable clock, with dummy data only. (1) Emit a medium-risk Edit permission request and do not let its prompt start (no .started output event). (2) Call engine.userStartedSpeaking() twice, then engine.submit("okay") and engine.submit("yes"). Under the intended invariant neither is counted and the backend gets no approval. Per source the second submit has answerSpokenAt == nil and approves. (3) Repeat with userStartedSpeaking(); userStartedSpeaking(); transcriptionFailed(); submit("yes"). (4) Advance the clock past the prompt start between the two starts, so the first transcript receives the later start time, and assert that an early "yes" is then counted. (5) Echo check: set spokenHighRiskConfirmation, emit rm -rf build, mark the prompt .started in FakeOutput, call userStartedSpeaking() twice, then submit("hello") and submit("confirm high risk") during playback, and assert the high-risk request is not approved. (6) Folder offer with spokenHighRiskConfirmation on: two quick starts, submit("yes") before the offer prompt starts, and assert the stage stays .asking.
- Owner-observed: Owner-observed, non-destructive: with log verbosity that records 'vad.speech.start' and 'user.submit', run the Mac app with a medium-risk request waiting whose prompt has not yet played. Say a short word, then 'yes' within about a second, and check the log for a 'permission.answerBeforePrompt' entry. A missing entry with the request approved shows the checks were skipped.

## Wrapper before env (nice env, time env, command env, timeout 5 env) is rated medium, so a shell folder grant auto-allows a command that prints the environment

Fingerprint: `PermissionPolicy.swift/environment-print-hidden-behind-wrapper-program`

BashRisk.segments skips wrapper words, and env is itself in wrapperNames. For 'nice env', 'time env', 'command env', 'nohup env' or 'timeout 5 env' the loop consumes both words and leaves an empty program. The structural environment check only flags an empty program when the segment's first word is env, and here the first word is the outer wrapper. The regex rule needs env at the start of the command or right after ; & | or (, so it also misses these strings. Nothing else matches, the command is not in the read-only list, and classify ends at medium with 'Not a recognized read-only command.'. When the owner has an allowShell folder grant covering the project, FolderScope.shellGrant finds no disqualifying reason, no $, quote, brace or slash, and returns the grant. ConversationEngine then answers allow without any prompt. The command prints the child's full environment, which in API-key mode includes the API key, into the model's context (model output or repository content can steer this). Without a grant the request is medium, voice-approvable, and spoken as the wrapper name, which is a weaker concern. The same strings inside sh -c are not caught either, since the nested body is classified by the same rules. Read from source only: the sandbox needed to run classify() was unavailable.

**Claimed root cause.** BashRisk.structuralFindings tests 'program.isEmpty && leading == "env"' where leading is the first word of the segment. When env follows another wrapper, the wrapper loop in segments() has already swallowed it, leading is the outer wrapper's name, and neither the structural check nor the command-position regex covers wrapped env.

**Trace**

1. `Sources/PairVoxCore/Conversation/ConversationEngine.swift:1043` (entrypoint, permissionRequested): A can_use_tool Bash request from the claude child (model output, possibly steered by repository content) is assessed with policy.assess.
2. `Sources/PairVoxCore/Policy/PermissionPolicy.swift:410` (propagation, BashRisk.segments): The wrapper loop drops 'nice' (or time, command, nohup, timeout plus its numeric duration), then drops 'env' because env is in wrapperNames (line 368), leaving program empty and args empty.
3. `Sources/PairVoxCore/Policy/PermissionPolicy.swift:459` (propagation, BashRisk.structuralFindings): The env-print finding needs leading == "env", but leading is the first word of the segment ('nice'), so no high finding. The regex rule at line 313 needs env at the start or after ; & | (, so it also misses. classify reaches the medium fallback at line 737.
4. `Sources/PairVoxCore/Policy/PermissionPolicy.swift:204` (propagation, PermissionPolicy.assess): risk is medium and not high, so the folder-grant branch runs and calls FolderScope.shellGrant.
5. `Sources/PairVoxCore/Policy/FolderGrants.swift:95` (propagation, FolderScope.shellGrant): The only reason is 'Not a recognized read-only command.', which is not in shellDisqualifiers. The string has no $, backtick, quote, brace, bracket or path token, so the allowShell grant covers it and coveredByFolderGrant is true.
6. `Sources/PairVoxCore/Conversation/ConversationEngine.swift:1046` (sink, permissionRequested): coveredByFolderGrant is true, so the engine responds allow without asking. The command runs and its output, the environment, is returned to the model.

**Blockers**

- Target execution was unavailable in this run (no enforceable sandbox for target code), so BashRisk.classify and PermissionPolicy.assess were not run on these strings. The result is derived by reading the code and the trace was re-checked line by line.
- Impact depends on the owner having granted allowShell for the project folder. Without a grant the command is medium and needs a click or a spoken yes (heard as the wrapper name), so the automatic allow is not reached.

**Resolution plan**

- Local: In a bounded XCTest with dummy paths (no real home or credentials), build PermissionPolicy(projectRoot: root, grants: [FolderGrant(path: root, allowShell: true)]) and call assess on Bash requests for 'nice env', 'time env', 'command env', 'nohup env', 'timeout 5 env', 'nice -n 5 env' and 'sh -c "nice env"'. Expected with the current code: risk == .medium and coveredByFolderGrant == true. Expected after the fix: risk == .high, coveredByFolderGrant == false, voiceApprovable == false. Fix: in segments(), also record the wrapper words that were skipped, and in structuralFindings treat an empty program whose skipped words include env (or printenv) as the high 'Reads the environment' finding. Add these strings to testPrintingTheEnvironmentIsHighAndNeverCoveredByAShellGrant.

## ps environment rule misses later flags and any wrapped or path-qualified ps (ps -ax -E, nice ps eww), so a shell grant auto-allows it

Fingerprint: `PermissionPolicy.swift/ps-environment-rule-first-arg-and-command-position-only`

Audit run 8 added one regex that rates 'ps' high only when ps sits at command position directly after start or ; & | ( and its first argument contains e or E. 'ps -ax -E', 'ps -A -E', 'ps -p 1 -E' (the e flag in a later argument), 'nice ps eww', 'command ps -E', and a ps on a new line after another command are not matched. structuralFindings has no ps handling (unlike env and printenv), and 'ps' is not in readOnlyCommands, so these commands end as medium 'Not a recognized read-only command'. FolderScope.shellGrant accepts a medium Bash request with no disqualifying reason, no $, backtick, inline code, brace/bracket characters or out-of-folder path token, so a folder with allowShell makes ConversationEngine answer allow with no prompt. On macOS ps -E (or the e flag) prints each same-user process's environment, including the claude child's (ANTHROPIC_API_KEY in API-key mode), and the output goes back to the model. Path-qualified forms such as '/bin/ps -E' are not covered by a grant because the path token falls outside the folder, so they would still be asked; only a spoken yes to a medium request applies there. Source verified: the hunter's trace is accurate except that the allow sink is at ConversationEngine.swift:1046 (the check is at 1044). Limited to forms the run 8 fix says it rates high; the policy is otherwise heuristic (python -c os.environ is medium too, but inline code is disqualified from grants).

**Claimed root cause.** The ps environment recognizer is a single command-position regex that inspects only the first argument; structuralFindings has no ps handling, so a later flag, a wrapper (nice, command, time), or a command after a newline is not normalised and the command stays medium and grant-coverable.

**Trace**

1. `Sources/PairVoxCore/Conversation/ConversationEngine.swift:1042` (entrypoint, ConversationEngine.permissionRequested): A Bash can_use_tool request such as 'ps -ax -E', shaped by model output or repository content, arrives from the claude child and is assessed.
2. `Sources/PairVoxCore/Policy/PermissionPolicy.swift:310` (propagation, BashRisk.rules (ps rule)): Pattern '(^|[;&|(]\s*)ps\s+(-?[A-Za-z]*[eE][A-Za-z]*)(\s|$)' needs ps at command position and an e/E letter in the first argument; '-ax', '-A', '-p' contain none, and 'nice ps' or a newline-preceded ps is not at command position. No match.
3. `Sources/PairVoxCore/Policy/PermissionPolicy.swift:737` (propagation, BashRisk.classify): No rule or structuralFindings entry mentions ps, and ps is not in readOnlyCommands, so the result is medium 'Not a recognized read-only command'.
4. `Sources/PairVoxCore/Policy/FolderGrants.swift:89` (propagation, FolderScope.shellGrant): risk <= .medium, no disqualifying reason, no $ or backtick, no inline code, none of {}[]!*?\ characters, no path tokens (flag tokens without a slash are skipped), so an allowShell grant covers the request.
5. `Sources/PairVoxCore/Conversation/ConversationEngine.swift:1046` (sink, ConversationEngine.permissionRequested): coveredByFolderGrant is true, so the engine responds .allow without asking; ps output with process environments goes back to the model.

**Blockers**

- Target execution was unavailable in this run (no enforceable sandbox, no local Linux Swift image), so BashRisk.classify and PermissionPolicy.assess were not run; the result is derived by reading the regex and code paths.
- Whether macOS ps prints the environment of the claude child for these flag spellings (-ax -E, -A -E, -p PID -E) is an OS fact only the owner can confirm on a Mac; it is documented for -E and the e flag.
- Impact needs an allowShell folder grant on the project (the owner's opt-in) or a spoken yes to a medium request, and an API-key-mode session for a key to be in the environment.

**Resolution plan**

- Local: Add a bounded XCTest in Tests/PairVoxCoreTests with dummy data only: projectRoot '/Users/dev/app' and a FolderGrant(path: that root, allowShell: true). For each of 'ps -ax -E', 'ps -A -E', 'ps -p 1 -E', 'nice ps eww', 'command ps -E', 'echo x\nps -E' call policy.assess(PermissionRequest(requestID:'r', toolName:'Bash', input:['command': ...])) and record risk and coveredByFolderGrant. Expected today: .medium and coveredByFolderGrant true for all; '/bin/ps -E' expected .medium but not covered (path token outside the folder). Control: 'ps -E' and 'ps eww' are .high and not covered. After a fix every listed form should be .high with voiceApprovable false. Fix: in structuralFindings add a branch for program == 'ps' that rates high when any argument is a bare 'e'/'eww' word or a short-flag group containing e/E (including a leading '-'), after wrapper skipping and path stripping, and extend the AuditRun8PolicyTests list; alternatively add ps to the shell-grant disqualifiers.
- Owner-observed: Owner check on a Mac, no audit traffic to any deployment: in Terminal run 'ps -ax -E | head -c 400' and 'ps -p $$ -E' as the same user and confirm the output contains environment variables for same-user processes (use a dummy variable such as PV_TEST=1 exported in that shell, not a real key).

## Lock-screen Allow is offered for a multi-line summary of 160 characters or fewer that the banner may not show in full

Fingerprint: `ios-lockscreen-allow-body-length-not-display-bound`

Run 8 withholds the lock-screen Allow button when the request summary is cut for the banner (over 160 characters), on the premise that the end of a long command would not be seen. The test is a Character count only. A Bash summary is 'Run: ' plus the raw model-chosen command, newlines included, so a short command with many blank or short lines stays under 160 characters while iOS may show only a few body lines. Allow is still offered, and the Mac accepts the answer because LinkHost.approvalRefusal applies the same count-only predicate. The project's own small-surface rule, PermissionAssessment.fitsCompactSurface, forbids newlines and caps length at 90, and is not applied here. Source verification: the path is real and the control is count-only. Impact is bounded and low. The hidden lines must still be rated below high, voice-approvable and non-network by BashRisk. The tap path already approves medium-risk requests without these checks, the phone is unlocked (.authenticationRequired), and the full card is in the app. Whether the tail is actually hidden depends on iOS line limits and the Show Previews setting.

**Claimed root cause.** RequestNotice.allowsLockScreenAnswer uses request.summary.count <= 160 (grapheme clusters) as the proxy for 'shown whole'. It bounds neither line count nor newlines, unlike PermissionAssessment.fitsCompactSurface. LinkHost.approvalRefusal reuses the same predicate, so the Mac has no independent check.

**Trace**

1. `Sources/PairVoxCore/Policy/PermissionPolicy.swift:137` (entrypoint, PermissionPolicy.assess (Bash case)): summary = "Run: \(command)" with the model-chosen (possibly prompt-injected) command verbatim, newlines included. Each segment is classified by BashRisk, so a multi-line command of medium risk stays voice-approvable.
2. `Sources/PairVoxLink/EngineLink.swift:22` (propagation, EngineLink.snapshot(from:)): The assessment summary is copied into LinkRequest.summary unchanged; nothing bounds newlines or line count.
3. `Sources/PairVoxLinkKit/RequestNotice.swift:43` (propagation, RequestNotice.allowsLockScreenAnswer): Allow is offered when risk != high, not truncated, not needsScreen, voiceApprovable and summary.count <= 160. make() (line 33) puts the summary in the notification body as is.
4. `ios/PairVoxPhone/PhoneModel.swift:434` (propagation, PhoneModel.handle(.snapshot)): When the app is not active the notification is posted with the Allow and Deny actions (.authenticationRequired, so the phone must be unlocked).
5. `Sources/PairVoxLink/LinkHost.swift:451` (sink, LinkHost.approvalRefusal (auth == .notification)): The Mac re-applies the same count-only predicate and the age limit, returns nil, and handle() then calls engine.approve (line 431) for a command whose later lines the banner may not have shown.

**Blockers**

- How many body lines iOS shows on the lock screen and in a banner for this notification, and whether body text is shown at all under Show Previews 'When Unlocked' or 'Never', depends on the iOS version and device notification settings. It is not observable from source.
- Target execution was unavailable in this run (no enforceable sandbox), so no unit test or device observation was made.

**Resolution plan**

- Local: Add a unit test in Tests/PairVoxLinkTests/LinkTests.swift with dummy data: build a LinkRequest with risk "medium", voiceApprovable true and summary "Run: ls\n\n\n\n\n\n\n\ntouch dummy.txt" (under 160 characters). Assert that RequestNotice.make(for:project:).offersButtons and RequestNotice.allowsLockScreenAnswer are false (today both are true), and, in the style of testTheMacHoldsALockScreenAnswerToTheLockScreenRule, that an approve with auth .notification is refused and engine.calls stays empty. A fix would add a newline check (and optionally a tighter length cap) to allowsLockScreenAnswer so the phone and the Mac refuse together.
- Owner-observed: Owner-observed check on a test iPhone: pair it to a test Mac, background the app, have a dummy project produce the multi-line Run request above, and record how many lines the lock-screen notification shows with Show Previews set to Always, When Unlocked and Never, and whether the last line is visible before Allow is tapped. Use dummy content only.

## The ad-hoc DMG built by release-assets.sh comes from the dry-run path, which does not refuse get-task-allow

Fingerprint: `release-assets/unsigned-dmg-skips-release-entitlement-and-hardened-runtime-gate`

scripts/release-assets.sh without --signed copies .build/release-dry/PairVox-X.dmg, built by `release.sh --dry-run` with SIGN_IDENTITY=-, into the folder that is hashed into SHA256SUMS and offered to `gh release create`. The real release path (release.sh lines 55-57) refuses a bundle carrying com.apple.security.get-task-allow or any unexpected entitlement. The dry run deliberately strips get-task-allow before comparing entitlements (line 93) and only prints an info line (line 95), so that DMG is never checked for it. If Xcode adds get-task-allow to the ad-hoc Release build, as the comment at release.sh:90 says, the DMG users download is debuggable: a same-user process can attach to it and read PSKs, a Keychain-held API key and audio from memory, and reuse its microphone and Apple Events grants. Hardened-runtime absence alone is a documented, deliberate choice for ad-hoc builds (build-app.sh:55-57, ad-hoc signatures have no Team ID so library validation would refuse the embedded frameworks), and the ad-hoc, non-notarized status is disclosed in docs/release-notes/v0.1.0-beta.1.md:26. The open question that decides the finding is whether the built ad-hoc app really carries get-task-allow. The impact is bounded to a same-UID local process, so severity would be low to medium at most. The mismatch with docs/security/2026-10-13-phase1-hardening.md:127 (release builds use hardened runtime) is a documentation inconsistency for the unsigned path. A remediation must not simply add --options runtime to an ad-hoc signature, because that would break framework loading.

**Claimed root cause.** release-assets.sh ships the output of the dry-run branch of release.sh, whose entitlement check is advisory (it removes get-task-allow from the comparison and only prints an info line), and adds no entitlement check of its own before the artifact is hashed and offered for publication.

**Trace**

1. `scripts/release-assets.sh:85` (entrypoint, main, unsigned branch): Runs scripts/release.sh VERSION --dry-run and treats exit status 0 as no problems.
2. `scripts/release.sh:51` (propagation, DRY branch): Builds with SIGN_IDENTITY=- into .build/release-dry; the get-task-allow refusal at lines 55-57 is in the else (real release) branch only.
3. `scripts/release.sh:93` (propagation, dry-run entitlement check): Removes get-task-allow from the entitlement list before comparing, and line 95 only prints an info line when it is present.
4. `scripts/build-app.sh:57` (propagation, ad-hoc signing branch): Adds ENABLE_HARDENED_RUNTIME=NO for identity '-' with no team; the comment at lines 55-56 states this is deliberate because library validation would refuse the embedded frameworks.
5. `scripts/release-assets.sh:86` (sink, main): Copies the dry-run DMG to $OUT/$DMG; only hdiutil verify (line 88) runs before it is hashed (line 116) and listed in the printed gh release create line (line 126).

**Blockers**

- Target execution was unavailable in this run (no enforceable sandbox), so the entitlements and runtime flag of a built ad-hoc PairVox.app were not read.
- Whether Xcode adds get-task-allow to a Release build of this project signed with CODE_SIGN_IDENTITY=- is a toolchain fact outside the repository source.

**Resolution plan**

- Local: On the release Mac, run scripts/release-assets.sh 0.0.0-test --out <new empty temp dir> (never gh release create), mount the DMG read-only with hdiutil attach -readonly, then run `codesign -d --entitlements :- /Volumes/<vol>/PairVox.app` and `codesign -dv --verbose=2 /Volumes/<vol>/PairVox.app`. Look for com.apple.security.get-task-allow and for `runtime` in the flags line. Present get-task-allow confirms the finding (impact: same-user process attach to the shipped app); absent get-task-allow rejects the entitlement part, leaving only the documented ad-hoc hardened-runtime exception. Fix if confirmed: in release-assets.sh unsigned mode, re-sign the bundle with `codesign --force --deep --sign - --entitlements Sources/PairVoxApp/PairVox.entitlements` (explicit entitlements file, no get-task-allow) or set CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO in the ad-hoc build, and add a check that fails the script when entitlement_keys of the DMG's app contains get-task-allow, with a fixture test. Do not add --options runtime to an ad-hoc signature without also accepting library-validation changes.
