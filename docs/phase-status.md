# Phase status

## Phase
Phase: 1 — CLI hardware validation
Base: 699b839 (main before implementation)
Author: mixed — openai (Codex) up to c205693; anthropic (claude-opus-5-5) from D-001 on
Advisory: none
Docs: docs/phases/phase-1/
Status: implementation done; hardware validation blocked on sub-phase 1.1

### Queue
- [x] Q1 Plan tasks 1–9 — Codex, up to 8734343
- [ ] Q2 Task 10 verification and hardware matrix on macOS 27 — blocked on 1.1
- [ ] Q3 (P1 correctness) HDMI disconnect needed a reboot to recover — src: codex-handoff-2026-06-30.md; addressed by 1.1, revalidated in Q2

### Exit gates
- [ ] tests/vet pass (observed) — 125 tests pass on macOS 27.0.1, 2026-11-23
- [ ] all queue items done or deferred
- [ ] design+plan cross-model review + triage: none on record (Codex designed and reviewed its own work) — run retroactively with Claude as reviewer, or waive
- [ ] phase cross-model review + triage: docs/phases/phase-1/reviews/phase-<reviewer>.md
- [ ] decisions.md / design / plan in sync with code
- [ ] phase-1-complete.md written, roadmap updated, tracked items closed

## Sub-phase
Sub-phase: 1.1 — Recoverable disconnects
Kind: planned (design amendment D-003)
Base: c205693eb32e15191bbd3e7df0dbcd5407c939a8
Author: anthropic (claude-opus-5-5)
Brief: docs/phases/phase-1/phase-1.1-brief.md

### Allowed work
Ledger, `connect` changes, `forget`, hardware-test watchdog, tests and docs, per the brief.

### Not allowed
Design changes beyond D-003 without a new decisions.md entry and user approval; DDC changes; Phase 2 work.

### Queue
- [x] Codex review of the D-003 design amendment + brief — reviews/1.1-design-codex.md, 8 accepted, D-004
- [x] Ledger, UUID-first connect, `forget`, `--trial`, with acceptance tests (TDD) — d6b1997
- [x] Hardware-test watchdog and internal-first order — d6b1997
- [x] Codex review of c205693..d6b1997 + triage — reviews/1.1-codex.md, 10 accepted (2 modified)
- [x] Fix round for reviews/1.1-codex.md
- [ ] Codex re-review of the fix round ← CURRENT
- [ ] Hardware test with the user: internal disconnect/reconnect on macOS 27

## Program
none

## Carry-over (deferred to later phases)
- none

## Notes
- Build/test: `swift test --parallel --scratch-path .agents-tmp/build` works on this Mac without the `/tmp` cache workaround from the Codex handoff.
- The Dell's UUID changed since June (`4E3207A4…` → `B3564974…`), likely a different cable/port. Check `list` before every hardware run.
- Logout/login as a recovery path was never tried in June; worth trying before a reboot if a display wedges again.
