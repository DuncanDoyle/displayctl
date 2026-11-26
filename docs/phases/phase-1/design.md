# Display Control Design

## 1. Status

- Phase: 1 — CLI hardware validation
- Status: Approved design
- Initial platform: Apple Silicon M5 Mac running macOS Tahoe 26.5; now macOS 27.0.1 (D-002)
- Initial display connections: HDMI, with USB-C compatibility evaluated separately
- Language: Swift

## 2. Problem

The project will provide focused display controls without the unrelated features of a general-purpose display-management application.

The complete product will eventually:

1. Logically connect and disconnect the MacBook's internal display or a physically connected external display.
2. Adjust a compatible external display's hardware brightness with the Mac keyboard brightness keys.
3. Select the keyboard brightness target using the display containing the mouse pointer.
4. Recover automatically if the last active display is physically removed while other physically connected displays are soft-disconnected.

Development is divided into phases so the private macOS hardware-control mechanisms are validated before adding a background agent or user interface.

## 3. Constraints

- Phase 1 is a command-line tool only.
- The implementation must be self-contained and must not require BetterDisplay at runtime.
- Private macOS APIs are acceptable because the initial tool is for personal use.
- Private API usage must be isolated so future macOS compatibility work has a narrow scope.
- The initial supported operating system is macOS Tahoe 26.5.
- The initial supported architecture is Apple Silicon.
- True hardware brightness control is required. Software gamma or overlay dimming is not an acceptable fallback.
- A display disconnect should remove the display from the active desktop layout where the operating system permits it.
- The tool must never disconnect the last active display.
- Phase 1 requires neither root privileges nor Accessibility permission.
- No new runtime dependencies will be introduced unless a later design and plan update justifies them.

## 4. Research Basis

Apple's documented Quartz Display Services API supports display discovery, display configuration transactions, mode changes, origins, and mirroring. It does not expose a documented operation for enabling or disabling a display, nor a documented DDC/CI transport for third-party monitor brightness.

Inspection of the locally installed BetterDisplay 4.3.4 binary on the target Mac shows imports for:

- `CGSConfigureDisplayEnabled`
- `IOAVServiceCreateWithService`
- `IOAVServiceReadI2C`
- `IOAVServiceWriteI2C`
- `DisplayServicesGetBrightness`
- `DisplayServicesSetBrightness`

The target Mac's I/O Registry exposes an external `DCPAVServiceProxy`. This is consistent with open-source Apple Silicon DDC implementations that match a Core Graphics display to an external AV service and transmit DDC/CI messages over I2C.

The design therefore uses two private mechanisms behind explicit adapters:

- `CGSConfigureDisplayEnabled` within a Core Graphics transaction for logical connection state.
- `IOAVService` I2C transport with MCCS VCP code `0x10` for external hardware brightness.

Because BetterDisplay is closed-source, the precise internal selection and retry algorithms cannot be verified. The observed imports and I/O Registry topology support the selected approach but do not justify copying BetterDisplay implementation details.

## 5. Architecture

The project will be a Swift Package Manager workspace with two initial products.

### 5.1 `DisplayControlCore`

A reusable library that owns display discovery, selection, connection changes, brightness operations, and safety validation. Later phases will use this library without duplicating hardware-control logic.

The core exposes domain-level operations and types. It does not expose private framework types in its public interface.

### 5.2 `displayctl`

A thin executable responsible for:

- Parsing commands and arguments.
- Calling `DisplayControlCore` operations.
- Rendering human-readable output.
- Rendering stable JSON output when requested.
- Mapping domain errors to documented nonzero exit codes.

The executable contains no direct Core Graphics, I/O Kit, or DDC implementation logic.

### 5.3 Private API boundary

Private symbols are accessed through a narrow internal bridge. Symbols are resolved dynamically at runtime rather than being hard-linked into executable startup.

This boundary provides:

- Availability checks for each required symbol.
- Typed wrappers around unsafe calls.
- Conversion of native return codes into domain errors.
- A single location for compatibility changes after macOS updates.

If a symbol is absent or incompatible, the CLI exits with a clear unsupported-platform error rather than failing during process launch.

## 6. Core Components

### 6.1 Display inventory

The inventory queries active and online Core Graphics display lists and builds a `Display` value containing:

- Stable display UUID.
- Current `CGDirectDisplayID` runtime identifier.
- Human-readable name when available.
- Internal or external classification.
- Online state.
- Active state.
- Main-display state.
- Candidate hardware-brightness capability.

