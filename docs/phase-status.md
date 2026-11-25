# Phase status

## Phase
Phase: 1 — CLI hardware validation
Base: 699b839 (main before implementation)
Author: mixed — openai (Codex) up to c324c9c; anthropic (claude-opus-5-5) from D-001 on
Advisory: none
Docs: docs/phases/phase-1/
Status: implementation done; hardware validation blocked on sub-phase 1.1

### Queue
- [x] Q1 Plan tasks 1–9 — Codex, up to d4b4ce3
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
Base: c324c9cbc3dfdd79df6f16091c51938911255918
Author: anthropic (claude-opus-5-5)
Brief: docs/phases/phase-1/phase-1.1-brief.md

### Allowed work
Ledger, `connect` changes, `forget`, hardware-test watchdog, tests and docs, per the brief.

### Not allowed
Design changes beyond D-003 to D-006 without a new decisions.md entry and user approval; Phase 2 work. DDC changes only as Task 10 hardware-verification fixes (USB-C), as recorded in the brief.

### Queue
- [x] Codex review of the D-003 design amendment + brief — reviews/1.1-design-codex.md, 8 accepted, D-004
- [x] Ledger, UUID-first connect, `forget`, `--trial`, with acceptance tests (TDD) — 1a2ec42
- [x] Hardware-test watchdog and internal-first order — 1a2ec42
- [x] Codex review of c324c9c..1a2ec42 + triage — reviews/1.1-codex.md, 10 accepted (2 modified)
- [x] Fix round for reviews/1.1-codex.md
- [x] Codex re-review of the fix round — reviews/1.1-fix-codex.md, 4 accepted, 1 rejected (user-confirmed)
- [x] Fix round 2 for reviews/1.1-fix-codex.md
- [x] Hardware test with the user on macOS 27 — runs 1–4, HDMI and USB-C; see Notes
- [x] Logout/login and a manual `connect all` — logout does not restore (D-008); `connect all` does (2026-11-25)
- [ ] Decide on a reboot test with a display disabled (D-008 open question)
- [x] Final Codex review of c324c9c..61333d2 + triage — reviews/1.1-final-codex.md, 5 accepted, 1 rejected
- [x] Fix round for reviews/1.1-final-codex.md — 159 tests pass (2026-11-23)

## Program
none

## Carry-over (deferred to later phases)
- none

## Notes
- Build/test: `swift test --parallel --scratch-path .agents-tmp/build` works on this Mac without the `/tmp` cache workaround from the Codex handoff.
- The Dell's UUID changed since June (`4E3207A4…` → `B3564974…`), likely a different cable/port. Check `list` before every hardware run.
- 2026-11-25, macOS 27.0.1, Dell on HDMI (UUID 4E3207A4…, runtime ID 4): `disconnect internal`, logout, login — built-in display stayed off throughout, Dell stayed on. `connect all` restored it from the ledger (same boot session), exit 0, Dell did not flicker (D-008).
- 2026-11-23 hardware, macOS 27.0.1, Dell U2720Q on HDMI (UUID 4E3207A4…, runtime ID 5): run 1 found D-005 (disabled display leaves the online list; rollback re-enabled it by recorded ID 1). Run 2: DDC brightness get 30 / set 10 confirmed; internal disconnect verified; app-only trial did not revert (D-006); watchdog `connect all` restored the internal display from the ledger on attempt 1. Logs: ~/Library/Logs/displayctl-hardware-test/run.DqA4Jd, run.U8SMSk.
- 2026-11-23 run 3 (run.qYsAha): full scripted matrix passed on HDMI — brightness, internal and external round trips (Dell left the online list; restored from the ledger), final-display refusal. Open: unattended run, USB-C, logout/login, manual connect all.
- 2026-11-23 USB-C (Dell UUID B3564974…, runtime ID 3): reads failed with DDC null messages (`6e 80 be`) until the request was written twice before the read; fixed, live read 25/100. Brightness set over USB-C awaiting user observation.
- 2026-11-23 run 4 over USB-C (run.SWPUBE): brightness get 25 and set 10 confirmed (after doubled DDC writes); internal and external round trips passed; final-display refusal passed; the user withheld the last YES and the watchdog restored the Dell from the ledger (counts as the unattended run).
- 2026-11-23 procedure deviation: the unattended watchdog run happened at the end of run 4 (after the external steps), not as a separate run before external opt-in as Task 10 lists. The behaviour was observed; only the order differs.
