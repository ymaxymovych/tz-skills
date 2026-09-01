---
name: tz-review
description: Cross-review a TZ, architecture decision, or risky change through 3 independent LLM critics (any mix of Claude/Codex/Gemini CLIs, OpenRouter, or NVIDIA NIM) with a fixed 12-category checklist (0-11, starting with Job-to-be-Done & success criteria), 3 iterations, grounding loops, and orchestrator-driven synthesis. Invoke when the user has a major TZ ready for review or is choosing between significant technical approaches.
allowed-tools: Bash, Read, Write, Edit, Glob, Grep
---

# TZ Cross-Review Protocol

Evidence-based multi-LLM review for specs, architecture decisions, and high-stakes PRs. Design grounded in 2026 multi-agent research: checklist-driven prompts (≈+16pp coverage vs free-form), independent parallel critique (no debate → avoids groupthink and hallucination cascades), stateless reviewers + orchestrator-curated changelogs (hybrid against both anchoring bias and coherence loss), grounding loops (post-review verification of factual claims), citation requirement (findings cite TZ sections so hallucinated findings are detectable).

## Critic providers (portable — configure once)

The three "critics" are NOT hard-wired to specific CLIs. They are three **slots** — `critic_a`, `critic_b`, `critic_c` — each routed by `providers.json` to any backend: a local CLI (`claude-cli` / `codex-cli` / `gemini-cli`), **OpenRouter**, or **NVIDIA NIM** (free hosted models). The only hard rule: the three slots MUST use **different model vendors** — that is what makes the review a cross-check instead of an echo.

All critic calls in this skill go through the dispatcher:

```bash
LLM_CRITIC="$(dirname "$SKILL_PATH")/../../lib/llm-critic.sh"   # path to the pack's dispatcher
"$LLM_CRITIC" --list           # show configured slots + backends
"$LLM_CRITIC" --smoke-all      # health-check every slot before a run
cat prompt.txt | "$LLM_CRITIC" critic_a    # run one critic; reply on stdout
```

