#!/usr/bin/env python3
"""Замір «до/після» / before-after count of mechanical agent failures in Claude Code transcripts.

  python measure.py                              # last 7 days
  python measure.py --from 2026-11-01 --to 2026-11-08 --out before.txt   # --to is exclusive

Reads ~/.claude*/projects/**/*.jsonl (every Claude Code config folder), counts tool results that failed
and match a category, and — if the guards are installed — what they fixed or denied (agent_guards.jsonl).
Run it once before installing and once a week after; compare the totals. Output is UTF-8. Stdlib only.
"""
import argparse
import collections
import glob
import json
import os
import re
import sys
import time
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

CATEGORIES = {
    "encoding / кодування": r"UnicodeEncodeError|UnicodeDecodeError|charmap. codec|codec can.t (en|de)code|cp1251|cp1252|cp866|(Р[ЎџІѕ°µ]){2,}|(Ð[\x80-\xbf]){2,}",
    "bash quoting / лапки bash": r"unexpected EOF while looking for matching|syntax error near unexpected token|bad substitution|unbound variable|syntax error: unexpected end of file",
    "JSON": r"JSONDecodeError|Bad control character|Invalid \\escape|Unexpected token .{0,20} in JSON|Expecting (value|property name|. delimiter)|Unterminated string",
    "PowerShell": r"ParserError|The string is missing the terminator|Unexpected token .{0,40} in expression|Missing closing",
    "MSYS path / шляхи MSYS": r"C:/Program Files/Git/|MSYS_NO_PATHCONV|invalid object name .?[A-Z]:/",
    "wrong shell / не та оболонка": r"is not recognized as (an internal or external command|the name of a cmdlet)|command not found",
}
RX = {name: re.compile(pattern) for name, pattern in CATEGORIES.items()}
LOOP = "failure loops / петлі відмов (3+ same refusal)"


def iso_date(value):
    try:
        return date.fromisoformat(value)
    except ValueError:
        raise argparse.ArgumentTypeError("expected YYYY-MM-DD")


def normalize(text):
    return " ".join(re.sub(r"\d+", "N", text).split())[:160]


def result_text(block):
    value = block.get("content")
    if isinstance(value, list):
        value = " ".join(x.get("text", "") for x in value if isinstance(x, dict))
    return value[:20000] if isinstance(value, str) else ""


def scan(roots, start, end):
    counts, sessions, samples = collections.Counter(), collections.Counter(), {}
    files = errors = 0
    cut = datetime.combine(start, datetime.min.time(), tzinfo=timezone.utc).timestamp()
    for root in roots:
        for path in glob.glob(os.path.join(root, "**", "*.jsonl"), recursive=True):
            try:
                if os.path.getmtime(path) < cut:
                    continue
            except OSError:
                continue
            files += 1
            seen, refusals = set(), collections.Counter()
            with open(path, encoding="utf-8", errors="replace") as stream:
                for line in stream:
                    if '"tool_result"' not in line:
                        continue
                    try:
                        row = json.loads(line)
                    except ValueError:
                        continue
                    day = str(row.get("timestamp", ""))[:10]
                    if day < start.isoformat() or (end and day >= end.isoformat()):
                        continue
                    content = row.get("message", {}).get("content")
                    if not isinstance(content, list):
                        continue
                    for block in content:
                        if not isinstance(block, dict) or block.get("type") != "tool_result":
                            continue
                        text = result_text(block)
                        failed = bool(block.get("is_error"))
                        if not (failed or text.lstrip().startswith("Exit code")):
                            continue
                        errors += failed
                        for name, rx in RX.items():
                            match = rx.search(text)
                            if match:
                                counts[name] += 1
                                seen.add(name)
                                if len(samples.setdefault(name, [])) < 3:
                                    samples[name].append(text[max(0, match.start() - 120):match.end() + 120].replace("\n", " ⏎ "))
                        # a refusal is an is_error result that is not an ordinary non-zero exit
                        if failed and not text.lstrip().startswith("Exit code"):
                            refusals[normalize(text)] += 1
            repeats = sum(n - 2 for n in refusals.values() if n >= 3)
            if repeats:
                counts[LOOP] += repeats
                seen.add(LOOP)
            sessions.update(seen)
    return files, errors, counts, sessions, samples


def guard_actions(start, end):
    log = Path.home() / ".claude/logs/agent_guards.jsonl"
    actions = collections.Counter()
    if log.exists():
        for line in log.read_text(encoding="utf-8", errors="replace").splitlines():
            try:
                row = json.loads(line)
            except ValueError:
                continue
            day = str(row.get("ts", ""))[:10]
            if day >= start.isoformat() and (not end or day < end.isoformat()):
                actions[f"{row.get('rule')}:{row.get('action')}"] += 1
    return actions


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--from", dest="start", type=iso_date, help="first day, YYYY-MM-DD (default: 7 days ago)")
    parser.add_argument("--to", dest="end", type=iso_date, help="last day, exclusive")
    parser.add_argument("--out", help="write the report to this UTF-8 file")
    parser.add_argument("--projects", action="append", help="transcript root (repeatable); default: ~/.claude*/projects")
    args = parser.parse_args()
    start = args.start or (date.today() - timedelta(days=7))
    if args.end and args.end <= start:
        parser.error("--to must be after --from")
    roots = args.projects or sorted(glob.glob(os.path.join(os.path.expanduser("~"), ".claude*", "projects")))
    if not roots:
        sys.exit("No transcript folders found (~/.claude*/projects). Nothing to measure.")
    files, errors, counts, sessions, samples = scan(roots, start, args.end)
    lines = [f"period: {start} .. {args.end or 'now'} | files scanned: {files} | tool errors (is_error): {errors}"]
    total = sum(counts.values())
    for name, n in counts.most_common():
        lines.append(f"{n:6d} hits in {sessions[name]:4d} sessions | {name}")
    lines.append(f"{total:6d} TOTAL")
    actions = guard_actions(start, args.end)
    if actions:
        lines.append("\nguards (agent_guards.jsonl): " + ", ".join(f"{k}={v}" for k, v in sorted(actions.items())))
    lines.append("\nsamples:")
    for name, items in samples.items():
        lines.append("## " + name)
        lines.extend("   " + item[:400] for item in items)
    report = "\n".join(lines) + "\n"
    if args.out:
        Path(args.out).write_text(report, encoding="utf-8")
        print(f"report written to {args.out}; total hits {total}")
    else:
        sys.stdout.buffer.write(report.encode("utf-8"))


if __name__ == "__main__":
    main()
