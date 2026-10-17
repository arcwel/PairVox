# Cross-project approvals and the approval ladder: PRD

| Field | Value |
|-------|-------|
| Status | Council reviewed; owner decisions recorded; ready for implementation planning |
| Owner | Anthony Guidry |
| Date | 2026-10-13 |
| Version | 0.1 |

## 1. Summary
When several projects run at once, a request for permission in a project you are not looking at should reach you at a good moment, with enough context to decide, and should be answerable without leaving the conversation you are in. This PRD describes that feature, and restates the approval rules at every risk level, including the new rule that voice may approve everything, high risk included, when the owner switches that on.

## 2. Problem
- **Who:** a developer running two or more Claude Code projects in PairVox (the owner does this daily).
- **Pain:** every approval in a background project means switching, rereading the context, deciding, and switching back. Each switch loses the thread of the conversation in progress, and the person often cannot remember what that project was doing when they approve.
- **Today:** a background project raises a macOS notification and a "NEEDS OK" badge in the sidebar. To answer, the person must switch to the project (the catch-up bar then offers to replay missed replies) and say yes there.
- **Evidence:** the owner's own workflow (stated 2026-10-13). No other voice tool for Claude Code handles several projects; this is an assumption, to be checked.

## 3. Goals and Success Metrics
| Goal | Metric | Target |
|------|--------|--------|
| Answer another project's request without leaving the conversation | Approvals of background-project requests that did not need a project switch | at least 80% for low and medium risk |
| Right moment | Announcements that interrupted the person while speaking or while Claude was speaking | 0 |
| Enough context | Decisions the person reverses or regrets after hearing the overview ("I should have looked first") | under 5% |
| Fast | From announcement to answer | under 10 s median |
| Safe | Approvals applied to a different request than the one announced | 0 |
North-star: approvals answered in place, as a share of all background-project approvals.

## 4. Non-Goals
- Changing what each risk level means (section 8 restates it).
- Answering on behalf of the person: nothing is approved without an explicit answer.
- Approving several different projects with one sentence (a bulk "allow all" across projects) in v1, except as listed in section 9.
- Replaying whole transcripts: the overview is short.

## 5. Users and Journey
The owner has the API project open and talking, and a second project (the website) working in the background.

1. The website's Claude asks to edit `pricing.html`, outside the folder grant. The request is queued on that project. Nothing is spoken yet because the owner is mid-conversation.
2. The owner finishes a thought and Claude in the API project finishes speaking. After a short pause (about 2 seconds of quiet) PairVox says: "Quick one from the website: Claude wants to edit pricing.html. Say approve, deny, tell me more, or switch."
3. "Tell me more": "In the website, you asked Claude to change the monthly price to 49 dollars. It is about to edit pricing.html. This stays inside the project."
4. "Approve." PairVox answers the website's Claude, says "Approved. The website is continuing." and returns to the API conversation without a switch.
5. If the owner says "switch", the website becomes the active project and the catch-up controls apply as today.

The "worth it" moment: step 4, a decision made with context, in four seconds, without losing the API thread.

