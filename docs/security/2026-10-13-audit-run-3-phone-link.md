# Security audit run 3: phone link and iPhone app (2026-10-13)

Scope: the Mac phone-link host and pairing (`Sources/PairVoxLink`), the shared wire library (`Sources/PairVoxLinkKit`), the Mac companion screens (`PhoneLinkModel`, Settings → Phone), the engine path for remote text, and the new iPhone app (`ios/`). Source ref: commit 0270ca8 plus the uncommitted phone work. Same sandbox as run 2: Core and Link code ran in `sandbox-exec` with no network, no home folder, scratch-only writes. The iPhone app's frameworks (SwiftUI, Speech, LocalAuthentication, Keychain) cannot run there, so the app was reviewed as source, with pure logic copied into tests.

## How it ran

Four hunters worked in parallel (crypto and handshake; pairing; host authorization and resource limits; transport and app wiring). I fixed their confirmed findings with regression tests. A fifth hunter then attacked the fixed code, and a sixth reviewed the iPhone app. Each finding was reproduced by the hunter that raised it; three hunters independently found the revoke flaw. Unlike run 2, fixes were not re-verified by a separate agent one by one: the second pass (hunter 5) is the independent check, and it found two real holes in my fixes (below). The final iPhone-app fixes have regression tests but no further independent pass.

## Findings and fixes

| Finding | Sev | Fix |
|---|---|---|
| Revoking a connected phone left it connected: it kept receiving transcripts, commands and spoken text (found by three hunters) | Medium | `LinkHost.dropDevice`; every push re-checks the device; Remove closes the connection |
| Switching the phone link off left connected phones active and able to instruct Claude | Medium | `LinkHost.shutdown()`; stale listener starts are discarded |
| Remote text was parsed as general commands: "execute mode" left Brainstorm, "new session" ended the session | Low | Text from a phone keeps only interrupt and acknowledgement as commands; the rest is an instruction to Claude |
| An oversized snapshot (one huge entry) silently cut a phone off | Low | `LinkSnapshot.bounded()`: every field cut by UTF-8 bytes, whole snapshot shrunk under 400 KB |
| Run-3 pass 2: the size cap counted characters, so combining marks still made a 4.8 MB frame | Medium | Cut by Unicode scalar and UTF-8 size, check the encoded size, same for `speak()` |
| Run-3 pass 2: a request cut for size could still be approved by tap, hiding the tail of a command | Medium | The request is flagged `truncated`; the Mac refuses to approve it from the phone, the phone shows "approve on the Mac" |
| Any tailnet peer could burn the open pairing offer with 3 wrong requests | Low | Failures counted per peer (3 and that peer is ignored), 12 total burn the offer; the on-screen code clears when it is used up |
| No timeout, connection cap or per-device cap before login | Low | 10 s pre-login deadline, 8 pre-login slots with 3 per peer, 3 sessions per device |
| A failed save on Remove was hidden; the phone could return after a restart | Low | Blocked in memory at once, error shown |
| Unreadable `paired-phones.json` was overwritten by the next pairing; temp file briefly readable | Low | Moved aside; written private (0600) before it replaces the file; folder 0700 |
| Phone name could carry control, direction-override or blank characters into the Accept dialog | Low | Cleaned and limited to 64 characters and 128 bytes |
| Handshake proofs did not bind the version and device ID and shared a key with other uses | Hardening | Proof key derived separately; version and device ID included |
| iPhone: a hostile QR code could pair the phone with any host, which then receives everything spoken or typed | Medium | Only Tailscale addresses (100.64.0.0/10, fd7a:115c:a1e0::/48), `*.ts.net` names, or this device are accepted, ASCII only; the app shows "Pair with host:port?" first |
| iPhone: the 15 s connect and pair timeout never fired | Low | The timer closes the transport |
| iPhone: a spoken sentence could be delivered twice; the phone could hear its own request prompt | Low (needs device) | Delivery guarded; the prompt is not spoken while the mic is open |
| iPhone: no way back to pairing after a failed attempt; Keychain save could lose the key; stale reconnect loop; transcript visible in the app switcher; audio session on at launch | Hardening | Pair screen follows "has a key"; update-in-place Keychain save; generation token; privacy cover; session started when speaking |

## Still open

- **Six-digit code** can be recovered from a captured pairing exchange in about a second. It still needs your Pair click on the Mac, and the QR code does not have this weakness. A longer code or a PAKE would close it.
- **Phone keys on the Mac** are in a 0600 file, not the Keychain.
- **Spoken "yes" binds to the request showing when the sentence finishes**, not when it started. The Mac still enforces voice approval rules, the 300 s limit and "shown on this connection".
- **The phone's own voice may be heard by its microphone** (no echo cancellation yet); measure with your earbuds and the speaker.
- **Not run on a device:** the iPhone app compiles for the simulator SDK but has not been run. This Mac has no iPhone simulator runtime installed.
- **TCP limits** (descriptor exhaustion, accept backlog) could not be measured without network access.
- This is a scoped, source-first audit with sandboxed local evidence, not a claim of complete coverage; the link has not been fuzzed.
