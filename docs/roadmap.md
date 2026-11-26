# displayctl — Roadmap

**Last updated:** 2026-11-25
Program: none
Advisor: none

## Goal
A small, self-contained macOS tool with the core of BetterDisplay that the owner actually uses: soft-disconnect the MacBook's internal display or an external display, and control external monitor brightness in hardware (DDC/CI). Personal use on an Apple Silicon Mac; private macOS APIs are acceptable but isolated.

## Phases

### Phase 1 — CLI hardware validation
**Status:** Complete 2026-11-26 (`docs/phases/phase-1/phase-1-complete.md`)
**Docs:** `docs/phases/phase-1/`

A `displayctl` CLI that lists displays, connects/disconnects them safely, and gets/sets external DDC brightness, validated on real hardware.

### Phase 2 — Menu bar app (D-009)
**Status:** Design and plan reviewed; awaiting owner approval of the amended versions
**Docs:** `docs/phases/phase-2/`

A menu bar panel with an on/off switch per display and a DDC brightness slider for external displays. It runs as a launchd agent and turns disabled displays back on when no display is active.

### Phase 3 — Keyboard brightness keys (D-009)
**Status:** Not started
**Docs:** `docs/phases/phase-3/` (not yet written)

Brightness keys adjust the display under the mouse pointer. Likely added to the Phase 2 app's process. See Phase 1 design.md §10.2, minus the recovery part, which moved to Phase 2.

## Deferred / out of roadmap
- Internal display brightness control — not in the approved design; macOS keys already handle it. Revisit if Phase 3 wants a single slider for all displays.
- Distribution (signing, notarization) — personal builds only.
