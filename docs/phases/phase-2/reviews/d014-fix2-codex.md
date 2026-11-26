Cross-model: YES (author: anthropic/claude-opus-5-5, reviewer: openai/gpt-6.2-sol, command: codex)
cli: codex · resolved_model: gpt-6.2-sol · status: ok
Scope: phase 2 (second re-review of the D-014 fix round)
Dimensions: both
Diff: ed34ff9..c2a28f3
Timing: on time
---

**Request changes. Two P2 findings remain. The watcher fix and the reported 9b and 12 results check out.**

- **P2 · Correctness · A slow listing can still make the fallback miss a recovery action.** In a read-only harness with three-second `list` calls, `--kickstart-after 5` fired at dark+10 s. The diagnostic listing began at dark+3 s, crossed the five-second threshold, and the next count delayed the action again. With both actions due at five seconds and a nine-second deadline, neither command ran. The log still said `running connect all`. The zero readiness reading now starts the timer correctly, and commands already due run before the diagnostic listing. The loop still needs to account for the next action time before it blocks. `Scripts/menu-fallback.sh:48`, `Scripts/menu-fallback.sh:93`, `Scripts/menu-fallback.sh:112`
- **P2 · Correctness · Task 7 still omits an accepted step 11 outcome from its reporting instructions.** Step 5 gives the correct per-step limits, including 15 s for 9b. It still asks the tester to record whether the app or the fallback restored the display. In the observed step 11 run, macOS lit the panel when the lid opened. That passes under the design, and the README records it correctly. The plan should let the tester record that outcome. `docs/phases/phase-2/implementation-plan.md:315`, `docs/phases/phase-2/design.md:175`, `README.md:243`

The watcher recreates the directory with the same `0700` permissions the CLI uses. A CLI save that wins the creation race can be picked up by the ledger reload after reopen. The watcher’s own creation does not trigger a restart loop. If permissions prevent recreation or reopen, the attempt still stops there and launch or wake retries it. The new deletion test exercises automatic reopen and both gate transitions. `Sources/DisplayMenuKit/LedgerDirectoryWatcher.swift:19`, `Sources/DisplayControlCore/DisabledDisplayLedger.swift:75`, `Tests/DisplayMenuKitTests/LedgerDirectoryWatcherTests.swift:75`

Task 7 step 3 includes 9b. The design and README correctly describe `tick` as the sole recovery trigger in that mode. Wake still refreshes the watch and reloads the gate. The README’s 9b and 12 results match the reported hardware runs. `docs/phases/phase-2/implementation-plan.md:313`, `docs/phases/phase-2/design.md:173`, `Sources/DisplayMenuApp/SystemObservers.swift:39`, `README.md:245`

Both rejections are reasonable. The final sleep’s subsecond rounding is distinct from the blocking calls above. Hardware 9b directly verifies timer delivery, and the automated tests cover the gate transitions. Proof mode still makes one `connect all` attempt even with a display active.

`bash -n` and `git diff --check ed34ff9..c2a28f3` passed. I relied on your Swift and hardware results and made no file changes.
## Triage
| # | Finding | Dimension | Source | Decision | Note |
|---|---|---|---|---|---|
| 1 | A slow listing can make the fallback miss a recovery action | correctness | reviewer | accept | Each `list` call (count and diagnostic) is capped at the time to the next due action; the 1 s sleep is skipped when an action is due within 1 s; a refused or timed-out `connect all` is logged as such. With a fake 3 s `list`, kickstart and `connect all` due at 5 s with a 9 s deadline now run at dark+7 s (before: never); due at 3 s they run at dark+3 s. The rest is whole-second rounding; a real `list` takes 40–60 ms (Q2). |
| 2 | Plan Task 7 cannot record the step 11 outcome where macOS lights the panel | correctness | reviewer | accept | Step 5 records the app, the fallback, or in step 11 macOS on lid open. |
