"""Tests for agent-guards. Stdlib only:  python -X utf8 -m unittest discover -s skills/agent-guards/tests -v"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
HOOKS = ROOT / "hooks"


def find_bash():
    # On Windows, plain `bash` may be WSL; prefer Git Bash.
    git_bash = Path("C:/Program Files/Git/bin/bash.exe")
    return str(git_bash) if git_bash.exists() else shutil.which("bash")


def hook_env(home, **extra):
    env = {**os.environ, "HOME": str(home), "USERPROFILE": str(home), "AGENT_GUARDS_LANG": "uk"}
    env.pop("AGENT_GUARDS_OFF", None)
    env.update(extra)
    return env


class Base(unittest.TestCase):
    def setUp(self):
        self.home = Path(tempfile.mkdtemp(prefix="agent-guards-test-"))
        self.addCleanup(shutil.rmtree, self.home, ignore_errors=True)

    def run_hook(self, name, stdin, **env):
        if isinstance(stdin, dict):
            stdin = json.dumps(stdin).encode("utf-8")
        r = subprocess.run([sys.executable, "-X", "utf8", str(HOOKS / name)], input=stdin,
                           capture_output=True, env=hook_env(self.home, **env), timeout=30)
        self.assertEqual(r.returncode, 0, r.stderr.decode("utf-8", "replace"))
        out = json.loads(r.stdout)["hookSpecificOutput"] if r.stdout.strip() else {}
        self.assertNotEqual(out.get("permissionDecision"), "allow")
        return out

    def guard(self, command, tool="Bash", enforce=None, **env):
        if enforce is not None:
            (self.home / ".claude/hooks").mkdir(parents=True, exist_ok=True)
            (self.home / ".claude/hooks/agent_guards.enforce").write_text(enforce, encoding="utf-8")
        return self.run_hook("shell_guard.py", {"tool_name": tool, "tool_input": {"command": command}}, **env)

    def fixed(self, command, tool="Bash", **env):
        return self.guard(command, tool, **env).get("updatedInput", {}).get("command", command)

    def rules(self, command, **kw):
        self.guard(command, **kw)
        log = self.home / ".claude/logs/agent_guards.jsonl"
        if not log.exists():
            return []
        return [json.loads(line)["rule"] for line in log.read_text(encoding="utf-8").splitlines()]


class FixRules(Base):
    def test_python_utf8(self):
        self.assertEqual(self.fixed("python x.py"), "python -X utf8 x.py")
        self.assertEqual(self.fixed("py -3 -I x.py", "PowerShell"), "py -3 -X utf8 -I x.py")
        self.assertEqual(self.fixed("A=b python x"), "A=b python -X utf8 x")

    def test_python_negative(self):
        for command in ["python -X utf8 x.py", 'echo "python x"', "echo 'python x'", "cat python.txt"]:
            self.assertEqual(self.fixed(command), command)

    def test_heredoc_is_data(self):
        command = "cat <<EOF\npython x\n. .env\nEOF\npython y"
        out = self.guard(command)
        self.assertEqual(out["updatedInput"]["command"], command[:-len("python y")] + "python -X utf8 y")
        self.assertEqual(self.rules(command), ["pyutf8", "pyutf8"])  # 1st run above + this one; the heredoc body adds none

    def test_powershell_here_string_is_data(self):
        command = "$x = @'\npython x\n'@\npy -3 y"
        self.assertEqual(self.fixed(command, "PowerShell"), command.replace("py -3 y", "py -3 -X utf8 y"))

    def test_msys_windows_only(self):
        win = {"AGENT_GUARDS_PLATFORM": "win"}
        for command in ["git show HEAD:a/b.txt", "gh api /repos/x/y", "docker run -v /app:/data img"]:
            self.assertEqual(self.fixed(command, **win), "MSYS_NO_PATHCONV=1 " + command)
            self.assertEqual(self.fixed(command, AGENT_GUARDS_PLATFORM="other"), command)
        for command in ["git show HEAD", 'echo "git show HEAD:f"', "MSYS_NO_PATHCONV=1 git show HEAD:f", "gh api repos/x"]:
            self.assertEqual(self.fixed(command, **win), command)
        self.assertEqual(self.fixed("git show HEAD:f", "PowerShell", **win), "git show HEAD:f")

    def test_utf8_bytes_and_all_fields_preserved(self):
        command = 'py -3 x.py "Київ — Україна $HOME" "q\\""'
        extra = {"description": "опис", "timeout": 5, "other": {"k": 1}}
        out = self.run_hook("shell_guard.py", {"tool_name": "Bash", "tool_input": {"command": command, **extra}})
        expected = command.replace("py -3", "py -3 -X utf8")
        self.assertEqual(out["updatedInput"], {"command": expected, **extra})
        self.assertEqual(out["updatedInput"]["command"].encode("utf-8"), expected.encode("utf-8"))


class WarnAndDeny(Base):
    cases = {
        "commitmsg": (['git commit -m "price $200"', "git commit -am 'fix!'", "git commit -m 'a\nb'"],
                      ["git commit -F f", "git commit -m safe", "echo 'git commit -m \"$HOME\"'"]),
        "ghbody": (['gh pr create --body "$HOME"', "gh issue comment 1 -b 'a`b'"],
                   ["gh pr create --body-file f", "gh issue create -b safe"]),
        "curljson": (["curl -d '{\"a\":1}' localhost", "curl --json '[1,2]' localhost"],
                     ["curl -d @f localhost", "curl --data-binary @file x", "curl --data name=value x"]),
        "dotenv": (["source .env", ". ./app/.env", "set -a; . .env", "export $(cat app/.env)"],
                   ["cat .env", 'echo "source .env"', ". script.sh", "grep '^KEY=' .env | cut -d= -f2-"]),
        "inline": (["python -c '%s'" % ("x" * 401), "node -e '%s'" % ("x" * 401), "ssh h '%s'" % ("x" * 401)],
                   ["python -c 'print(1)'", "ssh h uptime", "python script.py"]),
    }

    def test_positive_and_negative(self):
        for rule, (yes, no) in self.cases.items():
            for command in yes:
                self.assertIn(rule, self.rules(command), command)
            for command in no:
                with self.subTest(rule=rule, command=command):
                    fresh = Path(tempfile.mkdtemp(dir=self.home))
                    r = subprocess.run([sys.executable, "-X", "utf8", str(HOOKS / "shell_guard.py")],
                                       input=json.dumps({"tool_name": "Bash", "tool_input": {"command": command}}).encode("utf-8"),
                                       capture_output=True, env=hook_env(fresh), timeout=30)
                    self.assertEqual(r.returncode, 0)
                    log = fresh / ".claude/logs/agent_guards.jsonl"
                    seen = [json.loads(x)["rule"] for x in log.read_text(encoding="utf-8").splitlines()] if log.exists() else []
                    self.assertNotIn(rule, seen)

    def test_warning_then_enforcement(self):
        out = self.guard('git commit -m "$X"')
        self.assertNotIn("permissionDecision", out)
        self.assertIn("commitmsg", out["additionalContext"])
        out = self.guard('git commit -m "$X"', enforce="commitmsg")
        self.assertEqual(out["permissionDecision"], "deny")
        self.assertIn("git commit -F", out["permissionDecisionReason"])
        self.assertNotIn("updatedInput", out)
        out = self.guard('gh pr create --body "$X"', enforce="commitmsg")  # other rule stays a warning
        self.assertNotIn("permissionDecision", out)
        out = self.guard('curl -d \'{"a":1}\' x', enforce="all")
        self.assertEqual(out["permissionDecision"], "deny")
        out = self.guard("python -c '%s'" % ("x" * 401), enforce="all")  # inline never denies
        self.assertNotIn("permissionDecision", out)

    def test_english_messages(self):
        out = self.guard('git commit -m "$X"', AGENT_GUARDS_LANG="en")
        self.assertIn("WARNING agent_guards", out["additionalContext"])


class ClaudeP(Base):
    def denied(self, command):
        return self.guard(command).get("permissionDecision") == "deny"

    def test_prompt_swallowed(self):
        for command in ['claude -p --allowedTools Bash "do it"', 'claude -p --add-dir . "do it"',
                        'claude -p --mcp-config a.json "do it"', "claude -p --tools Bash Read"]:
            self.assertTrue(self.denied(command), command)

    def test_safe_forms(self):
        for command in ["claude -p --allowedTools Bash < prompt.md", "cat prompt.md | claude -p --allowedTools Bash",
                        'claude -p "do it" --allowedTools Bash', 'claude -p --model sonnet "do it"',
                        'claude -p --allowedTools Bash -- "do it"', "claude -p --allowedTools Bash <<EOF\ndo it\nEOF",
                        'echo "claude -p --allowedTools Bash x"']:
            self.assertFalse(self.denied(command), command)


class FailOpen(Base):
    def test_broken_input_exit_zero_no_stdout(self):
        for name in ("shell_guard.py", "loop_breaker.py", "tool_hints.py"):
            for stdin in (b"", b"{broken", b"[]", b"\xff\xfe", b'{"tool_name":"Bash","tool_input":{"command":42}}'):
                r = subprocess.run([sys.executable, "-X", "utf8", str(HOOKS / name)], input=stdin,
                                   capture_output=True, env=hook_env(self.home), timeout=30)
                self.assertEqual(r.returncode, 0, (name, stdin))
                self.assertEqual(r.stdout, b"", (name, stdin))

    def test_off_switch(self):
        r = subprocess.run([sys.executable, "-X", "utf8", str(HOOKS / "shell_guard.py")],
                           input=json.dumps({"tool_name": "Bash", "tool_input": {"command": "python x"}}).encode(),
                           capture_output=True, env=hook_env(self.home, AGENT_GUARDS_OFF="1"), timeout=30)
        self.assertEqual((r.returncode, r.stdout), (0, b""))


class LoopBreaker(Base):
    def transcript(self, failures):
        """failures = list of (tool_use_id, command, error text)."""
        lines = []
        for ident, command, error in failures:
            lines.append({"message": {"content": [{"type": "tool_use", "id": ident, "name": "Bash", "input": {"command": command}}]}})
            lines.append({"message": {"content": [{"type": "tool_result", "tool_use_id": ident, "is_error": True, "content": error}]}})
        path = self.home / "t.jsonl"
        path.write_text("\n".join(json.dumps(x) for x in lines) + "\n", encoding="utf-8")
        return str(path)

    def pre(self, path):
        return self.run_hook("loop_breaker.py", {"hook_event_name": "PreToolUse", "tool_name": "Bash",
                                                 "tool_input": {"command": "rm -rf build"}, "transcript_path": path})

    def test_third_warns_sixth_denies(self):
        error = "Permission to use Bash has been denied."
        calls = lambda n: [(f"id{i}", "rm -rf build", error) for i in range(n)]
        self.assertEqual(self.pre(self.transcript(calls(2))), {})
        out = self.pre(self.transcript(calls(3)))
        self.assertIn("additionalContext", out)
        self.assertNotIn("permissionDecision", out)
        out = self.pre(self.transcript(calls(6)))
        self.assertEqual(out["permissionDecision"], "deny")

    def test_ordinary_nonzero_exit_is_not_a_refusal(self):
        calls = [(f"id{i}", "rm -rf build", "Exit code 1\ntest failed") for i in range(8)]
        self.assertEqual(self.pre(self.transcript(calls)), {})


class Install(Base):
    def run_install(self):
        bash = find_bash()
        if not bash:
            self.skipTest("bash not available")
        return subprocess.run([bash, str(ROOT / "install.sh")], capture_output=True, text=True, encoding="utf-8",
                              env=hook_env(self.home, KIT_LANG="en"), timeout=120)

    def test_twice_does_not_duplicate_and_keeps_foreign_hooks(self):
        claude = self.home / ".claude"
        claude.mkdir()
        foreign = {"hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "my-own-hook"}]}]},
                   "model": "keep-me"}
        (claude / "settings.json").write_text(json.dumps(foreign), encoding="utf-8")
        first = self.run_install()
        self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
        after_first = (claude / "settings.json").read_text(encoding="utf-8")
        second = self.run_install()
        self.assertEqual(second.returncode, 0, second.stdout + second.stderr)
        self.assertEqual((claude / "settings.json").read_text(encoding="utf-8"), after_first)
        settings = json.loads(after_first)
        self.assertEqual(settings["model"], "keep-me")
        commands = [h["command"] for ev in settings["hooks"].values() for g in ev for h in g["hooks"]]
        self.assertIn("my-own-hook", commands)
        for name, expected in (("shell_guard.py", 1), ("loop_breaker.py", 2), ("tool_hints.py", 2)):
            self.assertEqual(sum(name in c for c in commands), expected, name)
        self.assertTrue(all("\\" not in c for c in commands if "agent-guards" in c or ".py" in c))
        for name in ("shell_guard.py", "loop_breaker.py", "tool_hints.py", "agent_guards.lang"):
            self.assertTrue((claude / "hooks" / name).exists(), name)
        self.assertEqual(len(list(claude.glob("settings.json.bak-agent-guards-*"))), 1)

    def test_broken_settings_changes_nothing_and_fails_loudly(self):
        claude = self.home / ".claude"
        claude.mkdir()
        (claude / "settings.json").write_text("{broken", encoding="utf-8")
        result = self.run_install()
        self.assertEqual(result.returncode, 1)
        self.assertEqual((claude / "settings.json").read_text(encoding="utf-8"), "{broken")


class Measure(Base):
    def test_counts_categories_and_loops(self):
        proj = self.home / "projects" / "p"
        proj.mkdir(parents=True)
        rows = []
        for i, text in enumerate(["UnicodeEncodeError: charmap codec", "JSONDecodeError: Expecting value",
                                  "command not found"] + ["denied by policy"] * 4):
            rows.append({"timestamp": "2026-11-03T10:00:00Z", "message": {"content": [
                {"type": "tool_result", "tool_use_id": str(i), "is_error": True, "content": text}]}})
        (proj / "s.jsonl").write_text("\n".join(json.dumps(x, ensure_ascii=False) for x in rows), encoding="utf-8")
        out = self.home / "r.txt"
        r = subprocess.run([sys.executable, "-X", "utf8", str(ROOT / "measure.py"), "--from", "2000-01-01", "--to", "2030-01-01",
                            "--projects", str(self.home / "projects"), "--out", str(out)],
                           capture_output=True, env=hook_env(self.home), timeout=60)
        self.assertEqual(r.returncode, 0, r.stderr.decode("utf-8", "replace"))
        report = out.read_text(encoding="utf-8")
        for needle in ("encoding", "JSON", "wrong shell", "failure loops"):
            self.assertIn(needle, report)
        self.assertIn(" 5 TOTAL", report)


if __name__ == "__main__":
    unittest.main()
