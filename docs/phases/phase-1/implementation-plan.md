# Phase 1 CLI Hardware Validation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a self-contained Swift CLI that lists displays, safely soft-connects and soft-disconnects them, and reads or sets external hardware brightness through DDC/CI on the target M5 Mac running macOS Tahoe 26.5.

**Architecture:** A thin `displayctl` executable calls a reusable `DisplayControlCore` library. Hardware access is hidden behind protocols and dynamically resolved private-API adapters, allowing deterministic tests and clean failure when Tahoe symbols are unavailable.

**Tech Stack:** Swift 6.2 language mode, Swift Package Manager, Foundation, CoreGraphics, AppKit, IOKit, Darwin dynamic loading, XCTest.

---

## Approval Gate

Phase 1 creates more than five files and exceeds the repository change-size guardrail. Do not begin Task 1 until the user explicitly approves this plan and authorizes the planned file count. No public package API, dependency, storage format, or architecture change is authorized beyond this document and `design.md`.

## Scope

This plan implements Phase 1 only. Phase 2 will add the login agent, mouse-targeted keyboard brightness handling, and zero-active-display recovery. Phase 3 will add the menu-bar UI. Neither later phase is implemented by this plan.

## File Map

| Path | Responsibility |
|---|---|
| `Package.swift` | Defines the library, CLI, and test targets without external dependencies. |
| `Sources/DisplayControlCore/Display.swift` | Domain models, capability state, selectors, and stable JSON fields. |
| `Sources/DisplayControlCore/DisplayControlError.swift` | Typed failures and stable CLI exit categories. |
| `Sources/DisplayControlCore/DisplayInventory.swift` | Core Graphics display enumeration and snapshot protocol. |
| `Sources/DisplayControlCore/DisplaySelector.swift` | UUID, runtime-ID, `internal`, and `external` resolution. |
| `Sources/DisplayControlCore/PrivateAPIBridge.swift` | Dynamic symbol loading and typed CGS/IOAV function wrappers. |
| `Sources/DisplayControlCore/ConnectionController.swift` | Safety validation, transactions, cancellation, and postcondition checks. |
| `Sources/DisplayControlCore/DDC.swift` | DDC packet codec, service matching, transport, retries, and brightness API. |
| `Sources/displayctl/main.swift` | Dependency composition, argument parsing, output, and exit codes. |
| `Tests/DisplayControlCoreTests/DisplaySelectorTests.swift` | Selector and display-model tests. |
| `Tests/DisplayControlCoreTests/ConnectionControllerTests.swift` | Connection safety and transaction tests. |
| `Tests/DisplayControlCoreTests/DDCTests.swift` | Codec, matching, retry, and brightness tests. |
| `Tests/displayctlTests/CLIParserTests.swift` | Command parsing and output-contract tests. |
| `Scripts/hardware-test.sh` | Explicit, interactive M5 hardware-validation sequence. |
| `README.md` | Build, usage, private-API warning, test, and recovery instructions. |

## Task 1: Scaffold the Swift Package

**Files:**
- Create: `Package.swift`
- Create: `Sources/DisplayControlCore/Display.swift`
- Create: `Sources/displayctl/main.swift`
- Create: `Tests/DisplayControlCoreTests/DisplaySelectorTests.swift`
- Create: `Tests/displayctlTests/CLIParserTests.swift`

- [ ] **Step 1: Write a failing package smoke test**

Create `Tests/DisplayControlCoreTests/DisplaySelectorTests.swift`:

```swift
import XCTest
@testable import DisplayControlCore

final class DisplaySelectorTests: XCTestCase {
    func testModuleLoads() {
        XCTAssertEqual(DisplayControlCoreVersion.current, "0.1.0")
    }
}
```

- [ ] **Step 2: Run the test and verify the package is absent**

Run: `swift test`

Expected: failure because `Package.swift` and `DisplayControlCoreVersion` do not exist.

- [ ] **Step 3: Add the minimal package and implementation**

Create `Package.swift`:

```swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "DisplayControl",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "DisplayControlCore", targets: ["DisplayControlCore"]),
        .executable(name: "displayctl", targets: ["displayctl"]),
    ],
    targets: [
        .target(name: "DisplayControlCore"),
        .executableTarget(name: "displayctl", dependencies: ["DisplayControlCore"]),
        .testTarget(name: "DisplayControlCoreTests", dependencies: ["DisplayControlCore"]),
        .testTarget(name: "displayctlTests", dependencies: ["displayctl"]),
    ]
)
```

Create `Sources/DisplayControlCore/Display.swift`:

```swift
public enum DisplayControlCoreVersion {
    public static let current = "0.1.0"
}
```

Create `Sources/displayctl/main.swift`:

```swift
import DisplayControlCore

print("displayctl \(DisplayControlCoreVersion.current)")
```

Create `Tests/displayctlTests/CLIParserTests.swift` with an empty XCTest case so SwiftPM discovers the target.

- [ ] **Step 4: Verify the scaffold**

Run: `swift test`

Expected: all tests pass.

- [ ] **Step 5: Commit the scaffold**

```bash
git add Package.swift Sources Tests
git commit -m "build: scaffold display control package"
```

## Task 2: Define Display Models, Errors, and Selection

**Files:**
- Modify: `Sources/DisplayControlCore/Display.swift`
- Create: `Sources/DisplayControlCore/DisplayControlError.swift`
- Create: `Sources/DisplayControlCore/DisplaySelector.swift`
- Modify: `Tests/DisplayControlCoreTests/DisplaySelectorTests.swift`

- [ ] **Step 1: Add failing selector tests**

Cover UUID, runtime ID, unique aliases, ambiguous identities and aliases, and missing selectors. Command-specific active-state validation is tested with `ConnectionController` in Task 5. Use fixtures with fixed UUID strings and runtime IDs `1`, `2`, and `3`.

```swift
func testExternalAliasRejectsMultipleExternalDisplays() throws {
    let displays = [fixture(id: 2, kind: .external), fixture(id: 3, kind: .external)]
    XCTAssertThrowsError(try DisplaySelector.resolve("external", in: displays)) {
        XCTAssertEqual($0 as? DisplayControlError, .ambiguousSelector("external"))
    }
}
```

- [ ] **Step 2: Verify the tests fail**

Run: `swift test --filter DisplaySelectorTests`

Expected: compile failure because the domain types do not exist.

- [ ] **Step 3: Implement the domain types and pure selector**

Define these exact shapes:

```swift
public enum DisplayKind: String, Codable, Sendable { case `internal`, external }
public enum DDCCapability: String, Codable, Sendable { case candidate, confirmed, unsupported, unknown }

public struct Display: Codable, Equatable, Sendable {
    public let uuid: UUID
    public let runtimeID: UInt32
    public let name: String
    public let kind: DisplayKind
    public let isOnline: Bool
    public let isActive: Bool
    public let isMain: Bool
    public let ddcCapability: DDCCapability
}

public enum DisplayControlError: Error, Equatable, Sendable {
    case invalidArguments(String)
    case displayNotFound(String)
    case ambiguousSelector(String)
    case invalidState(String)
    case lastActiveDisplay
    case unsupportedAPI(String)
    case configurationFailed(String)
    case postconditionFailed(String)
    case ddcServiceNotFound
    case ddcServiceAmbiguous
    case ddcUnsupported
    case ddcTimeout
    case ddcTransport(String)
    case ddcInvalidResponse(String)
}
```

`DisplaySelector.resolve(_:in:)` must compare aliases first, then exact UUID text, then decimal `UInt32` runtime ID. It must never resolve display names.

- [ ] **Step 4: Verify selector behavior**

Run: `swift test --filter DisplaySelectorTests`

Expected: all selector tests pass.

- [ ] **Step 5: Commit domain behavior**

```bash
git add Sources/DisplayControlCore Tests/DisplayControlCoreTests/DisplaySelectorTests.swift
git commit -m "feat: add display identity and selection"
```

