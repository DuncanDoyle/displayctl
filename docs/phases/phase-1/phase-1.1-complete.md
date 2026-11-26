# Phase 1.1 — Recoverable disconnects (Complete)

**Completed:** 2026-11-26
**Range:** c324c9cbc3dfdd79df6f16091c51938911255918..the commit that adds this file

## Summary
No display turned off by `displayctl` needs a reboot to come back any more. Every disabled display is recorded in a per-user ledger before it is turned off, and `connect <uuid|internal|external>` and `connect all` bring it back even after macOS drops it from its display list. The hardware test arms a detached watchdog before each disconnect, which restores the original displays if the user cannot confirm a usable screen. Validated on macOS 27.0.1 with the built-in display and a Dell U2720Q over HDMI and USB-C. Logout does not restore a disabled display (D-008); a reboot does (D-010).

## Reviews
- reviews/1.1-design-codex.md — 8 findings: 8 accepted, 0 rejected, 0 deferred
- reviews/1.1-codex.md — 10 findings: 10 accepted (2 modified), 0 rejected, 0 deferred
- reviews/1.1-fix-codex.md — 5 findings: 4 accepted, 1 rejected (owner-confirmed), 0 deferred
- reviews/1.1-final-codex.md — 6 findings: 5 accepted, 1 rejected, 0 deferred
- reviews/1.1-final2-codex.md — 7 findings: 6 accepted, 1 rejected, 0 deferred

## Waivers
none

## Deliverables
- `Sources/DisplayControlCore/DisabledDisplayLedger.swift` — ledger and lock in `~/Library/Application Support/displayctl/`.
- `ConnectionController` — UUID-first connect, ledger-backed `connect all`, `forget`, absence counts as disconnected (D-005).
- DDC fixes found on hardware: doubled requests for USB-C, set falls back when read-back fails.
- `Scripts/hardware-test.sh` — detached watchdog, internal-first order.
- `--trial` removed (D-006). No new dependencies.
- 160 tests pass (150 core, 10 CLI); `swift format lint` clean (2026-11-26).

## Notes for later phases
- A disable survives logout (D-008) but not a reboot (D-010). After a reboot an earlier-boot ledger entry can linger; the next `connect all` removes it.
- The Dell's UUID and runtime ID change with the cable and port (HDMI `4E3207A4…`, USB-C `B3564974…`). Never hard-code them.
- USB-C DDC on the Dell only answers requests sent twice.
- The brief asked for fail-before evidence of the acceptance tests. The tests were written first in 1a2ec42, but no fail-before run is recorded in the repo. They exercise APIs that did not exist at c324c9c.

## Deferred / open
- none