If `--smoke-all` fails for a slot, stop and fix `providers.json` (see the pack's `SETUP.md`) before running the protocol. Never silently drop to <3 working critics.

## When to invoke

- Large TZ marked `major`, new architecture, new authorization model, security-sensitive feature, choice between competing technologies, risky PR touching payments/auth/permissions.
- **Do NOT invoke** for bugfixes, UI tweaks, trivial refactors, or when the user has already expressed high confidence and said "just do it" — this is expensive and a waste of tokens on small changes.

## Input

Argument: either (a) path to a TZ file, or (b) a topic description. If no argument — ask: "What am I reviewing? Give me a path or a topic."

## Protocol

### Step 0 — Locate project conventions

Determine paths:
- If `.ai-context/` exists → `{TZ_DIR}=.ai-context`, `{REVIEWS_DIR}=.ai-context/reviews`.
- Else if `docs/specs/` or `docs/tz/` exists → use that; `{REVIEWS_DIR}=docs/reviews`.
- Else → create `docs/reviews/` at repo root.

Substitute `{TZ_DIR}` and `{REVIEWS_DIR}` everywhere below.

### Step 1 — Read and extract open questions

Read the TZ (or draft a 1-page summary at `{TZ_DIR}/TZ_{slug}.md` if starting from a topic).

Extract 5-15 **open questions** — points where the TZ is silent, ambiguous, or has weak justification (embedding model choice, concurrent-write safety, rate-limit policy, etc.).

### Step 2 — Perplexity pre-review research (facts, not judgment)

For each open question that needs **current empirical evidence** (benchmarks, library versions, competitor behavior, CVEs) — research via Perplexity.

Order of preference (use the first one available on YOUR machine — this skill is portable, it does not assume any specific subscription):
1. **Perplexity API key** if you configured one (env `PERPLEXITY_API_KEY`).
2. **Browser path** — if the Claude in Chrome MCP (`claude-in-chrome`) is connected AND you are logged into perplexity.ai, drive it in the browser (open a new tab → type the query → wait for the answer → read back the text with its citations).
3. **`WebSearch` fallback** — always available, no subscription. Sufficient for version/quota/CVE/benchmark-style facts.

Never silently skip grounding — always land at option 3 if 1 and 2 are unavailable.

Save to `{REVIEWS_DIR}/iter{N}_perplexity/OQ{i}_{slug}.md` with TL;DR, findings, source URLs.

**Do not send judgment questions** ("is this architecture good?") — only factual queries with citations ("what's the current best multilingual embedding model for Ukrainian?").

### Step 3 — Parallel independent critic reviews

**Design note — why parallel-independent, not debate:** 2025-2026 multi-agent research shows debate mode amplifies hallucination cascades and groupthink (22-61% anchoring rates in stateful/debate setups vs <10% in independent). For our task — finding a maximally diverse set of problems in a static artifact — independence wins. Debate is preferred for tasks where agents must converge on a single correct answer; that is not our task.

**Prompt design:** each reviewer gets the same 12-category (0-11) checklist (empirical +16pp coverage vs generic "review this code" per arxiv progressive-prompting study). Per-reviewer "lean especially on X" hints exploit comparative strengths without narrowing scope.

**Shared checklist** (`REVIEW_CHECKLIST`):

```
Go through EVERY category below. For each, either report findings or write "no issues found". Do not skip any category.

Every finding MUST cite the specific TZ section, heading, or paragraph it refers to (e.g., "Section 4.2", "heading 'Migration Plan'"). Findings without citation will be discarded.

0. JOB-TO-BE-DONE & SUCCESS CRITERIA — start here, before everything else. Does the TZ state a clear Job-to-be-Done (when [situation], [who] wants [what], so that [business outcome])? Are there explicit, measurable success criteria (numbers or observable consequences, not "works well")? Is there an explicit non-goals list — what the TZ deliberately does NOT do — placed next to the JTBD (flag its absence: without it scope creep is invisible)? Does every requirement trace back to the stated JTBD — flag requirements that serve no stated job, and jobs that no requirement serves. A TZ that fails this category is not reviewable on the merits of its details; say so explicitly.
1. SECURITY & AUTHORIZATION — authn/authz gaps, privilege escalation, IDOR, SSRF, secret handling, audit logging, rate limiting.
2. DATA MODEL & INTEGRITY — schema correctness, constraint gaps, race conditions, concurrent-write safety, migration risks, backfill strategy.
3. HIDDEN ASSUMPTIONS — things taken for granted without justification; tech choices without alternatives considered; "obvious" behavior that isn't.
4. SCOPE & COMPLEXITY — feature creep, over-engineering, missing MVP cutline, premature abstractions.
5. OPERATIONAL CONCERNS — monitoring, alerting, rollback plan, feature flags, migration safety, on-call runbook, cost envelope.
6. FAILURE MODES & EDGE CASES — partial failures, retries/idempotency, timeout behavior, adversarial input, load spikes, dependency outages.
7. TESTABILITY & VERIFICATION — how each requirement will be proven working; missing test strategy; unreachable states. Apply the REGENERATION TEST to each module the TZ touches: "if this file were deleted and an agent rewrote it from the TZ + docs + tests alone, what would break?" If the answer is "everything" — the knowledge lives in the code, not in the spec; flag it as a finding (the TZ must capture that intent).
8. MAINTAINABILITY & LONG-TERM COST — coupling, ownership boundaries, doc debt, reversibility of decisions.
9. USER EXPERIENCE (UX) — user flows end-to-end, silent failures visible to users, confusing error states, unnecessary steps, cognitive load, empty/loading/error states, accessibility (a11y, WCAG), i18n/l10n, mobile responsiveness, perceived performance.
10. USER INTERFACE (UI) — visual design consistency with existing design system, component reuse vs one-off styles, layout/spacing/typography, information hierarchy, color/contrast, interaction affordances (buttons look clickable, disabled states clear), form design, dark mode if applicable.
11. CONTRACT & INTERFACE — API stability, backward compat, versioning strategy, downstream consumer impact.

Output format:
- VERDICT: [ship-as-is | minor fixes | major rework | reject]
- FINDINGS BY CATEGORY (0-11): bullet each, label severity [critical | high | medium | low], include TZ citation.
- TOP 3 RISKS: ranked.
- QUESTIONS FOR AUTHOR: anything still ambiguous.
Be blunt. Do not soften.
```

**Invocation (parallel, each in `run_in_background`, with timeout + retry):**

Each reviewer is a critic **slot** (`critic_a/b/c`) dispatched through `llm-critic.sh` — so the same protocol runs whether a slot is backed by a local CLI, OpenRouter, or NIM. The per-reviewer "lean especially on X" hint is appended to the prompt, not tied to any particular vendor.

```bash
LLM="/path/to/pack/lib/llm-critic.sh"     # resolve once at Step 0
REVIEW_CHECKLIST="<text above>"
TZ_CONTENT="$(cat {TZ_DIR}/TZ_*.md)"
# On iterations 2 and 3, prepend CHANGELOG (see Step 5.5):
# TZ_CONTENT="$(printf '%s\n\n%s' "$(cat {REVIEWS_DIR}/iter{N}_changelog.md)" "$(cat {TZ_DIR}/TZ_*.md)")"

# Wrap each critic in timeout (10 min) + retry-once on nonzero exit.
# If a reviewer still fails after retry, log the failure and CONTINUE with the others —
# but NEVER present the result as a full 3-critic review. Rule (added 2026-09-01):
#   * 3 slots alive, 3 vendors → normal review.
#   * 2 slots alive, 2 DIFFERENT vendors → continue, and stamp EVERY verdict line and the
#     journal header with «⚠️ REVIEW DEGRADED: 2 of 3 critics ran (<which failed>)».
#   * <2 alive, or the survivors share a vendor → STOP. One model checking itself is an
#     echo, not a review. Print the smoke-test failure, point to SETUP.md (dead model id →
#     404/410 is the usual cause), and do not continue until fixed.
# A silent drop from 3 critics to 1 is exactly the "quiet success" this skill exists to catch.

run_reviewer() {
  local slot="$1" hint="$2" out="$3"
  local prompt attempt=1
  prompt="$(mktemp)"
  printf '%s\n\n%s\n\n%s\n' "$TZ_CONTENT" "$REVIEW_CHECKLIST" "$hint" > "$prompt"
  while [ $attempt -le 2 ]; do
    if timeout 600 bash -c "cat '$prompt' | '$LLM' $slot" > "$out" 2>&1; then
      echo "[$slot] ok on attempt $attempt"; rm -f "$prompt"; return 0
    fi
    echo "[$slot] attempt $attempt failed; retrying after 5s" >&2
    sleep 5; attempt=$((attempt+1))
  done
  echo "[$slot] FAILED after 2 attempts — skipping this reviewer for iter{N}" >&2
  echo "REVIEWER_FAILED_AFTER_RETRY" > "$out"; rm -f "$prompt"; return 1
}

# critic_a — hint: hidden assumptions (best for a fresh/no-context model)
run_reviewer critic_a \
  "You have no prior context on this project. Lean especially on category 3 (hidden assumptions) since you see this cold — but cover all 12 (0-11)." \
  {REVIEWS_DIR}/iter{N}_cli/critic_a_review.md &

# critic_b — hint: security/data-model
run_reviewer critic_b \
  "Lean especially on categories 1 (security) and 2 (data model) — but cover all 12 (0-11)." \
  {REVIEWS_DIR}/iter{N}_cli/critic_b_review.md &

# critic_c — hint: architecture/long-term cost/alternatives
run_reviewer critic_c \
  "Lean especially on categories 4 (scope), 8 (maintainability), and propose alternative designs where you disagree — but cover all 12 (0-11)." \
  {REVIEWS_DIR}/iter{N}_cli/critic_c_review.md &

wait
```

**Resilience rules:**
- If 1 of 3 reviewers fails after retry → continue with 2. Log to `{REVIEWS_DIR}/iter{N}_cli/FAILURES.md` and surface to user in reconciliation.
- If 2 of 3 fail → stop protocol, surface CLI errors to user for diagnosis. Do not proceed with a single-reviewer "consensus".
- If the same reviewer fails across multiple iterations → prompt user to check CLI install / quota / auth before running further iterations.

**Hard isolation rules (preserve independence):**
- Reviewers NEVER see each other's outputs.
- Reviewers NEVER see the orchestrator's reconciliation.
- Reviewers NEVER see their own prior-iteration output. Each invocation is a fresh stateless session.
- The ONLY state carried across iterations is the curated changelog (Step 5.5) + updated TZ — both produced by orchestrator, not reviewers.

### Step 4 — Grounding loop (post-review verification)

Read all three review files. For each finding that makes a **factual claim** (CVE exists, library X has feature Y, benchmark Z shows N%, competitor does W) — verify via Perplexity before accepting into reconciliation.

Save verifications to `{REVIEWS_DIR}/iter{N}_grounding/F{i}_{slug}.md`: claim, source reviewer, verification result (confirmed / refuted / inconclusive), Perplexity sources.

Findings whose factual basis is **refuted** are flagged as hallucinated and excluded. Inconclusive findings are kept but marked.

Findings that are judgment/opinion (not factual claims) skip this step.

### Step 5 — Reconciliation & synthesis

Before synthesis, run two automated filters on every finding.

**Filter 5a — Citation validation (automated).** Every finding must cite a TZ section/heading. For each finding:
- Extract the cited section reference.
- Grep the TZ for that heading/section (`grep -n "^## Section 4.2" {TZ_DIR}/TZ_*.md` or equivalent for the project's heading style).
- If not found → finding is **hallucinated**, move to `{REVIEWS_DIR}/iter{N}_cli/hallucinations.md` with reviewer name and original text, DO NOT pass to synthesis.
- Findings without any citation at all → same treatment.

This catches the common failure where a reviewer invents a section number or misreads the TZ.

**Filter 5b — Confidence scoring (meta-LLM pass).** After citation validation, run a confidence-scoring pass:
- For each surviving finding, ask ONE critic slot (a fresh `cat scoring_prompt.txt | "$LLM" critic_a` invocation — a stateless call, NOT one of the three reviewers' review outputs) to rate it on:
  - **Evidence strength** (1-5): is the cited section/content actually problematic, or is the reviewer misreading it?
  - **Actionability** (1-5): is it a specific change someone could make, or vague hand-waving?
  - **Severity match** (1-5): does claimed severity match the actual risk?
- Findings with average score ≥3.5 → pass to synthesis as "high-confidence".
- Findings with average score 2.0-3.4 → pass to synthesis as "medium-confidence, flag for user".
- Findings with average score <2.0 → move to `low_confidence.md`, exclude from synthesis unless user explicitly reviews.

The confidence pass is NOT voting — it's a meta-reviewer checking finding quality. Its own output is logged to `{REVIEWS_DIR}/iter{N}_cli/confidence_scores.md` for audit.

**Produce `{REVIEWS_DIR}/iter{N}_cli/RECONCILIATION.md`:**

- **High-confidence convergent** — ≥2 reviewers agreed, citations valid, confidence ≥3.5. Strong candidates for applying.
- **High-confidence divergent** — single reviewer, citation valid, confidence ≥3.5. Surface to user.
- **Medium-confidence** — flag for user judgment, don't auto-apply.
- **Rejected (citation failure)** — from Filter 5a, for audit.
- **Rejected (grounding failure)** — from Step 4 (factual claim refuted), for audit.
- **Rejected (low confidence)** — from Filter 5b, for audit.
- **Orchestrator synthesis** — what will actually change, with reasoning.

**Synthesis rules** (by critic ROLE, not vendor — roles come from the Step 3 per-slot hints, so they hold whatever backend each slot uses):
- Security/entitlement critique from the security-leaning critic (`critic_b`) → accept by default even at medium confidence (asymmetric cost of being wrong).
- Architectural alternatives from the architecture-leaning critic (`critic_c`) → always flag for user if they change scope, never silently apply.
- "Hidden assumption" findings from the fresh/no-context critic (`critic_a`) → surface to user; especially valuable when that slot is a model with no project context.
- **Never majority-vote** — LLM biases correlate (and are strongest when two slots share a vendor), 2-of-3 agreement isn't truth. Synthesize with reasoning.

### Step 5.5 — Curated changelog (for next iteration)

After applying synthesis changes and producing `TZ_v{N+1}`:

1. Run `diff {REVIEWS_DIR}/iter{N}_cli/TZ_v{N}_snapshot.md {TZ_DIR}/TZ_*.md > {REVIEWS_DIR}/iter{N+1}_raw_diff.txt` for audit.
2. Use the diff as input when writing the curated changelog — don't describe from memory, describe from the actual diff.
3. Write `{REVIEWS_DIR}/iter{N+1}_changelog.md`:

```
=== CHANGES SINCE TZ v{N} (curated by orchestrator for next-iteration reviewers) ===

The following issues raised in iteration {N} have been addressed in TZ v{N+1}:

- [Section X.Y]: <change> → resolves: "<finding summary>"
- [Section A.B]: <change> → resolves: "<finding summary>"

The following were considered and explicitly rejected (with reasoning):
- "<finding>" — rejected because <reason>

=== END CHANGELOG ===
```

This changelog is prepended to the TZ when invoking reviewers in iteration {N+1}. **Design note — hybrid statefulness:** 2026 research (SynAnchors dataset, multi-agent benchmarks) shows pure stateless reviewers cause 15-25% "coherence loss" (re-raising resolved issues), while pure stateful reviewers show 22-61% anchoring bias. Hybrid — stateless reviewer + orchestrator-curated external state — avoids both. The changelog is the orchestrator's neutral narration of changes, not any reviewer's prior output, which preserves anti-anchoring.

### Step 6 — Update TZ

Apply synthesis to the TZ. Bump version `v{N}` → `v{N+1}`. Add a "Changes from v{N}" section at the top summarizing the delta (same content as Step 5.5 changelog is fine).

Snapshot each version: `{REVIEWS_DIR}/iter{N}_cli/TZ_v{N}_snapshot.md` before running the next review.

### Step 7 — Journal

Append to `{REVIEWS_DIR}/REVIEW_JOURNEY.md`:

```
## Iteration {N} — {YYYY-MM-DD}
**Topic:** {slug}
**TZ version:** v{N} → v{N+1}
**Verdict consensus:** {convergent verdict}
**Findings:** {critical / high / medium / low counts}
**Hallucinations caught (grounding):** {count}
**Key changes applied:** {3-5 bullets}
**Rejected findings:** {brief — what and why}
```

## Iteration policy — THREE iterations, mandatory

Run Steps 1-7 **exactly three times**. Same 12-category (0-11) checklist on every pass. The only things that change between iterations:
- The TZ itself (applied fixes from prior iteration).
- The curated changelog prepended on iter-2 and iter-3.

**Why three:** evidence supports multi-pass review; the TZ is different each pass so reviewers find new issues against the same checklist. Three is empirical default for diminishing returns.

**Early stop:** only if all three reviewers return "ship-as-is" with zero findings across all 12 categories (0-11), AND grounding found no hallucinations. Log "early convergence confirmed at iter{N}". Rare — default is complete all three.

**After iteration 3:** produce `{REVIEWS_DIR}/FINAL_SUMMARY.md` with: findings matrix (category × severity × iteration), accepted vs rejected, hallucinations caught, remaining known risks, final TZ version.

## Anti-patterns (don't do these)

- Running this for a bugfix, UI tweak, or trivial refactor — wasted tokens.
- Running it when the user already said "just do it" — respect their conviction.
- Enabling a debate round where reviewers see each other's outputs — introduces groupthink and cascade risk.
- Giving reviewers their own prior-iteration output — anchoring bias.
- Narrowing the checklist per iteration ("iter-2 = security only") — misses regressions in dropped categories.
- Majority-voting findings — LLM biases correlate; voting is not truth.
- Sending judgment questions to Perplexity — only facts with citations.
- Accepting factual claims without grounding-loop verification — hallucinations leak into TZ.
- Accepting findings that don't cite a TZ section — hallucinated findings are harder to detect without citation requirement.

## Known limitations (honest list)

Design trade-offs we consciously accepted; surface these if user expects otherwise.

- **Not battle-tested.** Zero real TZ runs at time of writing (2026-04-21). Dragons expected; expect to refine the protocol after first 2-3 real uses.
- **Orchestration is manual (by the live Claude session).** No deterministic code enforces step ordering — a sloppy orchestrator can skip the grounding loop. Mitigation: each step in this skill file is numbered explicitly; follow in order.
- **No industry-standard hallucination eval** (e.g., Vectara HHEM). Grounding loop uses Perplexity which is fine for factual claims but not calibrated like a dedicated hallucination evaluator. Upgrade path if this becomes a bottleneck.
- **No cost optimization.** One invocation = 9+ CLI calls × 3 iterations + N Perplexity queries + meta-LLM confidence pass. Assume tens of thousands of tokens per `/tz-review` run. Do not invoke casually.
- **No SWE-Bench or public benchmark validation.** Design is evidence-grounded in published research but the specific combination has not been benchmarked against alternatives on a standard test suite.
- **Backend-fragile.** CLI slots depend on `claude -p` / `codex exec` / `gemini -p` flag shape (breaks on major CLI version bumps); API slots depend on the provider's model id still existing (OpenRouter/NIM delist models). `llm-critic.sh --smoke-all` at Step 0 catches both before a run.
- **No CI/PR integration.** For personal-use by a human orchestrator, not automated pipeline.

## Safety notes

- **Backend flags / model ids** may change. If a critic call errors, surface the error once and ask the user to fix `providers.json` (or the CLI flag) rather than retrying blindly. `--smoke-all` is the pre-flight guard.
- **Sensitive TZs** (real API keys, tokens, credentials) — sanitize to `<REDACTED>` before sending to ANY critic. CLI slots run in separate processes; **API slots (OpenRouter/NIM) send your TZ to a third-party server** — assume anything sent is logged there. Do not point an API slot at a TZ containing live secrets.
- **Skill trust**: this skill is a thinking aid, not ground truth. Final decisions belong to the user. Always surface divergent findings and the orchestrator's reasoning so the user can override.

## Evidence base (as of 2026-04)

Design choices are grounded in:
- arxiv progressive-prompting study (25 open-source projects) — structured checklists raise coverage ~96.9% vs ~80.5% for generic prompts.
- 2025-2026 multi-agent research (aclanthology, NeurIPS, arxiv) — parallel independent review avoids debate-mode hallucination cascades and groupthink for diverse-finding tasks.
- SynAnchors dataset (2026) — 22-61% anchoring rates in stateful setups; hybrid stateless+external-state is 2026 best practice.
- OWASP "cascading failures in agentic AI" — grounding loops and spec-based validation recommended for correctness-sensitive multi-agent systems.

Research artifacts live in `{REVIEWS_DIR}/meta_skill_research/` for audit.
