#!/usr/bin/env python3
"""PreToolUse shell guard. Stdlib only; fail open, never grant permissions."""
import json
import os
from pathlib import Path
import re
import sys
from datetime import datetime, timezone


ADVICE = {
    "msys": ("додано MSYS_NO_PATHCONV=1 перед викликом",
             "added MSYS_NO_PATHCONV=1 before the call"),
    "pyutf8": ("додано -X utf8 після інтерпретатора Python",
               "added -X utf8 after the Python interpreter"),
    "commitmsg": ("Запиши текст повідомлення інструментом Write у файл і зроби git commit -F <файл>",
                  "Write the message to a file with the Write tool and run git commit -F <file>"),
    "ghbody": ("Запиши тіло інструментом Write у файл і використай --body-file <файл>",
               "Write the body to a file with the Write tool and use --body-file <file>"),
    "curljson": ("серіалізуй JSON у файл і використай --data-binary @файл",
                 "serialize the JSON to a file and use --data-binary @file"),
    "dotenv": (".env не виконувати як код оболонки; щоб прочитати значення — grep '^KEY=' файл | cut -d= -f2- або python-dotenv",
               "do not run .env as shell code; to read a value use grep '^KEY=' file | cut -d= -f2- or python-dotenv"),
    "claudep": ("прапор зі списком значень (--allowedTools, --add-dir, --mcp-config, --tools, --betas, --file …) з'їдає позиційний промпт claude -p. Передай промпт через stdin: claude -p --allowedTools ... < файл-з-промптом",
                "a variadic flag (--allowedTools, --add-dir, --mcp-config, --tools, --betas, --file …) swallows the positional claude -p prompt. Pass the prompt on stdin: claude -p --allowedTools ... < prompt-file"),
    "inline": ("винеси код у файл скрипта (Write) і запусти файл",
               "move the code into a script file (Write) and run the file"),
}
LABELS = {"warn": ("ПОПЕРЕДЖЕННЯ", "WARNING"), "deny": ("ВІДМОВА", "DENIED"), "fix": ("ВИПРАВЛЕНО", "FIXED")}
SOON = ("Скоро це стане відмовою.", "This will become a denial soon.")
ENFORCEABLE = ("commitmsg", "ghbody", "curljson", "dotenv")
ALWAYS_DENY = ("claudep",)
FIXES = ("msys", "pyutf8")
# claude flags that accept a list of values and so swallow a following positional prompt
VARIADIC = ("--allowedTools", "--allowed-tools", "--disallowedTools", "--disallowed-tools",
            "--add-dir", "--mcp-config", "--tools", "--betas", "--file")
# claude flags with exactly one value
VALUE_FLAGS = ("--model", "--effort", "--permission-mode", "--output-format", "--input-format", "--settings",
               "--setting-sources", "--max-turns", "--append-system-prompt", "--system-prompt", "--fallback-model",
               "--session-id", "--resume", "-r", "--agent", "--max-budget-usd", "--plugin-dir")


def lang():
    value = os.environ.get("AGENT_GUARDS_LANG")
    if not value:
        try:
            value = (Path.home() / ".claude/hooks/agent_guards.lang").read_text(encoding="utf-8").strip()
        except OSError:
            value = "uk"
    return 1 if value == "en" else 0


def is_windows():
    # AGENT_GUARDS_PLATFORM=win|other exists for tests only
    forced = os.environ.get("AGENT_GUARDS_PLATFORM")
    return forced == "win" if forced else sys.platform.startswith("win")


class Cmd(list):
    """Words of one command plus whether it reads stdin (redirect, here-doc or pipe)."""
    stdin = False


