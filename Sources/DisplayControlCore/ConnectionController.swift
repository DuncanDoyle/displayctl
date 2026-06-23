import CoreGraphics
import Foundation

public protocol DisplayConnectionHardware: Sendable {
  func setEnabled(_ displayID: UInt32, enabled: Bool) throws
}

public struct ConnectionController: Sendable {
  private let snapshot: any DisplaySnapshotProviding
  private let hardware: any DisplayConnectionHardware

  public init(
    snapshot: any DisplaySnapshotProviding,
    hardware: any DisplayConnectionHardware
  ) {
    self.snapshot = snapshot
    self.hardware = hardware
  }

  public func connect(_ selector: String) throws -> Display {
    let displays = try snapshot.snapshot()
    let display = try DisplaySelector.resolve(selector, in: displays)
    guard !display.isActive else {
      throw DisplayControlError.invalidState("Display \(display.runtimeID) is already active")
    }
    return try transition(display, enabled: true)
  }

  public func connectAll() throws -> [Result<Display, DisplayControlError>] {
    let candidates = try snapshot.snapshot().filter { $0.isOnline && !$0.isActive }
    return candidates.map { display in
      do {
        return .success(try connect(display.uuid.uuidString))
      } catch let error as DisplayControlError {
        return .failure(error)
      } catch {
        return .failure(.configurationFailed(String(describing: error)))
      }
    }
  }

  public func disconnect(_ selector: String) throws -> Display {
    let displays = try snapshot.snapshot()
    let display = try DisplaySelector.resolve(selector, in: displays)
    guard display.isActive else {
      throw DisplayControlError.invalidState("Display \(display.runtimeID) is already inactive")
    }
    guard displays.filter(\.isActive).count > 1 else {
      throw DisplayControlError.lastActiveDisplay
    }
    return try transition(display, enabled: false)
  }

  private func transition(_ display: Display, enabled: Bool) throws -> Display {
    try hardware.setEnabled(display.runtimeID, enabled: enabled)
    let refreshed = try snapshot.snapshot()
    guard
      let result = refreshed.first(where: { $0.uuid == display.uuid }),
      result.isActive == enabled
    else {
      let state = enabled ? "active" : "inactive"
      throw DisplayControlError.postconditionFailed(
        "Display \(display.runtimeID) did not become \(state)"
      )
    }
    return result
  }
}

struct CoreGraphicsDisplayTransactionFunctions: @unchecked Sendable {
  let begin: (UnsafeMutablePointer<CGDisplayConfigRef?>) -> CGError
  let enable: (CGDisplayConfigRef?, CGDirectDisplayID, Bool) throws -> CGError
  let complete: (CGDisplayConfigRef?, CGConfigureOption) -> CGError
  let cancel: (CGDisplayConfigRef?) -> CGError

  static func live(bridge: PrivateAPIBridge) -> Self {
    Self(
      begin: CGBeginDisplayConfiguration,
      enable: { config, displayID, enabled in
        try bridge.requireDisplayEnable()(config, displayID, enabled)
      },
      complete: CGCompleteDisplayConfiguration,
      cancel: CGCancelDisplayConfiguration
    )
  }
}

public struct CoreGraphicsDisplayConnectionHardware: DisplayConnectionHardware {
  private let api: CoreGraphicsDisplayTransactionFunctions

  public init() {
    api = .live(bridge: PrivateAPIBridge())
  }

  init(api: CoreGraphicsDisplayTransactionFunctions) {
    self.api = api
  }

  public func setEnabled(_ displayID: UInt32, enabled: Bool) throws {
    var config: CGDisplayConfigRef?
    let beginError = api.begin(&config)
    guard beginError == .success else {
      throw nativeFailure("CGBeginDisplayConfiguration", beginError)
    }

    var completed = false
    defer {
      if !completed { _ = api.cancel(config) }
    }

    guard config != nil else {
      throw DisplayControlError.configurationFailed(
        "CGBeginDisplayConfiguration returned success with nil configuration"
      )
    }

    let enableError = try api.enable(config, displayID, enabled)
    guard enableError == .success else {
      throw nativeFailure("CGSConfigureDisplayEnabled", enableError)
    }

    let completeError = api.complete(config, .forSession)
    guard completeError == .success else {
      throw nativeFailure("CGCompleteDisplayConfiguration", completeError)
    }
    completed = true
  }

  private func nativeFailure(_ apiName: String, _ error: CGError) -> DisplayControlError {
    .configurationFailed("\(apiName) failed with error \(error.rawValue)")
  }
}
