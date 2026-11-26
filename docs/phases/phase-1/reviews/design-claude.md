Cross-model: YES (author: openai/Codex, reviewer: anthropic/claude-opus-5-5, command: claude)
cli: claude · resolved_model: claude-opus-5-5 · status: failed (repo changed; see runner note)
Scope: design (Phase 1 design + plan)
Dimensions: architecture
Diff: n/a (design review)
Timing: retroactive
Runner note: run-reviewer.sh reported "repository changed during the run" because the parallel Codex review wrote phase-codex.md into the repo meanwhile; the before/after fingerprints differ only by that file. The reviewer changed nothing. Report copied from the runner diagnostics.
---

No P1 findings. There are four P2s: two are stale or mismatched documents, and two are design premises that the code or hardware has contradicted. Codex designed Phase 1 and Claude reviewed it, so this review is cross-model. I edited no files.

## P2

**1. P2 · correctness: the design and plan don't match the public API the code now ships.** Phase 2 uses this API directly.
- `design.md:160` says "Every `connect all` outcome carries the original candidate display identity". However, `ConnectionController.swift:11` makes `display` optional, and `ConnectionController.swift:276-277` returns `display: nil` when the ledger can't be read. Plan Task 5 (`implementation-plan.md:363-366`) still has `display: Display`.
- `forget <uuid|all>` (`main.swift:11-12,36-44`) is missing from the command list in design §7.1 (`design.md:200-207`). `recoverySkipped` (`DisplayControlError.swift:10`) is missing from §8 (`design.md:225-239`) and from the enum in plan Task 2. `stateDirectory:` (`ConnectionController.swift:102`), `disabledDisplays()`, `DisplayControlState` and the public `CoreGraphicsDisplayTransactionFunctions` are not in plan Task 5.
- Why it matters: design §12 (`design.md:353`) requires a design update before any public API change. The Phase 2 plan (`phase-2/implementation-plan.md:117,147`) already uses the nil-display outcome and `recoverySkipped`, so the Phase 1 design is not a reliable contract for Phase 2.

**2. P2 · correctness: several design and plan statements are stale or contradicted by D-004 to D-010.**
1. `design.md:143` puts the lock "in the logged-in user's temporary directory". The same section (`design.md:149`) and the code (`DisabledDisplayLedger.swift:43-53`) use `~/Library/Application Support/displayctl/`. Plan Task 5 (`implementation-plan.md:376`) also says the temporary directory.
2. `design.md:112` says disabled displays "must remain discoverable through the online display inventory". The next paragraph (`:114`) says the opposite. The old sentence should be removed, not left next to the new one.
3. `design.md:137` ("Complete the transaction for the current login session") and `ConnectionController.swift:492` describe the change as session-scoped. D-008 and D-010 show it lasts until reboot. README `:90` has the same wording.
4. `design.md:7,30,277` and plan `:5` still target Tahoe 26.5 and the "M5/Tahoe 26.5 matrix". D-002 changed the target.
5. `design.md:302-334` (§10.2/§10.3), `design.md:355`, plan Scope (`implementation-plan.md:19`) and README Roadmap (`README.md:198-205`) still put the keyboard agent in Phase 2 and the menu bar in Phase 3. D-009 swapped them, and nothing in these sections marks them as superseded.
6. Plan Task 9 Step 3 (`implementation-plan.md:595`) describes an exit `trap` that runs `connect all`. The script that shipped is built around the watchdog (D-003/D-004/D-006).

The phase-status gate "decisions.md / design / plan in sync with code" can't be ticked until these are fixed.

