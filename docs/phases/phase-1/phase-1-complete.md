# Phase 1 — CLI hardware validation (Complete)

**Completed:** 2026-11-26
**Range:** 699b839..the commit that adds this file

## Summary
`displayctl` lists displays, turns the built-in or an external display off and on, and reads and sets an external monitor's brightness over DDC/CI. It never turns off the last active display. Every display it turns off is recorded, so `connect` and `connect all` bring it back even after macOS drops it from its display list; a reboot also restores it, logout does not. Validated on macOS 27.0.1 with the built-in display and a Dell U2720Q over HDMI and USB-C. Codex designed and built the first version; Claude continued from D-001, with each model reviewing the other's work.

## Sub-phases (phase record only)
| Sub-phase | Kind | Issues | Description |
|---|---|---|---|
| 1.1 | planned | none | Recoverable disconnects: ledger, UUID-first connect, `forget`, hardware-test watchdog; DDC fixes for USB-C (phase-1.1-complete.md) |
| 1.2 | stabilization | none | Phase review fixes: no-active-display guard, typed lock and inventory errors, docs in sync (phase-1.2-complete.md) |

## Reviews
- reviews/design-claude.md (retroactive design + plan) — 12 findings: 9 accepted, 1 rejected, 2 deferred
- reviews/phase-claude.md (Codex-authored range) — 5 findings: 4 accepted, 0 rejected, 1 deferred
- reviews/phase-codex.md (Claude-authored range) — 4 findings: 3 accepted, 1 rejected (owner-confirmed)
- Sub-phase reviews: see phase-1.1-complete.md and phase-1.2-complete.md

## Waivers
none. The design + plan gate was met by a retroactive Claude review (design-claude.md).

## Deliverables
- `DisplayControlCore`: inventory, selectors, connection controller with ledger and lock, DDC brightness (IOAVService, doubled sends for USB-C).
- `displayctl` CLI: `list`, `connect`, `disconnect`, `forget`, `brightness get|set`.
- `Scripts/hardware-test.sh` with a detached watchdog.
- 165 automated tests; no third-party dependencies.

## Notes for later phases
- Decisions that shape Phase 2: D-005 (a disabled display leaves the online list), D-008 (logout does not undo a disconnect), D-010 (a reboot does), D-009 (menu bar app is Phase 2).
- DDC matching works only through the monitor's numeric EDID serial; a monitor whose serial is 0 shows as unsupported.
- A display's UUID is stable per cable and port only.
- Snapshot and brightness-set cost (I/O Registry walks) is unmeasured; Phase 2 measures it first.
- Run the hardware matrix again after a macOS update, including logout and reboot.

## Deferred / open
- HDMI `brightness get external` with the current binary — next time the Dell is on HDMI.
- `DDCCapability.confirmed` never produced — Phase 2.
- Snapshot and brightness-set cost — Phase 2.
- Shared brightness boundary for keys and slider — Phase 3.
