---
name: worktree-finish
description: Safely land a finished branch — green gate first, then a three-option menu (merge locally / push + PR / keep as-is), then worktree and branch cleanup. Work is discarded ONLY when the user types the literal word «discard». Invoke after /tz-verify returns SAFE-TO-COMMIT (or better) and the user wants the work landed.
allowed-tools: Bash, Read, Glob, Grep
---

# Worktree Finish — land the branch, clean the desk

Adapted from the Superpowers `finishing-a-development-branch` skill (obra/superpowers,
MIT), compacted for the TZ pipeline:

```
/tz-draft → /tz-review → /worktree-start → реалізація → /tz-verify → **/worktree-finish**
```

## Protocol

### Step 1 — Green gate (nothing happens before this passes)

Run the project's full check (tests + typecheck + lint — whatever this repo's standard
gate is). **Red → stop and report the failures; the menu below never appears over a red
run.** If `/tz-verify` was run, its verdict must be SAFE-TO-COMMIT or
SAFE-TO-DEPLOY-AFTER-CHECK — a BLOCK/FIX-FIRST verdict outranks green tests.

Also: `git status --porcelain` — uncommitted changes get committed (or explicitly stashed
by user choice) before any integration. Never merge with a dirty tree.

### Step 2 — Detect where you are

```bash
git rev-parse --git-dir ; git rev-parse --git-common-dir ; git branch --show-current
```

Normal repo / linked worktree with a named branch / detached HEAD — this decides which
menu you show and what cleanup is possible.

### Step 3 — Confirm the base branch

Identify what this branch split from (`git merge-base`, branch naming, PR convention).
**If uncertain — ask; merging into the wrong base is expensive to undo.** (Superpowers rule.)

### Step 4 — Present the menu (one question, wait for the answer)

```
Робота готова і зелена. Як здаємо?
  a) Merge локально у {base} і прибрати worktree
  b) Push гілки + відкрити Pull Request (worktree лишається до мерджу PR)
  c) Лишити як є (повернусь пізніше)
✅ Моя порада: {a|b}) — {чому: наявність CI/рев'ю-процесу/ризиковість зміни}
```

Recommend **(b)** when the repo has CI or review conventions; **(a)** only for
low-risk changes in repos where direct merges are the norm. Detached HEAD → only (b)/(c).

### Step 5 — Execute

- **(a) merge locally:** `git checkout {base}` (in the main tree) → `git pull` → `git
  merge --no-ff feat/{slug}` → re-run the fast check on {base} → green? push {base}.
- **(b) push + PR:** `git push -u origin feat/{slug}` → `gh pr create` (title from TZ
  slug, body links the TZ and the `/tz-verify` report). If CI exists — tell the user to
  wait for green before merging; never advise merging over a red or pending check.
- **(c) keep:** confirm the worktree stays, list its path, done.

### Step 6 — Cleanup (only after a completed merge, or explicit discard)

```bash
git worktree remove ".worktrees/{slug}"   # refuses if dirty — good, that's the safety
git branch -d "feat/{slug}"               # -d not -D: refuses if unmerged — also good
```

- Remove only worktrees YOU (this pipeline) created; leave harness-managed workspaces to
  the harness.
- **Discarding unmerged work requires the user to type the literal word «discard».**
  (Superpowers rule, verbatim contract.) "Ну його", "не треба", "викинь мабуть" — NOT
  enough; ask for the word. Only `git worktree remove --force` + `git branch -D` after
  that word, and echo back exactly what was destroyed.

## Anti-patterns

- Showing the menu over red tests or a BLOCK/FIX-FIRST verify verdict.
- Merging into an unconfirmed base.
- `git branch -D` / `--force` removal without the literal «discard».
- Deleting the worktree while its PR is still open (option b keeps it until merge).
- Silent cleanup — always state what was removed.

## When NOT to invoke

- Work is not green yet — finish the work first.
- Mid-implementation checkpoint — this skill is for LANDING, not saving progress
  (progress is saved by ordinary commit + push of the feature branch).
