# Phase status

## Phase
Phase: 2 — Menu bar app (D-009)
Base: f39f451ee8addf1063cc400d130ca35dc2d7ded4 (code; Phase 2 design docs began at 7aa83e3)
Author: anthropic (claude-opus-5-5)
Advisory: none
Docs: docs/phases/phase-2/
Status: design and plan reviewed; awaiting owner approval of the amended versions before any code

### Queue
- [ ] Q0 Owner approves the amended design.md and implementation-plan.md ← CURRENT
- [ ] Q1 Task 1 spike: MenuBarExtra from a bare executable under launchd
- [ ] Q2 (P4 architecture) Measure snapshot and brightness-set cost (I/O Registry walks) before the slider relies on them — src: phases/phase-1/reviews/design-claude.md#10, phase-claude.md#4
- [ ] Q3 Task 2 safety net in DisplayControlCore
- [ ] Q4 Task 3 DisplayMenuKit executor, rows, switching
- [ ] Q5 Task 4 brightness model
- [ ] Q6 (P3 correctness) set `DDCCapability.confirmed` after a successful read, or remove it — src: phases/phase-1/reviews/design-claude.md#8
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
- 2026-11-26: Phase 1 closed (docs/phases/phase-1/phase-1-complete.md). No Phase 2 code was written while it was open (D-009). Phase 1 status notes, including hardware runs 1–4: `git show f39f451:docs/phase-status.md`.
- 2026-11-25: Phase 2 design + plan reviewed twice by Codex (reviews/design-codex.md, design2-codex.md), triaged. The loop stopped with P2 findings resolved on paper but not re-reviewed, by owner decision ("Stop design reviews here?" → "yes"); the Phase 2 code review must check them.
- 2026-11-26: Phase 2 design and plan amended after the Phase 1 reviews: typed `lockTimeout`/`inventoryChanged` errors, unsandboxed app, ledger rows per boot (orphans from re-cabling still show).
- Build/test: `swift test --parallel --scratch-path .agents-tmp/build`.
- The Dell's UUID depends on the cable: HDMI `4E3207A4…`, USB-C `B3564974…`. Check `list` before every hardware run.
