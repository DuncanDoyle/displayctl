Cross-model: YES (author: anthropic/claude-opus-5-5, reviewer: openai/gpt-6.2-sol, command: codex)
cli: codex · resolved_model: gpt-6.2-sol · status: ok
Scope: phase 2 (D-012 implementation)
Dimensions: both
Diff: 6a93979..9a42ad6
Timing: on time
---

**No P1 findings. Two P2 findings.** The implementation preserves runtime-ID ownership and applies the four-signal classifier to the required usable-active checks. The remaining mismatches are in panel ledger rows and command targeting.

1. **P2 · Correctness · `Sources/DisplayMenuKit/PanelRows.swift:25`** — A current-boot ledger entry with the placeholder’s UUID can bring the placeholder back as an off row. `onlineIDs` is built after filtering out the placeholder, so the ledger filter at line 48 treats that UUID as absent even while macOS lists it. This violates §6.1’s rule that ledger rows are for displays absent from the online inventory. Use the raw online UUIDs for the ledger check.

2. **P2 · Architecture · `Sources/DisplayControlCore/DisplaySelector.swift:7`** — The placeholder is hidden from `list` but remains a command target. With only the placeholder active and no eligible external reconnect candidate, `disconnect external` resolves to the placeholder and reports `lastActiveDisplay`. `connect external` takes a separate path and reports that the placeholder is already active. Both commands leave hardware untouched in that topology. If a reconnect snapshot contains both the placeholder and a real external, the placeholder can also make `disconnect external` ambiguous. Exclude it from command targets while retaining it in the snapshots used for ownership checks. `Sources/DisplayControlCore/ConnectionController.swift:206`, `:233`, `:316`

3. **P3 · Correctness · `Tests/DisplayControlCoreTests/ConnectionControllerTests.swift:224`** — The new rollback test gives the placeholder a different ID from the disabled target. The reconnect test covers a placeholder holding the saved ID, and the existing rollback collision test uses an ordinary display. A placeholder-specific rollback collision test would catch a future filter that drops the placeholder only from rollback’s ownership check. `Tests/DisplayControlCoreTests/ConnectionControllerTests.swift:201`, `:630`

4. **P3 · Correctness · `docs/phases/phase-2/reviews/placeholder-codex.md:28`** — The supplied results leave the accepted hardware proof open. The unit tests simulate the placeholder as main. The outstanding evidence is the app-stopped fallback detecting zero usable displays and restoring the built-in panel in that topology, followed by the timestamped app checks. The classifier’s negative controls on real virtual displays also remain unverified, as recorded in triage. `docs/phases/phase-2/reviews/placeholder-codex.md:27`

5. **P4 · Architecture · `Sources/DisplayControlCore/DisplayInventory.swift:205`** — The DDC gap is confirmed. Every full snapshot that contains the placeholder enumerates I/O Registry DDC candidates for it, including snapshots during recovery. Capability detection performs no DDC bus I/O and handles resolver errors internally. The concrete cost is extra registry work during recovery, with no timing impact established by the supplied evidence. `Sources/DisplayControlCore/DDC.swift:286`, `:625`

The rest of the checklist checks out. Inventory requires `unkn`, `virt`, 0×0 mm, and no current mode, and keeps the flagged record through active-list consistency checks and the reconnect and rollback ownership checks. Disconnect’s last-active guard and post-disable check, both `recoverIfNoneActive` guards, recovery verification, and the live scheduler re-arm count all exclude the placeholder. D-005’s target-UUID postconditions are preserved. The panel excludes the inventory placeholder from its rows and active count, subject to finding 1. Text and JSON list output omit it, stderr identifies it from the same snapshot, and JSON retains all eight existing fields.

The author reports 232 passing tests, a warning-free release build, clean strict lint, and the expected pre-change failures for the new tests. I did not run the tests or edit files.
## Triage
| # | Finding | Dimension | Source | Decision | Note |
|---|---|---|---|---|---|
| 1 | Placeholder UUID in the ledger can become an off row | correctness | reviewer | accept | Ledger-row absence check uses raw online UUIDs. |
| 2 | Placeholder still a command target | architecture | reviewer | accept | Selectors skip it; snapshots keep it for ownership checks. |
| 3 | No placeholder-specific rollback collision test | correctness | reviewer | accept | Test added. |
| 4 | Hardware proof still open | correctness | reviewer | accept | Next: fallback-only proof with the placeholder as main, then steps 9–12. |
| 5 | DDC lookup runs for the placeholder | architecture | reviewer | accept | Placeholder gets `unsupported` without a lookup. |
