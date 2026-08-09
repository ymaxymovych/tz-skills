---
name: worktree-start
description: Isolate the upcoming implementation in its own git worktree BEFORE the first edit, so parallel Claude sessions (or your own experiments) never trample each other's uncommitted work. Detects existing isolation, prefers the harness's native worktree tool, falls back to plain `git worktree add`. Invoke right after /tz-review approves a TZ and before implementation starts — or any time work will touch more than one file.
allowed-tools: Bash, Read, Write, Edit, Glob, Grep
---

# Worktree Start — isolate before you build

Adapted from the Superpowers `using-git-worktrees` skill (obra/superpowers, MIT),
compacted for the TZ pipeline:

```
/tz-draft → /tz-review → **/worktree-start** → реалізація → /tz-verify → /worktree-finish
```

**Why:** two sessions editing one working tree destroy each other's uncommitted changes —
the most expensive class of loss there is, because it leaves no trace in git. Isolation
costs one command; recovery from a trampled tree costs an evening, if it's possible at all.

## Protocol

### Step 0 — Detect existing isolation (don't double-wrap)

```bash
git rev-parse --git-dir
git rev-parse --git-common-dir
```

- Paths **differ** (and `git rev-parse --show-superproject-working-tree` is empty — i.e.
  not a submodule) → you are ALREADY in a linked worktree. Say so, skip creation, done.
- Paths equal → proceed.

**Never create a worktree from inside another worktree.** (Superpowers rule: no nesting.)

### Step 1 — Prefer the harness's native tool

If the agent harness has a native worktree mechanism (e.g. Claude Code's `EnterWorktree`
tool) — use it and stop here. Native tools handle placement, environment, and later
cleanup better than a manual fallback. (Superpowers rule: "Never fight the harness.")

### Step 2 — Manual fallback: `git worktree add`

1. **Pick the directory**, in priority order: explicit user instruction → an existing
   `.worktrees/` or `worktrees/` dir in the repo → default `.worktrees/` at repo root.
2. **Gitignore guard** (mandatory):
   ```bash
   git check-ignore -q .worktrees || { echo ".worktrees/" >> .gitignore; git add .gitignore; git commit -m "chore: ignore .worktrees"; }
   ```
   An unignored worktree dir turns every future `git status` into noise and risks
   committing a whole tree into itself.
3. **Branch name** from the TZ slug: `feat/{tz_slug}` (or `fix/…` if the TZ is remedial).
4. **Create and enter:**
   ```bash
   git worktree add ".worktrees/{tz_slug}" -b "feat/{tz_slug}"
   cd ".worktrees/{tz_slug}"
   ```

### Step 3 — Make the workspace runnable

- Install dependencies with the project's own manager (`pnpm i` / `npm ci` / `pip install
  -e .` / `cargo build` — detect from lockfiles). If the monorepo shares `node_modules`
  via links, do NOT reinstall — link or reuse per the project's convention.
- Copy/link untracked env files the build needs (`.env*`) — they don't follow worktrees.

### Step 4 — Baseline check

Run the project's fast check (tests / typecheck / lint — whatever is cheap and standard
here) BEFORE the first edit. Record the result:

- **Green** → note "baseline green" and start implementing.
- **Red** → STOP and tell the user: the breakage predates your work. Proceeding past a red
  baseline requires their explicit go-ahead — otherwise you'll spend the evening debugging
  someone else's failure as if it were yours, and `/tz-verify` will misattribute it.

## Anti-patterns

- Editing files in the shared main tree "just this once" while a worktree exists.
- Nesting worktrees.
- Skipping the gitignore guard.
- Proceeding past a red baseline without explicit user approval.
- Reinstalling shared monorepo dependencies inside the worktree when the project links them.

## When NOT to invoke

- Read-only / Q&A sessions — nothing to isolate.
- A one-file trivial edit you'll commit within minutes.
- You are already in a worktree (Step 0 catches this).
