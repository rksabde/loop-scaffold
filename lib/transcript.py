#!/usr/bin/env python3
"""loop/transcript.py — render a worker log to a readable markdown transcript.

Understands: claude `--output-format json` (one result object) and codex `--json`
(JSONL events). Tolerant of unknown shapes: falls back to dumping text-ish fields.
Never raises for the loop's sake — worst case it emits a stub note.

  python3 loop/transcript.py <logfile> [--prompt <promptfile>] [--role engineer] [--title T]
"""
import argparse
import json
import sys


def render_claude(d, out):
    mu = sorted((d.get("modelUsage") or {}).keys())
    out.append("## Run\n")
    out.append(f"- models: {', '.join(mu) or '?'}")
    for k in ("total_cost_usd", "num_turns", "duration_ms", "stop_reason",
              "terminal_reason", "is_error", "session_id"):
        if d.get(k) is not None:
            out.append(f"- {k}: {d[k]}")
    out.append("")
    out.append("## Assistant (final)\n")
    out.append(str(d.get("result") or "(empty result)"))
    out.append("")


def render_jsonl(raw, out):
    out.append("## Events\n")
    n = 0
    for line in raw.splitlines():
        try:
            ev = json.loads(line)
        except ValueError:
            continue
        if not isinstance(ev, dict):
            continue
        msg = ev.get("msg") if isinstance(ev.get("msg"), dict) else ev
        text = None
        for k in ("text", "message", "last_agent_message", "content", "result"):
            v = msg.get(k)
            if isinstance(v, str) and v.strip():
                text = v.strip()
                break
        if text:
            typ = msg.get("type") or ev.get("type") or "event"
            out.append(f"**{typ}**\n\n{text}\n")
            n += 1
    if not n:
        out.append("(no renderable events — see the raw log under loop/logs/)")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("logfile")
    ap.add_argument("--prompt", help="file containing the prompt sent to the worker")
    ap.add_argument("--role", default="worker")
    ap.add_argument("--title")
    a = ap.parse_args()

    out = [f"# {a.title or a.role + ' transcript'}\n"]
    if a.prompt:
        try:
            out.append("## Prompt\n\n```\n"
                       + open(a.prompt, errors="replace").read().strip()
                       + "\n```\n")
        except OSError:
            pass
    try:
        raw = open(a.logfile, errors="replace").read()
    except OSError as e:
        out.append(f"(log unreadable: {e})")
        print("\n".join(out))
        return
    try:
        render_claude(json.loads(raw), out)
    except ValueError:
        render_jsonl(raw, out)
    print("\n".join(out))


if __name__ == "__main__":
    try:
        main()
    except Exception as e:                          # never break the loop
        print(f"# transcript render error\n\n{e}")
        sys.exit(0)
