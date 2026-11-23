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

## D-004 — Refine D-003 after Codex design review; add a trial disconnect (2026-11-23, phase 1)
**Context:** Codex's review (`docs/phases/phase-1/reviews/1.1-design-codex.md`) found that D-003 could re-enable the wrong display through a reused runtime ID, that the watchdog could be disarmed or lose the lock race, and that nothing proves macOS 27 can re-enable a hidden display.
**Decision:** (1) Ledger entries are matched by UUID first; an offline entry is enabled by its recorded runtime ID only if no other online display holds that ID and the entry is from the current boot. The rollback follows the same rule. (2) Ledger and lock live in `~/Library/Application Support/displayctl/`, written atomically under the lock. (3) The watchdog stays armed until the original active set is restored, and retries until a hard deadline. (4) New test-only `displayctl disconnect <sel> --trial <seconds>` disables the display with the app-only configuration scope, holds it for at most the given time, then exits; macOS should undo the change at process exit. It is the first hardware step. User approved: "Yes, trial first".
**Alternatives:** Ledger + watchdog only — no protection that is independent of our own recovery code.
**Consequences:** One more CLI option. If the trial shows that app-only scope does not revert a private enable, or that a hidden display cannot be re-enabled, external disconnect stays unsupported in Phase 1 until a new decision.

## D-005 — A disabled display counts as disconnected when it leaves the online list (2026-11-23, phase 1)
**Context:** First hardware run on macOS 27.0.1: `disconnect internal --trial 10` failed with "had 0 matches after requesting enabled false", and the rollback re-enabled the internal display at once by its recorded ID 1. The June HDMI run on 26.5 failed with the same message. macOS drops a display disabled with `CGSConfigureDisplayEnabled` from `CGGetOnlineDisplayList`; it does not list it as online and inactive, which the postcondition in §6.3 step 9 expected.
**Decision:** After a disable, the display's UUID being absent from the online list, or present and inactive, both verify the disconnect. Enable still requires the UUID to be present and active. The ledger is the only way back to a display in that state.
**Alternatives:** Reading a wider display list that includes disabled displays — none is known in the public API, and the ledger already covers it.
**Consequences:** The June HDMI "failure" was most likely a successful disconnect misread by the postcondition, followed by recovery that could not find the display. The rollback on 2026-11-23 also showed that macOS 27 re-enables a display that has left the online list, by its recorded runtime ID (internal display; HDMI unverified).

## D-006 — Drop `--trial`; the watchdog and ledger are the safety net (2026-11-23, phase 1)
**Context:** Second macOS 27.0.1 hardware run: `disconnect internal --trial 10` disabled the internal display, held 11 s and exited 0, but the display was still off 5 s after exit. The app-only configuration scope does not undo a `CGSConfigureDisplayEnabled` change at process exit. The watchdog then ran `connect all`, which re-enabled the internal display from the ledger (it had left the online list) on its first attempt.
**Decision:** Remove `--trial` and the app-only scope; its safety promise is false on macOS 27. Supersedes D-004 (4) and design §6.3.2. Hardware test order: internal session round trip, unattended watchdog run, then the external display with the watchdog after a separate opt-in. User chose: "Drop trial, use watchdog".
**Alternatives:** Internal-only support, recording external disconnect as unsupported (no reboot risk, loses a feature); keeping `--trial` for a future macOS (dead code with a false promise).
**Consequences:** No OS-owned safety net exists. If the external display does not come back from the ledger, recovery is `connect all`, then logout/login, then reboot. External disconnect is recorded as supported only if its recovery from a dropped display is observed.
