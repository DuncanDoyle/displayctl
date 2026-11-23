# Sub-phase 1.1 — Recoverable disconnects

Kind: planned (design amendment D-003)
Base: c205693eb32e15191bbd3e7df0dbcd5407c939a8
Issues: none (repo has no GitHub remote) | Plan steps: Task 10 Step 4 blocked on this

## Problem / goal
On 2026-06-30 (macOS 26.5), `displayctl disconnect` on the HDMI Dell U2720Q made macOS drop the display from its online list. The postcondition failed, and the hardware script's `connect all` trap did nothing because it only targets online displays. Replugging HDMI did not help; only a reboot recovered it.

Reproduction (do not rerun until this sub-phase is done): `Scripts/hardware-test.sh`, external HDMI disconnect step.

Goal: no disconnect done by `displayctl` can leave a display that only a reboot brings back, as far as macOS allows a re-enable at all. Hardware testing must recover on its own when the user cannot see a screen.

## Expected behaviour

| Input / action | Expected |
|---|---|
| `disconnect <sel>` succeeds | Display recorded in the ledger before the disable; inactive afterwards |
| `disconnect <sel>` and the ledger cannot be written | Exit nonzero, display untouched |
| `disconnect <sel>` and macOS drops the display from the online list | Postcondition failure as today, but the display stays in the ledger and the existing rollback still runs |
| `connect <uuid>` for a ledger display that macOS no longer lists as online | Re-enable attempted with the recorded runtime ID; on verified active state the entry is removed, exit 0 |
| `connect all` with offline ledger entries | Each ledger entry and each online inactive display attempted once; results reported per display; exit nonzero if any fails |
| `connect all` with a stale entry (display unplugged) | Failure reported for that entry; other displays still reconnected |
| `forget <uuid\|all>` (inferred) | Ledger entries removed without touching displays; for unplugged displays that would otherwise fail `connect all` forever |
| `list` | Unchanged columns; ledger-only displays are not listed as online (inferred: a note on stderr names them) |
| Hardware test, before each disconnect | Watchdog armed; it runs `connect all` after 20 s unless the user types the confirmation first |
| Hardware test, user confirms in time | Watchdog cancelled; test continues |
| Hardware test order | Internal disconnect/reconnect first; external only after internal passes and the user opts in |

## Root cause (if known)
`connect all` and `connect <sel>` resolve targets only from `CGGetOnlineDisplayList` (`DisplayInventory.swift:34`, `:135`). Once macOS drops a disabled display from that list, the tool has no record of its runtime ID, so nothing can call `CGSConfigureDisplayEnabled(id, true)` for it. Whether macOS 27 honours that call for a dropped display is unverified; the hardware test answers it.

## Acceptance tests
At the `ConnectionController` boundary with the existing fake hardware, plus the CLI parser:
1. Disconnect where the fake drops the display from the online list → a later `connect all` (new controller instance, same ledger file) re-enables the recorded runtime ID.
2. `connect <uuid>` for a ledger-only display succeeds and empties the entry.
3. Ledger write failure → disconnect refused, no enable call made.
4. Stale entry → reported failure, other displays still reconnected.
5. `forget` parses and empties the ledger.
Each must fail before the change. The watchdog is verified on hardware (the script is not unit tested).

## Scope
In: `Sources/DisplayControlCore/ConnectionController.swift`, new ledger file in `DisplayControlCore`, `Sources/displayctl/main.swift`, matching tests, `Scripts/hardware-test.sh`, `README.md`.
Out: DDC/brightness code, Phase 2 agent, any `--force`, retesting the external HDMI disconnect before internal passes.

## Plan / design impact
design.md §6.3.1, §7.3, §9.2 amended (D-003); platform note (D-002). implementation-plan.md: Task 10 Step 4 now depends on 1.1.

## Definition of done
- [ ] acceptance tests fail before, pass after (report both)
- [ ] full test suite passes; `swift format lint` clean
- [ ] Codex review of `git diff c205693..HEAD` + triage
- [ ] hardware test: internal disconnect/reconnect with watchdog on macOS 27, result recorded in README
- [ ] phase-1.1-complete.md written; phase-status.md updated
