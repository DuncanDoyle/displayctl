import CoreGraphics
import Darwin
import Foundation

public protocol DisplayConnectionHardware: Sendable {
  func setEnabled(_ displayID: UInt32, enabled: Bool) throws
}

public struct DisplayConnectionOutcome: Sendable {
  public let display: Display
  public let result: Result<Display, DisplayControlError>

  public init(display: Display, result: Result<Display, DisplayControlError>) {
    self.display = display
    self.result = result
  }
}

protocol DisplayOperationLocking: Sendable {
  func withLock<T>(_ operation: () throws -> T) throws -> T
}

struct DarwinDisplayOperationLock: DisplayOperationLocking {
  private let configuredLockURL: URL?
  private let maximumAttempts: Int
  private let retryDelayMicroseconds: useconds_t

  init(
    lockURL: URL? = nil,
    maximumAttempts: Int = 50,
    retryDelayMicroseconds: useconds_t = 20_000
  ) {
    configuredLockURL = lockURL
    self.maximumAttempts = maximumAttempts
    self.retryDelayMicroseconds = retryDelayMicroseconds
  }

  func withLock<T>(_ operation: () throws -> T) throws -> T {
    let lockURL =
      configuredLockURL
      ?? FileManager.default.temporaryDirectory
      .appendingPathComponent("displaycontrol-connection.lock")
    let path = lockURL.path
    let descriptor = path.withCString {
      open($0, O_CREAT | O_RDWR | O_CLOEXEC, mode_t(S_IRUSR | S_IWUSR))
    }
    guard descriptor >= 0 else {
      let code = errno
      throw lockFailure("open", path: path, errno: code)
    }

    var acquired = false
    defer {
      if acquired {
        _ = flock(descriptor, LOCK_UN)
      }
      _ = close(descriptor)
    }

    for attempt in 0..<maximumAttempts {
      if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
        acquired = true
        return try operation()
      }

      let code = errno
      guard code == EWOULDBLOCK || code == EAGAIN else {
        throw lockFailure("flock", path: path, errno: code)
      }
      if attempt + 1 < maximumAttempts {
        usleep(retryDelayMicroseconds)
      }
    }

    throw DisplayControlError.configurationFailed(
      "flock timed out acquiring display operation lock at \(path) "
        + "after \(maximumAttempts) attempts"
    )
  }

  private func lockFailure(_ api: String, path: String, errno code: Int32) -> DisplayControlError {
    .configurationFailed(
      "\(api) failed for display operation lock at \(path) with errno \(code): "
        + String(cString: strerror(code))
    )
  }
}

public struct ConnectionController: Sendable {
  private let snapshot: any DisplaySnapshotProviding
  private let hardware: any DisplayConnectionHardware
  private let operationLock: any DisplayOperationLocking

  public init(
    snapshot: any DisplaySnapshotProviding,
    hardware: any DisplayConnectionHardware
  ) {
    self.snapshot = snapshot
    self.hardware = hardware
    operationLock = DarwinDisplayOperationLock()
  }

  init(
    snapshot: any DisplaySnapshotProviding,
    hardware: any DisplayConnectionHardware,
    lock: any DisplayOperationLocking
  ) {
    self.snapshot = snapshot
    self.hardware = hardware
    operationLock = lock
  }

  public func connect(_ selector: String) throws -> Display {
    try operationLock.withLock {
      try connectUnlocked(selector, acceptAlreadyActive: false)
    }
  }

  public func connectAll() throws -> [DisplayConnectionOutcome] {
    try operationLock.withLock {
      let candidates = try snapshot.snapshot().filter { $0.isOnline && !$0.isActive }
      return candidates.map { display in
        let result: Result<Display, DisplayControlError>
        do {
          result = .success(
            try connectUnlocked(display.uuid.uuidString, acceptAlreadyActive: true))
        } catch let error as DisplayControlError {
          result = .failure(error)
        } catch {
          result = .failure(.configurationFailed(String(describing: error)))
        }
        return DisplayConnectionOutcome(display: display, result: result)
      }
    }
  }

  public func disconnect(_ selector: String) throws -> Display {
    try operationLock.withLock {
      try disconnectUnlocked(selector)
    }
  }

  private func connectUnlocked(
    _ selector: String,
    acceptAlreadyActive: Bool
  ) throws -> Display {
    let displays = try snapshot.snapshot()
    let display = try DisplaySelector.resolve(selector, in: displays)
    if display.isActive, acceptAlreadyActive {
      return display
    }
    guard !display.isActive else {
      throw DisplayControlError.invalidState("Display \(display.runtimeID) is already active")
    }
    return try transition(display, enabled: true)
  }

  private func disconnectUnlocked(_ selector: String) throws -> Display {
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
    let refreshed: [Display]
    do {
      refreshed = try snapshot.snapshot()
    } catch {
      throw DisplayControlError.postconditionFailed(
        "Display \(display.uuid.uuidString) refresh failed after requesting enabled "
          + "\(enabled): \(error)"
      )
    }

    let matches = refreshed.filter { $0.uuid == display.uuid }
    guard matches.count == 1, let result = matches.first else {
      throw DisplayControlError.postconditionFailed(
        "Display \(display.uuid.uuidString) had \(matches.count) matches after requesting "
          + "enabled \(enabled)"
      )
    }
    guard result.isActive == enabled else {
      let state = enabled ? "active" : "inactive"
      throw DisplayControlError.postconditionFailed(
        "Display \(display.uuid.uuidString) did not become \(state)"
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
      throw nativeFailure(
        "CGBeginDisplayConfiguration",
        beginError,
        displayID: displayID,
        enabled: enabled
      )
    }

    do {
      guard config != nil else {
        throw DisplayControlError.configurationFailed(
          "CGBeginDisplayConfiguration returned success with nil configuration for display "
            + "\(displayID), enabled \(enabled)"
        )
      }

      let enableError = try api.enable(config, displayID, enabled)
      guard enableError == .success else {
        throw nativeFailure(
          "CGSConfigureDisplayEnabled",
          enableError,
          displayID: displayID,
          enabled: enabled
        )
      }

      let completeError = api.complete(config, .forSession)
      guard completeError == .success else {
        throw nativeFailure(
          "CGCompleteDisplayConfiguration",
          completeError,
          displayID: displayID,
          enabled: enabled
        )
      }
    } catch {
      let cancelError = api.cancel(config)
      guard cancelError == .success else {
        throw DisplayControlError.configurationFailed(
          "\(failureDescription(error)); CGCancelDisplayConfiguration failed with error "
            + "\(cancelError.rawValue) for display \(displayID), enabled \(enabled)"
        )
      }
      throw error
    }
  }

  private func nativeFailure(
    _ apiName: String,
    _ error: CGError,
    displayID: UInt32,
    enabled: Bool
  ) -> DisplayControlError {
    .configurationFailed(
      "\(apiName) failed with error \(error.rawValue) for display \(displayID), enabled \(enabled)"
    )
  }

  private func failureDescription(_ error: Error) -> String {
    if case .configurationFailed(let message) = error as? DisplayControlError {
      return message
    }
    return String(describing: error)
  }
}