Stable UUID is the canonical identifier. Runtime display IDs can change and are only convenience selectors.

Soft-disconnected displays must remain discoverable through the online display inventory for reconnection. If Tahoe does not expose a disabled display through that inventory, Phase 1 stabilization must add the smallest persistent identity record needed for recovery before the connect command is considered complete.

Soft-disconnected displays leave the online display inventory on macOS 26.5 and 27 (D-005). The ledger (§6.3.1) is the persistent identity record that makes them reachable again.

Commands accept:

- A stable display UUID.
- A current runtime display ID.
- `internal` when exactly one internal display matches.
- `external` when exactly one external display matches.
- `all` only for the recovery-oriented `connect all` command.

Ambiguous or missing selections produce explicit errors. State validation is command-specific: `connect` requires an inactive display, while `disconnect` requires an active display. For `connect`, a kind selector matches among inactive online displays of that kind plus ledger entries of that kind that are not online, and needs exactly one candidate. Display names are reported but are not canonical selectors because names may be duplicated or localized.

### 6.3 Connection controller

Connection changes use this sequence:

1. Acquire the per-user, cross-process display-operation lock.
2. Refresh the display inventory.
3. Resolve the requested display.
4. Validate the requested transition.
5. For disconnect, prove that another active display will remain.
6. Begin a Core Graphics display configuration transaction.
7. Invoke `CGSConfigureDisplayEnabled` through the private bridge.
8. Complete the transaction for the current login session.
9. Refresh inventory and verify the expected postcondition unambiguously. After a disable, a UUID absent from the online list counts as disconnected (D-005).
10. Release the display-operation lock.

If configuration fails before completion, the transaction is cancelled. On macOS 27 a session-scoped disable survives logout/login, so logout is not a recovery boundary (D-008). Recovery is `displayctl connect all` from the ledger, then a reboot, which restores the display (D-010).

The operation lock uses Darwin `flock` on a lock file in the logged-in user's temporary directory. It serializes the complete validation and mutation sequence across threads, controller instances, and CLI processes. Acquisition uses bounded waiting and fails clearly rather than hanging indefinitely. The operating system releases the advisory lock when a process exits or crashes.

#### 6.3.1 Disabled-display ledger (D-003)

macOS can drop a soft-disabled display from the online display list, so the inventory alone cannot always find it again. The controller therefore keeps a per-user ledger file of displays that `displayctl` disabled:

- The ledger and the operation lock live in `~/Library/Application Support/displayctl/`, independent of the working directory and `$TMPDIR`, so the CLI, the hardware-test watchdog and the Phase 2 agent share them.
- A disconnect records the display's UUID, runtime ID, name and the current boot time in the ledger, atomically and under the operation lock, before invoking `CGSConfigureDisplayEnabled`. If recording fails, the disconnect does not happen.
- A connect resolves its selector against the inventory and the ledger, by UUID first (D-004). If the UUID is online, its current runtime ID is used. An offline entry is enabled by its recorded runtime ID only when the entry is from the current boot (`kern.bootsessionuuid`), no online display of another UUID holds that ID, and Core Graphics does not map that ID to another UUID right before the enable. Otherwise the entry is reported and skipped. The disconnect rollback follows the same rule.
- An entry is removed only once its UUID is verified active again, or when the user runs `displayctl forget`. Entries whose state is uncertain are kept.
- Entries from an earlier boot are kept for reporting but never trigger a mutation.
- Identity checks and per-display outcomes stay in `DisplayControlCore`; the CLI only maps them to exit codes, so Phase 2 can reuse them under the lock.

#### 6.3.2 Trial disconnect — removed (D-006)

An app-only `--trial` mode was designed here (D-004). On macOS 27 the app-only scope does not undo a `CGSConfigureDisplayEnabled` disable at process exit, so the mode was removed (D-006). The watchdog and the ledger are the safety net.

There is no force option for disconnecting the final active display. `connect all` is idempotent: a candidate that becomes active before its turn is treated as a successful recovery. Every `connect all` outcome carries the original candidate display identity alongside its typed success or failure so callers can report results independently.

### 6.4 DDC service matching

External hardware brightness requires matching a Core Graphics display to its external `DCPAVServiceProxy`/`IOAVService`.

Matching uses the strongest identifiers available from Core Display metadata, EDID-derived properties, and I/O Registry location. A match must exceed a defined confidence threshold. Multiple equally plausible services are treated as ambiguous and no write is attempted.

The distinction between capability states is explicit:

