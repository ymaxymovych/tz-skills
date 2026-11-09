#!/usr/bin/env python3
"""Safe-path hints for common tool failures. Stdlib only, fail open, never grants permission."""
import json
import os
from pathlib import Path
import re
import sys

# (regex over the error text, (uk hint, en hint))
HINTS = [
    (r"Blocked: sleep", ("Очікування — фонова команда (run_in_background) або until-цикл із перевіркою умови, а не sleep.",
                         "Wait with a background command (run_in_background) or an until-loop that checks the condition, not sleep.")),
    (r"String to replace not found|modified since read", ("Перечитай файл (потрібний шматок) і зроби Edit по свіжому тексту; не повторюй старий old_string.",
                                                           "Re-read the file (the relevant part) and Edit against the fresh text; do not repeat the old old_string.")),
    (r"CDP sendCommand|did not respond in time|no tab group of its own|not in Claude.s tab group|tab group no longer exists",
     ("Вкладка втрачена: новий tabs_context_mcp → нова вкладка tabs_create_mcp → navigate; довгий текст — лише form_input.",
      "The tab is lost: new tabs_context_mcp -> new tab via tabs_create_mcp -> navigate; long text only via form_input.")),
    (r"exceeds maximum allowed tokens", ("Читай шматками: offset/limit або спершу rg -n.",
                                         "Read in parts: offset/limit, or rg -n first.")),
]


def lang():
    value = os.environ.get("AGENT_GUARDS_LANG")
    if not value:
        try:
            value = (Path.home() / ".claude/hooks/agent_guards.lang").read_text(encoding="utf-8").strip()
        except OSError:
            value = "uk"
    return 1 if value == "en" else 0


def hint_for(text):
    found = next((hint for pattern, hint in HINTS if re.search(pattern, text, re.I)), None)
    return found[lang()] if found else None


def pre_reason(tool, inputs):
    if tool in ("mcp__claude-in-chrome__computer", "mcp__Claude_Browser__computer"):
        text = inputs.get("text") or ""
        if inputs.get("action") == "type" and len(text) > 300:
            return (f"Довгий текст ({len(text)} симв.) через computer type зависає (CDP timeout). Встав через form_input(ref, value); потім за потреби один пробіл і Backspace, щоб сайт помітив ввід.",
                    f"Long text ({len(text)} chars) via computer type hangs (CDP timeout). Insert it with form_input(ref, value); then, if needed, one space and Backspace so the site notices the input.")[lang()]
    return None


def main():
    try:
        if os.environ.get("AGENT_GUARDS_OFF") == "1":
            return
        payload = json.loads(sys.stdin.buffer.read().decode("utf-8"))
        event = payload.get("hook_event_name")
        if event == "PreToolUse":
            reason = pre_reason(payload.get("tool_name"), payload.get("tool_input") or {})
            if reason:
                print(json.dumps({"hookSpecificOutput": {"hookEventName": event,
                      "permissionDecision": "deny", "permissionDecisionReason": reason}}, ensure_ascii=True))
        elif event == "PostToolUseFailure":
            from loop_breaker import error_for
            hint = hint_for(error_for(payload))
            if hint:
                print(json.dumps({"hookSpecificOutput": {"hookEventName": event,
                      "additionalContext": "💡 " + hint}}, ensure_ascii=True))
    except Exception:
        return


if __name__ == "__main__":
    main()
