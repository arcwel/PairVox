# Needs validation: PairVox audit run 7 (2026-10-24)

Source-grounded leads with an unresolved blocker, no severity. The shared blocker is that no target code ran in the audit. Each lead's local plan became a regression test in the fix (REPORT.md, section 4).

## Speech markdown parser re-copies the whole undecided line prefix for every character, giving quadratic stalls on the engine actor

Fingerprint: `markdown-speech-parser-line-start-requadratic-reclassify`

While the first characters of a model-authored line leave its kind undecided, MarkdownSpeechParser.processLineStart appends each character to lineStartBuffer and re-runs decide(final: false, line:) on the whole accumulated prefix. decide() starts by copying the prefix into a new String (line 136). A leading | (lines 216-220), a run of 3+ backticks or tildes (164-167), an all-# line (174), lines made only of -, *, +, _ or spaces (188, 196) and all-digit prefixes (206) return without clearing atLineStart, so every later character of the same line repeats the copy (some branches also run count, allSatisfy or filter over the prefix). A single line of n characters therefore costs about n^2/2 bytes of copying. The parser runs synchronously in the actor-isolated ConversationEngine.handleSession (ConversationEngine.swift:10, 978, 996 via SpeechPlanner.textDelta line 112), the same actor that serves interruptClaude, denyPending, approvePending and phone-link calls, so these wait until the loop ends. Text comes from the claude child's text_delta and can be steered by repository content (prompt injection). The verifier re-read the source and found no length cap on lineStartBuffer and no upstream bound other than the 64 MiB line cap and the model's own output budget. Impact is a bounded, self-recovering availability delay on the owner's own machine, not an approval bypass: a stalled engine approves nothing. Severity cannot be set without a measured growth curve.

**Claimed root cause.** decide(final: false, line:) is invoked per character over the whole lineStartBuffer; each call allocates and copies the trimmed prefix, and several classification branches return early without committing to a line kind, so the work is quadratic in line length with no cap on the buffer, and it runs on the engine actor.

**Trace**

1. `Sources/PairVoxCore/Session/ClaudeCLISession.swift:241` (entrypoint, ClaudeCLISession.handleStdout): Each stdout line from the claude child is parsed; text_delta content (steerable by repository content through the model) becomes a SessionEvent.
2. `Sources/PairVoxCore/Session/EventTranslator.swift:121` (propagation, EventTranslator.translateStream): A non-empty text_delta is emitted unchanged as .textDelta(t).
3. `Sources/PairVoxCore/Conversation/ConversationEngine.swift:996` (propagation, ConversationEngine.handleSession (actor)): speakFromPlanner(planner.textDelta(t)) runs inline on the engine actor, which also handles interrupt, deny, approve and phone-link requests.
4. `Sources/PairVoxCore/Speech/MarkdownSpeechParser.swift:61` (propagation, MarkdownSpeechParser.feed / process): feed calls process(ch) for every character; while atLineStart is true each character goes to processLineStart.
5. `Sources/PairVoxCore/Speech/MarkdownSpeechParser.swift:131` (propagation, MarkdownSpeechParser.processLineStart): Appends the character to lineStartBuffer and calls decide(final: false, line: lineStartBuffer) with the whole prefix.
6. `Sources/PairVoxCore/Speech/MarkdownSpeechParser.swift:136` (sink, MarkdownSpeechParser.decide): String(line.drop(while:)) copies the full prefix; the | case (217-220) and the fence-open (164-167), # (174), dash/star/plus/underscore (188, 196) and digit (206) cases return without leaving the line-start state, so the copy repeats for every later character of the same line.

**Blockers**

- Target execution was unavailable in this run (no enforceable memory or process limit for target code on this Mac, no local Linux Swift image), so the growth curve and the real stall time were not measured.
- Whether the claude child will emit a single line of several hundred KB starting with one of the undecided prefixes depends on model behaviour and on the output-token limit in the owner's Claude Code configuration, which are outside the repository.
- The per-character allocation and grapheme-counting cost depends on the platform's String and allocator behaviour, which only a run shows.

