# displayctl — Roadmap

**Last updated:** 2026-11-23
Program: none
Advisor: none

## Goal
A small, self-contained macOS tool with the core of BetterDisplay that the owner actually uses: soft-disconnect the MacBook's internal display or an external display, and control external monitor brightness in hardware (DDC/CI). Personal use on an Apple Silicon Mac; private macOS APIs are acceptable but isolated.

## Phases

### Phase 1 — CLI hardware validation
**Status:** In progress (implementation done by Codex; sub-phase 1.1 open)
**Docs:** `docs/phases/phase-1/`

A `displayctl` CLI that lists displays, connects/disconnects them safely, and gets/sets external DDC brightness, validated on real hardware.

### Phase 2 — Keyboard brightness agent
**Status:** Not started
**Docs:** `docs/phases/phase-2/` (not yet written)

Brightness keys adjust the display under the mouse pointer, and a background agent reconnects soft-disconnected displays when no active display remains. See design.md §10.2.

### Phase 3 — Menu-bar application
**Status:** Not started
**Docs:** `docs/phases/phase-3/` (not yet written)

Native menu-bar UI for per-display connect/disconnect and brightness. See design.md §10.3.

## Deferred / out of roadmap
- Internal display brightness control — not in the approved design; macOS keys already handle it. Revisit if Phase 3 wants a single slider for all displays.
- Distribution (signing, notarization) — personal builds only.