## 6. Scope
### MVP (v1)
| # | Feature | Priority | Acceptance criteria |
|---|---------|----------|---------------------|
| 1 | One approvals inbox across all open projects | P0 | Every pending request in every open project is listed in order of arrival, with project, summary, risk and age; visible in the project list, the menu bar, the mini window and on the phone |
| 2 | Announce at a break | P0 | A background request is announced only when the person is not speaking, Claude in the active project is not speaking or has paused, and there has been about 2 s of quiet; never mid-sentence; otherwise it waits. A pending announcement is dropped if the request is answered elsewhere |
| 3 | Spoken overview on demand | P0 | "Tell me more" or "what is that about" gives at most two sentences: what the person last asked in that project, what Claude was doing, and why this request. Labeled as a summary; the exact command stays one tap away. Works without switching |
| 4 | Answer in place | P0 | "Approve" or "deny" right after an announcement is applied to the announced request in the announced project, not to the active project. The reply names the project. The active conversation resumes |
| 5 | Switch if wanted | P0 | "Switch" or "go there" makes it the active project (existing switch and catch-up behavior) |
| 6 | Same rules at every risk level | P0 | Section 8 applies unchanged to cross-project answers, with two additions: the project name is part of the read-back and, for high risk, of the confirm phrase |
| 7 | Multiple waiting requests | P1 | Announced one at a time, in order; "that's N waiting" is said once; answering the first announces the next after the same pause rule |
| 8 | Settings | P1 | "Tell me about requests from other projects" (default on), "Wait for a pause before announcing" (default on), and a quiet period length |
| 9 | Phone parity | P1 | The phone shows and announces the same inbox and can answer in place under the phone rules in section 8 |
| 10 | Per-project mute | P1 | A project can be muted for announcements from its project-list menu or Settings → Project. A muted project's requests still appear in the inbox, the badge and the notification; they are just never spoken. Stored in that project's preferences (small change: one field, one check in the announcer, one menu item) |
| 11 | Say project names aloud (option) | P1 | Settings → "Say the project name when announcing" (default on). Off: the announcement says "another project" and the card shows the name; answers still bind to the announced request |
| 12 | Optional Touch ID or password after the spoken phrase on the Mac | P1 | Off by default. When on, a high-risk voice approval on the Mac also asks for Touch ID or the login password (system dialog) before it is applied. Small: one `LAContext` call and one setting |
### Later
Context memory per project beyond the last instruction (a rolling summary), per-project notification rules ("never interrupt me for the docs project"), grouping several requests from one project into one question, approving by tapping the notification.

## 7. UX Requirements
- The announcement is short and always starts with the project name.
- A visible card mirrors every spoken announcement (Mac window, mini window, menu bar, phone) so the person can answer by click or tap.
- "Tell me more" is clearly marked as a summary; if the summary service is unavailable, PairVox says so and reads the request summary instead.
- Unclear speech never approves: if PairVox is not sure which request an answer refers to, it asks again.
- Accessibility: every spoken announcement has a text equivalent; WCAG 2.2 AA for the card.
- States: announcement waiting for a break, announced and waiting for an answer, answered, expired (request cancelled by Claude or the project closed), too old for voice (older than 5 minutes).

## 8. The approval process at every risk level
This restates what exists and adds the owner's 2026-10-13 rulings. The Mac, not the phone and not the model, decides what each answer can do.

### What each level is
| Level | Examples | How it is rated |
|---|---|---|
| Low | Reading files inside the project; plain read-only commands (`ls`, `git status`) | Known-harmless only; anything not recognized is not low |
| Medium | Editing a file inside the project, running a build, installing packages, network fetches, unknown commands | The default for anything not clearly harmless or clearly dangerous |
| High | Deleting recursively, `git push`, `sudo`, writing outside the project or to credential, shell or settings files, publishing, changing system configuration, force operations | Structural rules on the program and its subcommand, not on spelling |
| Needs the screen | Claude Code itself says this request needs the person at the screen (a safety check or a required interaction) | Claude Code's own flag, which always wins |

### Who can answer, and how
| Level | By click or tap | By voice on the Mac | By voice or tap on the phone |
|---|---|---|---|
| Low | Yes. Optionally auto-approved when the owner turned that setting on (plain read-only tools inside the project only) | Yes: "yes", "allow", "go ahead" | Voice yes, or tap |
| Medium | Yes | Yes, after the request is read back in plain words ("Claude wants to edit pricing.html. Allow?"). Compound commands are read step by step; commands too long or complex to read fully are screen-only unless the owner's voice-for-everything setting is on | Voice yes or tap. A request older than 5 minutes needs a tap (voice yes is refused) |
| High | Yes, always | **Off by default.** With the setting on: PairVox reads the plain-language summary and says the project name, then the person must say the deliberate phrase "confirm high risk" (not a casual yes) | **Off by default.** With the setting on: the same spoken phrase, **plus** a second confirmation on the phone: Face ID, Touch ID or the device passcode. With the setting off: tap, which asks for Face ID, Touch ID or the passcode (or a plain tap if the phone has none) |
| Needs the screen | Yes | **Off by default, separate setting** ("Also allow voice for requests Claude Code says need the screen"), with a double confirmation when switching it on | Same, with the phone's second confirmation |

