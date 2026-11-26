# Phase status

## Phase
Phase: 2 — Menu bar app (D-009)
Base: 860cbeab7e5656e8984eea68250c1bf4e6248436 (code; Phase 2 design docs began at 7aa83e3)
Author: anthropic (claude-opus-5-5)
Advisory: none
Docs: docs/phases/phase-2/
Status: implementing on branch duncandoyle/menuBar (executing-plans, Claude implements; Codex reviews)

### Queue
- [x] Q0 Owner approves the amended design.md and implementation-plan.md — "Approved" (2026-11-26)
- [ ] Q1 Task 1 spike: MenuBarExtra from a bare executable under launchd ← CURRENT
- [x] Q2 (P4 architecture) Measure snapshot and brightness-set cost — src: phases/phase-1/reviews/design-claude.md#10, phase-claude.md#4 — 2026-11-26, Dell on USB-C, whole CLI process incl. launch: `list` 40–60 ms, `brightness get` 130–140 ms, `brightness set` (same value) 170–190 ms. One write in flight gives about 5–6 slider updates per second; acceptable, no caching needed now.
- [x] Q3 Task 2 safety net in DisplayControlCore — 44aa166; 184 tests pass. Choices beyond the plan: internal `drain()` for tests; a wake in a coalesced window wins; a disarmed net re-arms without running when `activeCount() > 0`.
- [x] Q4 Task 3 DisplayMenuKit executor, rows, switching — 2f8a9d7; 204 tests pass. Choices beyond the plan: a failed snapshot keeps the old rows; errors are pruned with their rows; `BootSession.current()` public; `Fakes.swift` test helper.
- [x] Q5 Task 4 brightness model — c0200ab; 215 tests pass. Choices beyond the plan: reads are awaited inside refresh/setDisplay; a successful write clears the error; a failed write is retried when the release value matches; last known value kept per UUID for the app run; `setBrightness` cancels an in-flight read.
- [x] Q6 (P3 correctness) `DDCCapability.confirmed` removed (never produced; Phase 2 does not need it) — src: phases/phase-1/reviews/design-claude.md#8
- [ ] Q7 Task 5 displayctl-menu app
- [ ] Q8 Task 6 install, uninstall, README
- [ ] Q9 Task 7 hardware validation
- [ ] Q10 Codex phase review; must check the P2 fixes from reviews/design2-codex.md that were not re-reviewed

### Exit gates
- [ ] tests/vet pass (observed)
- [ ] all queue items done or deferred
- [x] design+plan cross-model review + triage: reviews/design-codex.md, design2-codex.md (loop stopped by owner decision, see Notes)
- [ ] phase cross-model review + triage: reviews/phase-codex.md
- [ ] decisions.md / design / plan in sync with code
- [ ] phase-2-complete.md written, roadmap updated, tracked items closed

## Sub-phase
none

## Program
none

## Carry-over (deferred to later phases)
- (P4 correctness) HDMI `brightness get external` with the current binary, next time the Dell is on HDMI — src: phases/phase-1/reviews/1.2-codex.md#4
- (P4 architecture) Phase 3: shared brightness boundary so keys and slider writes are ordered — src: phases/phase-2/reviews/design-codex.md#11

## Notes
- 2026-11-26: Task 1 spike (`.agents-tmp/menubar-spike`): bare SwiftPM binary run from Terminal — icon shown, no Dock icon, panel with switch and slider, onAppear runs on every reopen (owner confirmed). Under launchd (label com.github.duncandoyle.displayctl-menu-spike, design §6.4 keys): state running; SIGKILL → restarted (runs = 2). Visual check under launchd and Quit-stays-stopped pending owner.
- 2026-11-26: Phase 1 closed (docs/phases/phase-1/phase-1-complete.md). No Phase 2 code was written while it was open (D-009). Phase 1 status notes, including hardware runs 1–4: `git show f39f451:docs/phase-status.md`.
- 2026-11-25: Phase 2 design + plan reviewed twice by Codex (reviews/design-codex.md, design2-codex.md), triaged. The loop stopped with P2 findings resolved on paper but not re-reviewed, by owner decision ("Stop design reviews here?" → "yes"); the Phase 2 code review must check them.
- 2026-11-26: Phase 2 design and plan amended after the Phase 1 reviews: typed `lockTimeout`/`inventoryChanged` errors, unsandboxed app, ledger rows per boot (orphans from re-cabling still show).
- Build/test: `swift test --parallel --scratch-path .agents-tmp/build`.
- The Dell's UUID depends on the cable: HDMI `4E3207A4…`, USB-C `B3564974…`. Check `list` before every hardware run.
