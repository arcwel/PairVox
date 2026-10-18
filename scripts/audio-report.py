#!/usr/bin/env python3
"""Summarizes one PairVox run from its log: recognition, turns, latency, audio glitches, announcements.

  scripts/audio-report.py            the newest run
  scripts/audio-report.py --since 10 only events from the last 10 minutes
  scripts/audio-report.py --json     machine-readable
Reads ~/Library/Logs/PairVox/pairvox.log. Prints counts and timings, never what was said."""
import argparse, collections, datetime, json, os, statistics as st, sys

LOG = os.path.expanduser("~/Library/Logs/PairVox/pairvox.log")

def load(since_minutes):
    rows = []
    with open(LOG, encoding="utf-8", errors="replace") as f:
        for line in f:
            try: rows.append(json.loads(line))
            except ValueError: pass
    if not rows: sys.exit("empty log")
    run = rows[-1]["run"]
    rows = [r for r in rows if r["run"] == run]
    if since_minutes:
        cutoff = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(minutes=since_minutes)
        rows = [r for r in rows if datetime.datetime.fromisoformat(r["t"].replace("Z", "+00:00")) >= cutoff]
    return run, rows

def pct(values, p):
    v = sorted(values)
    return round(v[min(len(v) - 1, int(len(v) * p))]) if v else None

def main():
    ap = argparse.ArgumentParser(); ap.add_argument("--since", type=float); ap.add_argument("--json", action="store_true")
    a = ap.parse_args()
    run, rows = load(a.since)
    ev = collections.defaultdict(list)
    for r in rows: ev[r["ev"]].append(r.get("f", {}))
    t = ev["transcribed"]; empty = [x for x in t if x.get("text") == "<0 chars>"]
    turns = ev["turn.completed"]; first = [x["firstAudioMs"] for x in turns if x.get("outcome") == "success" and x.get("firstAudioMs", -1) > 0]
    firstSound = [x["firstSoundMs"] for x in turns if x.get("outcome") == "success" and x.get("firstSoundMs", -1) > 0]
    stats = ev["stats"]
    out = {
        "run": run,
        "route": (ev["input.defaultChanged"] or ev["engine.configChange"] or [{}])[-1],
        "echoCancellation": ("on" if any(x.get("voiceProcessing") for x in stats) else
                             "off (separate engines)" if ev["engine.started.separate"] else
                             "off (" + "; ".join(x.get("reason") or "no reason logged" for x in ev["voiceProcessing.skipped"]) + ")" if ev["voiceProcessing.skipped"] else "off"),
        "voiceProcessingSkipped": [x.get("reason") for x in ev["voiceProcessing.skipped"]],
        "feedbackCaptured": [{k: x.get(k) for k in ("frequencyHz", "agentSpeaking", "files")} for x in ev["feedback.captured"]],
        "utterances": len(t), "emptyTranscripts": len(empty),
        "decodeMsMedian": pct([x["decodeMs"] for x in t], 0.5), "decodeMsP90": pct([x["decodeMs"] for x in t], 0.9),
        "turns": len(turns), "interrupted": sum(1 for x in turns if x.get("outcome") == "interrupted"),
        "firstAudioMsMedian": pct(first, 0.5), "firstAudioMsP90": pct(first, 0.9),
        "firstSoundMsMedian": pct(firstSound, 0.5), "firstSoundMsP90": pct(firstSound, 0.9),
        "commands": dict(collections.Counter(x.get("command") for x in ev["user.submit"])),
        "synthCorrupt": len(ev["synth.corrupt"]), "synthRecovered": [x.get("how") for x in ev["synth.recovered"]],
        "outputGlitches": len(ev["output.glitch"]), "clicksTotal": sum(x.get("outClicks", 0) for x in stats),
        "playbackGaps": len(ev["playback.gap"]), "gapMsMax": max([x["gapMs"] for x in ev["playback.gap"]], default=0),
        "captureDroppedBuffers": sum(x.get("droppedBuffers", 0) for x in stats),
        "approvals": {k: len(ev[k]) for k in ("permission.requested", "permission.decided", "permission.spokenHighRisk") if ev[k]},
        "phoneLink": [x.get("event", x.get("cmd")) for x in ev["phoneLink"] + ev["phoneLink.control"]][-8:],
    }
    if a.json: print(json.dumps(out, indent=1, default=str)); return
    print(f"run {run}")
    print(f"route: in={out['route'].get('in')} ({out['route'].get('inTransport')})  out={out['route'].get('out')} ({out['route'].get('outTransport')})")
    print(f"echo cancellation: {out['echoCancellation']}")
    for fb in out["feedbackCaptured"]:
        print(f"HOWL captured: {fb['frequencyHz']} Hz, agent speaking: {fb['agentSpeaking']}, files: {fb['files']}")
    if not out["feedbackCaptured"]: print("howls captured: none")
    print(f"speech: {out['utterances']} utterances, {out['emptyTranscripts']} empty; decode median {out['decodeMsMedian']} ms, p90 {out['decodeMsP90']} ms")
    print(f"turns: {out['turns']} ({out['interrupted']} interrupted); first sound (acknowledgement or answer) median {out['firstSoundMsMedian']} ms, p90 {out['firstSoundMsP90']} ms; first answer audio median {out['firstAudioMsMedian']} ms, p90 {out['firstAudioMsP90']} ms")
    print(f"commands heard: {out['commands']}")
    print(f"audio: corrupt synth {out['synthCorrupt']} (recovered by {out['synthRecovered'] or 'nothing'}), glitches {out['outputGlitches']}, clicks {out['clicksTotal']}, gaps {out['playbackGaps']} (max {out['gapMsMax']} ms), dropped capture buffers {out['captureDroppedBuffers']}")
    print(f"approvals: {out['approvals'] or 'none'}")
    print(f"phone link (last events): {out['phoneLink'] or 'none'}")

main()
