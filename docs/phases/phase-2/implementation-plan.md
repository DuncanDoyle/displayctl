# Phase 2 — Menu bar app Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A menu bar panel with an on/off switch per display, a DDC brightness slider for external displays, and a zero-active-display safety net, run as a per-user launchd agent.

**Architecture:** `DisplayControlCore` gains `ZeroActiveRecovery` (UI-free). A new library `DisplayMenuKit` holds the panel state model and brightness coalescer behind small protocols, so it is unit-tested with fakes. A thin executable `displayctl-menu` holds the SwiftUI `MenuBarExtra`, the Core Graphics and wake observers, and the live adapters.

**Tech Stack:** Swift 6.4.2, SwiftUI `MenuBarExtra` (`.window` style), AppKit, Observation, XCTest, launchd. No new dependencies.

**Spec:** `docs/phases/phase-2/design.md`

## Global Constraints

- Platform macOS 27.0.1 on Apple Silicon; `Package.swift` keeps `platforms: [.macOS(.v26)]`.
- No new third-party dependencies; `swift format lint --recursive --strict Sources Tests Package.swift` stays clean (Xcode's bundled `swift format`).
- The CLI (`Sources/displayctl`) is unchanged.
- One ledger and one lock shared with the CLI: `ConnectionController` with `DisplayControlState.defaultDirectory`.
- launchd label `com.github.duncandoyle.displayctl-menu`; binary `~/.local/bin/displayctl-menu`.
- Safety-net defaults: settle 2 s, 3 recovery attempts 2 s apart.
- Logging: `os.Logger(subsystem: "displayctl", category: "recovery")` and `category: "menu"`.
- Scratch files only under `.agents-tmp/`. Tests are deterministic: fakes and controllable sleepers, no wall-clock waits.
- No Phase 2 code lands on `main` before Phase 1 closes (D-009). Work on branch `duncandoyle/menuBar`.

## Review Focus

1. **CLI holds the lock when a switch is flipped** → the row shows "Busy — another displayctl is running. Try again." and the switch shows the real state, not the requested one. Test in Task 3.
2. **A display disappears while the panel is open or mid-operation** (unplug) → the next refresh drops its row and any brightness state; no stale error or crash. Test in Task 3 and Task 4.
3. **Ledger unreadable** (corrupt JSON) → the panel still lists online displays and shows one panel-level line naming `displayctl forget all`; the safety net still runs `connectAll`. Tests in Task 2 and Task 3.
4. **Safety net fires while a CLI disconnect holds the lock** → `connectAll` throws a lock timeout; counted as a failed attempt and retried, never treated as success. Test in Task 2.
5. **A second click while an operation runs** → ignored; exactly one controller call. Test in Task 3.

---

### Task 1: Spike — `MenuBarExtra` from a bare executable under launchd

Throwaway. Answers design §9's open question before the real target exists.

**Files:**
- Create: `.agents-tmp/menubar-spike/Package.swift`, `.agents-tmp/menubar-spike/Sources/Spike/main.swift`, `.agents-tmp/menubar-spike/spike.plist`
- Modify: `docs/phase-status.md` (Notes line with the result)

- [ ] **Step 1:** Write a minimal SwiftUI `App` with one `MenuBarExtra("Spike", systemImage: "display") { Toggle("Test", isOn: $on).toggleStyle(.switch); Slider(value: $v) }.menuBarExtraStyle(.window)`, setting `NSApplication.shared.setActivationPolicy(.accessory)` at launch.
- [ ] **Step 2:** `swift build -c release --package-path .agents-tmp/menubar-spike` → exit 0.
- [ ] **Step 3:** Run the binary directly from Terminal. Ask the user: icon visible, panel opens with a switch and slider, no Dock icon?
- [ ] **Step 4:** Load it with a LaunchAgent plist (label `com.github.duncandoyle.displayctl-menu-spike`, keys as design §6.4, plist copied to `~/Library/LaunchAgents/`) via `launchctl bootstrap gui/$(id -u) <plist>`. Ask the user the same question. Then `launchctl bootout gui/$(id -u)/com.github.duncandoyle.displayctl-menu-spike` and remove the plist.
- [ ] **Step 5:** If either run fails, wrap the binary in `Spike.app/Contents/{MacOS/Spike,Info.plist}` with `LSUIElement = true` and repeat Step 4 pointing `ProgramArguments` at `Contents/MacOS/Spike`.
- [ ] **Step 6:** Record the outcome in `docs/phase-status.md` Notes. If the bundle was needed, add D-010 and change Task 6 to build the bundle. Commit the status change only.

---

### Task 2: `ZeroActiveRecovery` in `DisplayControlCore`

Refinement of design §6.3 step 4, made here and written back to the design in this task: at zero active displays the app runs `connectAll` whether or not the ledger reads; `connectAll` already handles online inactive displays and reports an unreadable ledger.

**Files:**
- Create: `Sources/DisplayControlCore/ZeroActiveRecovery.swift`
- Test: `Tests/DisplayControlCoreTests/ZeroActiveRecoveryTests.swift`
- Modify: `docs/phases/phase-2/design.md` §6.3 step 4

**Interfaces:**
- Consumes: `DisplaySnapshotProviding.snapshot()`, `ConnectionController.connectAll() throws -> [DisplayConnectionOutcome]`
- Produces:
```swift
public protocol RecoveryConnecting: Sendable {
  func connectAll() throws -> [DisplayConnectionOutcome]
}
extension ConnectionController: RecoveryConnecting {}

public enum RecoveryOutcome: Equatable, Sendable {
  case displayActive                 // nothing done
  case nothingToRecover              // zero active, connectAll returned no outcomes
  case recovered(attempts: Int)      // at least one display active afterwards
  case failed(attempts: Int)         // still zero active after maxAttempts
  case snapshotUnavailable           // every snapshot attempt threw
}

public struct ZeroActiveRecovery: Sendable {
  public init(
    snapshot: any DisplaySnapshotProviding,
    connector: any RecoveryConnecting,
    sleep: @escaping @Sendable (Duration) async -> Void,
    retryDelay: Duration = .seconds(2),
    maxAttempts: Int = 3,
    maxSnapshotAttempts: Int = 5,
    log: @escaping @Sendable (String) -> Void = { _ in }
  )
  public func run() async -> RecoveryOutcome
}

/// Debounces triggers: each trigger restarts the settle wait; one `run()` per quiet period.
/// A run in progress is never cancelled; a trigger during a run schedules one more run after it.
public actor RecoveryScheduler {
  public init(recovery: ZeroActiveRecovery, settle: Duration = .seconds(2),
              sleep: @escaping @Sendable (Duration) async throws -> Void,
              onOutcome: @escaping @Sendable (RecoveryOutcome) -> Void = { _ in })
  public func trigger()
}
```

- [ ] **Step 1: Write the failing tests** (fakes: `ScriptedSnapshot` returning a queued list of `[Display]` or errors; `FakeConnector` recording calls and returning scripted outcomes or throwing; `ManualSleeper` whose `sleep` suspends until the test calls `advance()`):
  - `testDoesNothingWhileAnyDisplayIsActive` → `.displayActive`, connector calls 0.
  - `testRunsConnectAllAtZeroActive` → snapshots [inactive], [active]; outcome `.recovered(attempts: 1)`, connector calls 1.
  - `testNothingToRecoverWhenConnectAllReturnsEmpty` → `.nothingToRecover`, connector calls 1.
  - `testRunsConnectAllWhenLedgerUnreadable` → connector throws `.configurationFailed("ledger…")` on call 1, snapshot then shows active → `.recovered(attempts: 1)`.
  - `testLockTimeoutCountsAsFailedAttemptAndRetries` → connector throws `.configurationFailed("flock timed out …")` twice, then succeeds; outcome `.recovered(attempts: 3)`; sleeps recorded `[.seconds(2), .seconds(2)]`.
  - `testGivesUpAfterMaxAttempts` → always zero active → `.failed(attempts: 3)`, connector calls 3.
  - `testRetriesInconsistentSnapshot` → snapshot throws `"Display inventory changed while sampling; retry"` twice then returns active → `.displayActive`.
  - `testSnapshotUnavailableAfterMaxSnapshotAttempts` → snapshot always throws → `.snapshotUnavailable`, connector calls 0.
  - `testSchedulerCoalescesTriggersInSettleWindow` → three `trigger()` calls before `advance()` → one `run()`.
  - `testSchedulerRunsAgainForTriggerDuringRun` → trigger during a run → exactly two runs.
- [ ] **Step 2:** `swift test --scratch-path .agents-tmp/build --filter ZeroActiveRecoveryTests` → FAIL (types not defined).
- [ ] **Step 3:** Implement in `ZeroActiveRecovery.swift`. Active means `isOnline && isActive`. Snapshot retries need no sleep. A `connectAll` throw is logged and counts as an attempt.
- [ ] **Step 4:** Same command → PASS. Then full `swift test --parallel --scratch-path .agents-tmp/build` → all pass.
- [ ] **Step 5:** Update design §6.3 step 4 to the refinement above. Commit: `feat(core): zero-active-display recovery`.

---

### Task 3: `DisplayMenuKit` — rows and connection switching

**Files:**
- Modify: `Package.swift` (library `DisplayMenuKit` → depends on `DisplayControlCore`; test target `DisplayMenuKitTests`)
- Create: `Sources/DisplayMenuKit/DisplayOperating.swift`, `Sources/DisplayMenuKit/PanelRows.swift`, `Sources/DisplayMenuKit/PanelModel.swift`, `Sources/DisplayMenuKit/ErrorText.swift`
- Test: `Tests/DisplayMenuKitTests/PanelRowsTests.swift`, `Tests/DisplayMenuKitTests/PanelModelTests.swift`

**Interfaces:**
- Consumes: `Display`, `DisabledDisplayEntry`, `DisplayControlError`, `ConnectionController.connect(_:)`, `.disconnect(_:)`, `.disabledDisplays()`
- Produces:
```swift
public protocol DisplayOperating: Sendable {
  func snapshot() throws -> [Display]
  func disabledDisplays() throws -> [DisabledDisplayEntry]
  func connect(_ uuid: UUID) throws -> Display
  func disconnect(_ uuid: UUID) throws -> Display
}

public struct DisplayRow: Equatable, Identifiable, Sendable {
  public let id: UUID
  public let name: String
  public let kind: DisplayKind
  public let isOn: Bool
  public let isSwitchEnabled: Bool
  public let caption: String?       // "Only active display"
  public let error: String?
  public let isBusy: Bool
  public let showsBrightness: Bool  // external, active, ddcCapability != .unsupported
}

public enum PanelRows {
  public static func make(displays: [Display], ledger: [DisabledDisplayEntry],
                          busy: UUID?, errors: [UUID: String]) -> [DisplayRow]
}

public enum ErrorText {
  public static func short(_ error: any Error) -> String
}

@MainActor @Observable
public final class PanelModel {
  public init(operations: any DisplayOperating, brightness: any BrightnessOperating)
  public private(set) var rows: [DisplayRow]
  public private(set) var panelNote: String?   // ledger unreadable
  public private(set) var isBusy: Bool
  public func refresh() async
  public func setDisplay(_ id: UUID, on: Bool) async
}
```
`BrightnessOperating` (signature in Task 4) is declared in this task's `DisplayOperating.swift`, so `PanelModel.init` compiles; Task 4 adds its use.

Copy pinned by the design: caption `"Only active display"`; lock timeout `"Busy — another displayctl is running. Try again."`; ledger note `"Saved display list unreadable. Run: displayctl forget all"`. `ErrorText.short` maps `.lastActiveDisplay` → `"Cannot turn off the only active display"`, a `.configurationFailed` whose message starts with `"flock timed out"` → the busy text, any other `DisplayControlError` → its associated message (or a short fixed phrase for cases without one), other errors → `localizedDescription`.

- [ ] **Step 1: Write the failing `PanelRowsTests`:**
  - `testBuiltInFirstThenExternalsByName`
  - `testLedgerOnlyDisplayIsAnOffRow` (UUID in ledger, not in snapshot → `isOn == false`, `isSwitchEnabled == true`)
  - `testOnlineDisplayWinsOverItsLedgerEntry` (same UUID in both → one row, state from snapshot)
  - `testOnlyActiveDisplaySwitchDisabledWithCaption` → `isSwitchEnabled == false`, `caption == "Only active display"`
  - `testAllSwitchesDisabledWhileBusy` and busy row has `isBusy == true`
  - `testShowsBrightnessOnlyForActiveExternalNotUnsupported`
- [ ] **Step 2: Write the failing `PanelModelTests`** (fake `DisplayOperating` with scripted results and a gate to hold a call open):
  - `testRefreshBuildsRows`
  - `testTurnOffCallsDisconnectThenRefreshes` → calls `[.disconnect(uuid)]`, rows from the post-call snapshot.
  - `testLockTimeoutShowsBusyTextAndRealState` → `disconnect` throws `.configurationFailed("flock timed out acquiring …")`; row error equals the busy text; `isOn` still true.
  - `testErrorClearsOnNextSuccess` and `testErrorClearsOnRefreshAfterReopen` (`refresh()` clears errors).
  - `testSecondClickWhileBusyIsIgnored` → hold the first call at the gate, call `setDisplay` again, release → exactly one controller call.
  - `testUnreadableLedgerShowsNoteAndOnlineRows` → `disabledDisplays()` throws → `panelNote` equals the ledger note; rows from snapshot.
  - `testRowDisappearsAfterUnplugDuringOperation` → operation throws, next snapshot lacks the UUID → no row, no error kept for it.
- [ ] **Step 3:** `swift test --scratch-path .agents-tmp/build --filter DisplayMenuKitTests` → FAIL.
- [ ] **Step 4:** Implement. `PanelModel` runs controller calls with `Task.detached` (they block on the lock) and awaits the result; `isBusy` guards re-entry.
- [ ] **Step 5:** Same filter → PASS; full suite → PASS; `swift format lint …` → exit 0.
- [ ] **Step 6:** Commit: `feat(menu): panel rows and display switching`.

---

### Task 4: `DisplayMenuKit` — brightness

**Files:**
- Create: `Sources/DisplayMenuKit/BrightnessCoalescer.swift`
- Modify: `Sources/DisplayMenuKit/PanelModel.swift`
- Test: `Tests/DisplayMenuKitTests/BrightnessCoalescerTests.swift`, `Tests/DisplayMenuKitTests/PanelModelBrightnessTests.swift`

**Interfaces:**
- Consumes: `DDCBrightnessController.get(display:) -> DDCValue`, `.set(percent:display:)`
- Produces:
```swift
public protocol BrightnessOperating: Sendable {
  func percent(for display: Display) async throws -> Int   // current * 100 / maximum, rounded
  func set(_ percent: Int, for display: Display) async throws
}

/// At most one write in flight; the newest pending value is written after it; the last submitted value is always written.
public actor BrightnessCoalescer {
  public init(write: @escaping @Sendable (Int) async throws -> Void,
              onError: @escaping @Sendable (String?) -> Void)   // nil clears
  public func submit(_ percent: Int)
}

extension PanelModel {
  public func brightness(for id: UUID) -> BrightnessState?
  public func loadBrightness() async          // reads every row with showsBrightness
  public func setBrightness(_ percent: Int, for id: UUID)
}
public struct BrightnessState: Equatable, Sendable {
  public let percent: Int?      // nil until a read succeeds → label "—"
  public let sliderValue: Int   // last known this run, else 50
  public let error: String?
}
```

- [ ] **Step 1: Write the failing `BrightnessCoalescerTests`** (write fake suspends each call until released):
  - `testFirstValueWrittenImmediately`
  - `testValuesDuringInFlightWriteCollapseToNewest` → submit 10; while held submit 20, 30; release twice → writes `[10, 30]`.
  - `testSameValueAfterInFlightIsNotRewritten` → submit 10, submit 10 while held → writes `[10]`.
  - `testFailedWriteReportsErrorAndNextSubmitWrites` → write throws once; `onError` gets a message; submit 40 → writes include 40 and `onError(nil)`.
- [ ] **Step 2: Write the failing `PanelModelBrightnessTests`:**
  - `testLoadReadsOnlyBrightnessRows`
  - `testOpeningNeverWrites` → after `refresh()` + `loadBrightness()` the fake's set calls are 0.
  - `testReadFailureShowsDashAndKeepsSliderAtFifty` → `percent == nil`, `sliderValue == 50`, error set.
  - `testBrightnessStateDroppedWhenDisplayLeaves` → after a refresh without that UUID, `brightness(for:)` is nil.
- [ ] **Step 3:** Run `--filter DisplayMenuKitTests` → FAIL.
- [ ] **Step 4:** Implement. One `BrightnessCoalescer` per display UUID, dropped with its row.
- [ ] **Step 5:** Filter and full suite → PASS; lint → exit 0.
- [ ] **Step 6:** Commit: `feat(menu): brightness slider model with coalesced DDC writes`.

---

### Task 5: `displayctl-menu` app

**Files:**
- Modify: `Package.swift` (executable product `displayctl-menu`, target `DisplayMenuApp` → `DisplayMenuKit`)
- Create: `Sources/DisplayMenuApp/DisplayMenuApp.swift` (`@main` App, `MenuBarExtra` `.window`, accessory policy), `Sources/DisplayMenuApp/PanelView.swift`, `Sources/DisplayMenuApp/LiveAdapters.swift`, `Sources/DisplayMenuApp/SystemObservers.swift`

**Interfaces:**
- Consumes: `PanelModel`, `RecoveryScheduler`, `ZeroActiveRecovery`, `ConnectionController`, `DisplayInventory`, `DDCBrightnessController`
- Produces: the `displayctl-menu` executable.

- [ ] **Step 1:** `LiveDisplayOperations: DisplayOperating` wraps one `ConnectionController(snapshot: DisplayInventory(), hardware: CoreGraphicsDisplayConnectionHardware())`, passing `uuid.uuidString` as the selector. `LiveBrightness: BrightnessOperating` wraps one `DDCBrightnessController()`.
- [ ] **Step 2:** `SystemObservers` registers `CGDisplayRegisterReconfigurationCallback` and acts only on callbacks without `.beginConfigurationFlag`; it also observes `NSWorkspace.didWakeNotification`. Each event calls `scheduler.trigger()` and `await model.refresh()` on the main actor. On launch it calls `scheduler.trigger()` once.
- [ ] **Step 3:** `PanelView` per design §6.1–6.2: header "Displays", one row per `DisplayRow` (name, `Toggle(.switch)` disabled per `isSwitchEnabled`, `ProgressView` when `isBusy`, caption and error as secondary text), a `Slider(0...100, step: 1)` with "—"/percent label for `showsBrightness` rows, `panelNote` if set, divider, "Quit" → `exit(0)`. `.onAppear { refresh(); loadBrightness() }`. Icon `display`.
- [ ] **Step 4:** `swift build -c release --scratch-path .agents-tmp/build` → exit 0; full test suite → PASS; lint → exit 0.
- [ ] **Step 5:** Run `.agents-tmp/build/release/displayctl-menu` from Terminal with the user: icon shows, panel lists both displays, switches reflect state. Quit.
- [ ] **Step 6:** Commit: `feat(menu): displayctl-menu app`.

---

### Task 6: Install, uninstall and README

**Files:**
- Create: `Scripts/install-menu.sh`, `Scripts/uninstall-menu.sh`, `Scripts/com.github.duncandoyle.displayctl-menu.plist` (template; `__BINARY__` replaced at install)
- Modify: `README.md` (new "Menu bar app" section: install, uninstall, Quit and restart with `launchctl kickstart gui/$(id -u)/com.github.duncandoyle.displayctl-menu`, logs via `log show --predicate 'subsystem == "displayctl"' --last 1h`, recovery)

- [ ] **Step 1:** `install-menu.sh` (bash 3.2, `set -euo pipefail`): `swift build -c release`, copy to `~/.local/bin/displayctl-menu`, render the plist into `~/Library/LaunchAgents/`, `launchctl bootout` any old instance (ignore "not loaded"), `launchctl bootstrap gui/$(id -u) <plist>`. Plist keys per design §6.4. If Task 1 needed a bundle, build and install the bundle instead.
- [ ] **Step 2:** `uninstall-menu.sh`: `bootout`, remove the plist; leave the binary and the ledger.
- [ ] **Step 3:** `bash -n` both scripts → exit 0; `plutil -lint` the rendered plist → OK.
- [ ] **Step 4:** Run `Scripts/install-menu.sh`; `launchctl print gui/$(id -u)/com.github.duncandoyle.displayctl-menu` shows `state = running`.
- [ ] **Step 5:** Commit: `feat(menu): launchd install and docs`.

---

### Task 7: Hardware validation

**Files:**
- Modify: `README.md` (Phase 2 results checklist, dated), `docs/phase-status.md`

- [ ] **Step 1:** With the user, run design §8 hardware steps 1–9 in order. Steps 2–3 and 9 disable a display; the Dell stays attached except in step 9, where replugging it is the recovery.
- [ ] **Step 2:** For step 7 run `launchctl kill SIGKILL gui/$(id -u)/com.github.duncandoyle.displayctl-menu`; `launchctl print` shows a new PID within 15 s.
- [ ] **Step 3:** For step 9 also capture `log show --predicate 'subsystem == "displayctl" AND category == "recovery"' --last 10m` into `.agents-tmp/` and quote the outcome line in the README.
- [ ] **Step 4:** Record each step as observed (date, macOS version) or failed with the evidence. An unrun step is not a pass.
- [ ] **Step 5:** Commit: `docs: Phase 2 hardware results`.
