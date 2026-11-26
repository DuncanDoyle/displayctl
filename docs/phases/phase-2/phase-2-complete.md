# Phase 2 — Menu bar app (Complete)

**Completed:** 2026-11-26
**Range:** 860cbea..the commit that adds this file

## Summary
A menu bar icon opens a panel with an on/off switch per display and a DDC brightness slider for the Dell. The last active display's switch is disabled. A safety net turns a display back on when no usable display is left: it reacts to display changes, wake and app launch, and while a display is off it also checks every 10 s (D-014). It ignores the placeholder display macOS adds when no real display is left (D-012, D-013). The app runs as a per-user launchd agent: it starts at login, restarts after a crash and stays stopped after Quit. All hardware steps passed on macOS 27.0.1 with the Dell U2720Q over USB-C and HDMI. Claude wrote the code; Codex reviewed every round.

## Sub-phases (phase record only)
| Sub-phase | Kind | Issues | Description |
|---|---|---|---|
| none | | | The phase ran as one plan (Tasks 1–7); review fix rounds stayed inside the phase queue. |

## Reviews
- reviews/design-codex.md (design + plan) — 11 findings: 10 accepted, 1 deferred
- reviews/design2-codex.md (design + plan, second round) — 10 findings: 9 accepted, 1 rejected; loop stopped by owner decision
- reviews/code-codex.md (Tasks 2–6) — 8 findings: 6 accepted, 2 rejected
- reviews/placeholder-codex.md and d012-code-codex.md (D-012, D-013) — 9 findings: 9 accepted
- reviews/phase-codex.md (phase diff) — 8 findings: 8 accepted
- reviews/phase-fix-codex.md (phase fix round) — 5 findings: 5 accepted
- reviews/trigger-choice-codex.md — advice on events only vs events plus a check; the owner chose "A with 10 s" (D-014)
- reviews/d014-code-codex.md (D-014) — 8 findings: 6 accepted, 1 rejected, 1 deferred
- reviews/d014-fix-codex.md, d014-fix2-codex.md, d014-fix3-codex.md (D-014 fix rounds) — 9 findings: 8 accepted, 1 rejected (owner agreed); loop stopped by owner decision

## Waivers
none

## Deliverables
- `DisplayMenuApp` (`displayctl-menu`): SwiftUI `MenuBarExtra` panel, bare SwiftPM binary under launchd, no .app bundle.
- `DisplayMenuKit`: panel model, rows, brightness coalescing, periodic-check gate, ledger directory watch.
- `DisplayControlCore`: safety net (`ZeroActiveRecovery`, `RecoveryScheduler` with events, 10 s tick and cooldown), placeholder detection, `recoverIfNoneActive()`.
- `Scripts/install-menu.sh`, `uninstall-menu.sh`, launchd plist; `Scripts/menu-fallback.sh` for hardware tests.
- `AGENTS.md`, pre-commit hook and `Scripts/check-local-paths.sh` (no local paths in the public repo, D-011).
- 254 automated tests (199 core, 44 menu kit, 11 CLI); no third-party dependencies.

## Notes for later phases
- macOS adds a placeholder display (vendor `unkn`, model `virt`, serial 0) when no real display is left; never count it as active (D-012, D-013).
- A CLI call that reads `NSScreen` through the main thread made macOS wait about 10 s per display change; only the app may do that hop.
- App logs use `os.Logger` at notice level (subsystem `displayctl`); read them with `log show --predicate 'subsystem == "displayctl"'`.
- With the lid closed the panel cannot light; enable attempts then fail but leave it enabled, and macOS lights it when the lid opens. A ledger entry can remain until the next `connect all`.
- The Dell's UUID depends on the cable: HDMI `4E3207A4…`, USB-C `B3564974…`.
- Run the hardware steps again after a macOS update.

## Deferred / open
- Observer teardown (DispatchSource, timer, CG callback context) if observers can start more than once per process — Phase 3 (d014-code-codex.md #8).
- Shared brightness boundary so keys and slider writes are ordered — Phase 3 (design-codex.md #11).