- Candidate: a plausible external AV service exists.
- Confirmed: a valid DDC operation has succeeded.
- Unsupported: no safe service match or DDC transport is available.
- Unknown: probing failed without establishing support.

`displayctl list` must not claim confirmed DDC support solely because a candidate service exists.

### 6.5 DDC brightness controller

The controller uses DDC/CI luminance VCP code `0x10`.

External package clients can construct the default live controller without accessing internal I/O Registry or IOAV transport types. Transport injection remains available for deterministic tests and alternative implementations.

It supports:

- Setting a percentage from 0 through 100 inclusive.
- Attempting to read the current and maximum hardware value.
- Scaling percentages against the monitor-reported maximum where available.
- Serializing requests per display.
- Bounded retries and bounded delays.
- Checksum validation on responses.

Read-back is allowed to fail independently because some monitors accept writes but return unreliable reads. A failed read returns an error; it never returns an invented or cached value. A set operation can still succeed when write support is confirmed even if read-back is unavailable.

No software dimming fallback is provided.

## 7. Phase 1 CLI

### 7.1 Commands

```text
displayctl list [--json]
displayctl connect <selector>
displayctl connect all
displayctl disconnect <selector>
displayctl brightness get <selector>
displayctl brightness set <selector> <0...100>
```

Brightness commands accept external displays only in Phase 1.

### 7.2 Output

Human-readable output is concise and suitable for interactive terminal use. JSON output is initially required for `list` and uses stable field names so later phases and scripts can consume it.

Mutation commands print the resolved display identity and verified resulting state. Errors are written to standard error and use nonzero exit codes.

### 7.3 Recovery command

`displayctl connect all` attempts to enable every online soft-disabled display, plus every ledger entry (§6.3.1), including entries macOS no longer lists as online. It reports each result independently and returns failure if any requested reconnection fails.

This command does not bypass symbol availability checks. It never invents runtime IDs: the only offline displays it targets are those recorded in the ledger.

## 8. Safety and Error Handling

The core distinguishes at least these failure categories:

- Invalid arguments.
- Display not found.
- Ambiguous display selector.
- Invalid state transition.
- Last-active-display protection.
- Required private API unavailable.
- Core Graphics transaction failure.
- Postcondition verification failure.
- DDC service not found.
- Ambiguous DDC service match.
- DDC unsupported.
- DDC timeout or transport failure.
- DDC response or checksum failure.

Safety rules:

- Never disconnect the last active display.
- Serialize display connection operations across CLI processes so concurrent commands cannot bypass last-display validation.
- Never expose a force override in Phase 1.
- Never send DDC traffic to an ambiguous service match.
- Never report success until the requested state is verified.
- Never substitute software dimming for hardware brightness.
- Use bounded retries so a non-responsive monitor cannot hang the CLI indefinitely.

## 9. Testing

### 9.1 Automated tests

Hardware boundaries are expressed as protocols so ordinary tests use deterministic fakes.

Automated coverage includes:

- Internal/external display classification.
- Stable and convenience selector resolution.
- Ambiguous selector rejection.
- Last-active-display protection.
- Valid connection-state transitions.
- Transaction cancellation on failure.
- Postcondition verification.
- DDC request packet encoding and checksums.
- DDC response parsing and checksums.
- DDC service scoring, thresholds, and ambiguity rejection.
- Retry bounds and timeout mapping.
- CLI argument validation.
- Human-readable and JSON list formatting.

### 9.2 Opt-in hardware integration tests

Hardware tests must be explicitly invoked and must identify potentially disruptive operations before running.

The M5/Tahoe 26.5 validation matrix includes:

1. List the internal and HDMI displays with stable identities.
2. Read HDMI display brightness if the monitor supports read-back.
3. Set HDMI display brightness and verify the physical monitor changes.
4. Disconnect and reconnect the external display.
5. With the external display active, disconnect and reconnect the internal display.
6. Verify refusal to disconnect the final active display.
7. Run the DDC checks over USB-C and record supported or unsupported status.
8. Check whether logout/login restores a disabled display. On macOS 27 it does not (D-008).

The hardware test starts with the internal display. The external display follows only after a separate opt-in (D-006).

Before each session-scoped disconnect, the hardware test arms a watchdog that runs detached from the test's foreground flow, so it fires even when the user cannot type. The watchdog runs the disconnect as its own child, so it knows when the change has finished and can stop it at a deadline. Once it fires, no further disconnect runs in that test. It stays armed until the test has restored and verified the original set of active displays. If the user has not confirmed within the timeout (default 20 s), it retries `displayctl connect all` until that set is active again or a hard deadline passes, and the test stops; another disconnect needs a fresh opt-in. The internal display is tested before the external one, and every external disable, including test setup, needs the internal pass and an explicit opt-in (D-003, D-004).

