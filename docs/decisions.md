# Decision log

Append-only. Newest at the bottom. Supersede, don't edit.

## D-001 — Continue the project in Claude Code, reviewed by Codex (2026-11-23, phase 1)
**Context:** Phase 1 was designed and implemented by Codex in `<codex-checkout>`.
**Decision:** The repo was cloned with full history into `<this checkout>` (remote `codex`). Claude authors new work; Codex reviews it. Docs moved to the agentic-engineering-sdlc layout under `docs/`.
**Alternatives:** Working in the Codex checkout — rejected to keep the two agents' workspaces separate.
**Consequences:** Phase 1 authorship is mixed: commits up to `c205693` are Codex-authored, later ones Claude-authored.

## D-002 — Target platform is now macOS 27 (2026-11-23, phase 1)
**Context:** The design targets macOS Tahoe 26.5. The Mac now runs macOS 27.0.1 (26A434) with Swift 6.4.2. All private APIs used were only observed on 26.5.
**Decision:** Phase 1 validation targets macOS 27.0.1. The June hardware results on 26.5 are history, not evidence for 27. `displayctl list` and all 125 automated tests pass on 27.0.1 (2026-11-23).
**Alternatives:** none — the OS cannot be held back.
**Consequences:** Every hardware matrix item is re-run on 27, including the DDC brightness checks that passed in June.

## D-003 — Disabled displays must always be recoverable without a reboot (2026-11-23, phase 1)
**Context:** On 2026-06-30, disconnecting the HDMI Dell U2720Q made macOS drop it from the online display list. `connect all` only re-enables displays in that list, so it could not bring it back. Replugging HDMI failed too; only a reboot recovered it. The user called this the main pain point of testing.
**Decision:** Two safety mechanisms, approved by the user ("Ledger + watchdog"):
1. A persisted ledger of every display that `displayctl` disables (UUID and runtime ID, written before the disable). `connect <selector>` and `connect all` also try to re-enable ledger entries that macOS no longer lists as online.
2. The hardware test arms a watchdog before each disconnect. It reconnects everything after a short timeout unless the user confirms they can see and use a display.
Hardware testing does the internal display first (the main use case, with the Dell as the safe screen). External disconnect is retested only after the internal one passes.
**Alternatives:** Ledger only (no protection when the user cannot type); internal-only support (drops a designed feature).
**Consequences:** Amends design §6.3, §7.3 and §9.2: `connect` no longer limits itself to displays the OS reports as online, and the tool keeps state across invocations. Done in planned sub-phase 1.1.
