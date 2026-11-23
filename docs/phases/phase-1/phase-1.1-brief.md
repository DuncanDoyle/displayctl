# Sub-phase 1.1 — Recoverable disconnects

Kind: planned (design amendment D-003)
Base: c324c9cbc3dfdd79df6f16091c51938911255918
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
| `disconnect <sel>` and macOS drops the display from the online list | Verified disconnect (D-005); entry kept in the ledger, no rollback. A refresh that fails or is inconsistent still rolls back |
| `connect <uuid>` for a ledger display that macOS no longer lists as online | Re-enable attempted with the recorded runtime ID; on verified active state the entry is removed, exit 0 |
| `connect <uuid>` when the UUID is online under a new runtime ID | Enables the current ID, not the recorded one |
| Offline ledger entry whose recorded ID is now held by another UUID | No mutation; skipped with a reported reason; nonzero exit |
| Offline ledger entry from an earlier boot | No mutation; reported; nonzero exit |
| Enable call succeeds but the UUID is not active afterwards | Postcondition failure; entry kept |
| Disconnect rollback fails, later `connect all` (new process) | Display re-enabled from the ledger |
| `connect all` with offline ledger entries | Each ledger entry and each online inactive display attempted once; results reported per display; exit nonzero if any fails |
| `connect all` with a stale entry (display unplugged) | Failure reported for that entry; other displays still reconnected |
| `forget <uuid\|all>` (inferred) | Ledger entries removed without touching displays; for unplugged displays that would otherwise fail `connect all` forever |
| `list` | Unchanged columns; ledger-only displays are not listed as online (inferred: a note on stderr names them) |
| Hardware test, first disconnect | Internal session-scoped disconnect with the watchdog armed (D-006) |
| Hardware test, before each session-scoped disconnect | Detached watchdog armed; stays armed until the original active set is verified restored |
| Hardware test, no confirmation within 20 s | Watchdog retries `connect all` until the original active set is back or a hard deadline passes; the script stops |
| Hardware test, slow disconnect still holding the lock at 20 s | Watchdog keeps retrying and still restores the display |
| Hardware test order | Internal first; every external disable, including the final-display refusal setup, needs the internal pass and a separate opt-in |

## Root cause (if known)
`connect all` and `connect <sel>` resolve targets only from `CGGetOnlineDisplayList` (`DisplayInventory.swift:34`, `:135`). Once macOS drops a disabled display from that list, the tool has no record of its runtime ID, so nothing can call `CGSConfigureDisplayEnabled(id, true)` for it. Whether macOS 27 honours that call for a dropped display is unverified; the hardware test answers it.

## Acceptance tests
At the `ConnectionController` boundary with the existing fake hardware, plus the CLI parser. The fake must not restore a display just because its old ID is called; each test sets up what macOS does.
1. Disconnect whose post-disable refresh fails, and whose immediate rollback also fails; a later `connect all` (new controller, same ledger file) restores that UUID. (A display that only drops out of the list is a verified disconnect, D-005.)
2. `connect <uuid>` for a ledger-only display succeeds and empties the entry.
3. Same UUID online under a new runtime ID → the new ID is enabled.
4. Recorded ID now held by another UUID → no mutation, reported.
5. Entry from an earlier boot → no mutation, reported.
6. Enable succeeds without the UUID becoming active → failure, entry kept.
7. Ledger write failure → disconnect refused, no disable call made.
8. Stale entry → reported failure, other displays still reconnected.
9. `forget` parses; `--trial` is rejected (D-006).
Each must fail before the change. The watchdog is exercised with a stubbed `displayctl` (no input, late confirmation, slow lock holder); real recovery is verified on hardware.

## Scope
In: `Sources/DisplayControlCore/ConnectionController.swift`, new ledger file in `DisplayControlCore`, `Sources/displayctl/main.swift`, matching tests, `Scripts/hardware-test.sh`, `README.md`.
Out: Phase 2 agent, any `--force`. DDC changes were out of scope at start; the USB-C read/write fixes and the set fallback (`7017236`, `9d3bb36`, `cb24ec8`) are Task 10 hardware-verification fixes, recorded here so the sub-phase review covers them.

## Plan / design impact
design.md §6.3, §6.3.1, §6.3.2, §7.3, §9.2 amended (D-003 to D-006); platform note (D-002). implementation-plan.md: Task 10 Step 4 now depends on 1.1.

## Definition of done
- [ ] acceptance tests fail before, pass after (report both)
- [ ] full test suite passes; `swift format lint` clean
- [ ] Codex review of `git diff c324c9c..HEAD` + triage
- [ ] hardware test on macOS 27, recorded in README: internal session disconnect/reconnect with watchdog; one unattended watchdog timeout restores a usable screen
- [ ] external disconnect claimed supported only if recovery from a dropped display is observed; otherwise recorded as unsupported (D-004)
- [ ] phase-1.1-complete.md written; phase-status.md updated