## Task 3: Implement Display Inventory

**Files:**
- Create: `Sources/DisplayControlCore/DisplayInventory.swift`
- Create: `Tests/DisplayControlCoreTests/DisplayInventoryTests.swift`

- [ ] **Step 1: Write failing snapshot-conversion tests**

Test active/online merging, built-in classification, stable UUID propagation, main-display state, inactive online displays, and fallback names. Keep Core Graphics calls outside the conversion test by supplying raw records.

```swift
func testOnlineButInactiveDisplayRemainsInSnapshot() throws {
    let result = try DisplayInventory.makeDisplays(
        onlineIDs: [1, 2], activeIDs: [1], metadata: fakeMetadata
    )
    XCTAssertEqual(result.first { $0.runtimeID == 2 }?.isActive, false)
}
```

- [ ] **Step 2: Verify inventory tests fail**

Run: `swift test --filter DisplayInventoryTests`

Expected: compile failure because `DisplayInventory` does not exist.

- [ ] **Step 3: Implement the inventory boundary**

Define:

```swift
public protocol DisplaySnapshotProviding: Sendable {
    func snapshot() throws -> [Display]
}

public struct DisplayInventory: DisplaySnapshotProviding {
    public init() {}
    public func snapshot() throws -> [Display]
}
```

The live implementation must call `CGGetOnlineDisplayList` and `CGGetActiveDisplayList` for count and values, then verify the count; when topology changes make the capacity, returned count, and verified count incoherent, retry from the count call with bounded attempts. For every online ID, use `CGDisplayCreateUUIDFromDisplayID`, `CGDisplayIsBuiltin`, `CGDisplayIsActive`, and `CGDisplayIsMain`. Use `NSScreen.localizedName` when an active screen matches `NSScreenNumber`; otherwise use `Built-in Display` or `External Display <vendor>:<model>` from Core Graphics numeric metadata. Sort internal first, then UUID text.

- [ ] **Step 4: Run inventory and full tests**

Run: `swift test --filter DisplayInventoryTests`

Expected: all inventory tests pass.

Run: `swift test`

Expected: all tests pass.

- [ ] **Step 5: Commit inventory support**

```bash
git add Sources/DisplayControlCore/DisplayInventory.swift Tests/DisplayControlCoreTests/DisplayInventoryTests.swift
git commit -m "feat: enumerate online and active displays"
```

## Task 4: Add Dynamic Private API Loading

**Files:**
- Create: `Sources/DisplayControlCore/PrivateAPIBridge.swift`
- Create: `Tests/DisplayControlCoreTests/PrivateAPIBridgeTests.swift`

- [ ] **Step 1: Write failing symbol-loader tests**

Inject a `SymbolResolving` fake. Verify a present symbol is cached, an absent symbol maps to `.unsupportedAPI`, and no symbol is resolved during bridge initialization.

```swift
func testMissingDisplayEnableSymbolFailsWithoutCallingIt() {
    let bridge = PrivateAPIBridge(resolver: FakeResolver(symbols: [:]))
    XCTAssertThrowsError(try bridge.requireDisplayEnable()) {
        XCTAssertEqual($0 as? DisplayControlError, .unsupportedAPI("CGSConfigureDisplayEnabled"))
    }
}
```

- [ ] **Step 2: Verify the tests fail**

Run: `swift test --filter PrivateAPIBridgeTests`

Expected: compile failure because the bridge does not exist.

- [ ] **Step 3: Implement lazy symbol resolution**

Use `dlopen`/`dlsym` through this boundary:

```swift
protocol SymbolResolving: Sendable {
    func resolve(_ symbol: String, frameworkPath: String?) -> UnsafeMutableRawPointer?
}

typealias CGSConfigureDisplayEnabledFn = @convention(c)
    (CGDisplayConfigRef?, CGDirectDisplayID, Bool) -> CGError
typealias IOAVServiceCreateWithServiceFn = @convention(c)
    (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
typealias IOAVServiceWriteI2CFn = @convention(c)
    (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer?, UInt32) -> IOReturn
typealias IOAVServiceReadI2CFn = @convention(c)
    (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer?, UInt32) -> IOReturn
```

