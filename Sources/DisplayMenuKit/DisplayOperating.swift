import DisplayControlCore
import Foundation

/// Display reads and switches for the panel; the live adapter runs them on a `BlockingExecutor`.
public protocol DisplayOperating: Sendable {
  func snapshot() async throws -> [Display]
  func disabledDisplays() async throws -> [DisabledDisplayEntry]
  func bootSession() async throws -> String
  func connect(_ uuid: UUID) async throws -> Display
  func disconnect(_ uuid: UUID) async throws -> Display
}

/// DDC brightness for one display, looked up by UUID in a fresh snapshot on every call.
public protocol BrightnessOperating: Sendable {
  func percent(for uuid: UUID) async throws -> Int
  /// Drops the write if the display is not online and active.
  func set(_ percent: Int, for uuid: UUID) async throws
}
