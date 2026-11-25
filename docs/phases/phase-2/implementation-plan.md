# Phase 2 — Menu bar app Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A menu bar panel with an on/off switch per display, a DDC brightness slider for external displays, and a zero-active-display safety net, run as a per-user launchd agent.

**Architecture:** `DisplayControlCore` gains `recoverIfNoneActive()` and `ZeroActiveRecovery`/`RecoveryScheduler` (UI-free). A new library `DisplayMenuKit` holds the panel state model, a serial blocking-work executor and the brightness coalescer behind small protocols, so it is unit-tested with fakes. A thin executable `displayctl-menu` holds the SwiftUI `MenuBarExtra`, the Core Graphics and wake observers, and the live adapters.

**Tech Stack:** Swift 6.4.2, SwiftUI `MenuBarExtra` (`.window` style), AppKit, Observation, XCTest, launchd. No new dependencies.

**Spec:** `docs/phases/phase-2/design.md` (amended after `reviews/design-codex.md`)

## Global Constraints

- Platform macOS 27.0.1 on Apple Silicon; `Package.swift` keeps `platforms: [.macOS(.v26)]`.
- No new third-party dependencies; `swift format lint --recursive --strict Sources Tests Package.swift` stays clean (Xcode's bundled `swift format`).
- The CLI (`Sources/displayctl`) is unchanged; `connectAll()` keeps its behaviour.
- One ledger and one lock shared with the CLI: `ConnectionController` with `DisplayControlState.defaultDirectory`.
- Blocking core calls never run on the main thread or Swift's cooperative pool; they run on one serial `DispatchQueue` (design §5).
- launchd label `com.github.duncandoyle.displayctl-menu`; binary `~/.local/bin/displayctl-menu`.
- Safety-net defaults: settle 2 s; 3 attempts per episode, 2 s apart; 5 snapshot samples, 2 s apart.
- Logging: `os.Logger(subsystem: "displayctl", category: "recovery")` and `category: "menu"`.
- Copy: caption `"Only active display"`; busy `"Busy — another displayctl is running. Try again."`; ledger note `"Saved display list unreadable. See README › Recovery."`; observer failure `"Safety net off: display changes are not being watched."`.
- Scratch files only under `.agents-tmp/`. Tests are deterministic: fakes and controllable sleepers, no wall-clock waits.
- No Phase 2 code lands on `main` before Phase 1 closes (D-009). Work on branch `duncandoyle/menuBar`.

## Review Focus

1. **CLI holds the lock when a switch is flipped** → busy text under the row, switch shows the real state. Test in Task 3.
2. **A display disappears while the panel is open, mid-operation or mid-drag** → its row, error and pending brightness are dropped; no write reaches another monitor. Tests in Tasks 3 and 4.
3. **Ledger unreadable** → panel lists online displays with the ledger note, file untouched; recovery logs the outcome and still tries online displays. Tests in Tasks 2 and 3.
4. **Safety net while a CLI command holds the lock, or a CLI `connect` wins the lock first** → lock timeout counts as a failed attempt; after the CLI connect, recovery enables nothing. Tests in Task 2.
5. **Recovery's own enable triggers a reconfiguration callback and then fails** → the episode still ends after 3 attempts; no new episode until wake or an active display. Test in Task 2.

---

### Task 1: Spike — `MenuBarExtra` from a bare executable under launchd

Throwaway. Answers design §9's open question before the real target exists.

**Files:**
- Create: `.agents-tmp/menubar-spike/Package.swift`, `.agents-tmp/menubar-spike/Sources/Spike/main.swift`, `.agents-tmp/menubar-spike/spike.plist`
- Modify: `docs/phase-status.md` (Notes line with the result)

- [ ] **Step 1:** Write a minimal SwiftUI `App` with one `MenuBarExtra("Spike", systemImage: "display") { Toggle("Test", isOn: $on).toggleStyle(.switch); Slider(value: $v); Text(openCount) }.menuBarExtraStyle(.window)`, accessory activation policy, and an `.onAppear` that increments `openCount`.
- [ ] **Step 2:** `swift build -c release --package-path .agents-tmp/menubar-spike` → exit 0.
- [ ] **Step 3:** Run the binary from Terminal. Ask the user: icon visible, panel opens with switch and slider, no Dock icon, and the counter goes up on each close and reopen?
- [ ] **Step 4:** Load it with a LaunchAgent (label `com.github.duncandoyle.displayctl-menu-spike`, keys as design §6.4) via `launchctl bootstrap gui/$(id -u) <plist>`. Ask the same questions. Then `launchctl bootout gui/$(id -u)/com.github.duncandoyle.displayctl-menu-spike` and remove the plist.
- [ ] **Step 5:** If either run fails, wrap the binary in `Spike.app/Contents/{MacOS/Spike,Info.plist}` with `LSUIElement = true`, point `ProgramArguments` at `Contents/MacOS/Spike`, and repeat Steps 3–4.
- [ ] **Step 6:** If the bundle also fails, stop and ask the owner which requirement changes (design §9).
- [ ] **Step 7:** Record the outcome in `docs/phase-status.md` Notes; if the bundle was needed, add D-010 and Task 6 builds the bundle. Commit.

---

### Task 2: Safety net in `DisplayControlCore`

**Files:**
- Modify: `Sources/DisplayControlCore/ConnectionController.swift` (add `recoverIfNoneActive()`; `connectAll()` and it share one private body)
- Create: `Sources/DisplayControlCore/ZeroActiveRecovery.swift`
- Test: `Tests/DisplayControlCoreTests/ConnectionControllerTests.swift`, `Tests/DisplayControlCoreTests/ZeroActiveRecoveryTests.swift`

**Interfaces:**
- Consumes: `DisplaySnapshotProviding`, `DisplayConnectionOutcome`, existing `connectAll` body
- Produces:
```swift
extension ConnectionController {
  /// Under the operation lock: nil if any display is online and active; otherwise connectAll's outcomes.
  public func recoverIfNoneActive() throws -> [DisplayConnectionOutcome]?
}

public protocol RecoveryConnecting: Sendable {
  func recoverIfNoneActive() throws -> [DisplayConnectionOutcome]?
}
extension ConnectionController: RecoveryConnecting {}

public enum RecoveryOutcome: Equatable, Sendable {
  case displayActive               // nothing done
  case recovered(attempts: Int)    // a snapshot shows an active display afterwards
  case failed(attempts: Int)       // still none active after maxAttempts
  case snapshotUnavailable         // maxSnapshotAttempts samples all threw
}

public struct ZeroActiveRecovery: Sendable {
  public init(snapshot: any DisplaySnapshotProviding, connector: any RecoveryConnecting,
              sleep: @escaping @Sendable (Duration) async -> Void,
              retryDelay: Duration = .seconds(2), maxAttempts: Int = 3,
              maxSnapshotAttempts: Int = 5,
              log: @escaping @Sendable (String) -> Void = { _ in })
  public func run() async -> RecoveryOutcome
}

public enum RecoveryTrigger: Sendable { case launch, reconfiguration, wake }

/// Debounces triggers (settle), runs one episode at a time, and enforces the episode rule:
/// after .failed or .snapshotUnavailable, only .wake or a snapshot with an active display re-arms it.
public actor RecoveryScheduler {
  public init(recovery: ZeroActiveRecovery, snapshot: any DisplaySnapshotProviding,
              settle: Duration = .seconds(2),
              sleep: @escaping @Sendable (Duration) async throws -> Void,
              onOutcome: @escaping @Sendable (RecoveryOutcome) -> Void = { _ in })
  public func trigger(_ trigger: RecoveryTrigger)
}
```
`ZeroActiveRecovery` and `RecoveryScheduler` call the blocking connector and snapshot through the caller-supplied types; the app wraps them in the serial executor (Task 3), tests use fakes.

- [ ] **Step 1: Write failing `ConnectionControllerTests`** (existing `FakeDisplayStore`, `makeController`):
  - `testRecoverIfNoneActiveReturnsNilWhenADisplayIsActive` → `nil`, no hardware requests.
  - `testRecoverIfNoneActiveEnablesLedgerAndOnlineInactiveAtZero` → outcomes for each; requests enable both.
  - `testRecoverAfterCLIConnectWinsLockEnablesNothing` → the fake lock runs a `connect("1")` first (store now has 1 active), then the recovery body → `nil`; display 2 stays inactive.
- [ ] **Step 2: Write failing `ZeroActiveRecoveryTests`** (fakes: `ScriptedSnapshot` with queued `[Display]` or errors; `FakeConnector` with scripted returns/throws and a call count; `ManualSleeper` recording durations and suspending until `advance()`):
  - `testDisplayActiveWhenConnectorReturnsNil` → `.displayActive`.
  - `testRecoveredWhenSnapshotShowsActiveAfterAttempt` → `.recovered(attempts: 1)`.
  - `testReturnedFailuresAreLoggedIncludingLedgerOutcome` → connector returns `[failure(.recoverySkipped("earlier boot")), DisplayConnectionOutcome(display: nil, result: .failure(.configurationFailed("ledger unreadable")))]` → log lines contain `"earlier boot"` and `"ledger unreadable"`.
  - `testPartialRecoveryCountsAsRecovered` → one success, one failure, snapshot shows active → `.recovered(attempts: 1)`, failure logged.
  - `testLockTimeoutCountsAsFailedAttemptAndRetries` → throws `.configurationFailed("flock timed out …")` twice then succeeds → `.recovered(attempts: 3)`, sleeps `[.seconds(2), .seconds(2)]`.
  - `testGivesUpAfterMaxAttempts` → `.failed(attempts: 3)`, connector calls 3.
  - `testInconsistentSnapshotResampledAfterDelay` → snapshot throws `"Display inventory changed while sampling; retry"` twice, then shows active → `.recovered`, sleeps include two `.seconds(2)`.
  - `testSnapshotUnavailableAfterFiveSamples` → `.snapshotUnavailable`.
- [ ] **Step 3: Write failing `RecoverySchedulerTests`** (same file):
  - `testTriggersInSettleWindowCoalesce` → three triggers → one run.
  - `testTriggerDuringRunSchedulesOneMore` → exactly two runs.
  - `testFailedEpisodeIgnoresReconfigurationTriggers` → episode `.failed`; then `.reconfiguration` while still zero active → no run.
  - `testFailedEpisodeRearmsOnWake` → `.wake` → one new run.
  - `testFailedEpisodeRearmsAfterActiveSnapshot` → `.reconfiguration` with a snapshot showing active → re-armed; a later zero-active trigger runs.
- [ ] **Step 4:** `swift test --scratch-path .agents-tmp/build --filter "ZeroActiveRecoveryTests|ConnectionControllerTests"` → the new tests FAIL.
- [ ] **Step 5:** Implement. Active means `isOnline && isActive`. A thrown connector error is logged and counts as an attempt.
- [ ] **Step 6:** Filter → PASS; full `swift test --parallel --scratch-path .agents-tmp/build` → PASS; lint → exit 0.
- [ ] **Step 7:** Commit: `feat(core): zero-active-display recovery under the operation lock`.

---

### Task 3: `DisplayMenuKit` — executor, rows and switching

**Files:**
- Modify: `Package.swift` (library `DisplayMenuKit` → `DisplayControlCore`; test target `DisplayMenuKitTests`)
- Create: `Sources/DisplayMenuKit/BlockingExecutor.swift`, `Sources/DisplayMenuKit/DisplayOperating.swift`, `Sources/DisplayMenuKit/PanelRows.swift`, `Sources/DisplayMenuKit/PanelModel.swift`, `Sources/DisplayMenuKit/ErrorText.swift`
- Test: `Tests/DisplayMenuKitTests/PanelRowsTests.swift`, `Tests/DisplayMenuKitTests/PanelModelTests.swift`

**Interfaces:**
- Consumes: `Display`, `DisabledDisplayEntry`, `DisplayControlError`, `ConnectionController`
- Produces:
```swift
/// Runs blocking work on one serial DispatchQueue and resumes the caller with the result.
public final class BlockingExecutor: Sendable {
  public init(label: String = "displayctl.blocking")
  public func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T
}

public protocol DisplayOperating: Sendable {   // async; live adapter uses BlockingExecutor
  func snapshot() async throws -> [Display]
  func disabledDisplays() async throws -> [DisabledDisplayEntry]
  func connect(_ uuid: UUID) async throws -> Display
  func disconnect(_ uuid: UUID) async throws -> Display
}

public protocol BrightnessOperating: Sendable {  // used from Task 4
  func percent(for uuid: UUID) async throws -> Int            // resolves the UUID in a fresh snapshot
  func set(_ percent: Int, for uuid: UUID) async throws        // drops if not online and active
}

public struct DisplayRow: Equatable, Identifiable, Sendable {
  public let id: UUID, name: String, kind: DisplayKind
  public let isOn: Bool, isSwitchEnabled: Bool, isBusy: Bool
  public let caption: String?, error: String?
  public let showsBrightness: Bool  // external, online, active, ddcCapability != .unsupported
}

public enum PanelRows {
  public static func make(displays: [Display], ledger: [DisabledDisplayEntry],
                          busy: UUID?, errors: [UUID: String]) -> [DisplayRow]
}

public enum ErrorText { public static func short(_ error: any Error) -> String }

@MainActor @Observable
public final class PanelModel {
  public init(operations: any DisplayOperating, brightness: any BrightnessOperating)
  public private(set) var rows: [DisplayRow]
  public private(set) var panelNote: String?     // ledger note
  public var safetyNetNote: String?               // set by the app on observer failure
  public private(set) var isBusy: Bool
  public func panelOpened() async                  // clears errors, then refresh
  public func refresh() async                      // keeps errors
  public func setDisplay(_ id: UUID, on: Bool) async
}
```
`ErrorText.short`: `.lastActiveDisplay` → `"Cannot turn off the only active display"`; `.configurationFailed` starting with `"flock timed out"` → busy text; other `DisplayControlError` → its message (fixed short phrase for cases without one); others → `localizedDescription`.

Ordering rule (design §6.1): every `refresh` and `setDisplay` takes `seq += 1` at start; its result is applied only if `seq > appliedSeq`, then `appliedSeq = seq`.

- [ ] **Step 1: Write failing `PanelRowsTests`:** `testBuiltInFirstThenExternalsByName`, `testLedgerOnlyDisplayIsAnOffRow`, `testOnlineDisplayWinsOverItsLedgerEntry`, `testOnlyActiveDisplaySwitchDisabledWithCaption`, `testAllSwitchesDisabledWhileBusy`, `testShowsBrightnessOnlyForActiveExternalNotUnsupported`.
- [ ] **Step 2: Write failing `PanelModelTests`** (fake `DisplayOperating` with scripted results and per-call gates):
  - `testRefreshBuildsRows`
  - `testTurnOffCallsDisconnectThenRefreshes`
  - `testLockTimeoutShowsBusyTextAndRealState`
  - `testErrorClearsOnNextSuccessForThatDisplay`
  - `testBackgroundRefreshKeepsErrorPanelOpenedClearsIt`
  - `testSecondClickWhileBusyIsIgnored` → exactly one controller call.
  - `testStaleRefreshCannotOverwriteNewerOperation` → start refresh A (gated), run `setDisplay` to completion, release A with old data → rows and errors are from the operation.
  - `testUnreadableLedgerShowsNoteAndOnlineRows` → `panelNote == "Saved display list unreadable. See README › Recovery."`.
  - `testRowDisappearsAfterUnplugDuringOperation`
- [ ] **Step 3: Write failing `BlockingExecutorTests`:** `testRunsWorkOffMainThread` (work records `Thread.isMainThread == false`), `testRunsSerially` (two overlapping calls never overlap: an atomic in-flight counter never exceeds 1), `testPropagatesThrow`.
- [ ] **Step 4:** `swift test --scratch-path .agents-tmp/build --filter DisplayMenuKitTests` → FAIL.
- [ ] **Step 5:** Implement. `BlockingExecutor` uses `withCheckedThrowingContinuation` + `queue.async`.
- [ ] **Step 6:** Filter → PASS; full suite → PASS; lint → exit 0.
- [ ] **Step 7:** Commit: `feat(menu): panel rows, ordered refreshes and display switching`.

---

### Task 4: `DisplayMenuKit` — brightness

**Files:**
- Create: `Sources/DisplayMenuKit/BrightnessCoalescer.swift`
- Modify: `Sources/DisplayMenuKit/PanelModel.swift`
- Test: `Tests/DisplayMenuKitTests/BrightnessCoalescerTests.swift`, `Tests/DisplayMenuKitTests/PanelModelBrightnessTests.swift`

**Interfaces:**
- Consumes: `BrightnessOperating` (Task 3), `PanelModel` rows
- Produces:
```swift
/// One write in flight; newest pending value written after it; last submitted value always written;
/// after invalidate(), pending values are discarded and late results ignored.
public actor BrightnessCoalescer {
  public init(write: @escaping @Sendable (Int) async throws -> Void,
              onError: @escaping @Sendable (String?) -> Void)   // nil clears
  public func submit(_ percent: Int)
  public func invalidate()
}

public struct BrightnessState: Equatable, Sendable {
  public let percent: Int?      // nil until a read succeeds → label "—"
  public let sliderValue: Int   // last known this run, else 50
  public let error: String?
}

extension PanelModel {
  public func brightness(for id: UUID) -> BrightnessState?
  public func setBrightness(_ percent: Int, for id: UUID)
}
```
`PanelModel` reads brightness for a row when the panel opens and whenever a refresh makes a row newly `showsBrightness`. When a row leaves or stops showing brightness, its coalescer is invalidated and dropped. The live adapter (Task 5) converts `DDCValue` to percent and throws `.ddcInvalidResponse("maximum is 0")` when `maximum == 0`.

- [ ] **Step 1: Write failing `BrightnessCoalescerTests`** (write fake suspends until released):
  - `testFirstValueWrittenImmediately`
  - `testValuesDuringInFlightWriteCollapseToNewest` → writes `[10, 30]`.
  - `testSameValueAfterInFlightIsNotRewritten` → writes `[10]`.
  - `testFailedWriteReportsErrorAndNextSubmitWrites`
  - `testInvalidateDropsPendingAndIgnoresLateResult` → submit 10 (held), submit 20, `invalidate()`, release → writes `[10]` only; no `onError` call after invalidate.
- [ ] **Step 2: Write failing `PanelModelBrightnessTests`:**
  - `testOpeningReadsOnlyBrightnessRowsAndNeverWrites`
  - `testReadFailureShowsDashAndSliderAtFifty`
  - `testNewlyEligibleRowIsReadWhileOpen` → panel opened, Dell off; refresh turns it on → one read for it.
  - `testDisplayLeavingInvalidatesPendingWrite` → held write + pending value; refresh without the UUID → no further write; `brightness(for:)` is nil.
- [ ] **Step 3:** Filter → FAIL. **Step 4:** Implement. **Step 5:** Filter, full suite → PASS; lint → exit 0.
- [ ] **Step 6:** Commit: `feat(menu): brightness slider with coalesced, invalidatable DDC writes`.

---

### Task 5: `displayctl-menu` app

**Files:**
- Modify: `Package.swift` (executable product `displayctl-menu`, target `DisplayMenuApp` → `DisplayMenuKit`); `Sources/DisplayControlCore/DisplayInventory.swift` (`localizedNames` hops to the main thread with `DispatchQueue.main.sync` when `!Thread.isMainThread`)
- Create: `Sources/DisplayMenuApp/DisplayMenuApp.swift`, `Sources/DisplayMenuApp/PanelView.swift`, `Sources/DisplayMenuApp/LiveAdapters.swift`, `Sources/DisplayMenuApp/SystemObservers.swift`
- Test: `Tests/DisplayMenuKitTests/LiveBrightnessConversionTests.swift` (percent conversion lives in `DisplayMenuKit` as `BrightnessPercent.from(_ value: DDCValue) throws -> Int`)

- [ ] **Step 1: Write failing `LiveBrightnessConversionTests`:** `testRoundsToPercent` (`DDCValue(current: 50, maximum: 200)` → 25), `testZeroMaximumThrows` → `.ddcInvalidResponse("maximum is 0")`. Run → FAIL; implement `BrightnessPercent.from`; run → PASS.
- [ ] **Step 2:** `LiveAdapters`: one `BlockingExecutor`; `LiveDisplayOperations` wraps one `ConnectionController(snapshot: DisplayInventory(), hardware: CoreGraphicsDisplayConnectionHardware())` with `uuid.uuidString` selectors; `LiveBrightness` resolves the UUID in a fresh `DisplayInventory().snapshot()`, drops if not online and active, then calls `DDCBrightnessController`. The recovery connector and snapshot given to `ZeroActiveRecovery`/`RecoveryScheduler` also go through the executor.
- [ ] **Step 3:** `SystemObservers`: registers `CGDisplayRegisterReconfigurationCallback` with a context object retained for the process lifetime; the callback ignores begin-flag events and hands the rest to `Task { @MainActor in … }` → `scheduler.trigger(.reconfiguration)` and `model.refresh()`. A non-success `CGError` → log and set `model.safetyNetNote`. `NSWorkspace.shared.notificationCenter` `didWakeNotification` → `trigger(.wake)` + `refresh()`. On launch → `trigger(.launch)`.
- [ ] **Step 4:** `PanelView` per design §6.1–6.2: header "Displays"; rows (name, `Toggle(.switch)`, `ProgressView` when busy, caption and error as secondary text); `Slider(0...100, step: 1)` with "—"/percent for `showsBrightness` rows; `panelNote` and `safetyNetNote` lines; divider; "Quit" → `exit(0)`. `.onAppear { await model.panelOpened() }`. Icon `display`.
- [ ] **Step 5:** `swift build -c release --scratch-path .agents-tmp/build` → exit 0; full suite → PASS; lint → exit 0.
- [ ] **Step 6:** Run `.agents-tmp/build/release/displayctl-menu` with the user: icon shows, panel lists both displays, switches reflect state. Quit.
- [ ] **Step 7:** Commit: `feat(menu): displayctl-menu app`.

---

### Task 6: Install, uninstall and README

**Files:**
- Create: `Scripts/install-menu.sh`, `Scripts/uninstall-menu.sh`, `Scripts/com.github.duncandoyle.displayctl-menu.plist` (template; `__BINARY__` replaced at install)
- Modify: `README.md` ("Menu bar app": install, uninstall, Quit and restart via `launchctl kickstart gui/$(id -u)/com.github.duncandoyle.displayctl-menu`, logs via `log show --predicate 'subsystem == "displayctl"' --last 1h`; Recovery: how to inspect an unreadable ledger and when `forget all` is safe)

- [ ] **Step 1:** `install-menu.sh` (bash 3.2, `set -euo pipefail`): release build, copy to `~/.local/bin/displayctl-menu`, render the plist into `~/Library/LaunchAgents/`, `bootout` an old instance (ignore "not loaded"), `bootstrap gui/$(id -u)`. Bundle instead if Task 1 required it.
- [ ] **Step 2:** `uninstall-menu.sh`: `bootout`, remove the plist; keep the binary and the ledger.
- [ ] **Step 3:** `bash -n` both → exit 0; `plutil -lint` the rendered plist → OK.
- [ ] **Step 4:** Run `install-menu.sh`; `launchctl print gui/$(id -u)/com.github.duncandoyle.displayctl-menu` shows `state = running`.
- [ ] **Step 5:** Commit: `feat(menu): launchd install and docs`.

---

### Task 7: Hardware validation

**Files:**
- Create: `Scripts/menu-fallback.sh` (detached fallback: optional `kickstart` at N s, `displayctl connect all` at 30 s, logs to `.agents-tmp/`)
- Modify: `README.md` (Phase 2 results checklist, dated), `docs/phase-status.md`

- [ ] **Step 1:** Write `menu-fallback.sh`: `nohup`/`setsid`-style detach (as the Phase 1 watchdog), args `--kickstart-after <s>` (optional) and `--connect-all-after 30`, timestamps each action. `bash -n` → exit 0. Dry-run it with the Dell attached and both displays on: it logs a no-op `connect all`.
- [ ] **Step 2:** With the user, run design §8 hardware steps 1–12 in order. Before steps 9–11, start `menu-fallback.sh`.
- [ ] **Step 3:** Step 7: `launchctl kill SIGKILL gui/$(id -u)/com.github.duncandoyle.displayctl-menu`; `launchctl print` shows a new PID within 15 s.
- [ ] **Step 4:** Steps 9–11: save `log show --predicate 'subsystem == "displayctl" AND category == "recovery"' --last 10m` and the fallback log into `.agents-tmp/`; record whether the app (≤ 10 s) or the fallback restored the display.
- [ ] **Step 5:** Record each step as observed (date, macOS version) or failed with evidence. An unrun step is not a pass.
- [ ] **Step 6:** Commit: `docs: Phase 2 hardware results`.