### What the owner's ruling changes
- Before: voice could never approve high risk unless the owner switched on "Allow confirming high-risk requests by voice" (off by default, exact phrase "confirm high risk", PairVox reads the summary back first, and requests Claude Code marks as needing the screen were excluded). That is what exists today on the Mac.
- Now: voice can approve everything, including high risk and the needs-the-screen class, but only when the owner allows it, and the allowing is split into two switches, both off by default, so nothing is forced on and nothing is withheld from someone who wants it:
  1. Voice for high risk (exists today; extended to the phone with the second confirmation).
  2. Voice for requests Claude Code marks as needing the screen (new).
- Whether PairVox's own speech heard through the microphone can satisfy the phrase stays an accepted trade-off when switch 1 is on (decided earlier), and Settings must say so plainly. On the phone the second confirmation is what closes this gap.

### Rules that never switch off
- Every answer is bound to a request ID and a project; an answer cannot land on a different request.
- A request is answered at most once; a stale or cancelled request cannot be approved.
- The Mac applies these rules; a phone claiming "voice" or "Face ID" cannot widen them. Face ID results are logged, not trusted.
- Everything is logged with project, request, risk and how it was answered (no command text beyond what is already logged).
- Always-allow stays session-scoped.

### Cross-project additions
- The announced request is the only one a bare "approve" or "deny" can answer, and only until about 20 seconds pass, the person speaks about something else, or the announcement is replaced.
- High-risk cross-project voice needs the project in the phrase ("confirm high risk website"); a bare phrase is not accepted when the request is in another project.
- Medium and low can be answered with a bare "approve".
- If two projects have the same or confusingly similar names, PairVox says the folder name and asks which one.

## 9. Technical Approach
- **Architecture:** a new `ApprovalInbox` in the app layer aggregates `queuedPermissions` and `pendingPermission` from every `ProjectSession` (all of them already publish snapshots). A `BreakDetector` decides when the active conversation is idle (engine phase idle, not speaking, mic quiet for the quiet period, no utterance in progress). An `Announcer` speaks on the active project's output path when a break arrives and records which request was announced. `ConversationEngine.approvePending(requestID:)` and `denyPending(requestID:)` already exist and are request-ID bound; cross-project answers call the owning project's engine.
- **Voice routing:** `VoiceCommand` gains an "answering an announcement" context held by the app model, not any engine, so the active engine never sees the answer as its own.
- **Overview:** reuse the existing read-only advisor (a separate `claude -p` Haiku call, fenced, no tools beyond read inside the project) with a fixed prompt that includes the project's last user instruction, the last assistant text and the request. If unavailable, speak a deterministic fallback (last instruction plus request summary). Output is advice only.
- **Phone:** the link already carries the pending request; extend `LinkSnapshot` with the inbox (project, request, age) and a `project` field on approve/deny; the Mac routes by project.
- **Settings:** `announceOtherProjects`, `announceOnlyAtBreaks`, `announcementQuietSeconds`, `voiceApprovesHighRisk` (exists as `spokenHighRiskConfirmation`), `voiceApprovesNeedsScreen` (new, with double confirmation), `speakProjectNames` (default on), `macSecondConfirmation` (default off), and a per-project `muteAnnouncements` in project preferences.
- **Security and privacy:** project names and request summaries are spoken aloud (speaker-aware: not when output is the built-in speaker if the owner chose "headphones only", assumption); overview text can contain repository content, so it is fenced and filtered like other advisor speech (approval-shaped sentences removed); inbox shows only what the Mac already shows on the request card.
- **Testing:** fake engines for several projects; break-detector tests with a fake clock; tests that a bare "approve" answers only the announced request and never the active project's; high-risk phrase with and without project; stale and cancelled requests; two similarly named projects; phone path through the loopback link.
- **Rollback:** each setting off restores today's behavior (notification and badge only).

