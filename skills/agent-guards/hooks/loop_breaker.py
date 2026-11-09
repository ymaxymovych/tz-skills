#!/usr/bin/env python3
"""Loop breaker: 3rd identical refusal of the same tool -> hint, 6th -> deny the repeat.
Bounded transcript read. Stdlib only; fail open, never allow."""
from collections import Counter
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import sys

TAIL_BYTES = 3 * 1024 * 1024
WINDOW = 500
RECENT = 30


def text_content(value):
    if isinstance(value, str):
        return value
    if isinstance(value, list):
        return " ".join(text_content(x.get("text", "")) for x in value if isinstance(x, dict))
    if isinstance(value, dict):
        return text_content(value.get("error") or value.get("content") or value.get("text") or "")
    return ""


def normalize(text):
    text = re.sub(r'''[A-Za-z]:[\\/][^\s`"'<>|;,)]*|(?<![\w:])/(?:[^\s/`"'<>|;,)]*/)+[^\s`"'<>|;,)]*''', "P", text)
    text = re.sub(r"\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b|\b0x[0-9a-f]+\b|\b[0-9a-f]{16,}\b", "H", text, flags=re.I)
    text = re.sub(r"\d+", "N", text)
    return " ".join(text.split())[:160]


def command_tokens(inputs):
    command = str(inputs.get("command") or "").strip()
    # Strip either prefix repeatedly: assignments may appear before or after cd.
    prefix = r'''^(?:cd\s+(?:"[^"]*"|'[^']*'|\S+)\s*&&\s*|[A-Za-z_]\w*=(?:"[^"]*"|'[^']*'|[^\s]+)\s+)'''
    while True:
        stripped = re.sub(prefix, "", command, count=1, flags=re.I)
        if stripped == command:
            break
        command = stripped.lstrip()
    return [token.strip("\"'") for token in re.findall(r'''"[^"]*"|'[^']*'|\S+''', normalize(command))]


def action_key(tool, inputs):
    if tool in ("Bash", "PowerShell"):
        return " ".join(command_tokens(inputs)[:3])
    return (tool + " " + json.dumps(inputs, sort_keys=True, ensure_ascii=False, separators=(",", ":")))[:200]


def tail_lines(path):
    """Read backwards in blocks, stopping at the 500th distinct tool use."""
    selected, seen, pending = [], set(), b""
    with Path(path).open("rb") as stream:
        stream.seek(0, 2)
        position = stream.tell()
        while position:
            size = min(position, TAIL_BYTES)
            position -= size
            stream.seek(position)
            data = stream.read(size) + pending
            if b'"tool_' not in data:
                # Preserve only the incomplete first line for the preceding
                # block; skip large irrelevant records without splitting them.
                newline = data.find(b"\n")
                pending = data[:newline] if newline >= 0 else data
                continue
            lines = data.split(b"\n")
            pending = lines.pop(0) if position else b""
            for line in reversed(lines):
                if b'"tool_use"' not in line and b'"tool_result"' not in line:
                    continue
                selected.append(line)
                for _, block in blocks([line]):
                    if block["type"] == "tool_use":
                        seen.add(block.get("id"))
                if len(seen) >= WINDOW:
                    yield from reversed(selected)
                    return
    yield from reversed(selected)


def blocks(lines):
    for line in lines:
        if isinstance(line, bytes):
            if b'"tool_use"' not in line and b'"tool_result"' not in line:
                continue
        try:
            row = json.loads(line)
            content = row.get("message", {}).get("content")
            if isinstance(content, list):
                for block in content:
                    if isinstance(block, dict) and block.get("type") in ("tool_use", "tool_result"):
                        yield row, block
        except (ValueError, AttributeError, TypeError):
            continue


def new_call(block):
    return {"id": block.get("id"), "tool": block.get("name", ""),
            "input": block.get("input") or {}, "error": None}


def history_from(lines):
    calls = {}
    for _, block in blocks(lines):
        if block["type"] == "tool_use":
            ident = block.get("id")
            if ident not in calls:
                calls[ident] = new_call(block)
                if len(calls) > WINDOW:
                    del calls[next(iter(calls))]
        elif block.get("is_error") is True and block.get("tool_use_id") in calls:
            calls[block["tool_use_id"]]["error"] = text_content(block.get("content"))
    return list(calls.values())


def blocked(error):
    """Policy/tool refusals only: an ordinary non-zero exit (red test, failed build) is normal iteration."""
    return error is not None and not error.lstrip().startswith("Exit code")


def failures(history):
    return [(call["tool"], normalize(call["error"]), action_key(call["tool"], call["input"]))
            for call in history[-WINDOW:] if blocked(call.get("error"))]


