# Phase 1.2 — Phase 1 review fixes (Complete)

**Completed:** 2026-11-26
**Range:** a6c1ff2..the commit that adds this file

## Summary
`disconnect` no longer reports success when no display is left active: it fails and attempts a rollback. A display list read while the setup changes is read again (3 samples in total) before failing. "Another `displayctl` is running" and "the display setup kept changing" are now their own errors, and they and an invalid DDC reply exit 75 (temporary, try again). The Phase 1 design and plan match the code and decisions D-002 to D-010.

## Reviews
- reviews/1.2-codex.md — 6 findings: 6 accepted (finding 4 partly deferred: HDMI GET), 0 rejected
- reviews/1.2-fix-codex.md — 2 findings: 1 accepted, 1 rejected

## Waivers
none

## Deliverables
- `ConnectionController`: post-disable active-display check; `lockTimeout`.
- `DisplayInventory`: bounded resampling; `inventoryChanged` for an inconsistent or unstable list.
- `DisplayControlError`: `lockTimeout`, `inventoryChanged`.
- CLI: exit 75 for both new cases and `ddcInvalidResponse`; help text updated.
- `CoreGraphicsDisplayTransactionFunctions` is package-visible.
- Tests: 165 pass (155 core, 10 CLI); strict `swift format lint` clean. New tests failed before the change, except the Dell matcher test and two guard tests, which cover gaps.

## Notes for later phases
- Phase 2 matches `lockTimeout` and `inventoryChanged` by case, never by message.
- A display re-cabled while off leaves an orphan ledger entry until `forget`.

## Deferred / open
- HDMI `brightness get external` with the current binary — next time the Dell is on HDMI (phase-status carry-over).
