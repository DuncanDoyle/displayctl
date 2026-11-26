import CoreGraphics
import Darwin
import Foundation

public protocol DisplayConnectionHardware: Sendable {
  func setEnabled(_ displayID: UInt32, enabled: Bool) throws
}

public struct DisplayConnectionOutcome: Sendable {
  /// The candidate display, or nil for the outcome of reading the ledger itself.
  public let display: Display?
  public let result: Result<Display, DisplayControlError>

  public init(display: Display?, result: Result<Display, DisplayControlError>) {
    self.display = display
    self.result = result
  }
}

/// Recovery saw an active display before its first enable; it ends without acting.
private struct DisplayBecameActive: Error {}

protocol DisplayOperationLocking: Sendable {
  func withLock<T>(_ operation: () throws -> T) throws -> T
}

struct DarwinDisplayOperationLock: DisplayOperationLocking {
  private let lockURL: URL
  private let maximumAttempts: Int
  private let retryDelayMicroseconds: useconds_t

  init(
    lockURL: URL,
    maximumAttempts: Int = 50,
    retryDelayMicroseconds: useconds_t = 20_000
  ) {
    self.lockURL = lockURL
    self.maximumAttempts = maximumAttempts
    self.retryDelayMicroseconds = retryDelayMicroseconds
  }

