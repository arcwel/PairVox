# Microphone test plan (Mac, headset on)

Run it in one sitting, about 15 minutes. Open **two projects** in PairVox (File → Open Project, twice) so the cross-project parts can be tried. After each part, `scripts/audio-report.py --since 5` prints what the log recorded (counts and timings only, never what you said).

**Before you start**
1. Quit and reopen PairVox so it runs the latest build.
2. Put the headset on and make it the default input and output (System Settings → Sound). If macOS picks your iPhone as the microphone, choose the headset by hand.
3. Settings → Phone: link on if you want the phone parts.
4. Optional switches for part 4: Settings → General → "Allow confirming high-risk requests by voice" on, the other two off.

## 1. Basic loop (2 min)
Say: "What files are in this project?" Expect a spoken reply within about 3 seconds of finishing your sentence.
Then interrupt mid-reply by saying "stop".
Report line to check: `speech`, `turns` (interrupted count goes up by one), `commands heard` includes `stopSpeaking`.

## 2. Voice quality and the new recovery (3 min)
Ask something that gets a long spoken answer ("Explain what this project does, in detail"). Listen for crackle or static.
Report line to check: `audio:` corrupt synth should be 0, or if not, `recovered by` should name `split` or `systemVoice`, and glitches/clicks should stay near 0.

## 3. Echo (2 min)
Stay silent while PairVox speaks a long answer through your headset. Nothing should be transcribed.
Then take the headset off one ear so the sound leaks into the microphone, and let it speak again.
Report line: `empty` transcripts should not climb while you are silent. If they do, tell me which step.

## 4. Approvals by voice (4 min)
In project A, ask Claude to create a file called `mic-test.txt` containing "hello".
- A prompt like "Claude wants to write mic test dot txt. Allow?" should be spoken. Say "yes". Expect "approved" behaviour and the file created.
- Ask it to run `git push` (it will be refused or need a click: a high-risk request). Say "yes": nothing should happen. Say "confirm high risk" (only if you turned that switch on): it should be allowed after the phrase, not before.
Report line: `approvals`.

## 5. Another project's request (4 min)
In project B, ask Claude to edit a file, then switch to project A and keep talking about something else.
- At a pause, PairVox should say "Quick one from <B>: …" without cutting you off.
- Say "tell me more": a two-sentence recap. Then "approve" or "deny": it should answer B and leave you in A.
- Say something unrelated while an announcement is live: it should be treated as ordinary speech, not an answer.

## 6. Phone (optional, 3 min)
With the phone connected, ask for a file edit on the Mac. The phone should show the request; say "yes" on the phone or tap Allow. A high-risk request on the phone must ask for Face ID or the passcode.

## What to send back
Run `scripts/audio-report.py` once at the end and paste the output, plus a line for anything that felt wrong (a cut-off announcement, a wrong answer landing, crackle).
