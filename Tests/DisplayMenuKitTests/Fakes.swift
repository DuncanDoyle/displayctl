import DisplayControlCore
import Foundation
import Synchronization

@testable import DisplayMenuKit

let builtInID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
let dellID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
let lgID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
let thisBoot = "boot-current"

func display(
  _ uuid: UUID, _ name: String, kind: DisplayKind = .external, active: Bool = true,
  online: Bool = true, ddc: DDCCapability = .confirmed
) -> Display {
  Display(
    uuid: uuid, runtimeID: UInt32(uuid.uuidString.suffix(2), radix: 16) ?? 0, name: name,
    kind: kind, isOnline: online, isActive: active, isMain: false, ddcCapability: ddc)
}

func builtIn(active: Bool = true) -> Display {
  display(builtInID, "Built-in Retina Display", kind: .internal, active: active, ddc: .unsupported)
}

func dell(active: Bool = true) -> Display { display(dellID, "DELL U2720Q", active: active) }

func entry(_ uuid: UUID, _ name: String, boot: String = thisBoot) -> DisabledDisplayEntry {
  DisabledDisplayEntry(uuid: uuid, runtimeID: 9, name: name, kind: .external, bootSession: boot)
}

/// Suspends callers in `pass()` until `open()`; `arrived()` waits for the first caller.
final class Gate: Sendable {
  private struct State {
    var isOpen = false
    var hasArrival = false
    var passers: [CheckedContinuation<Void, Never>] = []
    var watchers: [CheckedContinuation<Void, Never>] = []
  }
  private let state = Mutex(State())

  func pass() async {
    await withCheckedContinuation { continuation in
      let watchers = state.withLock { state -> [CheckedContinuation<Void, Never>] in
        state.hasArrival = true
        if state.isOpen {
          continuation.resume()
        } else {
          state.passers.append(continuation)
        }
        defer { state.watchers = [] }
        return state.watchers
      }
      for watcher in watchers { watcher.resume() }
    }
  }

  func arrived() async {
    await withCheckedContinuation { continuation in
      let ready = state.withLock { state -> Bool in
        if !state.hasArrival { state.watchers.append(continuation) }
        return state.hasArrival
      }
      if ready { continuation.resume() }
    }
  }

  func open() {
    let passers = state.withLock { state -> [CheckedContinuation<Void, Never>] in
      state.isOpen = true
      defer { state.passers = [] }
      return state.passers
    }
    for passer in passers { passer.resume() }
  }
}

/// One scripted snapshot: optionally held at a gate, then returns `result`.
struct SnapshotStep: Sendable {
  var gate: Gate?
  var result: Result<[Display], DisplayControlError>
}

/// One scripted connect or disconnect: optionally held, then fails or changes the displays.
struct SwitchStep: Sendable {
  var gate: Gate?
  var error: DisplayControlError?
  var then: [Display]?
}

final class FakeOperations: DisplayOperating {
  private struct State {
    var current: [Display]
    var ledger: Result<[DisabledDisplayEntry], DisplayControlError>
    var snapshotSteps: [SnapshotStep] = []
    var switchSteps: [SwitchStep] = []
    var calls: [String] = []
  }
  private let state: Mutex<State>

  init(
    _ current: [Display],
    ledger: Result<[DisabledDisplayEntry], DisplayControlError> = .success([])
  ) {
    state = Mutex(State(current: current, ledger: ledger))
  }

  var calls: [String] { state.withLock { $0.calls } }

  func setCurrent(_ displays: [Display]) { state.withLock { $0.current = displays } }

  func addSnapshot(_ step: SnapshotStep) { state.withLock { $0.snapshotSteps.append(step) } }

  func addSwitch(_ step: SwitchStep) { state.withLock { $0.switchSteps.append(step) } }

  func snapshot() async throws -> [Display] {
    let step = state.withLock { state -> SnapshotStep in
      state.snapshotSteps.isEmpty
        ? SnapshotStep(result: .success(state.current)) : state.snapshotSteps.removeFirst()
    }
    await step.gate?.pass()
    return try step.result.get()
  }

  func disabledDisplays() async throws -> [DisabledDisplayEntry] {
    try state.withLock { $0.ledger }.get()
  }

  func bootSession() async throws -> String { thisBoot }

  func connect(_ uuid: UUID) async throws -> Display {
    try await perform("connect", uuid)
  }

  func disconnect(_ uuid: UUID) async throws -> Display {
    try await perform("disconnect", uuid)
  }

  private func perform(_ name: String, _ uuid: UUID) async throws -> Display {
    let step = state.withLock { state -> SwitchStep in
      state.calls.append("\(name) \(uuid.uuidString)")
      return state.switchSteps.isEmpty ? SwitchStep() : state.switchSteps.removeFirst()
    }
    await step.gate?.pass()
    if let error = step.error { throw error }
    let displays = state.withLock { state -> [Display] in
      if let then = step.then { state.current = then }
      return state.current
    }
    return displays.first { $0.uuid == uuid } ?? display(uuid, "unknown")
  }
}

/// Records reads and writes; a write call can be held at a gate or made to fail, by call index.
final class FakeBrightness: BrightnessOperating {
  private struct State {
    var reads: [UUID] = []
    var writes: [Int] = []
    var readResults: [UUID: Result<Int, DisplayControlError>] = [:]
    var writeGates: [Int: Gate] = [:]
    var writeErrors: [Int: DisplayControlError] = [:]
  }
  private let state = Mutex(State())

  var reads: [UUID] { state.withLock { $0.reads } }
  var writes: [Int] { state.withLock { $0.writes } }

  func setRead(_ uuid: UUID, _ result: Result<Int, DisplayControlError>) {
    state.withLock { $0.readResults[uuid] = result }
  }

  func holdWrite(_ call: Int) -> Gate {
    let gate = Gate()
    state.withLock { $0.writeGates[call] = gate }
    return gate
  }

  func failWrite(_ call: Int, _ error: DisplayControlError) {
    state.withLock { $0.writeErrors[call] = error }
  }

  func percent(for uuid: UUID) async throws -> Int {
    try state.withLock { state in
      state.reads.append(uuid)
      return state.readResults[uuid] ?? .success(40)
    }.get()
  }

  func set(_ percent: Int, for uuid: UUID) async throws {
    let (gate, error) = state.withLock { state in
      let call = state.writes.count
      state.writes.append(percent)
      return (state.writeGates[call], state.writeErrors[call])
    }
    await gate?.pass()
    if let error { throw error }
  }
}

struct UnusedBrightness: BrightnessOperating {
  func percent(for uuid: UUID) async throws -> Int { 50 }
  func set(_ percent: Int, for uuid: UUID) async throws {}
}
