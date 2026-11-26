# Phase status

## Phase
Phase: 3 — Keyboard brightness keys (D-009)
Base: not set (record HEAD when Phase 3 starts)
Author: not set
Advisory: none
Docs: docs/phases/phase-3/ (not yet written)
Status: not started; waiting for the owner to start Phase 3

### Queue
- [ ] Q1 Owner starts Phase 3 (design, then plan, then cross-model review)

### Exit gates
- [ ] tests/vet pass (observed)
- [ ] all queue items done or deferred
- [ ] design+plan cross-model review + triage: reviews/design-codex.md
- [ ] phase cross-model review + triage: reviews/phase-codex.md
- [ ] decisions.md / design / plan in sync with code
- [ ] phase-3-complete.md written, roadmap updated, tracked items closed

## Sub-phase
none

## Program
none

## Carry-over (deferred to later phases)
- (P4 architecture) Observer teardown (DispatchSource, timer, CG callback context) if observers can start more than once per process — src: phases/phase-2/reviews/d014-code-codex.md#8
- (P4 architecture) Shared brightness boundary so keys and slider writes are ordered — src: phases/phase-2/reviews/design-codex.md#11

## Notes
- 2026-11-26: Phase 2 closed (docs/phases/phase-2/phase-2-complete.md). Phase 2 status notes, including all hardware runs: `git show b308184:docs/phase-status.md`.
- Build/test: `swift test --parallel --scratch-path .agents-tmp/build`. For per-bundle counts run without `--parallel`.
- The Dell's UUID depends on the cable: HDMI `4E3207A4…`, USB-C `B3564974…`. Check `list` before every hardware run.
- Before pushing: `Scripts/check-local-paths.sh` must print nothing (AGENTS.md).