**3. P2 · architecture: DDC matching can only succeed through the EDID serial number. The design promised location and EDID matching.**
- `design.md:166` says matching uses "Core Display metadata, EDID-derived properties, and I/O Registry location".
- In the code, `DDCDisplayIdentity` always sets `edidUUID = nil` and `displayLocation = nil` (`DDC.swift:241,244`). `isEligible` (`DDC.swift:376-378`) needs a location, serial or EDID match. That leaves the CG serial as the only way to qualify.
- `DDCRegistryMetadataParser` collects `PortID` and `EDID UUID` (`DDC.swift:457,460`), but nothing on the display side ever matches against them. The comment at `DDC.swift:300-301` ("EDID carries the lowest qualifying score") describes a path that can't happen.
- Consequence: a monitor whose numeric EDID serial is 0 (common) is reported `unsupported`, and brightness can never work for it. That affects the roadmap goal and the Phase 2 slider. The Dell passes only because it has a numeric serial.
- Fix: either update the design to "serial only" with that limitation stated, or add a display-side location such as the `IOAVService` ↔ `CGDisplay` path that MonitorControl uses.

**4. P2 · architecture: "Stable display UUID" (`design.md:101,110`) is contradicted by a hardware finding, and the ledger has no rule for it.**
- `phase-status.md:38` records that the Dell's UUID changed from `4E3207A4…` to `B3564974…` with a different cable or port.
- The ledger is keyed only by UUID (`ConnectionController.swift:218-223,259-262`). Take a display disabled on one port and brought back on another: its entry is never cleared. That has these effects:
  1. `connect all` reports a failure on every run until `forget`.
  2. `connect external` treats the orphan entry as a candidate. With a second real candidate the result is `ambiguousSelector`; on its own the orphan gets a pointless enable attempt.
  3. Phase 2 shows a ghost "off" row for every ledger entry that isn't online (`phase-2/design.md:94`), and its switch can only fail.
- Entries from an earlier boot whose display is offline also never expire (`design.md:153`). D-010 calls lingering entries "harmless" only for the case where the display is online.
- The design should limit the stability claim to one connection path. It also needs a rule for orphan entries, for example dropping them from kind selection and from Phase 2 rows, or expiring entries from an earlier boot whose UUID is offline.

**5. P2 · correctness: one acceptance criterion is not met by the code as it is now.**
- `design.md:366` says "changes the external HDMI monitor's physical brightness". README `:174` says HDMI brightness set was confirmed *before* DDC requests were sent twice (`DDC.swift:831-833`), and HDMI "is not yet rechecked".
- Every send now goes out twice, and the second must also succeed (`DDC.swift:840-841`). Nobody has watched this work over HDMI.
- `phase-status.md:13` marks Q2 done anyway. One HDMI `brightness set` check closes it.

## P3

**6. P3 · architecture/correctness: an inconsistent inventory read throws instead of retrying.** That leads to spurious failures, rollbacks, and string-matching in Phase 2.
- `DisplayInventory.swift:46-49,110-113` throws `configurationFailed("…changed while sampling; retry")`. Plan Task 3 asks for bounded retries only for the count/values race.
- `transition` treats any refresh error after a disable as `postconditionFailed` and rolls back (`ConnectionController.swift:371-379,413-416`). A refresh right after the topology change is exactly when this race happens. A disconnect that worked can therefore be reported as failed and undone (`ConnectionControllerTests.swift:246-265` locks this behaviour in).
- Phase 2 then has to detect the condition by substring (`phase-2/implementation-plan.md:108,121`).
- Fix: a bounded retry inside `snapshot()`. That removes both problems.

**7. P3 · correctness: the "never disconnect the last active display" rule is checked only before the change.**
- `ConnectionController.swift:289` counts active displays before the change. Since D-005, the postcondition after a disable accepts "UUID absent" as success (`:384-388`) and never checks that some display is still active.
- If the remaining display goes inactive too (mirroring, or a virtual display or Sidecar as the "other" display), the command reports success with no screen left.
- Fix: one extra check after the disable that `refreshed.contains(where: \.isActive)`, with a rollback if not. That turns the invariant into something the postcondition verifies.

**8. P3 · correctness: tests and states that test the mechanism, not the intent.**
- `CLIParserTests.swift:179` and `ConnectionControllerTests.swift:703` assert `.forSession`. That scope's promise (revert at logout) was disproved by D-008. The tests protect a mechanism whose meaning is gone.
- `DDCCapability.confirmed` (`design.md:171`) is never produced. It appears only in a test fixture (`CLIParserTests.swift:15`). Either drop it or let Phase 2 set it after a successful read.

