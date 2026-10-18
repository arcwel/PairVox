# Phone link setup: Tailscale

The iPhone app talks to the PairVox Mac app over [Tailscale](https://tailscale.com). Both devices must be signed in to the same tailnet. **If your tailnet restricts which ports devices may reach, one rule is needed (below). Without it, pairing fails silently.**

## The one thing most people miss: open port 47821

PairVox listens for phones on **TCP port 47821** on the Mac (change it with `phoneLinkPort` in `~/Library/Application Support/PairVox/settings.json`, from 1024 to 65535).

- **Default tailnet policy ("allow all"):** nothing to do.
- **Your own access rules (ACLs):** allow your phone to reach your Mac on port 47821. In the admin console (login.tailscale.com/admin/acls/file), add the port to the rule whose source is the phone and whose destination is the Mac. For example, this rule lets a device named `phone` (defined under `hosts`) reach the Mac, here called `mac`, on that port:

  ```json
  {"action": "accept", "src": ["phone"], "dst": ["mac:47821"]}
  ```

  If you already have a rule from the phone to the Mac, append `,47821` to its port list instead (for example `"mac:8787,443,47821"`).

**What it looks like when the port is blocked.** The phone sits on "connecting" and then shows "Pairing did not complete (closed; network: connecting (cancelled))". The Mac's log shows nothing at all, because the traffic never arrives. Tailscale drops blocked connections without any error.

**To check from the Mac** that the rule is in effect (Tailscale CLI):

```bash
tailscale debug netmap | python3 -c "import json,sys; [print(sorted({d['Ports']['First'] for d in r['Dsts']})) for r in json.load(sys.stdin)['PacketFilter']]"
```

The list for your phone's rule must contain 47821. (With the macOS app version of Tailscale, use `/Applications/Tailscale.app/Contents/MacOS/Tailscale` in place of `tailscale`.)

## If Tailscale on the Mac runs in "userspace" mode

Some setups (for example a `tailscaled --tun=userspace-networking` started from Homebrew) have no network interface, so the Mac does not receive connections on its tailnet address unless Tailscale forwards them. PairVox finds the address by asking the `tailscale` command and shows this notice in **Settings → Phone**. Run once, in Terminal:

```bash
tailscale --socket="$HOME/.config/tailscale/tailscaled.sock" serve --bg --tcp 47821 tcp://127.0.0.1:47821
```

Remove it later with the same command ending `serve --tcp=47821 off`. Connections then reach PairVox from `127.0.0.1`, which PairVox accepts; the access rules above still decide who may connect. With the normal Tailscale macOS app (which has a network interface) this step is not needed.

**If Tailscale later gets a network interface** (the Tailscale app, or `tailscaled` run as a system service), remove that forward. With an interface, Tailscale holds port 47821 on the tailnet address itself, PairVox cannot listen on it, and the phone shows the Mac as offline. Settings → Phone then says the port is taken, and `pairvox-link doctor` reports a stale forward. The fix:

```bash
tailscale serve --tcp 47821 off
```

Then turn the phone link off and on, or reopen PairVox. Seen on 2026-10-18.

## Setup checklist

1. Tailscale is running and signed in on the Mac and on the iPhone (the iPhone shows the VPN indicator in its status bar).
2. The access rules allow the phone to reach the Mac on 47821 (above).
3. PairVox on the Mac: **Settings → Phone**, switch on "Let paired phones connect over Tailscale". It shows "This Mac: 100.x.y.z:47821".
4. PairVox on the phone: scan the QR code, or on the Mac press **Copy link** and paste it into the phone app (Universal Clipboard carries it across). Click **Pair** in the dialog on the Mac.

## Staying connected

Pairing is a one-time process. Once paired, the phone reconnects automatically using saved credentials. You only need to pair again if you remove the Mac from the phone or the phone from the Mac.

Because of how iOS manages background processes, a live connection cannot remain permanent. When the phone app moves to the background (e.g., you switch to another app or lock the screen), iOS freezes the app within seconds, which terminates the network connection. The Mac will drop the phone connection after 35 seconds of inactivity. 

To manage these interruptions, the phone app performs the following actions:

- **Reconnection on foregrounding:** When you bring the app to the front, it immediately checks the link. If the Mac has been silent for over 15 seconds, the phone drops the inactive link and establishes a new one.
- **Network changes:** If the network changes (such as switching from Wi-Fi to cellular) or Tailscale reconnects, the app reconnects immediately rather than waiting for the next retry interval.
- **Retry logic:** If a connection attempt fails while the app is open, the app retries after 1, 2, 4, 8, and 15 seconds.
- **Dead link detection:** If a ping cannot be sent, the app closes the link immediately. This allows a dead connection to be replaced within 10 seconds while the app is in the foreground.

To maintain a reliable connection, configure your devices as follows:

- **On the phone:** In the Tailscale app, enable **VPN On Demand** so the tunnel reconnects automatically after sleep or a network change.
- **On the Mac:** Ensure the Mac stays awake with Tailscale and PairVox running. Set your System Settings > Energy to prevent sleep (or use the `caffeinate` command) and ensure Tailscale is set to start at login.
- **During use:** Keep the PairVox app in the foreground on your phone when you expect a request. This application does not currently support push notifications for approvals while the phone is locked.

## Troubleshooting

| What you see | Likely cause | Fix |
|---|---|---|
| Phone: "connecting (cancelled)" | Port blocked by tailnet rules, or Tailscale is off on the phone | Add port 47821 to the rule; check the VPN indicator on the phone |
| Phone: "That address is not on your Tailscale network" | The address typed is not a Tailscale address (100.64.0.0/10, a `.ts.net` name or an fd7a:115c:a1e0 address) | Use the address shown in Settings → Phone |
| Mac: "Tailscale is not running on this Mac" | No Tailscale address could be found | Start Tailscale, then switch the phone link off and on |
| Phone connects, then "Pairing did not complete" with "closed" and the network state "connected" | The code expired (two minutes), was used already, or you did not click Pair on the Mac | Show a new code and try again |
| Phone: "Pairing did not complete" with "Software caused connection abort" (error 53), and the Mac log says `pairing.granted` or `pairing.undelivered` | The phone stopped waiting before you clicked Pair on the Mac. Older phone builds waited 15 seconds; current ones wait 130 | Update the phone app, show a new code, and click Pair on the Mac while the phone says it is waiting. A Mac that does not hear back from the phone removes the pairing again |
| `pairvox-link pair` says an offer is already open | A previous code or QR has not expired | Cancel it in Settings → Phone, or wait two minutes |
