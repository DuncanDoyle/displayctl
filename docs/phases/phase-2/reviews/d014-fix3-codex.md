Cross-model: YES (author: anthropic/claude-opus-5-5, reviewer: openai/gpt-6.2-sol, command: codex)
cli: codex · resolved_model: gpt-6.2-sol · status: ok
Scope: phase 2 (third re-review of the D-014 fix round: fallback timing)
Dimensions: both
Diff: c2a28f3..568d5a2
Timing: on time
---

Request changes. The fallback can still miss both recovery actions and can now miss a successful recovery. Task 7 step 5 is fixed.

- **P1 · Correctness · A due action can lose its last second to a count.** With both actions due at dark+5 s, a deadline at dark+6 s, and a three-second `list`, the diagnostic listing reached dark+5 s. The next count still got a one-second timeout. Both actions were refused at the deadline, so neither ran. [Scripts/menu-fallback.sh:82](Scripts/menu-fallback.sh:82), [Scripts/menu-fallback.sh:111](Scripts/menu-fallback.sh:111)
- **P1 · Correctness · The fallback can keep reconnecting after a display is active.** Once `connect all` becomes due, every subsequent count gets at most one second. In a read-only harness with a two-second `list` and a display that became active mid-run, the new script timed out every count, ran `connect all` three times, and exited with a deadline failure. The base script saw the active display and exited successfully. [Scripts/menu-fallback.sh:71](Scripts/menu-fallback.sh:71), [Scripts/menu-fallback.sh:118](Scripts/menu-fallback.sh:118)
- **P2 · Correctness · A CLI error is logged as a timeout.** If `connect all` finishes promptly but returns a nonzero status because a display could not be enabled, the fallback logs `did not finish (deadline or time limit)`. That gives the hardware record the wrong cause. [Scripts/menu-fallback.sh:127](Scripts/menu-fallback.sh:127), [Sources/displayctl/main.swift:203](Sources/displayctl/main.swift:203)

Task 7 step 5 now explicitly covers macOS lighting the panel on lid open. Its timing matches design step 11 and the README. Proof mode still makes one `connect all` attempt while a display is active. [implementation-plan.md:315](docs/phases/phase-2/implementation-plan.md:315), [design.md:175](docs/phases/phase-2/design.md:175), [README.md:243](README.md:243), [Scripts/menu-fallback.sh:137](Scripts/menu-fallback.sh:137)

`bash -n` and `git diff --check` passed. I used fake commands for the timing checks and relied on your Swift and hardware results. No files were edited.
## Triage
| # | Finding | Dimension | Source | Decision | Note |
|---|---|---|---|---|---|
| 1 | A due action can lose its last second to a count | correctness | reviewer | reject: the count must get its full time (see #2), so a `list` slower than the gap between an action and the deadline can always crowd it out. The real `list` takes 40–60 ms (Q2) and the hardware settings leave 60 s between the first `connect all` (30 s) and the deadline (90 s). | Owner to confirm. |
| 2 | Capped counts can miss a display that came back | correctness | reviewer | accept | Regression from 568d5a2. The count again gets its full 10 s (bounded only by the deadline); only the diagnostic listing is capped at the next due action. Fake run with a 2 s `list`: the display came back mid-run and the fallback ended with "a display is active again". |
| 3 | A CLI error is logged as a timeout | correctness | reviewer | accept | Logs the cause by exit status: 124 not started (deadline), 142 stopped by its time limit, otherwise "exited N". Fake run: "connect all exited 1". |
