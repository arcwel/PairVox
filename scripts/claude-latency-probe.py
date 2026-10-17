#!/usr/bin/env python3
"""Measures how long a persistent Claude Code session takes to start answering, the way PairVox runs it.

Starts `claude -p` in stream-json mode with PairVox's arguments, sends a tiny prompt several times and reports, per turn,
the time from writing the message to the first text delta and to the end of the turn. The first turn is a warm-up.

  scripts/claude-latency-probe.py                       # as PairVox runs it
  scripts/claude-latency-probe.py --no-hooks            # with all hooks disabled (--settings disableAllHooks)
  scripts/claude-latency-probe.py --no-thinking         # with extended thinking off (MAX_THINKING_TOKENS=0)
  scripts/claude-latency-probe.py --model haiku --turns 3 --json
It makes real Claude calls: --turns N sends N+1 tiny prompts ("Reply with exactly: ok"). Exit codes: 0 done, 1 failed.
"""
import argparse, json, os, shutil, subprocess, sys, tempfile, threading, time, queue

ap = argparse.ArgumentParser()
ap.add_argument("--turns", type=int, default=3)
ap.add_argument("--no-hooks", action="store_true")
ap.add_argument("--no-thinking", action="store_true")
ap.add_argument("--model")
ap.add_argument("--json", action="store_true")
a = ap.parse_args()

claude = shutil.which("claude") or os.path.expanduser("~/.local/bin/claude")
args = [claude, "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
        "--permission-mode", "default", "--setting-sources", "user", "--include-partial-messages"]
if a.model: args += ["--model", a.model]
if a.no_hooks: args += ["--settings", json.dumps({"disableAllHooks": True})]
env = dict(os.environ)
env.pop("CLAUDECODE", None)
if a.no_thinking: env["MAX_THINKING_TOKENS"] = "0"
cwd = tempfile.mkdtemp(prefix="pairvox-latency-")
proc = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, cwd=cwd, env=env, text=True, bufsize=1)
events = queue.Queue()
threading.Thread(target=lambda: [events.put((time.monotonic(), l)) for l in proc.stdout], daemon=True).start()

def turn(prompt):
    sent = time.monotonic()
    proc.stdin.write(json.dumps({"type": "user", "message": {"role": "user", "content": prompt}, "parent_tool_use_id": None}) + "\n")
    proc.stdin.flush()
    first = None
    while True:
        try: t, line = events.get(timeout=90)
        except queue.Empty: return None
        try: d = json.loads(line)
        except Exception: continue
        if first is None and d.get("type") == "stream_event":
            ev = d.get("event", {})
            if ev.get("type") == "content_block_delta" and ev.get("delta", {}).get("type") == "text_delta":
                first = t - sent
        if d.get("type") == "result":
            return {"firstTextMs": round(first * 1000) if first else None, "totalMs": round((t - sent) * 1000)}

results = []
for i in range(a.turns + 1):
    r = turn("Reply with exactly: ok")
    if r is None: print("timed out waiting for Claude", file=sys.stderr); proc.kill(); sys.exit(1)
    r["warmup"] = (i == 0)
    results.append(r)
proc.stdin.close(); proc.terminate()
timed = [r["firstTextMs"] for r in results if not r["warmup"] and r["firstTextMs"] is not None]
summary = {"variant": {"hooks": not a.no_hooks, "thinking": not a.no_thinking, "model": a.model or "default"},
           "turns": results, "medianFirstTextMs": sorted(timed)[len(timed) // 2] if timed else None}
if a.json: print(json.dumps(summary))
else:
    print(f"hooks={'on' if not a.no_hooks else 'OFF'} thinking={'on' if not a.no_thinking else 'OFF'} model={a.model or 'default'}")
    for r in results: print(f"  {'warm-up' if r['warmup'] else 'turn   '}: first text {r['firstTextMs']} ms, finished {r['totalMs']} ms")
    print(f"  median first text (timed turns): {summary['medianFirstTextMs']} ms")