Resolve CGS from the current process/CoreGraphics and IOAV symbols from `/System/Library/PrivateFrameworks/IOMobileFramebuffer.framework/IOMobileFramebuffer`. Retain successful framework handles for process lifetime. Never hard-link a private framework in `Package.swift`.

- [ ] **Step 4: Verify loader behavior and launch safety**

Run: `swift test --filter PrivateAPIBridgeTests`

Expected: all loader tests pass.

Run: `swift run displayctl`

Expected: prints the version without resolving or invoking a private symbol.

- [ ] **Step 5: Commit the private API boundary**

```bash
git add Sources/DisplayControlCore/PrivateAPIBridge.swift Tests/DisplayControlCoreTests/PrivateAPIBridgeTests.swift
git commit -m "feat: isolate private display APIs"
```

## Task 5: Implement Safe Connection Transactions

**Files:**
- Create: `Sources/DisplayControlCore/ConnectionController.swift`
- Create: `Tests/DisplayControlCoreTests/ConnectionControllerTests.swift`

- [ ] **Step 1: Write failing controller tests**

Use fake snapshots, a fake cross-process operation lock, and a fake transaction adapter. Test connect, disconnect, already-active/inactive rejection, last-active protection, concurrent disconnect serialization, lock timeout/failure, begin failure, enable failure with cancellation, complete failure, cancellation failure diagnostics, refreshed-state read failure, duplicate-UUID postcondition rejection, and refreshed-state postcondition failure. Test that `connectAll` is idempotent when a candidate becomes active before its turn and still attempts all remaining candidates.

```swift
func testDisconnectRefusesLastActiveDisplayBeforeBeginningTransaction() throws {
    let hardware = FakeConnectionHardware(displays: [fixture(id: 1, active: true)])
    let controller = ConnectionController(snapshot: hardware, hardware: hardware)
    XCTAssertThrowsError(try controller.disconnect("internal")) {
        XCTAssertEqual($0 as? DisplayControlError, .lastActiveDisplay)
    }
    XCTAssertEqual(hardware.beginCount, 0)
}
```

- [ ] **Step 2: Verify the tests fail**

Run: `swift test --filter ConnectionControllerTests`

Expected: compile failure because connection types do not exist.

- [ ] **Step 3: Implement transactions and postconditions**

Define:

```swift
public protocol DisplayConnectionHardware: Sendable {
    func setEnabled(_ displayID: UInt32, enabled: Bool) throws
}

public struct DisplayConnectionOutcome: Sendable {
    public let display: Display
    public let result: Result<Display, DisplayControlError>
}

public struct ConnectionController: Sendable {
    public init(snapshot: any DisplaySnapshotProviding, hardware: any DisplayConnectionHardware)
    public func connect(_ selector: String) throws -> Display
    public func connectAll() throws -> [DisplayConnectionOutcome]
    public func disconnect(_ selector: String) throws -> Display
}
```

The controller's public initializer uses a per-user Darwin `flock` implementation stored in the user's temporary directory; an internal initializer injects the lock for tests. Hold the lock across the complete snapshot, selection, last-active validation, hardware transaction, and postcondition verification sequence. Use bounded nonblocking acquisition retries and map acquisition failure or timeout to a descriptive `configurationFailed`. Open lock descriptors with `O_CLOEXEC`. Keep `connectAll` under one lock and use internal non-locking helpers to avoid recursive acquisition. Tests must exercise two independent live lock instances contending on the same path, bounded timeout, and release after both successful and throwing protected operations.

The live adapter must call `CGBeginDisplayConfiguration`, the dynamically resolved `CGSConfigureDisplayEnabled`, and `CGCompleteDisplayConfiguration(config, .forSession)`. Call `CGCancelDisplayConfiguration` on every failure after a successful begin and before successful completion. If cancellation also fails, preserve both failures in the reported diagnostic. Tests must verify that enable, complete, and cancel receive the exact configuration returned by begin and that completion uses `.forSession`.