class Scanner:
    """Keep offsets, quotes and substitutions; skip data in here-documents.

    This deliberately isn't a shell interpreter. Only unquoted command positions
    are visited. A quoted argument remains one token, even with $(... <<EOF).
    """

    def __init__(self, text, powershell=False):
        self.text = text
        self.ps = powershell
        self.commands = []

    def word(self, i, collect):
        text, start, parts = self.text, i, []
        while i < len(text) and not text[i].isspace() and text[i] not in ";|&()<>":
            if self.ps and text[i:i + 2] in ("@'", '@"'):
                quote = text[i + 1]
                match = re.search(r"(?m)^" + re.escape(quote + "@") + r"\r?$", text[i + 2:])
                end = len(text) if match is None else i + 2 + match.end()
                parts.append(text[i:end])
                i = end
            elif text[i] in "'\"":
                quote = text[i]
                i += 1
                while i < len(text):
                    if text[i] == quote:
                        if self.ps and quote == "'" and text[i:i + 2] == "''":
                            parts.append("'")
                            i += 2
                            continue
                        i += 1
                        break
                    if quote == '"' and text[i:i + 2] == "$(":
                        end = self.scan(i + 2, False, True)
                        parts.append(text[i:end])
                        i = end
                    elif (not self.ps and quote == '"' and text[i] == "\\"
                          and i + 1 < len(text) and text[i + 1] in '$`"\\\n'):
                        parts.append(text[i + 1])
                        i += 2
                    elif self.ps and quote == '"' and text[i] == '`' and i + 1 < len(text):
                        parts.append(text[i:i + 2])
                        i += 2
                    else:
                        parts.append(text[i])
                        i += 1
            elif text[i:i + 2] == "$(":
                end = self.scan(i + 2, collect, True)
                parts.append(text[i:end])
                i = end
            elif text[i] == ("`" if self.ps else "\\") and i + 1 < len(text):
                parts.append(text[i + 1])
                i += 2
            else:
                parts.append(text[i])
                i += 1
        return (start, i, "".join(parts)), i

    def scan(self, i=0, collect=True, nested=False):
        text, words, heredocs = self.text, [], []
        state = {"stdin": False, "pipe": False}

        def flush():
            if words and collect:
                command = Cmd(words)
                command.stdin = state["stdin"] or state["pipe"]
                self.commands.append(command)
            words.clear()
            state["stdin"] = state["pipe"] = False

        while i < len(text):
            char = text[i]
            if char in " \t\r":
                i += 1
            elif char == "#" and (i == 0 or text[i - 1].isspace()):
                end = text.find("\n", i)
                i = len(text) if end < 0 else end
            elif char == "\n":
                flush()
                i += 1
                for delimiter, strip_tabs in heredocs:
                    while i < len(text):
                        end = text.find("\n", i)
                        end = len(text) if end < 0 else end
                        line = text[i:end].rstrip("\r")
                        i = min(end + 1, len(text))
                        if (line.lstrip("\t") if strip_tabs else line) == delimiter:
                            break
                heredocs.clear()
            elif char == ")":
                flush()
                i += 1
                if nested:
                    return i
            elif char in ";|&(":
                flush()
                if char == "|" and text[i + 1:i + 2] != "|":
                    state["pipe"] = True
                i += 2 if text[i:i + 2] == "||" else 1
            elif char in "<>":
                if char == "<":
                    state["stdin"] = True
                if text[i:i + 2] == "<<" and text[i:i + 3] != "<<<":
                    i += 2
                    strip_tabs = text[i:i + 1] == "-"
                    i += int(strip_tabs)
                    while i < len(text) and text[i] in " \t":
                        i += 1
                    token, i = self.word(i, False)
                    heredocs.append((token[2], strip_tabs))
                else:
                    # Redirection targets are data, not command arguments.
                    i += 1
                    while i < len(text) and text[i] in "<> &\t":
                        i += 1
                    if i < len(text):
                        _, i = self.word(i, collect)
            else:
                token, i = self.word(i, collect)
                words.append(token)
        flush()
        return i


def command_index(words):
    i = 0
    while i < len(words):
        value = words[i][2]
        if re.match(r"^[A-Za-z_][A-Za-z_0-9]*=", value):
            i += 1
        elif value in ("env", "sudo", "xargs", "nohup", "exec", "time"):
            i += 1
            while i < len(words) and words[i][2].startswith("-"):
                option = words[i][2]
                i += 1
                if option in ("-u", "-g", "-n", "-P", "-I", "-S"):
                    i += 1
        elif value == "timeout":
            i += 1
            while i < len(words) and words[i][2].startswith("-"):
                i += 1
            i += 1  # duration
        else:
            return i
    return i


def option_values(args, names):
    for i, arg in enumerate(args):
        if arg in names and i + 1 < len(args):
            yield args[i + 1]
        else:
            for name in names:
                if arg.startswith(name + "="):
                    yield arg[len(name) + 1:]
                elif name.startswith("-") and not name.startswith("--") and arg.startswith(name) and len(arg) > len(name):
                    yield arg[len(name):]


