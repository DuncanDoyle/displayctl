# Phase status

## Phase
Phase: 1 — CLI hardware validation
Base: 699b839 (main before implementation)
Author: mixed — openai (Codex) up to c324c9c; anthropic (claude-opus-5-5) from D-001 on
Advisory: none
Docs: docs/phases/phase-1/
Status: implementation and hardware validation done; closing (phase review pending)

### Queue
- [x] Q1 Plan tasks 1–9 — Codex, up to d4b4ce3
- [x] Q2 Task 10 verification and hardware matrix on macOS 27 — README "Results on macOS 27", all items observed 2026-11-23 to 2026-11-26. HDMI brightness set was confirmed before DDC sends were doubled; USB-C was confirmed after.
- [x] Q3 (P1 correctness) HDMI disconnect needed a reboot to recover — src: codex-handoff-2026-06-30.md; root cause: the postcondition misread a display leaving the online list (D-005) and `connect all` only saw online displays; fixed by the 1.1 ledger, observed on HDMI 2026-11-23

### Exit gates
- [x] tests/vet pass (observed) — 160 tests pass, `swift format lint` clean, macOS 27.0.1, 2026-11-26
- [x] all queue items done or deferred
- [ ] design+plan cross-model review + triage: none on record (Codex designed and reviewed its own work) — run retroactively with Claude as reviewer, or waive
- [ ] phase cross-model review + triage: docs/phases/phase-1/reviews/phase-<reviewer>.md
- [ ] decisions.md / design / plan in sync with code
- [ ] phase-1-complete.md written, roadmap updated, tracked items closed

## Sub-phase
none — 1.1 closed 2026-11-26 (docs/phases/phase-1/phase-1.1-complete.md)

## Program
none

## Carry-over (deferred to later phases)
- (P4 architecture) Phase 3: shared brightness boundary so keys and slider writes are ordered — src: phases/phase-2/reviews/design-codex.md#11

## Notes
- 2026-11-26: reboot test — the built-in display came back after a reboot; a later `connect all` removed the earlier-boot ledger entry, exit 0 (D-010).
- 2026-11-25: Phase 2 (menu bar app, D-009) design started in parallel. Phase 2 base: 7aa83e3c8424d088d1967401da867e6348e6e4b6. No Phase 2 code until Phase 1 closes; this file switches to Phase 2 then.
- 2026-11-25: Phase 2 design + plan reviewed twice by Codex (reviews/design-codex.md, design2-codex.md), triaged. The loop stopped with P2 findings resolved on paper but not re-reviewed, by owner decision ("Stop design reviews here?" → "yes"); the Phase 2 code review must check them. Design and plan await owner approval of the amended versions before implementation.
- Build/test: `swift test --parallel --scratch-path .agents-tmp/build` works on this Mac without the `/tmp` cache workaround from the Codex handoff.
- The Dell's UUID changed since June (`4E3207A4…` → `B3564974…`), likely a different cable/port. Check `list` before every hardware run.
- 2026-11-25, macOS 27.0.1, Dell on HDMI (UUID 4E3207A4…, runtime ID 4): `disconnect internal`, logout, login — built-in display stayed off throughout, Dell stayed on. `connect all` restored it from the ledger (same boot session), exit 0, Dell did not flicker (D-008).
- 2026-11-23 hardware, macOS 27.0.1, Dell U2720Q on HDMI (UUID 4E3207A4…, runtime ID 5): run 1 found D-005 (disabled display leaves the online list; rollback re-enabled it by recorded ID 1). Run 2: DDC brightness get 30 / set 10 confirmed; internal disconnect verified; app-only trial did not revert (D-006); watchdog `connect all` restored the internal display from the ledger on attempt 1. Logs: ~/Library/Logs/displayctl-hardware-test/run.DqA4Jd, run.U8SMSk.
- 2026-11-23 run 3 (run.qYsAha): full scripted matrix passed on HDMI — brightness, internal and external round trips (Dell left the online list; restored from the ledger), final-display refusal. Open: unattended run, USB-C, logout/login, manual connect all.
- 2026-11-23 USB-C (Dell UUID B3564974…, runtime ID 3): reads failed with DDC null messages (`6e 80 be`) until the request was written twice before the read; fixed, live read 25/100. Brightness set over USB-C awaiting user observation.
- 2026-11-23 run 4 over USB-C (run.SWPUBE): brightness get 25 and set 10 confirmed (after doubled DDC writes); internal and external round trips passed; final-display refusal passed; the user withheld the last YES and the watchdog restored the Dell from the ledger (counts as the unattended run).
- 2026-11-23 procedure deviation: the unattended watchdog run happened at the end of run 4 (after the external steps), not as a separate run before external opt-in as Task 10 lists. The behaviour was observed; only the order differs.