## 10. Business Model
None. Personal and tester-use tool.

## 11. Go-to-Market
N/A for now. If the Mac app is released publicly, "answer approvals from other projects without switching" is the headline feature.

## 12. Competitive Landscape
| Alternative | Strength | Weakness | Our angle |
|---|---|---|---|
| Claude Code terminal prompts | Exact, official | One terminal per project, constant switching, no voice | One inbox, voice, context overview |
| Single-project voice tools | Hands-free | One session at a time | Several projects at once |
| Notifications only | Simple | Still requires opening the project | Answer in place with a short overview |

## 13. Risks and Mitigations
| Risk | Likelihood | Impact | Early signal | Mitigation |
|---|---|---|---|---|
| A bare "yes" lands on the wrong project's request | Medium | High | Approvals with no matching announcement in the log | Announced-request binding; project name in high-risk phrase; ask when unsure |
| Announcement interrupts or talks over the person | Medium | Medium | Complaints; barge-in right after an announcement | Break detector with quiet period; never mid-speech |
| The overview is wrong or misleading and the person approves on it | Medium | Medium | Reversals after "tell me more" | Mark as summary; exact command one tap away; deterministic fallback; repository text fenced |
| Voice for high risk makes accidents easy | Medium | High | Unintended deletions or pushes | Off by default; exact phrase plus project name; phone second confirmation; Settings states the echo trade-off |
| Notification fatigue with many projects | Medium | Medium | The person mutes announcements | Folder grants reduce prompts; one request at a time; per-project mute later |
| Spoken project names are recognized wrongly | Medium | Low | "switch" or approve commands misrouted | Unambiguous matches only (existing rule); confirm on ambiguity |
Kill/pivot criteria: if announced requests are answered wrongly more than once in the first 100 uses, require the project name for every answer.

## 14. Milestones
| Milestone | Scope | Target date |
|---|---|---|
| A1 | Inbox model, request-ID and project binding, tests with fake engines | TBD |
| A2 | Break detector and announcer, settings | TBD |
| A3 | Answer in place by voice, switch, ask-again rules | TBD |
| A4 | Overview ("tell me more") with advisor and fallback | TBD |
| A5 | Inbox UI (project list, menu bar, mini) and phone parity | TBD |
| A6 | Voice for high risk and needs-the-screen on both devices (second confirmation on the phone), security audit | TBD |

## 15. Assumptions
- A "break" is: nobody speaking, Claude in the active project not speaking, and about 2 seconds of quiet; the quiet length is adjustable.
- Announcing is on by default; it only speaks, never acts.
- The overview uses the existing advisor; no new model or service.
- The high-risk phrase on the Mac stays "confirm high risk"; for another project it gains the project name.
- On the Mac, a second confirmation for high-risk voice (Touch ID or login password through the system) is an option, off by default, and in v1 because it is a small change (owner, 2026-10-13). On the phone the second confirmation is required (owner ruling).
- Requests Claude Code marks as needing the screen are excluded from voice by default and get their own switch (confirmed by the owner, 2026-10-13).
- The 5-minute limit for voice approvals of an old request stays.

## 16. Decisions and Open Questions
Decided by the owner on 2026-10-13:
| Question | Decision |
|---|---|
| One switch or two for high-risk voice? | Two: "needs the screen" has its own switch |
| Can long or complex commands be voice-approved? | Yes, with the high-risk phrase only, after the overview reads what the command does and names its biggest effects |
| Quiet period before announcing | 2 seconds, and wait for the end of Claude's reply; both adjustable |
| Mac second confirmation (Touch ID or password) for high-risk voice | Option, off by default, in v1 because it is simple |
| Speak project names aloud? | A setting; spoken every time or not |
| Per-project mute | In v1 because it is under an hour of work |

