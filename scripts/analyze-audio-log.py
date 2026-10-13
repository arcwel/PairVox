#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Summarize one PairVox run from its diagnostic log, for comparing audio setups by ear and by log.

  scripts/analyze-audio-log.py                 # newest run in ~/Library/Logs/PairVox/pairvox.log
  scripts/analyze-audio-log.py RUNID           # a specific run
  scripts/analyze-audio-log.py --log FILE      # a log from an exported zip
  scripts/analyze-audio-log.py --json          # machine-readable

Reports engine starts and restarts, route changes, dropped or held playback, playback gaps, source and
mixer-side corruption, and capture health. A line that says "mixer-side corrupt" with no "synth.corrupt"
means the garbage appeared after synthesis; a clean log with audible crackle points at the link or headset.
"""
import argparse, collections, json, os, sys

ap = argparse.ArgumentParser()
ap.add_argument("run", nargs="?")
ap.add_argument("--log", default=os.path.expanduser("~/Library/Logs/PairVox/pairvox.log"))
ap.add_argument("--json", action="store_true")
args = ap.parse_args()

rows = []
with open(args.log, encoding="utf-8") as fh:
    for line in fh:
        if line.startswith("{"):
            try: rows.append(json.loads(line))
            except ValueError: pass
if not rows:
    sys.exit("no log lines found in " + args.log)
run = args.run or rows[-1]["run"]
rs = [r for r in rows if r["run"] == run]
if not rs:
    sys.exit("no lines for run " + run)

counts = collections.Counter(r["ev"] for r in rs if r["ev"] != "stats")
def ev(name): return [r for r in rs if r["ev"] == name]
stats = [r["f"] for r in rs if r["ev"] == "stats"]
playing = [f for f in stats if f.get("outPlayingBuffers", 0) > 0 and f.get("outPeakDb", -120) > -119]
started = ev("engine.started") + ev("engine.started.separate") + ev("engine.started.outputOnly")
mode = ("separate" if ev("engine.started.separate") else "combined" if ev("engine.started") else
        "output-only" if ev("engine.started.outputOnly") else "none")
report = {
    "run": run, "from": rs[0]["t"], "to": rs[-1]["t"], "mode": mode,
    "engine_starts": len(started), "restarts": len(ev("engine.restarted")) + len(ev("capture.restarted")),
    "config_changes": len(ev("engine.configChange")), "config_changes_ignored": len(ev("engine.configChange.ignored")),
    "restart_loops": len(ev("engine.restartLoop")),
    "playback_dropped": len(ev("playback.dropped")), "playback_held": len(ev("playback.held")),
    "playback_interrupted": len(ev("playback.interrupted")), "playback_gaps": [r["f"]["gapMs"] for r in ev("playback.gap")],
    "synth_sentences": len(ev("synth")), "synth_corrupt": len(ev("synth.corrupt")),
    "mixer_corrupt": sum(1 for r in ev("output.glitch") if r["f"].get("corrupt")),
    "mixer_sustained_noise": sum(1 for r in ev("output.glitch") if r["f"].get("sustainedNoise")),
    "capture_failures": len(ev("capture.failed")), "capture_start_failures": len(ev("capture.start.failed")),
    "max_output_peak_db": max([f["outPeakDb"] for f in playing] or [None]),
    "capture_seconds_total": round(sum(f.get("captureSeconds", 0) for f in stats), 1),
    "routes": sorted({(r["f"].get("pinnedOut") or r["f"].get("out") or "-") for r in started}),
}
if args.json:
    print(json.dumps(report, indent=2)); sys.exit(0)
print(f"run {run}  {report['from'][11:19]} -> {report['to'][11:19]}  mode={mode}  output={', '.join(report['routes'])}")
print(f"  engine starts {report['engine_starts']}, restarts {report['restarts']}, restart loops {report['restart_loops']}")
print(f"  config changes {report['config_changes']} (ignored as harmless: {report['config_changes_ignored']})")
print(f"  playback: dropped {report['playback_dropped']}, held {report['playback_held']}, interrupted {report['playback_interrupted']}, gaps(ms) {report['playback_gaps']}")
print(f"  synthesis: {report['synth_sentences']} sentences, corrupt at source {report['synth_corrupt']}")
print(f"  mixer: corrupt buffers {report['mixer_corrupt']}, sustained noise {report['mixer_sustained_noise']}, peak {report['max_output_peak_db']} dB")
print(f"  capture: {report['capture_seconds_total']} s heard, failures {report['capture_failures']}, start failures {report['capture_start_failures']}")
