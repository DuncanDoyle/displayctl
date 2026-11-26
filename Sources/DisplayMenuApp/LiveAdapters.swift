import DisplayControlCore
import DisplayMenuKit
import Foundation
import os

/// The live objects behind the panel and the safety net; blocking calls share one executor.
struct LiveServices: Sendable {
  let operations: LiveDisplayOperations
  let brightness: LiveBrightness
  let scheduler: RecoveryScheduler

  init() {
    let executor = BlockingExecutor()
    let inventory = DisplayInventory(namesOnMainThread: true)
    // Same ledger and lock as the CLI: the default state directory.
    let controller = ConnectionController(
      snapshot: inventory, hardware: CoreGraphicsDisplayConnectionHardware())
    operations = LiveDisplayOperations(
      executor: executor, inventory: inventory, controller: controller)
    brightness = LiveBrightness(executor: executor, inventory: inventory)

    let logger = Logger(subsystem: "displayctl", category: "recovery")
    let recovery = ZeroActiveRecovery(
      sampler: LiveSampler(executor: executor, inventory: inventory),
      connector: LiveRecoveryConnector(executor: executor, controller: controller),
      sleep: { try? await Task.sleep(for: $0) },
      log: { logger.notice("\($0, privacy: .public)") })
    scheduler = RecoveryScheduler(
      recovery: recovery, usableCount: { try DisplayInventory.usableActiveDisplayCount() },
      sleep: { try await Task.sleep(for: $0) },
      log: { logger.notice("\($0, privacy: .public)") },
      onOutcome: { logger.notice("episode outcome: \(String(describing: $0), privacy: .public)") })
  }
}

struct LiveDisplayOperations: DisplayOperating {
  let executor: BlockingExecutor
  let inventory: DisplayInventory
  let controller: ConnectionController

  func snapshot() async throws -> [Display] {
    try await executor.run { [inventory] in try inventory.snapshot() }
  }

  func disabledDisplays() async throws -> [DisabledDisplayEntry] {
    try await executor.run { [controller] in try controller.disabledDisplays() }
  }

  func bootSession() async throws -> String {
    try await executor.run { try BootSession.current() }
  }

  func connect(_ uuid: UUID) async throws -> Display {
    try await executor.run { [controller] in try controller.connect(uuid.uuidString) }
  }

  func disconnect(_ uuid: UUID) async throws -> Display {
    try await executor.run { [controller] in try controller.disconnect(uuid.uuidString) }
  }
}

/// DDC calls stay on the controller's actor; only the display lookup uses the executor.
struct LiveBrightness: BrightnessOperating {
  let executor: BlockingExecutor
  let inventory: DisplayInventory
  let ddc = DDCBrightnessController()

  func percent(for uuid: UUID) async throws -> Int {
    guard let display = try await activeDisplay(uuid) else {
      throw DisplayControlError.displayNotFound(uuid.uuidString)
    }
    return try BrightnessPercent.from(await ddc.get(display: display))
  }

  func set(_ percent: Int, for uuid: UUID) async throws {
    // A display that left or turned off may have handed its runtime ID to another monitor.
    guard let display = try await activeDisplay(uuid) else { return }
    try await ddc.set(percent: percent, display: display)
  }

  private func activeDisplay(_ uuid: UUID) async throws -> Display? {
    let displays = try await executor.run { [inventory] in try inventory.snapshot() }
    return displays.first { $0.uuid == uuid && $0.isOnline && $0.isActive }
  }
}

struct LiveRecoveryConnector: RecoveryConnecting {
  let executor: BlockingExecutor
  let controller: ConnectionController

  func recoverIfNoneActive() async throws -> [DisplayConnectionOutcome]? {
    try await executor.run { [controller] in try controller.recoverIfNoneActive() }
  }
}

struct LiveSampler: DisplaySampling {
  let executor: BlockingExecutor
  let inventory: DisplayInventory

  func snapshot() async throws -> [Display] {
    try await executor.run { [inventory] in try inventory.snapshot() }
  }
}