  func withLock<T>(_ operation: () throws -> T) throws -> T {
    let path = lockURL.path
    // A failure here surfaces as the open error below.
    try? FileManager.default.createDirectory(
      at: lockURL.deletingLastPathComponent(), withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
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

    throw DisplayControlError.lockTimeout
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
  private let ledger: any DisabledDisplayLedger
  private let bootSession: @Sendable () throws -> String
  private let runtimeIDOwner: @Sendable (UInt32) -> UUID?

  /// Creates a controller whose ledger and operation lock live in `stateDirectory`.
  public init(
    snapshot: any DisplaySnapshotProviding,
    hardware: any DisplayConnectionHardware,
    stateDirectory: URL = DisplayControlState.defaultDirectory
  ) {
    self.init(
      snapshot: snapshot,
      hardware: hardware,
      lock: DarwinDisplayOperationLock(lockURL: DisplayControlState.lockURL(in: stateDirectory)),
      ledger: FileDisabledDisplayLedger(url: DisplayControlState.ledgerURL(in: stateDirectory)),
      bootSession: BootSession.current,
      runtimeIDOwner: DisplayInventory.uuid(forRuntimeID:)
    )
  }

  /// `runtimeIDOwner` names the UUID Core Graphics maps a runtime ID to right now, if any.
  init(
    snapshot: any DisplaySnapshotProviding,
    hardware: any DisplayConnectionHardware,
    lock: any DisplayOperationLocking,
    ledger: any DisabledDisplayLedger,
    bootSession: @escaping @Sendable () throws -> String,
    runtimeIDOwner: @escaping @Sendable (UInt32) -> UUID?
  ) {
    self.snapshot = snapshot
    self.hardware = hardware
    operationLock = lock
    self.ledger = ledger
    self.bootSession = bootSession
    self.runtimeIDOwner = runtimeIDOwner
  }

  /// Returns the ledger's entries without taking the operation lock.
  public func disabledDisplays() throws -> [DisabledDisplayEntry] {
    try ledger.load()
  }

  /// Removes the ledger entry for `uuid` without touching any display.
  public func forget(_ uuid: UUID) throws -> DisabledDisplayEntry {
    try operationLock.withLock {
      let entries: [DisabledDisplayEntry]
      do {
        entries = try ledger.load()
      } catch {
        throw DisplayControlError.configurationFailed(
          "\(Self.message(error)); use forget all to reset the ledger")
      }
      guard let entry = entries.first(where: { $0.uuid == uuid }) else {
        throw DisplayControlError.displayNotFound(uuid.uuidString)
      }
      try ledger.save(entries.filter { $0.uuid != uuid })
      return entry
    }
  }

  /// Replaces the ledger with an empty one without touching any display, even when it is
  /// unreadable; returns the entries it could still read.
  public func forgetAll() throws -> [DisabledDisplayEntry] {
    try operationLock.withLock {
      let entries = (try? ledger.load()) ?? []
      try ledger.save([])
      return entries
    }
  }

  private static func message(_ error: Error) -> String {
    if case .configurationFailed(let message) = error as? DisplayControlError { return message }
    return String(describing: error)
  }

  /// Enables an online inactive display, or a ledger display that macOS no longer lists when the
  /// selector is its UUID or a kind with exactly one candidate.
  public func connect(_ selector: String) throws -> Display {
    try operationLock.withLock {
      let displays = try snapshot.snapshot()
      if let kind = DisplayKind(rawValue: selector) {
        return try connect(kind, selector: selector, in: displays)
      }
      let display: Display
      do {
        display = try DisplaySelector.resolve(selector, in: displays)
      } catch DisplayControlError.displayNotFound(let missing) {
        // A display that left the online list is reachable by its UUID through the ledger.
        let uuid = UUID(uuidString: selector)
        let matches = uuid == nil ? [] : try ledger.load().filter { $0.uuid == uuid }
        guard let entry = matches.first else {
          throw DisplayControlError.displayNotFound(missing)
        }
        guard matches.count == 1 else {
          throw DisplayControlError.ambiguousSelector(selector)
        }
        return try reconnect(entry.uuid, entry: entry, acceptAlreadyActive: false)
      }
      guard !display.isActive else {
        throw DisplayControlError.invalidState("Display \(display.runtimeID) is already active")
      }
      let result = try transition(display, enabled: true)
      removeEntry(display.uuid)
      return result
    }
  }

  /// Resolves a kind across online inactive displays and ledger entries that are not online, and
  /// enables the single candidate; zero or several candidates fail before any mutation.
  private func connect(_ kind: DisplayKind, selector: String, in displays: [Display]) throws
    -> Display
  {
    let online = displays.filter { $0.kind == kind }
    let onlineUUIDs = Set(online.map(\.uuid))
    let inactive = online.filter { !$0.isActive }
    let entries: [DisabledDisplayEntry]
    do {
      entries = try ledger.load()
    } catch {
      throw DisplayControlError.configurationFailed(
        "\(Self.message(error)); use connect <UUID>, connect all, or forget all"
      )
    }
    var ledgerOnly: [DisabledDisplayEntry] = []
    for entry in entries
    where entry.kind == kind && !onlineUUIDs.contains(entry.uuid)
      && !ledgerOnly.contains(where: { $0.uuid == entry.uuid })
    {
      ledgerOnly.append(entry)
    }

    switch (inactive.count + ledgerOnly.count, inactive.first, ledgerOnly.first) {
    case (1, let display?, _):
      let result = try transition(display, enabled: true)
      removeEntry(display.uuid)
      return result
    case (1, _, let entry?):
      return try reconnect(entry.uuid, entry: entry, acceptAlreadyActive: false)
    case (0, _, _):
      let active = online.filter(\.isActive)
      guard let display = active.first else {
        throw DisplayControlError.displayNotFound(selector)
      }
      guard active.count == 1 else {
        throw DisplayControlError.ambiguousSelector(selector)
      }
      throw DisplayControlError.invalidState("Display \(display.runtimeID) is already active")
    default:
      throw DisplayControlError.ambiguousSelector(selector)
    }
  }

  /// Attempts every online inactive display and every ledger entry once, in that order. An
  /// unreadable ledger is reported as a last failed outcome; online displays are still attempted.
  public func connectAll() throws -> [DisplayConnectionOutcome] {
    try operationLock.withLock {
      try connectAllLocked(from: try snapshot.snapshot(), stopIfActive: false)
    }
  }

  /// Under the operation lock: nil if a usable display is active (the macOS placeholder does not
  /// count); otherwise connectAll's outcomes, with candidates from the same snapshot. Stops with
  /// nil if a usable display turns active before the first enable succeeds.
  public func recoverIfNoneActive() throws -> [DisplayConnectionOutcome]? {
    try operationLock.withLock {
      let displays = try snapshot.snapshot()
      guard !displays.contains(where: \.isUsableActive) else { return nil }
      do {
        return try connectAllLocked(from: displays, stopIfActive: true)
      } catch is DisplayBecameActive {
        return nil
      }
    }
  }

  /// The body of `connectAll` over `displays`; the caller holds the operation lock.
  private func connectAllLocked(from displays: [Display], stopIfActive: Bool) throws
    -> [DisplayConnectionOutcome]
  {
    var ledgerFailure: DisplayControlError?
    var entries: [DisabledDisplayEntry] = []
    do {
      entries = try ledger.load()
    } catch {
      ledgerFailure = error as? DisplayControlError ?? .configurationFailed("\(error)")
    }
    var candidates =
      displays
      .filter { $0.isOnline && !$0.isActive }
      .map { display in (display, entries.first { $0.uuid == display.uuid }) }
    let candidateUUIDs = Set(candidates.map(\.0.uuid))
    candidates += entries.filter { !candidateUUIDs.contains($0.uuid) }.map {
      ($0.placeholder, $0)
    }

    var outcomes: [DisplayConnectionOutcome] = []
    var enabledAny = false
    for (display, entry) in candidates {
      let result: Result<Display, DisplayControlError>
      do {
        result = .success(
          try reconnect(
            display.uuid, entry: entry, acceptAlreadyActive: true,
            stopIfActive: stopIfActive && !enabledAny))
        enabledAny = true
      } catch let error as DisplayControlError {
        result = .failure(error)
      } catch let error as DisplayBecameActive {
        throw error
      } catch {
        result = .failure(.configurationFailed(String(describing: error)))
      }
      outcomes.append(DisplayConnectionOutcome(display: display, result: result))
    }
    guard let ledgerFailure else { return outcomes }
    return outcomes + [DisplayConnectionOutcome(display: nil, result: .failure(ledgerFailure))]
  }

  /// Records the display in the ledger, then disables it; a ledger failure leaves it untouched.
  public func disconnect(_ selector: String) throws -> Display {
    try operationLock.withLock {
      let displays = try snapshot.snapshot()
      let display = try DisplaySelector.resolve(selector, in: displays)
      guard display.isActive else {
        throw DisplayControlError.invalidState("Display \(display.runtimeID) is already inactive")
      }
      guard displays.filter(\.isUsableActive).count > 1 else {
        throw DisplayControlError.lastActiveDisplay
      }
      let entry = DisabledDisplayEntry(
        uuid: display.uuid, runtimeID: display.runtimeID, name: display.name, kind: display.kind,
        bootSession: try bootSession())
      try ledger.save(try ledger.load().filter { $0.uuid != display.uuid } + [entry])
      return try transition(display, enabled: false)
    }
  }

  /// Enables `uuid` by its current runtime ID, or by the entry's recorded ID when it is offline.
  private func reconnect(
    _ uuid: UUID,
    entry: DisabledDisplayEntry?,
    acceptAlreadyActive: Bool,
    stopIfActive: Bool = false
  ) throws -> Display {
    let displays = try snapshot.snapshot()
    if stopIfActive, displays.contains(where: \.isUsableActive) {
      throw DisplayBecameActive()
    }
    let matches = displays.filter { $0.uuid == uuid }
    guard matches.count <= 1 else {
      throw DisplayControlError.ambiguousSelector(uuid.uuidString)
    }

    let result: Display
    if let online = matches.first {
      if online.isActive {
        guard acceptAlreadyActive else {
          throw DisplayControlError.invalidState("Display \(online.runtimeID) is already active")
        }
        result = online
      } else {
        result = try transition(online, enabled: true)
      }
    } else if let entry {
      guard entry.bootSession == (try bootSession()) else {
        throw DisplayControlError.recoverySkipped(
          "Display \(uuid.uuidString) was disabled in an earlier boot; its recorded runtime ID "
            + "\(entry.runtimeID) is not trusted")
      }
      try requireRuntimeIDUnclaimed(entry.runtimeID, by: uuid, in: displays)
      try requireRuntimeIDNotMappedElsewhere(entry.runtimeID, by: uuid)
      result = try transition(entry.placeholder, enabled: true)
    } else {
      throw DisplayControlError.displayNotFound(uuid.uuidString)
    }
    removeEntry(uuid)
    return result
  }

  private func requireRuntimeIDUnclaimed(
    _ runtimeID: UInt32,
    by uuid: UUID,
    in displays: [Display]
  ) throws {
    if let holder = displays.first(where: { $0.runtimeID == runtimeID && $0.uuid != uuid }) {
      throw DisplayControlError.recoverySkipped(
        "Display \(uuid.uuidString) is offline and its recorded runtime ID \(runtimeID) is now "
          + "held by display \(holder.uuid.uuidString)")
    }
  }

  /// Skips an offline enable when Core Graphics maps the saved ID to another UUID right now.
  /// The short window between this check and the enable, under our lock, is accepted.
  private func requireRuntimeIDNotMappedElsewhere(_ runtimeID: UInt32, by uuid: UUID) throws {
    if let owner = runtimeIDOwner(runtimeID), owner != uuid {
      throw DisplayControlError.recoverySkipped(
        "Display \(uuid.uuidString) is offline and Core Graphics maps its recorded runtime ID "
          + "\(runtimeID) to display \(owner.uuidString)")
    }
  }

  /// Drops the entry of a display verified active; a failed write keeps it for `connect all`.
  private func removeEntry(_ uuid: UUID) {
    guard let entries = try? ledger.load(), entries.contains(where: { $0.uuid == uuid }) else {
      return
    }
    try? ledger.save(entries.filter { $0.uuid != uuid })
  }

  private func transition(_ display: Display, enabled: Bool) throws -> Display {
    try hardware.setEnabled(display.runtimeID, enabled: enabled)
    let refreshed: [Display]
    do {
      refreshed = try snapshot.snapshot()
    } catch {
      throw postconditionFailure(
        "Display \(display.uuid.uuidString) refresh failed after requesting enabled "
          + "\(enabled): \(error)",
        display: display,
        enabled: enabled
      )
    }

    // The last-active check ran before the disable; another display may have gone away since.
    if !enabled, !refreshed.contains(where: \.isUsableActive) {
      throw postconditionFailure(
        "Display \(display.uuid.uuidString) was disabled but no active display remains",
        display: display,
        enabled: enabled
      )
    }

    let matches = refreshed.filter { $0.uuid == display.uuid }
    // macOS drops a disabled display from the online list, so absence means disconnected (D-005).
    if !enabled, matches.isEmpty {
      return Display(
        uuid: display.uuid, runtimeID: display.runtimeID, name: display.name, kind: display.kind,
        isOnline: false, isActive: false, isMain: false, ddcCapability: display.ddcCapability)
    }
    guard matches.count == 1, let result = matches.first else {
      throw postconditionFailure(
        "Display \(display.uuid.uuidString) had \(matches.count) matches after requesting "
          + "enabled \(enabled)",
        display: display,
        enabled: enabled
      )
    }
    guard result.isActive == enabled else {
      let state = enabled ? "active" : "inactive"
      throw postconditionFailure(
        "Display \(display.uuid.uuidString) did not become \(state)",
        display: display,
        enabled: enabled
      )
    }
    return result
  }

  private func postconditionFailure(
    _ message: String,
    display: Display,
    enabled: Bool
  ) -> DisplayControlError {
    guard !enabled else {
      return .postconditionFailed(message)
    }
    return .postconditionFailed("\(message); \(rollback(display))")
  }

  /// Re-enables a display whose disable failed its postcondition, using the same identity rules
  /// as `connect`, and describes the result.
  private func rollback(_ display: Display) -> String {
    do {
      let displays = try snapshot.snapshot()
      let matches = displays.filter { $0.uuid == display.uuid }
      guard matches.count <= 1 else {
        throw DisplayControlError.ambiguousSelector(display.uuid.uuidString)
      }
      let target: Display
      if let online = matches.first {
        if online.isActive {
          removeEntry(display.uuid)
          return "rollback not needed, display \(online.runtimeID) is active"
        }
        target = online
      } else {
        try requireRuntimeIDUnclaimed(display.runtimeID, by: display.uuid, in: displays)
        try requireRuntimeIDNotMappedElsewhere(display.runtimeID, by: display.uuid)
        target = display
      }

      try hardware.setEnabled(target.runtimeID, enabled: true)
      let restored = try snapshot.snapshot().filter { $0.uuid == display.uuid }
      guard restored.count == 1, restored[0].isActive else {
        return "rollback enabled true for display \(target.runtimeID) did not restore it; "
          + "ledger entry kept"
      }
      removeEntry(display.uuid)
      return "rollback enabled true completed for display \(target.runtimeID)"
    } catch DisplayControlError.recoverySkipped(let reason) {
      return "rollback skipped: \(reason); ledger entry kept"
    } catch {
      return "rollback enabled true failed for display \(display.runtimeID): \(error); "
        + "ledger entry kept"
    }
  }
}

/// The Core Graphics calls one display configuration transaction makes; tests inject fakes.
/// Package-visible: only the CLI wiring and its tests use it.
package struct CoreGraphicsDisplayTransactionFunctions: @unchecked Sendable {
  let begin: (UnsafeMutablePointer<CGDisplayConfigRef?>) -> CGError
  let enable: (CGDisplayConfigRef?, CGDirectDisplayID, Bool) throws -> CGError
  let complete: (CGDisplayConfigRef?, CGConfigureOption) -> CGError
  let cancel: (CGDisplayConfigRef?) -> CGError

  package init(
    begin: @escaping (UnsafeMutablePointer<CGDisplayConfigRef?>) -> CGError,
    enable: @escaping (CGDisplayConfigRef?, CGDirectDisplayID, Bool) throws -> CGError,
    complete: @escaping (CGDisplayConfigRef?, CGConfigureOption) -> CGError,
    cancel: @escaping (CGDisplayConfigRef?) -> CGError
  ) {
    self.begin = begin
    self.enable = enable
    self.complete = complete
    self.cancel = cancel
  }

  /// The real Core Graphics calls, with `CGSConfigureDisplayEnabled` from the private bridge.
  package static func live() -> Self { live(bridge: PrivateAPIBridge()) }

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

/// Completes each change for the login session (`CGConfigureOption.forSession`).
public struct CoreGraphicsDisplayConnectionHardware: DisplayConnectionHardware {
  private let api: CoreGraphicsDisplayTransactionFunctions

  /// Creates live hardware.
  public init() {
    api = .live(bridge: PrivateAPIBridge())
  }

  /// Creates hardware that runs its transactions through `api`.
  package init(api: CoreGraphicsDisplayTransactionFunctions) {
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