def pre_decision(history, tool, inputs):
    """Pure decision shared by live hooks and counterfactual replay.

    warn: >=3 однакові відмови у вікні 500 викликів для схожої дії (той самий ключ або перший токен команди).
    deny: >=6 однакових відмов САМЕ цієї дії (той самий ключ) і петля свіжа — остання така відмова
    не далі RECENT викликів тому. Ширше не блокуємо: прогін 01-08.11 показав, що блок за першим
    токеном («git») дав би 2 279 відмов, зокрема легітимним командам у власному дереві.
    """
    key = action_key(tool, inputs)
    window = history[-WINDOW:]
    first = command_tokens(inputs)[:1] if tool in ("Bash", "PowerShell") else []
    similar, same, last_seen = Counter(), Counter(), {}
    for pos, call in enumerate(window):
        if call["tool"] != tool or not blocked(call.get("error")):
            continue
        sig = normalize(call["error"])
        old_key = action_key(tool, call["input"])
        if key == old_key or (first and first == command_tokens(call["input"])[:1]):
            similar[sig] += 1
        if key == old_key:
            same[sig] += 1
            last_seen[sig] = pos
    for sig, count in same.most_common():
        if count >= 6 and len(window) - last_seen[sig] <= RECENT:
            return "deny", count, sig, key
    if similar:
        sig, count = similar.most_common(1)[0]
        if count >= 3:
            return "warn", count, sig, key
    return None


def error_for(payload, history=None):
    error = text_content(payload.get("error")) or text_content(payload.get("tool_response"))
    if error:
        return error
    if history is None:
        history = history_from(tail_lines(payload["transcript_path"]))
    return next((call["error"] for call in reversed(history) if call.get("error") is not None), "")


def post_decision(payload, history):
    tool = payload.get("tool_name", "")
    error = error_for(payload, history)
    if not blocked(error or None):
        return None
    signature = normalize(error)
    count = sum(name == tool and sig == signature for name, sig, _ in failures(history))
    # Failure events may arrive before their result is appended. Use the id when
    # available; otherwise only treat the latest matching call as already recorded.
    ident = payload.get("tool_use_id")
    current = next((c for c in reversed(history) if c["id"] == ident), None) if ident else (history[-1] if history else None)
    recorded = current and current["tool"] == tool and current.get("error") is not None and normalize(current["error"]) == signature
    if not recorded:
        count += 1
    if count >= 3:
        return "warn", count, signature, action_key(tool, payload.get("tool_input") or {})
    return None


def response(payload, decision):
    from tool_hints import hint_for, lang
    action, count, signature, key = decision
    n = lang()
    hint = hint_for(signature) or ""
    if action == "deny":
        message = (f"🛑 РОЗМИКАЧ ПЕТЕЛЬ: ця дія вже {count} разів отримала ту саму відмову ({signature[:160]}). Повтор заблоковано. Зміни підхід: {hint}",
                   f"🛑 LOOP BREAKER: this action got the same refusal {count} times ({signature[:160]}). The repeat is blocked. Change approach: {hint}")[n]
    else:
        message = (f"⚠️ Зупинись: ця дія заблокована політикою ({count} однакових відмов). Зміни підхід. {hint}",
                   f"⚠️ Stop: this action keeps being refused ({count} identical refusals). Change approach. {hint}")[n]
    message = message.strip()
    output = {"hookEventName": payload["hook_event_name"], "additionalContext": message}
    if action == "deny":
        output.update(permissionDecision="deny", permissionDecisionReason=message)
    log = {"ts": datetime.now(timezone.utc).isoformat(), "session_id": payload.get("session_id"),
           "event": payload["hook_event_name"], "tool": payload.get("tool_name"),
           "action": action, "count": count, "signature": signature[:200], "key": key}
    path = Path.home() / ".claude/logs/loop_breaker.jsonl"
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as stream:
        stream.write(json.dumps(log, ensure_ascii=False) + "\n")
    return {"hookSpecificOutput": output, "systemMessage": message}


def main():
    try:
        if os.environ.get("AGENT_GUARDS_OFF") == "1":
            return
        payload = json.loads(sys.stdin.buffer.read().decode("utf-8"))
        event = payload.get("hook_event_name")
        if event not in ("PreToolUse", "PostToolUseFailure"):
            return
        history = history_from(tail_lines(payload["transcript_path"]))
        decision = (pre_decision(history, payload.get("tool_name", ""), payload.get("tool_input") or {})
                    if event == "PreToolUse" else post_decision(payload, history))
        if decision:
            print(json.dumps(response(payload, decision), ensure_ascii=True))
    except Exception:
        return


if __name__ == "__main__":
    main()
