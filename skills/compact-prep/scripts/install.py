"""Install /compact-prep's safety net: the PreCompact hook and (optionally) the context-band mod.

Run:  python ~/tz-skills/skills/compact-prep/scripts/install.py [--with-mod] [--claude-dir DIR]

Safe to run again: it only adds what is missing, never touches other hooks or settings, backs up
settings.json before the first change it makes, and ends with a check. Exit code 0 = everything in place.
Standard library only.
"""
import argparse
import datetime
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
SKILL_DIR = HERE.parent
REPO = SKILL_DIR.parent.parent
HOOK_SRC = SKILL_DIR / "hooks" / "pre_compact_instructions.py"
HOOK_NAME = "compact_prep_pre_compact.py"
MOD_DIR = REPO / "mods" / "context-band"
SECTIONS = ["РІШЕННЯ", "ЧЕРГА", "ЗАРАЗ", "ШЛЯХИ І ЗНАЧЕННЯ", "ЛІЧИЛЬНИКИ", "ВІДКРИТЕ", "ІНСТРУМЕНТИ"]


def say(msg: str) -> None:
    print(msg, flush=True)


def fwd(p: Path) -> str:
    # Hooks run through bash on Windows too: backslashes would be eaten, so forward slashes only.
    return str(p).replace("\\", "/")


def norm(p: str) -> str:
    return os.path.normcase(os.path.normpath(p.strip().strip('"')))


def main() -> int:
    try:
        sys.stdout.reconfigure(encoding="utf-8")
    except Exception:
        pass
    ap = argparse.ArgumentParser()
    ap.add_argument("--with-mod", action="store_true", help="also enable the context-band mod")
    ap.add_argument("--claude-dir", default=os.environ.get("CLAUDE_CONFIG_DIR") or str(Path.home() / ".claude"))
    args = ap.parse_args()

    claude = Path(args.claude_dir).expanduser().resolve()
    settings_path = claude / "settings.json"
    if not HOOK_SRC.is_file():
        say(f"✗ Не знайдено {HOOK_SRC} — запускай із клону tz-skills.")
        return 2

    # 1. The hook file.
    hooks_dir = claude / "hooks"
    hooks_dir.mkdir(parents=True, exist_ok=True)
    hook_dst = hooks_dir / HOOK_NAME
    if not hook_dst.exists() or hook_dst.read_bytes() != HOOK_SRC.read_bytes():
        shutil.copyfile(HOOK_SRC, hook_dst)
        say(f"✓ Хук скопійовано: {hook_dst}")
    else:
        say(f"· Хук уже на місці: {hook_dst}")

    # 2. settings.json — read strictly; never write over a file we could not parse.
    if settings_path.exists():
        raw = settings_path.read_text(encoding="utf-8")
        try:
            settings = json.loads(raw) if raw.strip() else {}
        except json.JSONDecodeError as err:
            say(f"✗ {settings_path} — не валідний JSON ({err}). Нічого не змінено: виправ файл і запусти ще раз.")
            return 3
    else:
        raw, settings = "", {}
    if not isinstance(settings, dict):
        say(f"✗ {settings_path} — не обʼєкт JSON. Нічого не змінено.")
        return 3

    changed = False
    command = f'"{fwd(Path(sys.executable))}" "{fwd(hook_dst)}"'
    pre = settings.setdefault("hooks", {}).setdefault("PreCompact", [])
    present = any(
        HOOK_NAME in str(h.get("command", ""))
        for group in pre if isinstance(group, dict)
        for h in group.get("hooks", []) if isinstance(h, dict)
    )
    if present:
        say("· Хук PreCompact уже підключено в settings.json")
    else:
        pre.append({"matcher": "auto", "hooks": [{"type": "command", "command": command}]})
        changed = True
        say("✓ Хук PreCompact (matcher auto) додано в settings.json")

    if args.with_mod:
        if not (MOD_DIR / ".claude-plugin" / "plugin.json").is_file():
            say(f"✗ Не знайдено мод {MOD_DIR} — онови клон tz-skills (git pull).")
            return 4
        env = settings.setdefault("env", {})
        current = str(env.get("CLAUDE_CODE_PLUGIN_DIRS", ""))
        parts = [p for p in current.split(os.pathsep) if p.strip()]
        if any(norm(p) == norm(str(MOD_DIR)) for p in parts):
            say("· Мод context-band уже підключено (CLAUDE_CODE_PLUGIN_DIRS)")
        else:
            parts.append(str(MOD_DIR))
            env["CLAUDE_CODE_PLUGIN_DIRS"] = os.pathsep.join(parts)
            changed = True
            say(f"✓ Мод context-band підключено: {MOD_DIR}")

    if changed:
        if settings_path.exists():
            stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
            backup = settings_path.with_name(f"settings.json.bak-compact-prep-{stamp}")
            shutil.copyfile(settings_path, backup)
            say(f"✓ Копія старих налаштувань: {backup}")
        tmp = settings_path.with_name("settings.json.tmp-compact-prep")
        tmp.write_text(json.dumps(settings, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        json.loads(tmp.read_text(encoding="utf-8"))
        os.replace(tmp, settings_path)

    # 3. Check what is now true, loudly.
    ok = True
    try:
        json.loads(settings_path.read_text(encoding="utf-8"))
    except Exception as err:
        say(f"✗ settings.json після запису не читається: {err}")
        ok = False
    probe = subprocess.run(
        [sys.executable, str(hook_dst)],
        input=json.dumps({"trigger": "auto", "transcript_path": "probe.jsonl"}),
        capture_output=True, text=True, encoding="utf-8", timeout=30,
    )
    missing = [s for s in SECTIONS if s not in probe.stdout]
    if probe.returncode != 0 or missing:
        say(f"✗ Хук не друкує розділи {missing or ''} (код {probe.returncode}): {probe.stderr[-300:]}")
        ok = False
    else:
        say("✓ Перевірка: хук друкує всі 7 розділів")
    skill = claude / "skills" / "compact-prep" / "SKILL.md"
    if skill.is_file():
        say(f"✓ Скіл на місці: {skill}")
    else:
        say(f"⚠ Скіла ще немає в {skill} — скопіюй теку skills/compact-prep туди (крок 2 у SKILL.md).")
        ok = False
    say("Готово. Перезапусти Claude Code або відкрий новий чат — хук і мод діють у нових сесіях." if ok
        else "Є помилки вище — виправ і запусти ще раз (повторний запуск безпечний).")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
