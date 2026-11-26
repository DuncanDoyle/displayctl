Cross-model: YES (author: anthropic/claude-opus-5-5 for c324c9c..420c8b0, reviewer: openai/gpt-6.2-sol, command: codex)
cli: codex · resolved_model: gpt-6.2-sol · status: ok
Scope: phase 1 (Claude-authored range)
Dimensions: both (architecture weighted)
Diff: c324c9c..420c8b0
Timing: on time
---

## Phase 1 review

**Request changes before closing Phase 1.** I found one P1 in last-display protection and two P2s in hardware recovery and HDMI validation. Scope was the Claude-authored range `c324c9c..420c8b0`.

1. **P1 · correctness · `ConnectionController.swift:284`, `:382` — Disconnect can report success with zero active displays.** With the built-in panel and Dell active, unplugging the Dell after `disconnect internal` samples the inventory can leave the built-in panel as the only active display before the disable commits. The ledger write sits between the last-active check and the transaction. The lock serializes cooperating callers, but a physical unplug can still occur. If the refresh then consistently reports zero active displays, D-005’s target-absence branch returns success and skips rollback. Before accepting a disable, verify that an active display remains. If none does, attempt the existing rollback and report the failure. A regression test can remove the other display between validation and the hardware call. [ConnectionController.swift:284](Sources/DisplayControlCore/ConnectionController.swift:284) · [ConnectionController.swift:382](Sources/DisplayControlCore/ConnectionController.swift:382) · [design.md:241](docs/phases/phase-1/design.md:241)

2. **P2 · architecture · `hardware-test.sh:129`, `:675` — Test recovery can enable displays that were intentionally off before the run.** Both timeout recovery and final-test cleanup call unconditional `connect all`. A third monitor that was already soft-disabled and absent from inventory can pass the script’s startup checks, then be enabled from the ledger during cleanup. The watchdog checks only that every original UUID is active, so it can certify restoration with an extra screen on. The script already records the UUIDs it needs to restore. Use that set for automated recovery and keep `connect all` available for manual recovery. [hardware-test.sh:99](Scripts/hardware-test.sh:99) · [hardware-test.sh:129](Scripts/hardware-test.sh:129) · [hardware-test.sh:675](Scripts/hardware-test.sh:675) · [design.md:292](docs/phases/phase-1/design.md:292)

3. **P2 · correctness · `DDC.swift:831`, `README.md:174` — The final HDMI brightness path still needs hardware validation.** The USB-C workaround now requires two successful SET sends on every route. The final 1.1 fix correctly propagates a failed second send on the Dell over USB-C, where both sends are needed. It also restores the earlier failure mode for a monitor that applies the first SET and rejects the second. The recorded HDMI pass used a single send, and the current HDMI behavior is unknown. Task 10 and §13 require a physical brightness change over HDMI. Verify GET and a visibly effective SET with the current binary before marking that gate complete. [DDC.swift:830](Sources/DisplayControlCore/DDC.swift:830) · [README.md:173](README.md:173) · [design.md:366](docs/phases/phase-1/design.md:366)

4. **P3 · architecture · `ConnectionController.swift:459` — CLI test injection exposes a low-level public API.** The CLI fixture makes the Core Graphics transaction table public and `@unchecked Sendable`, including its raw configuration pointer and escaping closures. Production composition can use the existing live hardware initializer, and the fixture only needs access within the package. Package visibility would keep the same live-wiring coverage without making those transaction details part of the library contract used by later phases. [ConnectionController.swift:459](Sources/DisplayControlCore/ConnectionController.swift:459) · [main.swift:80](Sources/displayctl/main.swift:80) · [design.md:64](docs/phases/phase-1/design.md:64)

The author reported 160 passing tests, 10 CLI and 150 core, with zero failures and clean strict Swift format lint on macOS 27.0.1 with Swift 6.4.2. The recorded hardware runs demonstrate recovery of dropped displays, final-display refusal with stable topology, and USB-C brightness with doubled sends. I ran no tests and edited no files.
## Triage
| # | Finding | Dimension | Source | Decision | Note |
|---|---|---|---|---|---|
| 1 | Disconnect can report success with zero active displays | correctness | reviewer | accept | P1. After a disable, require an active display to remain; otherwise roll back and fail. Regression test removes the other display between check and disable. Sub-phase 1.2. |
| 2 | Test recovery can turn on a display that was off before the run | architecture | reviewer | reject: only a display already turned off by `displayctl` and absent from the start inventory is affected; turning it on is harmless, and the owner has one external monitor. `connect all` stays the simplest recovery. | Owner confirmed: "Agree. It also does what it says it does: connect all connects all monitors." (2026-11-26) |
| 3 | HDMI brightness not rechecked with doubled sends | correctness | reviewer | accept | Owner hardware check before close. |
| 4 | Transaction table exposed as public API | architecture | reviewer | accept | Make it package-visible in sub-phase 1.2 if the CLI test fixture allows; otherwise record why. |
