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

## Setup checklist

1. Tailscale is running and signed in on the Mac and on the iPhone (the iPhone shows the VPN indicator in its status bar).
2. The access rules allow the phone to reach the Mac on 47821 (above).
3. PairVox on the Mac: **Settings → Phone**, switch on "Let paired phones connect over Tailscale". It shows "This Mac: 100.x.y.z:47821".
4. PairVox on the phone: scan the QR code or type the Mac's address, port and six-digit code. Click **Pair** in the dialog on the Mac.

## Troubleshooting

| What you see | Likely cause | Fix |
|---|---|---|
| Phone: "connecting (cancelled)" | Port blocked by tailnet rules, or Tailscale is off on the phone | Add port 47821 to the rule; check the VPN indicator on the phone |
| Phone: "That address is not on your Tailscale network" | The address typed is not a Tailscale address (100.64.0.0/10, a `.ts.net` name or an fd7a:115c:a1e0 address) | Use the address shown in Settings → Phone |
| Mac: "Tailscale is not running on this Mac" | No Tailscale address could be found | Start Tailscale, then switch the phone link off and on |
| Phone connects, then "Pairing did not complete" with "closed" and the network state "connected" | The code expired (two minutes), was used already, or you did not click Pair on the Mac | Show a new code and try again |
| `pairvox-link pair` says an offer is already open | A previous code or QR has not expired | Cancel it in Settings → Phone, or wait two minutes |