Still open:
| Question | Owner | Needed by |
|---|---|---|
| Default for "Say the project name when announcing": on (suggested, so an answer is never ambiguous) or off | Anthony | A2 |
| When a project is muted, should its high-risk requests still be spoken once (suggested: no, they wait on screen) | Anthony | A2 |

## Council Deliberation
### Phase 1: Assessments
- **Contrarian** (§8, §13): the dangerous moment is a bare "yes" or "approve" spoken a few seconds after an announcement, when the person has already turned back to the other conversation. Voice for high risk plus announcements from a different project is the most error-prone combination in the product. Spoken project names are also easy to mishear.
- **First-Principles** (§9): the real invariant is "an answer is bound to the request the person last heard described". Everything else (break detection, overview) is about making that hearing real. The binding should be explicit state, an announced request ID with an expiry, not inferred from the active project.
- **Expansionist** (§6, §12): the inbox is the product's strongest differentiator and also the foundation for the phone: the same inbox, announced on earbuds, makes the phone genuinely useful. Per-project rolling summaries later make "tell me more" much better.
- **Outsider** (§5): why speak a request at all, rather than a chime and a card? Because the owner's hands and eyes are busy; but a spoken announcement during someone else's sentence is rude. The break rule is the whole feature.
- **Executor** (§9, §14): most pieces exist (per-project snapshots, request-ID approvals, gated speech, advisor). The new work is the announcer, break detector, routing context and tests. The advisor call costs one Haiku call per "tell me more", which is acceptable. Risk: the break detector needs real-world tuning.

### Phase 2: Peer review
- The Contrarian's wrong-project risk is correct and is already addressed in the draft by announced-request binding; the council adds an expiry (the binding ends after about 20 s without an answer or when anything else is said).
- The Outsider's chime-only alternative is rejected, but a chime before the first words of an announcement is a cheap kindness.
- The Expansionist's rolling summaries are good but are not needed for v1.
- The Executor underestimates voice for high risk: the second confirmation on the phone and the project name in the phrase should be tested before anything ships.

### Phase 3: Decision matrix
| Option | Feasibility and effort | Risk | Upside | Assumptions |
|---|---|---|---|---|
| A. Inbox + break announcements + answer in place (PRD) | Medium | Medium, controlled by binding and expiry | High, the headline feature | Break detection tunable; advisor available |
| B. Notification and card only, no speech | Low | Low | Low | The owner would accept it (he asked for voice) |
| C. Announce immediately, interrupting | Low | High: talks over the person | Medium | None, rejected |
| D. Auto-answer low-risk cross-project requests | Low | Medium | Medium | Already covered by auto-approve and folder grants; keep separate |

### Phase 4: Chairman's verdict
**Verdict:** Go on option A, with these changes (folded into the PRD):
1. The announced-request binding expires after about 20 seconds or on any other utterance, and is shown on screen.
2. A short chime precedes the first announcement after silence.
3. High-risk answers for another project require the project name in the phrase; bare "confirm high risk" is refused with a prompt that names the project.
4. The break detector's quiet period, and whether announcements wait for the end of Claude's reply, are tunable settings and measured in the first week.
**Final move:** build the inbox model and the routing context first (A1) with fake engines, and prove with tests that a bare "approve" answers only the announced request in the owning project and never the active one. Success: those tests pass before any speech code is written.


## Revision Log
| Date | Change | Reason |
|------|--------|--------|
| 2026-10-13 | v0.1 drafted from the owner's description | For alignment before implementation |
| 2026-10-13 | Owner decisions folded in: separate switch for needs-the-screen, long commands by voice with the high-risk phrase after the overview, 2 s quiet and wait for end of reply, optional Mac second confirmation, project-name option, per-project mute in v1 | Owner review |
| 2026-10-13 | Council verdict recorded: binding expiry (about 20 s), chime before first announcement, project name in high-risk phrase for other projects, tunable break detector | Council |
