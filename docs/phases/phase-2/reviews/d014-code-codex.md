Cross-model: YES (author: anthropic/claude-opus-5-5, reviewer: openai/gpt-6.2-sol, command: codex)
cli: codex · resolved_model: gpt-6.2-sol · status: ok
Scope: phase 2 (D-014 implementation)
Dimensions: both
Diff: a15b226..3edfabf
Timing: on time
---

**Request changes. No P1 findings.** The P2 findings concern ledger eligibility, event delivery, the polling-only hardware test, the fallback deadline, and the acceptance docs.

## Findings

1. **P2 · correctness · Polling starts when ledger eligibility is unknown.** A boot-session lookup or ledger read error sets `running = true`, and the test explicitly expects polling to start from an unreadable ledger. D-014 requires a current-boot entry. The practical difference is more than extra wakeups. A zero tick can call recovery, which still tries online inactive displays when the ledger is unreadable. `Sources/DisplayMenuKit/PeriodicCheckGate.swift:23`, `Tests/DisplayMenuKitTests/PeriodicCheckGateTests.swift:48`, `Sources/DisplayControlCore/ConnectionController.swift:283`, `docs/decisions.md:88`

2. **P2 · architecture · The directory watch can silently stop tracking CLI writes for the rest of the app run.** Watching the containing directory for `.write` is appropriate for atomic ledger replacement. An initial `open` failure leaves no watch, and replacing the directory leaves the descriptor attached to the old directory. Wake reloads the ledger but does not restore the watch. A later CLI disconnect can therefore leave the timer off until a wake or restart. `Sources/DisplayMenuApp/SystemObservers.swift:49`, `Sources/DisplayMenuApp/SystemObservers.swift:72`, `Sources/DisplayControlCore/DisabledDisplayLedger.swift:75`

3. **P2 · correctness · An in-episode callback can still schedule a follow-up check.** A reconfiguration travels through a main-actor task and then a scheduler task. If it reaches the scheduler after a `.displayActive` or `.recovered` episode ends, `running` is already false and there is no cooldown. It starts another settle window even though macOS reported it during the episode. The burst test delivers each event directly to the scheduler before the connector returns, so it misses this ordering. `Sources/DisplayMenuApp/SystemObservers.swift:59`, `Sources/DisplayMenuApp/SystemObservers.swift:113`, `Sources/DisplayControlCore/ZeroActiveRecovery.swift:174`, `Sources/DisplayControlCore/ZeroActiveRecovery.swift:233`, `Tests/DisplayControlCoreTests/ZeroActiveRecoveryTests.swift:175`

4. **P2 · correctness · The polling-only switch leaves the launch fast path enabled.** `DISPLAYCTL_MENU_NO_EVENTS=1` skips display and wake registration, then unconditionally schedules `.launch`. If the first settled launch check sees darkness, it can restore a display during the run advertised as “periodic check only.” Step 9b’s required `tick` log would distinguish the result, but the procedure has no wait for the launch check to finish. `Sources/DisplayMenuApp/SystemObservers.swift:27`, `docs/phases/phase-2/design.md:173`

5. **P2 · architecture · The fallback starts its deadline after it already knows the screen is dark.** `active_count` can return zero, then the separate diagnostic `list` can spend another 10 seconds before `dark_at` is set. The five-second kickstart and 90-second deadline both slip by that delay. Once `dark_at` is set, the command caps work as intended, though the unconditional one-second sleep can still push loop exit past the deadline. The new readiness wait does cover the ten-second probe. `Scripts/menu-fallback.sh:43`, `Scripts/menu-fallback.sh:87`, `Scripts/menu-fallback.sh:105`, `Scripts/menu-fallback.sh:130`, `Scripts/menu-fallback.sh:148`

6. **P2 · correctness · The docs still give conflicting recovery and acceptance rules.** The hardware overview requires app restoration within 10 seconds, step 9b allows about 15, and step 11 both requires a post-wake trigger and accepts macOS lighting the panel on lid open. The plan’s review focus still describes the retired re-arm rule, and Task 5 still says callbacks take arrival stamps and counts. The README omits cooldown after an inconclusive episode. `docs/phases/phase-2/design.md:161`, `docs/phases/phase-2/design.md:173`, `docs/phases/phase-2/design.md:175`, `docs/phases/phase-2/implementation-plan.md:33`, `docs/phases/phase-2/implementation-plan.md:282`, `README.md:73`

7. **P3 · correctness · The CLI ledger test covers the gate but bypasses the watch and timer.** It changes a fake ledger and calls `reload()` directly. It would pass if atomic replacement never notified the app, or if starting and stopping the gate had no effect on timer delivery. The missing integration case is an empty → current-boot → empty ledger written through the production atomic-save path. `Tests/DisplayMenuKitTests/PeriodicCheckGateTests.swift:17`, `Sources/DisplayMenuApp/SystemObservers.swift:72`

8. **P4 · architecture · Observer resources assume a single process-lifetime start.** The app currently starts observers once, and the new closures avoid a retain cycle through `SystemObservers`. There is no teardown to cancel the source or invalidate the run-loop timer if that lifetime changes. The timer retains the scheduler and can keep firing after the observer is released. The pre-existing retained Core Graphics context also stays retained when registration fails. I found no Swift 6 isolation issue on the current callback paths. `Sources/DisplayMenuApp/DisplayMenuApp.swift:31`, `Sources/DisplayMenuApp/SystemObservers.swift:40`, `Sources/DisplayMenuApp/SystemObservers.swift:82`, `Sources/DisplayMenuApp/SystemObservers.swift:93`

On inspection, delivered events coalesce without resetting the settle deadline. Ticks use the cheap usable count, skip query errors, and require zero before entering the locked recovery path. Failed and inconclusive outcomes start a 60-second cooldown, and a wake delivered during an episode gets one settled check afterward. Launch and normal wake reload the gate. The timer has two seconds of tolerance and no sleep assertion. The placeholder UUID is refused at either its old or new runtime ID when it is present in the snapshot.

`git diff --check` passed. The author reported 250 passing tests, 25 consecutive scheduler-suite passes, a warning-free release build, and clean strict lint and local-path checks. I did not rerun those checks or edit files. D-014 still awaits hardware validation.
## Triage
| # | Finding | Dimension | Source | Decision | Note |
|---|---|---|---|---|---|
| 1 | Polling starts when eligibility is unknown | correctness | reviewer | accept | Periodic check only on a confirmed current-boot entry; events still run. |
| 2 | Directory watch can stop for the rest of the run | architecture | reviewer | accept | Watcher re-opens on delete/rename/revoke and on restart at launch and wake. |
| 3 | A late-delivered in-episode callback can schedule one more check | correctness | reviewer | reject: the extra settled check costs one cheap count and does nothing while a usable display is active; it cannot repeat itself, and D-014 makes event precision unnecessary. | |
| 4 | Events-off switch still runs the launch check | correctness | reviewer | accept | Launch trigger skipped too in that mode. |
| 5 | Fallback dark timer starts late | architecture | reviewer | accept | `dark_at` set at the zero reading; sleep capped by the time left. |
| 6 | Docs give conflicting rules | correctness | reviewer | accept | Acceptance times per step (9: 10 s, 9b: 15 s, 11: 10 s after lid open by either route); plan Review Focus and Task 5; README cooldown text. |
| 7 | Gate test bypasses the watch and timer | correctness | reviewer | accept | Watcher moved to DisplayMenuKit with a real temporary-directory test through the atomic save. |
| 8 | Observer resources assume one start per process | architecture | reviewer | defer: tracked P4 | Observers live for the whole process today; add teardown if that changes (Phase 3). |