After hardware completion, wrap snapshot failures as `postconditionFailed` because final state is unknown. Require exactly one refreshed display with the selected UUID and the requested active state. Make `connectAll` recovery idempotent by treating a candidate that is already active when re-resolved as success. Preserve the original candidate `Display` in every `DisplayConnectionOutcome`, including failures, while retaining the underlying typed `DisplayControlError`.

- [ ] **Step 4: Verify controller behavior**

Run: `swift test --filter ConnectionControllerTests`

Expected: all connection tests pass.

Run: `swift test`

Expected: all tests pass.

- [ ] **Step 5: Commit safe connection control**

```bash
git add Sources/DisplayControlCore/ConnectionController.swift Tests/DisplayControlCoreTests/ConnectionControllerTests.swift
git commit -m "feat: safely connect and disconnect displays"
```

## Task 6: Implement the DDC Codec and Service Matcher

**Files:**
- Create: `Sources/DisplayControlCore/DDC.swift`
- Create: `Tests/DisplayControlCoreTests/DDCTests.swift`

- [ ] **Step 1: Write failing DDC unit tests**

Test VCP `0x10` write bytes for values `0`, `50`, and `100`; reply checksum rejection; maximum-value parsing; unique service score selection; below-threshold rejection; and tied-best-score ambiguity.

```swift
func testBrightnessWritePacketForFiftyPercent() throws {
    XCTAssertEqual(
        DDCPacket.writeVCP(code: 0x10, value: 50),
        [0x84, 0x03, 0x10, 0x00, 0x32, 0x9A]
    )
}
```

The expected checksum uses the DDC/CI XOR seed `(0x37 << 1) ^ 0x51` and then XORs bytes `0x84`, `0x03`, `0x10`, `0x00`, and `0x32` to produce `0x9A`.

- [ ] **Step 2: Verify the tests fail**

Run: `swift test --filter DDCTests`

Expected: compile failure because DDC types do not exist.

- [ ] **Step 3: Implement codec and pure matching**

Define `DDCPacket.writeVCP(code:value:)`, `DDCPacket.readVCP(code:)`, and `DDCPacket.parseVCPReply(_:expectedCode:)`. Define a `DDCServiceCandidate` containing registry service ID, location, EDID UUID, product name, serial, and display location. Score exact display-location match highest, then serial, product/vendor, name, manufacture date, and physical size. Require a documented minimum score and reject tied highest scores.

The checksum implementation must XOR the DDC write seed with every packet byte except the checksum slot. The parser must validate source address, opcode, VCP code, result code, length, and checksum before returning current and maximum values.

- [ ] **Step 4: Verify codec and matching**

Run: `swift test --filter DDCTests`

Expected: codec and matcher tests pass without hardware access.

- [ ] **Step 5: Commit codec and matching**

```bash
git add Sources/DisplayControlCore/DDC.swift Tests/DisplayControlCoreTests/DDCTests.swift
git commit -m "feat: add DDC packet codec and service matching"
```

## Task 7: Implement IOAV Transport and Brightness Operations

**Files:**
- Modify: `Sources/DisplayControlCore/DDC.swift`
- Modify: `Sources/DisplayControlCore/DisplayInventory.swift`
- Modify: `Tests/DisplayControlCoreTests/DDCTests.swift`

- [ ] **Step 1: Add failing transport and brightness tests**

Use a fake transport to verify serialized operations, bounded write retries, bounded read retries, percentage validation, reported-maximum scaling, write success when read-back fails, and distinct timeout/transport/invalid-response errors.

```swift
func testSetSucceedsWhenWriteWorksAndReadBackIsUnsupported() throws {
    let transport = FakeDDCTransport(readResult: .failure(.ddcUnsupported), writeResults: [.success(())])
    let controller = DDCBrightnessController(transport: transport, retryPolicy: .test)
    XCTAssertNoThrow(try controller.set(percent: 50, display: externalFixture))
    XCTAssertEqual(transport.writtenValues, [50])
}
```

