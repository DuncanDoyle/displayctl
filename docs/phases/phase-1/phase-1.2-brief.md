# Sub-phase 1.2 — Phase 1 review fixes

Kind: stabilization
Base: a26062e
Issues: none (queue in phase-status.md) | Plan steps: Phase 1 close; findings in reviews/phase-codex.md, phase-claude.md, design-claude.md

## Problem / goal
The Phase 1 reviews found one P1 and a few small reliability gaps that Phase 2 would otherwise build on:
1. `disconnect` can report success and leave no active display. Reproduction: two active displays; the other one goes inactive (unplug) after the last-active check but before the disable; the refresh shows the target absent and nothing active.
2. An inventory sample taken while the display setup changes throws at once, so a disconnect that worked can be reported as failed and rolled back.
3. A lock timeout and an inconsistent inventory sample are both `configurationFailed`; callers can only tell them apart by message text.
4. An invalid DDC reply (including the DDC null message) exits 1, although it is retried as temporary and the help text promises 75 for temporary DDC failures.
5. No test runs the production DDC identity and registry parser through the matcher together.
6. The Core Graphics transaction function table is public only so the CLI tests can inject it.
7. The Phase 1 design and plan are out of date with the code and with D-002 to D-010.

## Expected behaviour

| Input / action | Expected |
|---|---|
| `disconnect` where no display is active after the disable | Rollback attempted (same rules as today); `postconditionFailed` naming "no active display"; nonzero exit |
| `disconnect` where another display stays active | Unchanged |
| Inventory sample inconsistent once, then consistent | `snapshot()` returns the consistent sample (bounded retry, inferred: 3 attempts, 20 ms apart) |
| Inventory sample inconsistent on every attempt | Throws `DisplayControlError.inventoryChanged` |
| Lock not acquired within its bounded wait | Throws `DisplayControlError.lockTimeout`; CLI: "Another displayctl command is running; try again", exit 75 |
| CLI gets `ddcInvalidResponse` | Exit 75 (message unchanged) |
| CLI gets `inventoryChanged` | "Display setup changed while reading it; try again", exit 75 |
| Dell's observed identity (serial 1113146188, vendor 4268, model 16816) through production identity builder, registry parser and matcher | Selects that service |

The CLI messages are inferred; the exit codes follow the existing 75 = temporary rule.

## Root cause (if known)
1. `transition` (ConnectionController.swift) accepts target absence after a disable (D-005) without checking that another display is still active.
2. `DisplayInventory.snapshot()` throws on the first inconsistent sample.
3, 4. `DisplayControlError` has no cases for them; `exitCode(for:)` in main.swift maps only timeout and transport to 75.

## Acceptance tests
At the `ConnectionController`, `DisplayInventory` and CLI boundaries with the existing fakes:
1. `testDisconnectFailsAndRollsBackWhenNoDisplayRemainsActive` — the fake's `beforeRequest` marks the other display inactive; expect `postconditionFailed` containing "no active display", and an enable request for the target.
2. `testSnapshotRetriesInconsistentSample` and `testSnapshotThrowsInventoryChangedAfterRetries` (injected ID samplers).
3. `testLockTimeoutThrowsLockTimeout` (real lock held by another descriptor, small attempt count).
4. CLI mapping table: `lockTimeout`, `inventoryChanged`, `ddcInvalidResponse` → 75 with their messages.
5. `testProductionIdentitySelectsDellService` — both sides built by production code from the Dell's values.
Each must fail before the change.

## Scope
In: `Sources/DisplayControlCore/ConnectionController.swift`, `DisplayInventory.swift`, `DisplayControlError.swift`, `Sources/displayctl/main.swift`, matching tests; Phase 1 `design.md`, `implementation-plan.md`, README wording; Phase 2 design/plan where they relied on message matching.
Out: DDC matcher scoring cleanup (deferred), I/O Registry cost (Phase 2 item), hardware-test recovery scope (rejected, phase-codex #2).

## Plan / design impact
Phase 1 design §6.3, §7, §8 and the plan's API sections updated to the shipped API (design-claude #1–#4). Phase 2 design and plan use `lockTimeout` and `inventoryChanged` instead of message matching. No new decision needed: the fixes restore designed behaviour.

## Definition of done
- [ ] acceptance tests fail before, pass after (report both)
- [ ] full test suite passes; `swift format lint` clean
- [ ] cross-model review of `git diff a26062e..HEAD` + triage
- [ ] phase-1.2-complete.md written; phase-status.md updated
