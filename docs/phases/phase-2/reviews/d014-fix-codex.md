Cross-model: YES (author: anthropic/claude-opus-5-5, reviewer: openai/gpt-6.2-sol, command: codex)
cli: codex · resolved_model: gpt-6.2-sol · status: ok
Scope: phase 2 (re-review of the D-014 fix round)
Dimensions: both
Diff: 3edfabf..ed34ff9
Timing: on time
---

**Request changes. No P1 findings.** Findings #1 and #4 are resolved. Parts of #2, #5, and #6 remain open. The atomic-save coverage accepted for #7 is in place, with gaps around automatic reopen and timer delivery.

### Findings

- **P2 · architecture · #2 — The ledger watch can still go dormant after directory recreation.** `Sources/DisplayMenuKit/LedgerDirectoryWatcher.swift:19`, `Sources/DisplayMenuKit/LedgerDirectoryWatcher.swift:29`, `Sources/DisplayMenuApp/SystemObservers.swift:39`. The invalidation handler cancels the old source and tries to open the path once. If the directory is absent at that moment and a later CLI save recreates it, there is no source to see the save. Launch and wake now retry the watch, but until then a current-boot entry can go unnoticed and leave polling off.
- **P2 · architecture · #5 — The fallback still misses parts of its timing contract.** `Scripts/menu-fallback.sh:77`, `Scripts/menu-fallback.sh:90`, `Scripts/menu-fallback.sh:94`, `Scripts/menu-fallback.sh:123`, `Scripts/menu-fallback.sh:133`. The main loop now sets `dark_at` before the diagnostic listing, so that listing no longer shifts the deadline. It can still occupy the first 10 seconds before the script checks whether the five-second kickstart is due. If the readiness probe itself reads zero, that reading is discarded. The sleep guard skips sleep once the deadline has expired, but a positive whole-second remainder can still allow a full one-second sleep just before the deadline.
- **P2 · correctness · #6 — The hardware plan still gives conflicting pass criteria.** `docs/phases/phase-2/implementation-plan.md:315`, `docs/phases/phase-2/design.md:161`, `docs/phases/phase-2/design.md:173`, `docs/phases/phase-2/design.md:175`. Task 7 still records steps 9–11 against a blanket 10-second app-or-fallback rule. That can misclassify a valid 9b recovery at 12 seconds or the accepted step 11 route where macOS lights the panel. Step 9b also describes wake events as absent, although the observer remains registered to maintain the ledger watch. The README cooldown text and the plan’s callback and cooldown updates match the code.
- **P3 · correctness · #2 and #7 — The tests cover atomic saves and explicit restart, but leave two production paths untested.** `Tests/DisplayMenuKitTests/LedgerDirectoryWatcherTests.swift:39`, `Tests/DisplayMenuKitTests/LedgerDirectoryWatcherTests.swift:62`, `Tests/DisplayMenuKitTests/LedgerDirectoryWatcherTests.swift:74`, `Sources/DisplayMenuApp/SystemObservers.swift:88`. The empty → current-boot → empty test exercises the real atomic-save notification and gate transitions. The deletion test calls `restart()` explicitly before and after recreation, so it can pass with the automatic invalidation handler broken. The test callback records gate changes and does not exercise app timer creation, tick delivery, or invalidation.

**Verified fixes.** #1 turns polling off after either a boot-session or ledger-read error. The tests cover an unreadable ledger both at launch and after polling has started. #4 skips the display callback and launch trigger in events-off mode. Its wake observer only reopens the watch and reloads the gate, leaving `tick` as the sole recovery trigger. `Sources/DisplayMenuKit/PeriodicCheckGate.swift:23`, `Tests/DisplayMenuKitTests/PeriodicCheckGateTests.swift:48`, `Sources/DisplayMenuApp/SystemObservers.swift:29`

`git diff --check 3edfabf..HEAD` passed. The author reported 253 passing tests (199 core, 43 menu kit, 11 CLI), 10 of 10 watcher test runs passing, a warning-free release build, and clean strict lint and local-path checks. I did not rerun those checks or edit files.
## Triage
| # | Finding | Dimension | Source | Decision | Note |
|---|---|---|---|---|---|
| 1 | Ledger watch goes dormant after the directory is recreated | architecture | reviewer | accept | `restart()` creates the directory before opening it, so a delete or rename reopens a new watch at once. Test deletes the directory with no explicit restart; it failed before the fix. |
| 2 | Fallback timing: listing delays the kickstart; a zero readiness reading is discarded; last sleep can pass the deadline | architecture | reviewer | accept in part | Kickstart and `connect all` now run before the diagnostic listing; a zero readiness reading starts the timers. Rejected: the whole-second sleep can pass the deadline by under 1 s, which changes no test outcome. |
| 3 | Plan Task 7 still uses a blanket 10 s rule; 9b says wake events are absent | correctness | reviewer | accept | Plan Task 7 points to the per-step times in design §8; 9b says the wake observer still reopens the ledger watch. |
| 4 | Tests leave automatic reopen and timer delivery untested | correctness | reviewer | accept in part | Automatic reopen now tested (see #1). Timer delivery: hardware step 9b observed a `tick` episode on 2026-11-26. |