**Resolution plan**

- Local: In an approved sandbox (30 s wall clock, about 1 GB memory, no network), add one XCTest in Tests/PairVoxCoreTests that creates MarkdownSpeechParser() and times feed() on dummy strings "|" + String(repeating: "x", count: N) for N = 10_000, 20_000, 40_000, 80_000 (no newline), then repeats with "```" + x, "#" repeated, "-" repeated and "1" repeated. Pass if time about quadruples when N doubles for any family; extrapolate to 500_000. After the fix, the same inputs must scale linearly (ratio under 2.5 per doubling) and the existing MarkdownSpeechParserTests in SpeechTests.swift must be unchanged. Fix to test: classify from at most the first few characters (stop re-copying the prefix per character; keep a running state or commit the line kind once lineStartBuffer exceeds a small cap such as 16 characters) and buffer the rest without reclassifying.

## A dangling symlink inside the project is rated as a new file in the project, so a write through it is medium, voice-approvable and covered by a folder edit grant

Fingerprint: `policy/dangling-symlink-leaf-classified-inside-project-and-grant-covered`

FolderScope.resolved decides whether a write target is inside the project by stripping trailing components until FileManager.fileExists(atPath:) is true, then resolving symlinks only on that existing prefix and re-appending the stripped names. fileExists(atPath:) follows symlinks, so a symlink whose target does not exist returns false and the link's own name is re-appended under its resolved parent, as if it were a new file. A symlink committed to a repository (git stores dangling links) that points outside the project, for example to a not-yet-created launch agent plist or shell login file, is therefore classified as inside the project. PermissionPolicy.assess rates a Write/Edit/NotebookEdit through it medium with a spoken 'Allow?' prompt, and with an owner folder edit grant FolderScope.editGrant covers it, so ConversationEngine allows it with no prompt. If Claude Code's Write follows the link and creates the target, the file lands outside the project (persistence or code execution under the owner's account), steered by repository content. The sensitive-path needles run on the unresolved name and the protected-folder check uses the same blind resolution, so neither catches it. Source establishes the PairVox-side misclassification; whether the child actually writes through the link, and what decision_reason_type or blocked_path Claude Code sends for it, is not visible in this repository. Correction to the hunter wording: the fixture's blocked_path (line 195) is a Bash request whose blocked_path is the in-project path, not evidence of a symlink-resolved target; PermissionPolicy.assess only consults blockedPath when file_path and notebook_path are both absent.

**Claimed root cause.** FolderScope.resolved infers the real location from fileExists(atPath:), which follows symlinks and is false for a dangling link, so the leaf link is never resolved. PermissionPolicy.assess (isInsideProject, isSensitivePath's protected-folder check) and FolderScope.editGrant all depend on it and treat the link as a new in-project file.

**Trace**

1. `Sources/PairVoxCore/Protocol/InboundMessage.swift:351` (entrypoint, PermissionRequest.init(requestID:body:)): A can_use_tool request for Write/Edit/NotebookEdit arrives from the child with input.file_path set to the path of a dangling symlink inside the project; the model picks the path, steered by repository content.
2. `Sources/PairVoxCore/Policy/PermissionPolicy.swift:102` (propagation, PermissionPolicy.assess (fileWriteTools case)): path = file_path ?? notebook_path ?? blockedPath; risk is medium when isInsideProject(path) (line 106), high only when outside or isSensitivePath(path) (line 112). blockedPath is not consulted when file_path is present.
3. `Sources/PairVoxCore/Policy/FolderGrants.swift:35` (propagation, FolderScope.resolved): The loop strips trailing components while !fm.fileExists(atPath:). fileExists follows symlinks, so a dangling link is stripped as a missing file; line 39 resolves only the existing parent and line 40 re-appends the link's name, so the result stays under the project root.
4. `Sources/PairVoxCore/Policy/PermissionPolicy.swift:185` (propagation, PermissionPolicy.assess (folder grant coverage)): With risk medium and no safetyCheck flag, FolderScope.editGrant (FolderGrants.swift:51-56, same resolved/contains) returns the grant, so coveredByFolderGrant is true.
5. `Sources/PairVoxCore/Conversation/ConversationEngine.swift:1016` (sink, ConversationEngine event handling (.permissionRequested)): coveredByFolderGrant triggers backend.respond(to: request, decision: .allow) with no prompt; without a grant the medium rating still allows a spoken yes. The allow echoes the original input, and a write that follows the link would create the file at the outside location.

**Blockers**

- Target execution was unavailable in this run (no enforceable sandbox), so the PairVox classification of a dangling link has been read from source only and not observed.
- Whether Claude Code's Write/Edit follows a dangling symlink and creates the target, and whether its own permission layer already flags the resolved outside path (decision_reason_type, blocked_path, safetyCheck) for such a request, depends on the installed claude version and is not visible in this repository.

**Resolution plan**

- Local: Add a PairVoxCoreTests case using only temp dummy directories: create base/project and base/elsewhere; FileManager.createSymbolicLink(atPath: base/project/notes, withDestinationPath: base/elsewhere/not-yet-created.txt) with the target absent. Build PermissionPolicy(projectRoot: project, grants: [FolderGrant(path: project)]) and assess PermissionRequest(toolName: "Write", input: ["file_path": project/notes]). Source predicts risk == .medium, voiceApprovable == true and coveredByFolderGrant == true; the expected safe result is risk == .high and coveredByFolderGrant == false. Also assert FolderScope.contains(folder: project, path: project/notes) is false after a fix, and that FolderScope.resolved(project/notes) equals the resolved target path. Repeat for NotebookEdit with notebook_path. Run under swift test with a low timeout; never use real home folders.
- Owner-observed: Owner check on a dummy repository whose tracked file is a dangling symlink to a dummy path in a scratch folder (not a real LaunchAgents or login file): ask claude to Write to the link, read the can_use_tool frame in the PairVox log to record blocked_path and decision_reason_type, and check whether the file appears at the link's target. No audit traffic to any deployment.

## For NotebookEdit the policy classifies and grant-covers the file_path field, but the tool writes notebook_path

Fingerprint: `policy/notebookedit-file_path-shadows-notebook_path-in-classification`

PermissionPolicy.assess and FolderScope.editGrant both choose the write target as input.file_path first and input.notebook_path second for every file-write tool, NotebookEdit included. Source confirms there is no per-tool selection and no check that the two fields agree. If a NotebookEdit can_use_tool request carries a file_path inside the project and a notebook_path outside it (or at a sensitive notebook), the policy rates it medium, the card summary reads 'Edit <inside path>', the spoken prompt names the inside file, and an owner edit grant auto-allows it. The allow response echoes the original input, so the tool is invoked with the unclassified notebook_path. Whether Claude Code's NotebookEdit schema permits an extra file_path and still asks for permission is not visible in source.

**Claimed root cause.** The target-selection expression file_path ?? notebook_path is applied uniformly to all file-write tools instead of by tool name, so an extra field the tool ignores can mask the notebook_path the tool actually uses (schema and dispatcher disagreement).

**Trace**

1. `Sources/PairVoxCore/Protocol/InboundMessage.swift:355` (entrypoint, PermissionRequest.init(requestID:body:)): input is taken verbatim from the can_use_tool body (b["input"]) from the claude child, including any extra keys the model supplied; no per-tool normalization.
2. `Sources/PairVoxCore/Policy/PermissionPolicy.swift:102` (propagation, PermissionPolicy.assess (fileWriteTools case)): path = file_path ?? notebook_path ?? blockedPath for Edit, MultiEdit, Write and NotebookEdit alike. Risk (inside project = medium), summary, spoken text and isSensitivePath all use this path.
3. `Sources/PairVoxCore/Policy/FolderGrants.swift:53` (propagation, FolderScope.editGrant): Same precedence; the folder-grant containment check is made against the shadowing file_path, so a grant covers the request.
4. `Sources/PairVoxCore/Protocol/OutboundMessage.swift:38` (sink, OutboundMessage.permissionResponse): allow returns updatedInput = request.input unchanged, including the real notebook_path, so the tool would act on a notebook that was never classified.

**Blockers**

- Target execution was unavailable in this run (no enforceable sandbox), so the classification result is predicted from source only.
- Whether Claude Code's NotebookEdit input schema rejects or strips an unknown file_path before it requests permission, and whether the tool then reads notebook_path from the same updatedInput, is not visible in this repository. If the schema is strict the shadowing request never reaches can_use_tool and this is only a defense-in-depth gap. NotebookEdit needs an .ipynb target, which limits impact.

**Resolution plan**

- Local: Add a PairVoxCoreTests unit test using temporary dummy directories only: create tmp/project and tmp/elsewhere; build PermissionRequest(toolName: "NotebookEdit", input: ["file_path": tmp/project/a.ipynb, "notebook_path": tmp/elsewhere/b.ipynb]); call PermissionPolicy(projectRoot: tmp/project).assess and FolderScope.editGrant with a FolderGrant on tmp/project. Source predicts risk == .medium, voice-approvable, and a non-nil grant; the expected safe result is risk == .high with 'outside the project folder' and no grant. Repeat with notebook_path = tmp/project/.ssh/id.ipynb style sensitive name. No network, no real files.
- Owner-observed: Owner check with a dummy notebook in a scratch project: ask the installed claude CLI to call NotebookEdit with both file_path and notebook_path, and observe whether the CLI reports a schema error, or sends can_use_tool with both keys present and which file it edits. Observe only; send no audit traffic to any service.

## WebFetch is voice-approved on the host read by Foundation's URL parser, which may differ from the host the fetch contacts

Fingerprint: `policy/webfetch-spoken-host-from-foundation-parser-differs-from-fetch-host`

For WebFetch, PermissionPolicy.assess speaks only URL(string:)?.host (falling back to the whole string when parsing fails). The request stays medium risk with no screenOnly flag, so a spoken yes approves it, and approvePending echoes the original input.url unchanged as updatedInput. For a URL such as https://attacker.invalid\@docs.invalid/x, an RFC 3986 parser (Foundation) can report docs.invalid as the host, while a WHATWG parser (what Node-based Claude Code is expected to use) treats the backslash as a path separator and contacts attacker.invalid. The listener would then approve 'a page from docs.invalid' while the request, whose path can carry data the model has read, goes elsewhere. The full URL is shown on the approval card, and the model or a prompt-injected repo must choose the URL; the owner must also say yes from the spoken text alone. Two prerequisites are unobserved: Foundation's result on the owner's macOS version (on versions where URL(string:) returns nil for a backslash, the whole URL is read out and there is no deception), and the parser Claude Code's WebFetch uses. The run 6 hardening note about WebFetch being voice-approvable assumes the spoken host is correct and does not cover this.

**Claimed root cause.** The spoken host comes from a different URL parser than the one that decides where the request goes, and WebFetch has no on-screen-only rule or check that the URL has no backslash, user info or non-canonical form.

**Trace**

1. `Sources/PairVoxCore/Protocol/InboundMessage.swift:351` (entrypoint, PermissionRequest.init(requestID:body:)): A WebFetch can_use_tool request from the claude child, with a model- or repo-influenced input.url, is decoded without any URL validation.
2. `Sources/PairVoxCore/Policy/PermissionPolicy.swift:98` (propagation, PermissionPolicy.assess (WebFetch case)): host = URL(string: url)?.host ?? url; the spoken prompt names only that host (line 99), risk is medium and screenOnly stays false, so voiceApprovable is true. WebFetch is not in readOnlyTools, so it is not auto-approved.
3. `Sources/PairVoxCore/Conversation/ConversationEngine.swift:894` (sink, ConversationEngine.perform (.approve)): A spoken yes on a voiceApprovable, non-stale pending request calls approvePending, which sends allow with updatedInput equal to the original input (OutboundMessage.swift:38); the child then fetches the URL with its own parser.

**Blockers**

- Target execution was unavailable in this run (no enforceable sandbox), so Foundation's host for the backslash form on the owner's macOS version is not observed; a nil result would make PairVox read out the whole URL and remove the deception.
- The parser Claude Code's WebFetch uses to pick the destination host (and any URL validation it does before fetching) is not in this repository and needs a check against the installed claude version.
- The impact depends on a model or prompt-injected request choosing the URL and the owner approving by voice without reading the card; this is not observable from source.

**Resolution plan**

- Local: In PairVoxCoreTests add a test that calls URL(string: "https://attacker.invalid\\@docs.invalid/x")?.host and PermissionPolicy(projectRoot: nil).assess(PermissionRequest(toolName: "WebFetch", input: ["url": "https://attacker.invalid\\@docs.invalid/x"])). Record the host and the spoken string, plus voiceApprovable. Source predicts either host docs.invalid (spoken 'docs.invalid', voiceApprovable true, the defect) or nil (whole URL spoken, no defect). Use .invalid names only and make no network call. If the first outcome holds, the fix is to speak the full authority and refuse voice approval (screenOnly) when the URL contains a backslash, user info, a non-http(s) scheme or any non-canonical form.
- Owner-observed: Owner check on the installed claude: in a scratch session, request a WebFetch of the backslash URL on a name under .invalid (or a local test host the owner controls) and read the host Claude Code reports in its own prompt or error text, to see which host its parser selects.

## Echo of the spoken prompt's final word 'Allow?' can return as a one-word spoken approval

Fingerprint: `voice/echo-tail-of-allow-prompt-approves-pending-request`

Every voice-approvable permission prompt ends with the single word 'Allow?' (high-risk prompts swap it for 'Please confirm on screen', PermissionPolicy.swift:178-179). The VAD's echo rejection (echoCeiling and playback penalty) applies only while playbackActive is true, and VoiceSpeechOutput clears playbackActive as soon as the last buffer has played (no hangover). The engine's only timing check, answerPrecedesPrompt, compares the utterance's speech start with the time the prompt STARTED, so any speech start after the prompt began passes. If residual echo of the end of the prompt (speakers, AEC off, failed or leaving residue; half-duplex barge-in-off mode only skips frames while playback is active) clears the VAD gate (floor+12 dB, above -50 dBFS, 0.18 s) after playback ends, the utterance is seeded with the 0.35 s pre-roll (already over the 0.3 s blip filter), is transcribed, and a one-word 'Allow' with no '?' parses as .approve and runs approvePending for a medium-risk request. Nobody spoke. Source verification found no transcript-level comparison with the last spoken text and no post-playback holdoff. The mitigating facts: the player's dataPlayedBack fires after the audio has been rendered, so only room reverb or device latency residue is left, which usually decays fast and sits well below the speech threshold; a clip of the last 0.3 to 0.5 s of 'Allow?' may not transcribe to 'Allow' at all; and a trailing '?' in the transcript blocks approval. Impact is bounded to a medium-risk request the owner had just heard announced (high-risk and screen-only requests are not voice-approvable) and is subject to the 300 s staleness check.

**Claimed root cause.** Self-echo is handled only acoustically (AEC plus a playback-gated VAD ceiling) and not at the transcript or timing level: no post-playback hangover in the VAD, no comparison of the transcript with the text just spoken, and answerPrecedesPrompt measures against prompt start rather than prompt end. The prompt's last word is itself an accepted approval word.

**Trace**

1. `Sources/PairVoxCore/Policy/PermissionPolicy.swift:82` (entrypoint, PermissionPolicy.assess): Voice-approvable prompts are built as 'Claude wants to ... . Allow?' (also lines 83, 99, 105, 131, 155), so PairVox's own audio ends with an approving word. The lower-trust input is the room/echo path of PairVox's own audio, not an authenticated principal.
2. `Sources/PairVoxVoice/VoiceSpeechOutput.swift:268` (propagation, VoiceSpeechOutput.startPlaybackIfNeeded): When the last buffer has finished (AudioIO.swift:794 dataPlayedBack completion) and nothing is queued, onPlaybackActiveChange(false) is called immediately, which reaches VoiceInputController.setPlaybackActive (VoiceInputController.swift:87-91) and clears vad.playbackActive.
3. `Sources/PairVoxCore/Conversation/VoiceActivityDetector.swift:100` (propagation, VoiceActivityDetector.process): penalty (line 98) and echoCeiling (line 100) are zero or nil when playbackActive is false, so afterwards a frame only needs level > floor+12 dB and > -50 dBFS for 0.18 s (lines 103, 111).
4. `Sources/PairVoxVoice/VoiceInputController.swift:171` (propagation, VoiceInputController.handle): On speechStarted the utterance is seeded with the 0.35 s pre-roll (filled at lines 142-143, even in the half-duplex branch at line 164, which only skips the detector while playback is active), then engine.userStartedSpeaking() sets speechStartedAt (ConversationEngine.swift:169). finishUtterance accepts it because the pre-roll alone exceeds the 0.3 s blip filter (line ~219).
5. `Sources/PairVoxCore/Conversation/ConversationEngine.swift:1246` (propagation, ConversationEngine.answerPrecedesPrompt): Rejects an answer only when speechStartedAt < promptHeardAt, the time the prompt started playing (set at line 1144). A speech start after the prompt's start, including its own echo tail, passes.
6. `Sources/PairVoxCore/Conversation/VoiceCommand.swift:215` (sink, VoiceCommand.permissionAnswer): A transcript of 5 or fewer words with an approve word and no refusal returns .approve; ConversationEngine.process (lines 867-896) then calls approvePending for a fresh, voiceApprovable pending request.

**Blockers**

- Target execution was unavailable in this run (no enforceable sandbox), so no observed result exists.
- Whether residual echo after dataPlayedBack clears the VAD gate (floor+12 dB, above -50 dBFS, 0.18 s) on real hardware with AEC off or degraded cannot be established from source.
- Whether WhisperKit or Apple Speech returns 'Allow' (approving) rather than 'Allow?' or nothing for a 0.35 to 0.5 s clip holding the end of the final word cannot be established from source.

**Resolution plan**

- Local: Unit test 1 (PairVoxCoreTests, dummy data): construct VoiceActivityDetector with default Config; feed 2 s of 30 ms frames at 16 kHz of room noise near -60 dBFS to settle the floor. Feed 2 s of echo at -35 dBFS with playbackActive=true and playbackLevelDB=-15 and assert no .speechStarted. Then set playbackActive=false (playbackLevelDB=nil) and feed a decaying tail starting at -35 dBFS and falling 10 dB per 100 ms; record whether .speechStarted fires and after how many frames. Repeat with a fall of 20 and 40 dB per 100 ms to bound the reverb time needed. Unit test 2 (ConversationEngine with the existing stub backend and speech output used in EngineApprovalTests): raise a Bash or Read request that is voiceApprovable, emit .started for the prompt utterance, then .finished, call userStartedSpeaking() 0.5 s after .finished and submit('Allow') and assert whether approvePending ran (expected today: it runs). Fix test: after the change, the same sequence must not approve when the utterance began within a holdoff of the prompt's end or when the transcript is a suffix of the last spoken prompt, while a genuine 'yes' spoken after the holdoff still approves.
- Owner-observed: Owner-observed, non-destructive: on a MacBook with built-in speakers and Settings echo cancellation off (or AEC auto-disabled), with nobody speaking and the room quiet, trigger a harmless voice-approvable request (for example a Read of a file inside the project). Check the diagnostics log for 'permission approved' following a 'vad.speech.start' whose time falls within about 1 s after the prompt's 'utterance.finished', and the 'transcribed' text for that utterance. Repeat about 20 times at normal and high speaker volume.

## Repository file and folder names are fed verbatim into the recognizer prompt, including phrases such as 'allow it'

Fingerprint: `voice/repo-names-reach-whisper-prompt-unfiltered`

RepoVocabulary.scan counts whole directory names (3+ characters, +1) and whole file base names of source files (3+ characters, +3) with no character-class, length or word filter. The result is sorted by count and the top 150 are returned. AppModel.openProject appends them to the owner's own vocabulary and passes them to VoiceInputController.setVocabulary. WhisperKitTranscriber then joins the first 40 terms with ', ' into options.promptTokens, and AppleSpeechTranscriber passes the first 100 as contextualStrings. A repository the owner opens could contain files such as 'allow it.swift' or 'confirm high risk.swift' in several folders. Those names would rank into the list and bias the recognizer toward emitting approval phrases that VoiceCommand.permissionAnswer treats as approvals ('allow it' is in approvePhrases; 'allow' and 'confirm' are in approveWords) on ambiguous audio. Source confirms the missing filter. It does not show that the recognizer actually emits these phrases on noise or echo, and the downstream gates still apply: transcript of 5 words or fewer, not a question, freshness, prompt-timing and risk checks, and high-risk requests need 'confirm high risk' or a click. The effect is therefore a bias that lowers the bar for an accidental approval, which only a model-behaviour check can size. Low confidence.

**Claimed root cause.** The repository, a lower-trust input, is an unfiltered free-text channel into the speech recognizer's decoding context. Directory and file names are used verbatim, with no character-class filter, length cap, or exclusion of the words and phrases VoiceCommand treats as approvals or confirmations. Only declaration identifiers are regex-limited, and commonWords covers only generic words.

**Trace**

1. `Sources/PairVoxCore/Support/RepoVocabulary.swift:37` (entrypoint, RepoVocabulary.scan): Directory names of 3 or more characters are counted verbatim (+1); file base names of source files are counted verbatim at line 45 (+3 each). The enumerated repository is the lower-trust input.
2. `Sources/PairVoxApp/AppModel.swift:304` (propagation, AppModel.openProject): words = owner vocabulary + RepoVocabulary.scan(root:) are stored on the session and passed to VoiceInputController.setVocabulary (line 307).
3. `Sources/PairVoxVoice/VoiceInputController.swift:239` (propagation, VoiceInputController.finishUtterance): Every utterance, including the speculative early transcription at line 211, is transcribed with the stored vocabulary.
4. `Sources/PairVoxVoice/Transcription.swift:79` (sink, WhisperKitTranscriber.transcribe): prompt = ' ' + first 40 terms joined by ', ' is tokenized into options.promptTokens (decoder context). AppleSpeechTranscriber.transcribe sets contextualStrings from the first 100 terms at line 124.

**Blockers**

- Target execution was unavailable in this run, so no bounded local result could be observed.
- Whether the Whisper model or Apple Speech actually emits a prompt-biased approval phrase on noise or echo, and at what rate, is model behaviour that source cannot show.
- Whether such output would survive the engine's freshness, prompt-timing, question and risk checks on a live pending request needs an end-to-end observation.

**Resolution plan**

- Local: Unit test in Tests/PairVoxCoreTests on RepoVocabulary.scan with a temporary dummy folder holding three source files named 'allow it.swift' and one 'confirm high risk.swift' in different subfolders, plus 40 ordinary source files, each with one declaration. Assert whether 'allow it' and 'confirm high risk' appear in the first 40 returned terms (expected: yes today). Fix test: after sanitising, every returned term must match ^[A-Za-z][A-Za-z0-9_]{2,40}$ and must not contain any word in VoiceCommand.approveWords, denyWords, approvePhrases or 'confirm high risk', so the same fixture returns neither phrase.
- Owner-observed: Owner-observed, non-destructive: on a development build with the WhisperKit model loaded, open a dummy project containing those file names, raise a voice-approvable (medium risk) request using a harmless fake tool, play about 2 s of room-level white noise at the microphone (no speech), and read the 'transcribed' log line for approval words. Repeat 20 times with and without the dummy files and compare. Deny the request afterwards.
