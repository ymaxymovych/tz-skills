## Rules against code rot (IMMUNE)

<!-- Source: the IMMUNE principles (t.me/abstractDL/436) as adapted by AI Advisory Board.
     bootstrap-student.sh appends this block once; edit it freely afterwards. -->

1. Before any feature touching 3+ files — a short spec first: what, why, how we will verify. A spec pipeline is installed — use /tz-draft or /tz-go, never a one-line "build me X".
2. A change is finished only when every projection agrees: code, data schema, API, docs, tests. At the end of a task, list every place that references what you changed and check each one.
3. A repeated mistake → fix the mechanism: add a rule here or to coordination/MISTAKES.md, not just the instance.
4. Unexpected state → stop and say so loudly. Forbidden: silently guessing a "convenient" value, swallowing errors in an empty try/catch, reporting success on work that was not done.
5. Every constant and every decision has exactly one owner file. Never duplicate a value; reference the source. Decisions with their reasons live in coordination/DECISIONS.md.
6. Commit after every logical step. At the end of a session — three lines: done / verified / deferred (deferred items go to coordination/BACKLOG.md in the same commit).
7. "Done" is proven by live evidence (a real request, a real number, a screenshot, command output), not by your own report. Before handing over — /tz-verify.
