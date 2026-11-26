import AppKit
import CoreGraphics
import DisplayControlCore
import DisplayMenuKit
import os

/// Feeds display reconfigurations, wake, launch and the periodic check to the safety net.
@MainActor
final class SystemObservers {
  private let scheduler: RecoveryScheduler
  private let model: PanelModel
  private let operations: any DisplayOperating
  private let logger = Logger(subsystem: "displayctl", category: "menu")
  private var wakeToken: (any NSObjectProtocol)?
  private var ledgerWatch: (any DispatchSourceFileSystemObject)?
  private var timer: Timer?
  private lazy var gate = PeriodicCheckGate(operations: operations) { [weak self] in
    self?.setPeriodicCheck($0)
  }

  init(scheduler: RecoveryScheduler, model: PanelModel, operations: any DisplayOperating) {
    self.scheduler = scheduler
    self.model = model
    self.operations = operations
  }

  func start() {
    // Hardware test switch: no event fast path, so only the periodic check can recover.
    if ProcessInfo.processInfo.environment["DISPLAYCTL_MENU_NO_EVENTS"] == "1" {
      logger.notice("DISPLAYCTL_MENU_NO_EVENTS=1: display and wake events off, periodic check only")
    } else {
      registerEvents()
    }
    watchLedgerDirectory()
    reloadGate()
    let scheduler = scheduler
    Task { await scheduler.trigger(.launch) }
  }

  private func registerEvents() {
    // The callback context is retained for the whole process and never released.
    let context = Unmanaged.passRetained(self).toOpaque()
    let error = CGDisplayRegisterReconfigurationCallback(displaysReconfigured, context)
    if error != .success {
      logger.error("display reconfiguration callback not registered: \(error.rawValue)")
      model.safetyNetNote = ErrorText.safetyNetOff
    }

    wakeToken = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.handle(.wake)
        self?.reloadGate()
      }
    }
  }

  fileprivate func handle(_ trigger: RecoveryTrigger) {
    logger.notice("trigger \(trigger.rawValue, privacy: .public)")
    let scheduler = scheduler
    let model = model
    Task { await scheduler.trigger(trigger) }
    Task { await model.refresh() }
  }

  private func reloadGate() {
    let gate = gate
    Task { await gate.reload() }
  }

  /// The CLI replaces the ledger atomically, so the directory, not the file, sees each write.
  private func watchLedgerDirectory() {
    let directory = DisplayControlState.defaultDirectory
    try? FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let descriptor = open(directory.path, O_EVTONLY)
    guard descriptor >= 0 else {
      logger.error("cannot watch \(directory.path, privacy: .public): errno \(errno)")
      return
    }
    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: descriptor, eventMask: .write, queue: .main)
    source.setEventHandler { [weak self] in
      MainActor.assumeIsolated { self?.reloadGate() }
    }
    source.setCancelHandler { close(descriptor) }
    source.resume()
    ledgerWatch = source
  }

  /// One timer with tolerance; Timer skips missed firings, so nothing is replayed after sleep.
  private func setPeriodicCheck(_ on: Bool) {
    timer?.invalidate()
    timer = nil
    logger.notice("periodic check \(on ? "on" : "off", privacy: .public)")
    guard on else { return }
    let scheduler = scheduler
    let timer = Timer(timeInterval: 10, repeats: true) { _ in
      Task { await scheduler.tick() }
    }
    timer.tolerance = 2
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
  }
}

/// Nonisolated C callback: skips begin events and hands the event to the main actor.
private func displaysReconfigured(
  _ display: CGDirectDisplayID, _ flags: CGDisplayChangeSummaryFlags,
  _ context: UnsafeMutableRawPointer?
) {
  guard !flags.contains(.beginConfigurationFlag), let context else { return }
  let observers = Unmanaged<SystemObservers>.fromOpaque(context).takeUnretainedValue()
  Task { @MainActor in observers.handle(.reconfiguration) }
}
