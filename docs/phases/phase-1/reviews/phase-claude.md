Cross-model: YES (author: openai/Codex for 699b839..c324c9c, reviewer: anthropic/claude-opus-5-5, command: claude)
cli: claude · resolved_model: claude-opus-5-5 · status: failed (repo changed; see runner note)
Scope: phase 1 (Codex-authored range)
Dimensions: both
Diff: 699b839..c324c9c (code), checked against f1b688e
Timing: on time
Runner note: run-reviewer.sh reported "repository changed during the run" because the parallel Codex review wrote phase-codex.md into the repo meanwhile; the before/after fingerprints differ only by that file. The reviewer changed nothing. Report copied from the runner diagnostics.
---

**There are no P1 or P2 findings.** I checked every finding against the current files at HEAD (`f1b688e`). Claude's later commits replaced or fixed most of the Codex code that carried risk:

- **Hardware script:** fully rewritten, with a watchdog.
- **Lock:** moved to `~/Library/Application Support/displayctl/`.
- **Disconnect check:** a display that leaves the online list now counts as disconnected (D-005).
- **Ledger:** `connect` and `connect all` now also find displays macOS no longer lists.
- **Inventory:** a sample taken while the display setup changes is now rejected.

Four findings still hold. All of them are in the DDC and CLI code that Codex wrote and Claude has not touched.

### P3 · architecture · the DDC matcher scores fields the real code never fills
- **Where:** `Sources/DisplayControlCore/DDC.swift:240-251` (which fields get set), `:365-379` (the strong-identity gate), `:330-363` (scoring)
- **Evidence:** The only way the real code builds a display's identity is `DDCDisplayIdentity(display:cgMetadata:)`. It always leaves `edidUUID`, `displayLocation`, the manufacture date and the physical size empty. To be accepted, a service must match location, serial or EDID UUID (`isEligible`). In practice only the Core Graphics serial number can pass that gate. The location (100) and EDID weights, the date (20) and size (15) scoring, and the parser code that reads those fields (`:457-466`) never run in production. `DDCCapability.confirmed` (`Display.swift`) is also never produced.
- **Why it matters:**
  - Design §6.4 says matching uses "Core Display metadata, EDID-derived properties, and I/O Registry location". The display side uses none of these.
  - The matcher tests use `displayIdentity()` (`DDCTests.swift:898`), which fills in EDID and location values. So `testSelectsUniqueHighestScoringExternalService` (`:643`) and similar tests check inputs that production never builds. That is a test asserting a mechanism, not the real behaviour.
  - Fix: either fill the display-side fields from a real source, or remove the scoring paths nothing can reach.

### P3 · correctness · no test runs the real identity through the matcher
- **Where:** `Tests/DisplayControlCoreTests/DDCTests.swift:206` and `:284`
- **Evidence:** The only matches that work in production depend on two pairs of values agreeing:
  - `CGDisplaySerialNumber` as a decimal string, and the registry's `SerialNumber` as a decimal string.
  - `CGDisplayVendorNumber`/`CGDisplayModelNumber`, and the registry's `LegacyManufacturerID`/`ProductID`.

  Each side is tested on its own, with the same Dell numbers (1113146188, 4268, 16816). No test passes the output of `DDCDisplayIdentity(display:cgMetadata:)` and `DDCRegistryMetadataParser.candidate(...)` to `DDCServiceMatcher.select` together.
- **Why it matters:** The only proof that the production path matches is the Dell hardware run. A change to the format on either side would still pass all tests. One test that builds both sides from the Dell's observed values and calls `select` closes this gap.

### P4 · architecture · monitors whose EDID serial is 0 can never get brightness control
- **Where:** `DDC.swift:243` and `:376-378`, combined with Phase 2 `docs/phases/phase-2/design.md:107`
- **Evidence:** If `CGDisplaySerialNumber` returns 0, the display gets no serial. Then no service is eligible, so the result is `ddcServiceNotFound` and the display is shown as `unsupported`. Many monitors leave the numeric EDID serial at 0 and store the serial only as text.
- **Why it matters:** For such a monitor, the Phase 2 panel hides the brightness slider, and `brightness set` exits 69, even though DDC would work. The owner's Dell has a serial, so the stated requirement is met. This only matters when the monitor changes. It has the same root cause as the first P3 finding.

### P4 · architecture · every display snapshot also searches the I/O Registry for DDC services
- **Where:** `DisplayInventory.swift:86`, `DDC.swift:640-664`, `DDC.swift:695-713`, `ConnectionController.swift:31-32`
- **Evidence:**
  - `snapshot()` runs the DDC service lookup for each external display. Each lookup walks the whole I/O Registry, and also walks up the parent chain for every proxy and framebuffer it finds.
  - `ConnectionController` takes 2–4 snapshots per operation, all while holding the lock. Another process waits at most about 1 s for that lock (50 × 20 ms).
  - A `brightness set` walks the registry three times: once in the snapshot, once in the transport's lookup, and once in `service(withRegistryEntryID:)`. The last could be one `IORegistryEntryIDMatching` lookup.
- **Why it matters:** Connect and disconnect don't need DDC capability, but they pay for the lookup while holding the lock. Phase 2 takes a fresh snapshot before every slider write (`phase-2/design.md:110`) and on every display change. The cost has not been measured. Measure it before Phase 2, or give the connection controller a snapshot that skips the DDC lookup.

### P4 · correctness · an invalid DDC reply exits with 1, not 75
- **Where:** `Sources/displayctl/main.swift:249-255`, `DDC.swift:110-116` and `:142-144`
- **Evidence:** The controller retries `ddcInvalidResponse` as a temporary failure. That includes the DDC null message, which a monitor sends when it has no reply ready. The CLI maps it to exit 1. The help text (`main.swift:144`) and the plan (Task 8) promise 75 for temporary DDC failures.
- **Why it matters:** A script cannot tell a temporary DDC failure from a permanent one by the exit code. No current caller checks for 75, so the impact is small.

These conclusions come from reading the code only. I did not run anything, as the review brief asked.
## Triage
| # | Finding | Dimension | Source | Decision | Note |
|---|---|---|---|---|---|
| 1 | DDC matcher scores fields production never fills | architecture | reviewer | accept | Design documents serial-only matching (design-claude #3). Removing the dead scoring is deferred: Phase 2 may add a display-side location. |
| 2 | No test runs the real identity through the matcher | correctness | reviewer | accept | One test with the Dell's observed values through both sides and `select`, sub-phase 1.2. |
| 3 | Monitors with EDID serial 0 never get brightness | architecture | reviewer | accept | Documented limitation (design-claude #3). |
| 4 | Every snapshot walks the I/O Registry | architecture | reviewer | defer: Phase 2 | Same as design-claude #10. |
| 5 | Invalid DDC reply exits 1, not 75 | correctness | reviewer | accept | Map `ddcInvalidResponse` to 75 in sub-phase 1.2. |