Tests must restore the initial display state when possible. Failures must print manual recovery instructions, led by `displayctl connect all` (D-008).

## 10. Phase Roadmap

### 10.1 Phase 1 — CLI hardware validation

Deliver the inventory, selector, connection controller, external DDC brightness controller, CLI, automated tests, and opt-in hardware tests described above.

A stabilization checkpoint follows Phase 1. Private APIs and both connection types are assessed before Phase 2 begins.

### 10.2 Phase 2 — Keyboard brightness agent

Add a background agent that:

- Starts automatically for the logged-in user.
- Requests Accessibility permission.
- Observes brightness-key events.
- Determines which display contains the mouse pointer.
- Consumes brightness events only when the pointer is on a supported external display.
- Adjusts that display through `DisplayControlCore`.
- Allows events to pass through unchanged when the pointer is on the internal display.
- Shows appropriate feedback without coupling key handling to DDC transport internals.
- Observes physical and logical display reconfiguration events independently of keyboard handling.
- When the active-display count reaches zero after a physical display removal, reconnects every physically present display that is currently soft-disconnected.
- Verifies that at least one display became active and records a clear diagnostic if macOS exposes no recoverable display.

The recovery path requires no Accessibility permission. It must run on the agent's startup as well as after display reconfiguration events so launchd restart can recover from an earlier agent failure. Recovery is limited to the zero-active-display condition; it does not override intentional display choices while any display remains active.

Phase 2 automated tests must cover zero-active-display detection, startup reconciliation, reconnection of all recoverable displays, and the no-op path while any display remains active. Its hardware acceptance test must soft-disconnect the internal display, physically remove the last active external display, and verify that the internal display becomes active without user intervention.

Phase 2 requires its own approved implementation-plan section before implementation.

### 10.3 Phase 3 — Menu-bar application

Add a native menu-bar application that:

- Lists online and active displays.
- Provides per-display connect and disconnect controls.
- Provides hardware brightness controls for supported external displays.
- Surfaces errors and unsupported states clearly.
- Reuses `DisplayControlCore` and the Phase 2 background behavior.

Phase 3 may add launch-at-login behavior after explicit design approval. It requires its own approved implementation-plan section before implementation.

## 11. Distribution and Compatibility

The first version is locally built and installed for personal use. Open-source distribution may be considered later.

Before wider distribution, the project must add:

- A supported macOS version matrix.
- Compatibility checks against each targeted macOS release.
- Clear disclosure of private API usage and resulting compatibility risk.
- Signing and notarization validation.
- License attribution for any incorporated open-source implementation material.

Mac App Store distribution is not a design goal because the required private APIs are incompatible with normal App Store expectations.

## 12. Guardrails

- Phase 1 implementation is expected to add more than five files. Human approval is required after reviewing `implementation-plan.md` and before implementation begins.
- Any public API, architecture, dependency, storage-format, or scope change requires a design and plan update before code changes.
- Refactoring unrelated code is out of scope.
- Phase 2 and Phase 3 must not begin during Phase 1 implementation or stabilization without explicit approval.

## 13. Acceptance Criteria

Phase 1 is complete only when:

- The Swift package builds successfully on the target M5 Mac.
- Automated tests pass.
- The CLI lists both internal and external displays with stable identities.
- The CLI disconnects and reconnects either display while another remains active.
- The CLI refuses to disconnect the last active display.
- The CLI changes the external HDMI monitor's physical brightness through DDC/CI.
- Unsupported USB-C DDC behavior fails clearly without software dimming.
- Missing private APIs fail cleanly without a launch-time crash.
- Hardware test instructions and recovery steps are documented.
- No unrelated files are changed.

## 14. References

- Apple Quartz Display Services: https://developer.apple.com/documentation/coregraphics/quartz-display-services
- Apple display configuration transactions: https://developer.apple.com/library/archive/documentation/GraphicsImaging/Conceptual/QuartzDisplayServicesConceptual/Articles/DisplayTransactions.html
- BetterDisplay feature comparison: https://github.com/waydabber/BetterDisplay/wiki/List-of-free-and-Pro-features
- BetterDisplay direct DDC CLI documentation: https://github.com/waydabber/BetterDisplay/wiki/Integration-features%2C-CLI
- MonitorControl: https://github.com/MonitorControl/MonitorControl
