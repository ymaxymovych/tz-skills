# agent-guards — guards against mechanical agent failures / запобіжники агентів

Claude Code hooks that fix or refuse the shell commands on which agents lose hours every week, plus a loop breaker
and a before/after measurement. Full Ukrainian description: [SKILL.md](SKILL.md).

## English

**What it fixes**

| Problem | Guard |
|---|---|
| Cyrillic turns to mojibake (cp866/cp1251) | adds `-X utf8` to `python`/`py` calls (auto-fix) |
| Git Bash rewrites `HEAD:path`, `gh api /…`, `-v /a:/b` (Windows only) | adds `MSYS_NO_PATHCONV=1` (auto-fix) |
| `$`, backtick, `!`, newline eaten in `git commit -m` / `gh … --body` | warn → deny: use `git commit -F file` / `--body-file` |
| JSON inside `curl -d '{…}'` | warn → deny: `--data-binary @file` |
| `. .env`, `source .env`, `export $(cat .env)` | warn → deny: never run `.env` as shell code |
| `claude -p --allowedTools X "prompt"` — the flag swallows the prompt | deny at once: pass the prompt on stdin |
| `python -c` / `node -e` / `ssh host '…'` over 400 chars | warning only |
| The same refused action 3, 6 times in a row | hint on the 3rd, deny the repeat on the 6th |

Quotes, here-documents and PowerShell here-strings are treated as data and never touched. The hooks never emit
`permissionDecision: "allow"`, fail open (any internal error → exit 0, no output) and log to
`~/.claude/logs/agent_guards.jsonl`.

**Install** (idempotent; backs up `settings.json`, keeps foreign hooks, never duplicates entries):

```bash
git clone https://github.com/ymaxymovych/tz-skills ~/tz-skills   # or: git -C ~/tz-skills pull
KIT_LANG=en bash ~/tz-skills/skills/agent-guards/install.sh
```

New Claude Code sessions pick the hooks up. Requires Python 3.8+ (and Git Bash on Windows).

**Warn → deny.** `commitmsg`, `ghbody`, `curljson`, `dotenv` start as warnings. After a few days check the log
for false positives, then `echo all > ~/.claude/hooks/agent_guards.enforce` (or a comma list of rule names).

**Switch off:** `AGENT_GUARDS_OFF=1`. To remove: delete the `agent_guards` entries from `~/.claude/settings.json`
(a `settings.json.bak-agent-guards-<time>` copy is made before the first change).

**Measure:**

```bash
python measure.py --from 2026-11-01 --to 2026-11-08 --out before.txt
python measure.py --from 2026-11-15 --to 2026-11-22 --out after.txt
```

Counts failed tool results per category (encoding, bash quoting, JSON, PowerShell, MSYS, wrong shell, failure loops)
from `~/.claude*/projects/**/*.jsonl`, plus what the guards fixed or denied.

**Background workers (`claude -p`):** prompt on stdin, and keep only the guards with
`--setting-sources project,local --settings worker-settings.example.json`. Do not use `disableAllHooks` — it
switches the guards off too. A worker's report is not proof: check the PR and the diff.

**Habits (not hooks):** long browser text via `form_input`, not `computer type`; wait with a background task or an
until-loop, not `sleep`.

**Tests:** `python -X utf8 -m unittest discover -s skills/agent-guards/tests`.

**Honest status.** Author's measurement, 01–08.11.2026: ≈115 quoting/encoding failures in 8 days and ≈1,100
mechanical agent failures in a week; the effect of the guards is still being measured. **Not verified on macOS** —
tested on Windows (Git Bash) only; the MSYS rule is Windows-only by design.

## Українською

Див. [SKILL.md](SKILL.md): що ставиться, режим відмови, вимкнення (`AGENT_GUARDS_OFF=1`), заміри «до/після»,
звички для фонових робітників. Встановлення одним рядком:

```bash
bash ~/tz-skills/skills/agent-guards/install.sh
```

`bootstrap-student.sh` ставить запобіжники автоматично (необов'язковий крок, не ламає решту встановлення).
Не перевірено на macOS.
