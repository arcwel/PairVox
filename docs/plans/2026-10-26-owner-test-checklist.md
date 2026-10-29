# Owner test checklist (2026-10-26)

These need you: your voice, your headset, your iPhone in your hand, or a clean Mac account. Each one was built and passed its unit tests, but none has been tried for real. Both apps were reinstalled on 2026-10-26 from `main`.

Tick a box when it passes. If one fails, note the time it happened and send the logs (bottom of this page).

## A. The v0.1 checks (docs/plans/2026-10-17-v0.1-checks.md)

- [ ] **Check 2, voice session.** Ask 10 questions with the headset, then run `scripts/v01-check.py`. Pass: first sound within 3.5 s of the end of each question. The new 1.5 s end-of-turn wait counts against this, so note whether 3.5 s still holds.
- [ ] **Check 3, approvals by voice on the Mac.** `docs/MIC_TEST.md` parts 4 and 5. A spoken yes creates a file, a spoken yes does not run `git push`, and a request from a second project is answered at a pause.
- [ ] **Check 4, the phone.** Say "Allow" on the iPhone for one real request.

## B. Mac voice (fixed 2026-10-25)

- [ ] **No cut-offs.** Say a sentence with a one-second pause in the middle. Pass: PairVox waits for the whole sentence, and Claude gets one request, not two.
- [ ] **Spoken yes counts.** Answer five requests by voice in a row. Pass: none needs a click. If one does, note the time.
- [ ] **Plain-words summary.** Pass: a few seconds after the short prompt, you hear "In plain words: …".
- [ ] **Approval gates.** Settings, Approvals: set "other commands" to Auto and add `gh pr list` as Manual. Pass: an ordinary command reads back what it will do and needs a second yes, and `gh pr list` needs a click whatever you say.

## C. Mac, other

- [ ] **Microphone sleep.** Leave PairVox hands-free and quiet for 3 minutes. Pass: the top bar turns orange with "Microphone asleep · Wake". Wake turns it back on, and holding push-to-talk records only while held.
- [ ] **Folder access needs a click.** When PairVox offers to let Claude edit a whole folder, say "yes". Pass: it answers "Folder access needs a click" and grants nothing until you click.
- [ ] **Beta.2 DMG on a clean account.** Install `PairVox-0.1.0-beta.2.dmg` from GitHub on another macOS user account. Pass: Open Anyway works, the microphone prompt appears, the voice downloads and a reply is spoken. This is the first public build with the hardened runtime, so it is the one to watch.

## D. iPhone (Noava17)

- [x] **Open the updated app once.** Done 2026-10-27: it connected to the Mac.
- [ ] **No cut-offs on the phone** (fixed 2026-10-29). Hands-free, say a sentence with a one-second pause in the middle. Pass: Claude gets one message with the whole sentence, and answers it instead of saying it was cut off.
- [ ] **No crash with AirPods.** Start talking hands-free, then connect AirPods or another Bluetooth headset. Pass: no crash. It keeps listening, or says the microphone is not ready and works after a tap.
- [ ] **No crash on a fresh start.** Force-quit the app, open it and talk before it has said anything. Pass: no crash.
- [ ] **Hearing itself does not deny.** With a request that needs a tap, say "yes". Pass: the phone says it needs a tap, and the request stays waiting instead of being denied.
- [ ] **Plain words on the phone.** Pass: a request card says "Claude needs approval to …", and the phone reads it.
- [ ] **Lock-screen Allow.** Lock the phone with the app just backgrounded, and have Claude ask for a one-line edit. Pass: the notification shows Allow and Deny, and Allow asks for Face ID. A command over several lines shows no Allow button.
- [ ] **Share Logs.** In the app, open the "…" menu and choose Share Logs…. Pass: the share sheet offers `phone.log`.

## E. Logs

- [ ] **Mac:** Help, Export Diagnostics… (⇧⌘L), or `scripts/collect-diagnostics.sh`. Pass: a zip of the logs, recent crash reports and a system summary appears on the Desktop.
- [ ] **iPhone over the cable:** with the phone connected and past its passcode screen, run `scripts/pull-phone-logs.sh`. Pass: a `PairVoxPhone-logs-…` folder on the Desktop holds `app-log/phone.log`, plus any crash reports.

## Not a test, but yours to do

- Rotate the Gemini key stored in plain text in `~/.strix/cli-config.json`.
- Decide on the paid Apple Developer Program. A notarized Mac build and a TestFlight iPhone build both need it.

## Sending logs after a failure

Note the time, then run both commands and send the two folders:

```bash
scripts/collect-diagnostics.sh
```

```bash
scripts/pull-phone-logs.sh
```

Neither uploads anything. The Mac log records lengths, not what you said, unless "Include conversation text" is on. The phone log records only events.