## P4

**9. P4 · architecture: a lock timeout can only be recognised by its error message.**
- `ConnectionController.swift:76-79` reports it as `configurationFailed`, the same case used for transaction, ledger and inventory failures.
- Phase 2 shows "Busy" by checking the message prefix `"flock timed out"` (`phase-2/implementation-plan.md:194`).
- Rewording the message would quietly turn Busy into a generic error. A separate error case is cheap to add before Phase 2 code exists.

**10. P4 · architecture: display discovery and DDC are tied together, and each brightness write costs a lot.**
- Every `snapshot()` walks the whole IORegistry for each external display (`DisplayInventory.swift:86`). That includes every refresh in `connectAll` and every postcondition read, so the connection path now depends on DDC discovery.
- Every `set` does a doubled read to learn the maximum, then a doubled write (`DDC.swift:70-86`). Each of those calls resolves the registry twice (`DDC.swift:911-912`).
- That is fine for a CLI. For the Phase 2 slider, and especially Phase 3 key repeat, the delay per step adds up. Caching the maximum and the service per UUID would remove most of it.

**11. P4 · architecture: the state directory depends on the app not being sandboxed.**
- `DisabledDisplayLedger.swift:44` uses `URL.applicationSupportDirectory`. Inside a sandboxed app that resolves to the app's container.
- The Phase 2 app would then use a different ledger and lock from the CLI, which breaks "Both share one ledger and one lock" (`phase-2/design.md:35`).
- The Phase 2 design never says the app is unsandboxed. Saying so, or building the path from the home directory, closes the gap.

My recommendation: fix findings 1, 2 and 5 before closing Phase 1. Decide findings 3 and 4 in decisions.md, because Phase 2's rows and slider rely on them. Findings 6 and 9 are cheapest to fix now, before the Phase 2 plan's string-matching is written into code.
## Triage
| # | Finding | Dimension | Source | Decision | Note |
|---|---|---|---|---|---|
| 1 | Design/plan don't match the shipped public API | correctness | reviewer | accept | Docs fix: optional outcome display, `forget`, `recoverySkipped`, state directory, public types. |
| 2 | Stale statements (lock dir, discoverable, session-scoped, 26.5 target, phase order, exit trap) | correctness | reviewer | accept | Docs fix; superseded sections marked with their decisions. |
| 3 | DDC matching only works through the EDID serial | architecture | reviewer | accept | Design states "serial only" and the serial-0 limitation; no code change in Phase 1. Unused scoring left in place (see phase-claude #1). |
| 4 | UUID not stable across cable/port; orphan ledger entries | architecture | reviewer | accept | Design: UUID stable per connection path. Phase 2 design: ledger-only rows only for entries from the current boot; orphans cleared with `forget`. |
| 5 | HDMI brightness not rechecked with doubled sends | correctness | reviewer | accept | Owner hardware check (same as phase-codex #3). |
| 6 | Inconsistent inventory read throws instead of retrying | architecture | reviewer | accept | Bounded retry inside `snapshot()` in sub-phase 1.2; Phase 2 drops its string match. |
| 7 | Last-active invariant checked only before the change | correctness | reviewer | accept | Same as phase-codex #1 (P1). |
| 8a | Tests assert `.forSession` | correctness | reviewer | reject: the scope still matters. D-010's reboot recovery likely depends on the session scope; a permanent scope could survive reboot. The tests protect that. | |
| 8b | `DDCCapability.confirmed` never produced | correctness | reviewer | defer: Phase 2 | Phase 2 may set it after a successful read; otherwise remove. |
| 9 | Lock timeout recognisable only by message | architecture | reviewer | accept | New error case in sub-phase 1.2, temporary failure (exit 75). |
| 10 | Snapshot walks the I/O Registry; brightness writes are costly | architecture | reviewer | defer: Phase 2 | Measure snapshot and `set` cost early in Phase 2 before the slider relies on them. |
| 11 | State directory breaks under a sandbox | architecture | reviewer | accept | Phase 2 design states the app is unsandboxed. |
