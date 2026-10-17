# PairVox for iPhone (first build)

A small SwiftUI app that talks to the PairVox Mac app over Tailscale. It pairs by QR code (or the same pairing link, pasted), shows the active project's transcript, speaks replies and approval prompts, listens with on-device speech recognition, and answers permission requests. The Mac makes every permission decision.

> **Before you pair:** Tailscale must run on both devices, and if your tailnet restricts ports, your phone must be allowed to reach your Mac on **TCP 47821**. Otherwise the phone sits on "connecting" and the Mac sees nothing. See [../docs/PHONE_LINK_SETUP.md](../docs/PHONE_LINK_SETUP.md).

## Build and run on your iPhone

1. On the Mac: `cd ios && xcodegen generate && open PairVoxPhone.xcodeproj`
2. In Xcode, select the PairVoxPhone target, Signing & Capabilities, and choose your team (a free personal team works for your own phone). Change the bundle identifier if Xcode says it is taken.
3. Plug the phone in (or use wireless debugging), pick it as the run destination, press Run. On the phone, trust the developer profile under Settings → General → VPN & Device Management if asked.
4. Install Tailscale on the phone and sign in to the same tailnet as the Mac.

## Pair

1. Mac: PairVox → Settings → Phone → switch on "Let paired phones connect over Tailscale". The screen shows this Mac's tailnet address and port.
2. Mac: press "Show QR code".
3. Phone: Scan the QR code. Without a camera (the iOS Simulator), press "Copy link" on the Mac and paste the link into the phone's pair form. With Universal Clipboard the iPhone's Paste button picks it up directly. Then Pair.
4. Mac: a dialog asks "Pair '<phone name>' with this Mac?" Click Pair.

## Things to try, and what you should see

| Try | Expected |
|---|---|
| Start a task on the Mac, open the phone app | Transcript appears within a second or two; the status bar shows the engine phase |
| Tap the mic, say "tell Claude to list the files" | Your words appear as you speak, then are sent; Claude's reply is spoken |
| A low-risk request appears (an edit inside the project) | The phone speaks the prompt; say "yes" or tap Allow |
| A shell command with several steps, or any high-risk request | The phone says it needs a decision on the screen; voice "yes" does nothing; tap Allow, which asks for Face ID, Touch ID or the passcode |
| Lock the phone with earbuds in | Replies keep speaking (background audio) |
| A request waiting in another Mac project | A "Waiting in other projects" card appears; Allow or Deny answers it in that project |
| High-risk request with the Mac's voice switch on | Say "confirm high risk"; the phone then asks for Face ID, Touch ID or the passcode |
| Mac: Settings → Phone → Remove on the phone | The phone drops at once and shows it can't reach the Mac |
| Switch the Mac's phone link off | Same: the phone is disconnected |

## What is not here yet

Push notifications when the app is closed, lock-screen controls, starting or switching projects from the phone, Kokoro voice (the phone uses the system voice), several Macs, and an App Store build. Audio is never sent to the Mac: only text crosses the link.

## Known limits (see docs/security/2026-10-13-audit-run-3-phone-link.md)

Pairing needs the Mac's tailnet address. There is no six-digit code: it could be guessed offline from a captured exchange and gave away the phone's key, so it was removed on 2026-10-17. Nothing here has been run on a real device by the author.