- [ ] **Step 2: Verify the new tests fail**

Run: `swift test --filter DDCTests`

Expected: compile failure because transport and controller types do not exist.

- [ ] **Step 3: Implement registry enumeration and IOAV calls**

Enumerate the I/O Registry recursively for `IOMobileFramebufferShim`/`AppleCLCD2` metadata paired with external `DCPAVServiceProxy` entries. Build candidates without sending I2C traffic, choose exactly one through the pure matcher, then call dynamically resolved `IOAVServiceCreateWithService`.

Define:

```swift
public protocol DDCTransport: Sendable {
    func readVCP(_ code: UInt8, for display: Display) throws -> DDCValue
    func writeVCP(_ code: UInt8, value: UInt16, for display: Display) throws
}

public struct DDCValue: Equatable, Sendable {
    public let current: UInt16
    public let maximum: UInt16
}

public actor DDCBrightnessController {
    public init()
    public init(transport: any DDCTransport)
    public func get(display: Display) throws -> DDCValue
    public func set(percent: Int, display: Display) throws
}
```

The zero-argument initializer composes the internal live I/O Registry resolver and IOAV transport so the separate `displayctl` target can use hardware brightness without exposing private transport implementation types. The transport initializer remains available for tests and alternative transports.

Use chip address `0x37`, data address `0x51`, bounded retry counts, and bounded `usleep` delays. Require `.external`; reject any other display before service resolution. `set` validates `0...100`, attempts a read to discover maximum, uses `100` if read-back is unsupported, and does not hide write failure. Update inventory capability to `.candidate` only when a unique safe service match exists; never report `.confirmed` from discovery alone.

- [ ] **Step 4: Verify all DDC tests**

Run: `swift test --filter DDCTests`

Expected: all DDC tests pass and complete within the test retry-policy bound.

Run: `swift test`

Expected: all tests pass.

- [ ] **Step 5: Commit live hardware brightness support**

```bash
git add Sources/DisplayControlCore/DDC.swift Sources/DisplayControlCore/DisplayInventory.swift Tests/DisplayControlCoreTests/DDCTests.swift
git commit -m "feat: control external brightness over DDC"
```

## Task 8: Implement the CLI Contract

**Files:**
- Modify: `Sources/displayctl/main.swift`
- Modify: `Tests/displayctlTests/CLIParserTests.swift`

- [ ] **Step 1: Write failing parser and renderer tests**

Test every documented command, `--help`, invalid arity, invalid brightness, unknown commands, stable JSON keys, human list columns, stderr messages, and exit-code mapping. Parser tests must not construct live hardware adapters.

```swift
func testParsesBrightnessSet() throws {
    XCTAssertEqual(
        try CLIParser.parse(["brightness", "set", "external", "42"]),
        .brightnessSet(selector: "external", percent: 42)
    )
}
```

- [ ] **Step 2: Verify CLI tests fail**

Run: `swift test --filter CLIParserTests`

Expected: compile failure because parser and command types do not exist.

- [ ] **Step 3: Implement parsing, composition, and output**

Define the command enum exactly:

```swift
enum CLICommand: Equatable {
    case help
    case list(json: Bool)
    case connect(selector: String)
    case connectAll
    case disconnect(selector: String)
    case brightnessGet(selector: String)
    case brightnessSet(selector: String, percent: Int)
}
```

Manual parsing avoids a dependency. No arguments and `--help` select `.help` and print the complete command synopsis with exit code `0`. Compose live inventory, private bridge, connection controller, IOAV transport, and brightness controller only after parsing succeeds. `list --json` encodes `[Display]` with sorted keys; human output includes UUID, runtime ID, name, kind, online, active, main, and DDC capability. Map usage errors to `64`, unavailable APIs/capabilities to `69`, temporary transport failures to `75`, and other operation failures to `1`.

- [ ] **Step 4: Verify CLI behavior**