def prompt_eaten(args, stdin):
    """True when a list-valued flag comes before any positional prompt and no stdin carries the prompt."""
    if stdin:
        return False
    positional, i = False, 0
    while i < len(args):
        arg = args[i]
        if arg == "--":
            return False
        if arg in VARIADIC:
            j = i + 1
            while j < len(args) and not args[j].startswith("-"):
                j += 1
            if args[j:j + 1] == ["--"]:
                return False  # the prompt follows an explicit end-of-options marker
            if j > i + 1 and not positional:
                return True
            i = j
        elif arg in VALUE_FLAGS:
            i += 2
        elif arg.startswith("-"):
            i += 1
        else:
            positional = True
            i += 1
    return False


def inspect(command, tool):
    scanner = Scanner(command, tool == "PowerShell")
    scanner.scan()
    edits, hits = [], []
    commands = sorted(scanner.commands, key=lambda words: words[0][0])
    msys_seen, previous_line = False, -1
    for words in commands:
        line_start = command.rfind("\n", 0, words[0][0]) + 1
        if line_start != previous_line:
            msys_seen = False
        previous_line = line_start
        msys_seen = msys_seen or any(re.match(r"^MSYS_NO_PATHCONV(?:=|$)", w[2]) for w in words)
        index = command_index(words)
        if index >= len(words):
            continue
        token = words[index]
        name = token[2].replace("\\", "/").rsplit("/", 1)[-1].lower()
        args = [w[2] for w in words[index + 1:]]
        is_python = bool(re.fullmatch(r"(?:python(?:\d+(?:\.\d+)*)?(?:\.exe)?|py(?:\.exe)?)", name))
        is_python = is_python or ("/" in token[2].replace("\\", "/") and bool(re.fullmatch(r"python[^/]*\.exe", name)))
        inline = []
        if is_python:
            options = []
            j = 0
            while j < len(args) and args[j].startswith("-") and args[j] not in ("-c", "-m", "-"):
                options.append(args[j])
                if args[j] in ("-X", "-W") and j + 1 < len(args):
                    j += 1
                    options.append(args[j])
                j += 1
            utf8 = any(v == "-Xutf8" or (v == "-X" and k + 1 < len(options) and options[k + 1] == "utf8")
                       for k, v in enumerate(options))
            if not utf8:
                position = token[1]
                if name in ("py", "py.exe") and args and re.fullmatch(r"-3(?:\.\d+)?", args[0]):
                    position = words[index + 1][1]
                edits.append((position, " -X utf8"))
                hits.append("pyutf8")
            if j < len(args) and args[j] == "-c" and j + 1 < len(args):
                inline = [args[j + 1]]
        msys = (
            name in ("git", "git.exe") and args and args[0] in ("show", "log", "diff", "cat-file", "blame", "ls-tree", "rev-parse")
            and any(re.match(r"^[^\s:]+:[^\s]+", a) for a in args[1:])
        ) or (name in ("gh", "gh.exe") and args[:1] == ["api"] and any(a.startswith("/") for a in args[1:]))
        msys = msys or any(re.match(r"^/[^:]+:/", a) for a in args)
        msys = msys or (name in ("wsl", "wsl.exe") and any(a.startswith("/") for a in args))
        if tool == "Bash" and is_windows() and msys and not msys_seen:
            # Put assignment before wrappers (sudo/env/timeout), not their argument.
            edits.append((words[0][0], "MSYS_NO_PATHCONV=1 "))
            hits.append("msys")
        if name in ("git", "git.exe") and args[:1] == ["commit"]:
            if any(any(c in value for c in "$`!\n") for value in option_values(args[1:], ("-m", "--message", "-am"))):
                hits.append("commitmsg")
        if name in ("gh", "gh.exe") and len(args) >= 2 and (
            args[0] == "pr" and args[1] in ("create", "comment", "edit", "review")
            or args[0] == "issue" and args[1] in ("create", "comment", "edit")
        ):
            if any(any(c in value for c in "$`\n") for value in option_values(args[2:], ("--body", "-b"))):
                hits.append("ghbody")
        if name in ("curl", "curl.exe") and any(value.startswith(("{", "[")) for value in option_values(
            args, ("-d", "--data", "--data-raw", "--data-binary", "--json")
        )):
            hits.append("curljson")
        if name in ("claude", "claude.exe", "claude.cmd") and ("-p" in args or "--print" in args) and prompt_eaten(args, words.stdin):
            hits.append("claudep")
        if (name in ("source", ".") and args and re.search(r"(?:^|/)\.env(?:\.\w+)?$", args[0])) or (
            name in ("export", "eval") and any("$(" in a and "env" in a for a in args)
        ):
            hits.append("dotenv")
        if name in ("node", "node.exe"):
            for j, arg in enumerate(args):
                if not arg.startswith("-") or arg == "--":
                    break
                if arg in ("-e", "--eval") and j + 1 < len(args):
                    inline = [args[j + 1]]
                    break
                if arg.startswith("--eval="):
                    inline = [arg[len("--eval="):]]
                    break
        if name in ("ssh", "ssh.exe"):
            # Skip options and host; remaining tokens form the remote command.
            j = 0
            while j < len(args) and args[j].startswith("-"):
                j += 2 if args[j] in ("-p", "-i", "-l", "-o", "-F", "-J", "-L", "-R", "-D", "-S", "-W", "-b", "-c", "-E", "-m", "-w") else 1
            inline = [" ".join(args[j + 1:])]
        if any(len(value) > 400 for value in inline):
            hits.append("inline")
    for position, addition in sorted(edits, reverse=True):
        command = command[:position] + addition + command[position:]
    return command, hits


