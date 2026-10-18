#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Measure one PairVox run against the v0.1 checks (docs/plans/2026-10-17-v0.1-checks.md).

Reads ~/Library/Logs/PairVox/pairvox.log (and the rotated pairvox.1.log). Counts and timings only, never text.

  scripts/v01-check.py                 # the newest run
  scripts/v01-check.py --run 16e4c87a  # a given run
  scripts/v01-check.py --json          # one JSON object

Exit codes: 0 every measured check passed, 1 a check failed or has too few turns, 2 bad usage, 3 no log or run.
"""
import argparse, json, os, statistics, sys

LOG_DIR = os.path.expanduser("~/Library/Logs/PairVox")
SETTINGS = os.path.expanduser("~/Library/Application Support/PairVox/settings.json")

# Thresholds. Change them here and in the checks doc together.
LAUNCH_SHORTCUTS_MS = 5000      # shortcuts registered within 5 s (scripts/launch-check.sh uses the same limit)
MIN_TURNS_PER_ROUTE = 10        # answered turns needed before a route's numbers count
HEARD_LATENCY_MEDIAN_MS = 3500  # end of your speech to first sound, median: pass mark (owner, 2026-10-17)
HEARD_LATENCY_GOAL_MS = 2000    # the goal; reported, not required
MAX_GAP_MS = 1000               # no silence longer than this inside a reply


def events():
    out = []
    for name in ("pairvox.1.log", "pairvox.log"):
        path = os.path.join(LOG_DIR, name)
        if not os.path.exists(path):
            continue
        with open(path, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                try:
                    out.append(json.loads(line))
                except ValueError:
                    pass
    return out


def end_silence_ms():
    try:
        with open(SETTINGS, encoding="utf-8") as fh:
            return int(float(json.load(fh).get("endOfTurnSilence", 0.65)) * 1000)
    except (OSError, ValueError):
        return 650


def measure(evs, run, silence):
    evs = [e for e in evs if e.get("run") == run]
    evs.sort(key=lambda e: e.get("ms", 0))
    first = lambda name: next((e for e in evs if e.get("ev") == name), None)
    reg = first("register")
    started = next((e for e in evs if str(e.get("ev", "")).startswith("engine.started")), None)
    launch = {"shortcutsMs": reg and reg["ms"], "engineMs": started and started["ms"]}
    launch["pass"] = bool(reg and started and reg["ms"] <= LAUNCH_SHORTCUTS_MS)

    route, last_end, last_submit, submit_end = "unknown", None, None, None
    has_first_sound = any(e.get("ev") == "turn.firstSound" for e in evs)
    turns, gaps, howls, corrupt, dropped = [], [], 0, 0, 0
    for e in evs:
        ev, f = e.get("ev", ""), e.get("f", {}) or {}
        if ev.startswith("engine.started") or ev == "engine.configChange":
            route = f.get("outTransport", route)
        elif ev == "user.speech.end":
            last_end = e["ms"]
        elif ev == "user.submit":
            last_submit, submit_end = e["ms"], last_end
        elif ev == "turn.firstSound" and last_submit is not None:
            # Written when the answer is first heard, even after Claude has finished the turn (newer builds).
            heard_since_send = f.get("sinceSendMs", -1)
            if isinstance(heard_since_send, (int, float)) and heard_since_send >= 0:
                has_first_sound = True
                stt = last_submit - submit_end if submit_end is not None and 0 <= last_submit - submit_end < 10000 else 0
                turns.append({"route": route, "heardMs": silence + stt + heard_since_send, "firstAudioMs": heard_since_send})
                last_submit = None
        elif ev == "turn.completed" and not has_first_sound:
            # Older builds only: firstAudioMs is -1 when the answer started playing after the turn ended.
            fa = f.get("firstAudioMs", -1)
            if isinstance(fa, (int, float)) and fa >= 0 and last_submit is not None:
                # What you hear: the end-of-turn silence PairVox waits for, transcription, then Claude and the voice.
                stt = last_submit - last_end if last_end is not None and 0 <= last_submit - last_end < 10000 else 0
                turns.append({"route": route, "heardMs": silence + stt + fa, "firstAudioMs": fa})
            last_submit = None
        elif ev == "playback.gap":
            gaps.append({"route": route, "ms": f.get("gapMs", 0)})
        elif ev == "feedback.captured":
            howls += 1
        elif ev == "synth.corrupt":
            corrupt += 1
        elif ev == "playback.dropped":
            dropped += 1

    routes = {}
    for r in sorted({t["route"] for t in turns} | {g["route"] for g in gaps}):
        heard = [t["heardMs"] for t in turns if t["route"] == r]
        long_gaps = [g["ms"] for g in gaps if g["route"] == r and g["ms"] > MAX_GAP_MS]
        enough = len(heard) >= MIN_TURNS_PER_ROUTE
        median = int(statistics.median(heard)) if heard else None
        p90 = int(sorted(heard)[int(0.9 * (len(heard) - 1))]) if heard else None
        routes[r] = {"answeredTurns": len(heard), "enoughTurns": enough, "heardMedianMs": median, "heardP90Ms": p90,
                     "gapsOver1s": len(long_gaps), "longestGapMs": max(long_gaps) if long_gaps else 0,
                     "latencyPass": enough and median is not None and median <= HEARD_LATENCY_MEDIAN_MS,
                     "gapsPass": not long_gaps}
    voice = {"routes": routes, "howls": howls, "corruptSynth": corrupt, "droppedPlayback": dropped,
             "cleanPass": howls == 0 and corrupt == 0 and dropped == 0}
    voice["pass"] = bool(routes) and voice["cleanPass"] and all(v["latencyPass"] and v["gapsPass"] for v in routes.values())
    return {"run": run, "launch": launch, "voice": voice}


def main():
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--run")
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args()
    evs = events()
    if not evs:
        print(f"no log in {LOG_DIR}", file=sys.stderr); return 3
    runs = [e["run"] for e in evs if e.get("ev") == "app.launch" and e.get("run")]
    run = a.run or (runs[-1] if runs else None)
    if not run or not any(e.get("run") == run for e in evs):
        print("no such run", file=sys.stderr); return 3
    r = measure(evs, run, end_silence_ms())
    ok = r["launch"]["pass"] and r["voice"]["pass"]
    if a.json:
        print(json.dumps(r | {"ok": ok}))
    else:
        L, V = r["launch"], r["voice"]
        print(f"run {run}")
        print(f"  launch: shortcuts at {L['shortcutsMs']} ms, engine at {L['engineMs']} ms -> {'PASS' if L['pass'] else 'FAIL'}")
        for name, v in V["routes"].items():
            note = "" if v["enoughTurns"] else f" (need {MIN_TURNS_PER_ROUTE} answered turns)"
            goal = " (goal met)" if v["heardMedianMs"] is not None and v["heardMedianMs"] <= HEARD_LATENCY_GOAL_MS else ""
            print(f"  voice on {name}: {v['answeredTurns']} turns, heard median {v['heardMedianMs']} ms{goal}, p90 {v['heardP90Ms']} ms"
                  f" -> {'PASS' if v['latencyPass'] else 'FAIL'}{note}; gaps over 1 s: {v['gapsOver1s']}"
                  f" (longest {v['longestGapMs']} ms) -> {'PASS' if v['gapsPass'] else 'FAIL'}")
        if not V["routes"]:
            print("  voice: no answered turns in this run -> NOT MEASURED")
        print(f"  howls {V['howls']}, corrupt sentences {V['corruptSynth']}, dropped playback {V['droppedPlayback']}"
              f" -> {'PASS' if V['cleanPass'] else 'FAIL'}")
        print("PASS" if ok else "NOT YET")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