Run: `swift test --filter CLIParserTests`

Expected: all CLI tests pass.

Run: `swift run displayctl list --json`

Expected: valid JSON containing at least the built-in display and no private-API launch failure.

- [ ] **Step 5: Commit the CLI**

```bash
git add Sources/displayctl/main.swift Tests/displayctlTests/CLIParserTests.swift
git commit -m "feat: expose display control CLI"
```

## Task 9: Add Hardware Validation and User Documentation

**Files:**
- Create: `Scripts/hardware-test.sh`
- Create: `README.md`

- [ ] **Step 1: Write the hardware-test contract before the script**

Document these required checks in `README.md`: build, automated test, list, HDMI brightness get, visually confirmed HDMI brightness set, external disconnect/reconnect, internal disconnect/reconnect, final-display refusal, USB-C brightness result, logout/login recovery, and `connect all` recovery.

- [ ] **Step 2: Verify documented commands against CLI help behavior**

Run: `swift run displayctl --help`

Expected: exit `0` and commands matching the design.

- [ ] **Step 3: Implement the opt-in interactive script**

`Scripts/hardware-test.sh` must use `set -euo pipefail`, refuse non-interactive execution, build once, print the disruption warning, capture the initial JSON list, and require explicit confirmation before each disconnect or brightness mutation. It must install a shell trap that runs `.build/debug/displayctl connect all` on exit. It must not automate logout/login; print that manual check as the final instruction.

- [ ] **Step 4: Validate documentation and script syntax**

Run: `zsh -n Scripts/hardware-test.sh`

Expected: exit `0` with no output.

Run: `swift test`

Expected: all tests pass.

- [ ] **Step 5: Commit validation assets**

```bash
git add README.md Scripts/hardware-test.sh
git commit -m "docs: add hardware validation and recovery guide"
```

## Task 10: Phase 1 Verification and Stabilization Gate

**Files:**
- Modify only files implicated by verification failures.

- [ ] **Step 1: Run formatting and whitespace checks**

Run: `swift format lint --recursive --strict Sources Tests Package.swift`

Expected: exit `0`. Use Xcode's bundled `swift format`; do not add a formatter dependency.

Run: `git diff --check`

Expected: exit `0`.

- [ ] **Step 2: Run clean automated verification**

Run: `swift package clean`

Expected: exit `0`.

Run: `swift build -c release`

Expected: build succeeds without warnings introduced by this project.

Run: `swift test --parallel`

Expected: all tests pass.

- [ ] **Step 3: Run non-mutating target-Mac checks**

Run: `.build/release/displayctl list`

Expected: internal and HDMI displays are shown with stable UUIDs and correct active state.

Run: `.build/release/displayctl list --json | plutil -lint -`

Expected: valid JSON. If `plutil` rejects JSON from stdin on the installed version, validate with `python3 -m json.tool` without adding Python as a project dependency.

- [ ] **Step 4: Run the opt-in hardware matrix with the user present**

Run: `Scripts/hardware-test.sh`

Expected: HDMI hardware brightness changes physically; both displays can be disconnected and reconnected only while another remains active; final-display disconnect is refused; `connect all` restores all physically present displays. Record USB-C as supported or unsupported in the hardware-validation section of `README.md` using the observed result.

- [ ] **Step 5: Check scope and commit stabilization changes**

Run: `git status --short`

Expected: only plan-listed files are changed.

Run: `git diff --stat HEAD~1`

Expected: no Phase 2 agent, keyboard listener, menu-bar UI, unrelated refactor, dependency, or public API outside the approved design.

If verification required fixes, commit them with:

```bash
git add Package.swift Sources Tests Scripts README.md
git commit -m "fix: stabilize phase one display control"
```

If no files changed, do not create an empty commit.

## Completion Criteria

Phase 1 is complete only after Task 10 evidence satisfies every Phase 1 acceptance criterion in `design.md`. Completion does not authorize Phase 2. The next action is a Phase 1 stabilization review and an explicit decision whether to design and plan Phase 2.