def log(payload, rule, action, error=None):
    try:
        target = Path.home() / ".claude/logs/agent_guards.jsonl"
        target.parent.mkdir(parents=True, exist_ok=True)
        tool_input = payload.get("tool_input")
        tool_input = tool_input if isinstance(tool_input, dict) else {}
        entry = {"ts": datetime.now(timezone.utc).isoformat(), "rule": rule, "action": action,
                 "tool": payload.get("tool_name"), "session_id": payload.get("session_id"),
                 "tool_use_id": payload.get("tool_use_id"), "cwd": payload.get("cwd"),
                 "cmd": str(tool_input.get("command", ""))[:200]}
        if error:
            entry["error"] = error
        with target.open("a", encoding="utf-8") as stream:
            stream.write(json.dumps(entry, ensure_ascii=True) + "\n")
    except Exception:
        pass


def main():
    payload = {}
    try:
        if os.environ.get("AGENT_GUARDS_OFF") == "1":
            return
        raw = sys.stdin.buffer.read()
        if not raw.strip():
            return
        payload = json.loads(raw.decode("utf-8"))
        if not isinstance(payload, dict):
            payload = {}
            return
        tool = payload.get("tool_name")
        if tool not in ("Bash", "PowerShell"):
            return
        tool_input = payload.get("tool_input") or {}
        command = tool_input.get("command", "")
        if not command:
            return
        updated, hits = inspect(command, tool)
        if not hits:
            return
        enforce_file = Path.home() / ".claude/hooks/agent_guards.enforce"
        enforced = set(re.split(r"[,\s]+", enforce_file.read_text(encoding="utf-8").strip())) if enforce_file.exists() else set()
        n = lang()
        denied, messages = [], []
        for rule in hits:
            action = "fix" if rule in FIXES else "warn"
            if rule in ALWAYS_DENY or (rule in ENFORCEABLE and ("all" in enforced or rule in enforced)):
                action = "deny"
                denied.append(rule)
            log(payload, rule, action)
            message = f"{LABELS[action][n]} agent_guards [{rule}]: {ADVICE[rule][n]}."
            if action == "warn" and rule in ENFORCEABLE:
                message += " " + SOON[n]
            messages.append(message)
        output = {"hookEventName": "PreToolUse", "additionalContext": "\n".join(messages)}
        if denied:
            output.update(permissionDecision="deny", permissionDecisionReason="\n".join(ADVICE[r][n] for r in denied))
        elif updated != command:
            # updatedInput WITHOUT permissionDecision: permissions still apply. Never set "allow".
            output["updatedInput"] = {**tool_input, "command": updated}
        sys.stdout.write(json.dumps({"hookSpecificOutput": output}, ensure_ascii=True) + "\n")
    except Exception as error:
        log(payload if isinstance(payload, dict) else {}, "internal", "error", type(error).__name__)


if __name__ == "__main__":
    main()
