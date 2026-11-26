import AppKit
import CoreGraphics
import DisplayControlCore
import DisplayMenuKit
import os

/// Feeds display reconfigurations, wake and launch to the safety net and the panel.
@MainActor
final class SystemObservers {
  private let scheduler: RecoveryScheduler
  private let model: PanelModel
  private let logger = Logger(subsystem: "displayctl", category: "menu")
  private var wakeToken: (any NSObjectProtocol)?

  init(scheduler: RecoveryScheduler, model: PanelModel) {
    self.scheduler = scheduler
    self.model = model
  }

  func start() {
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
      let arrival = ContinuousClock.now
      MainActor.assumeIsolated { self?.handle(.wake, at: arrival) }
    }

    let scheduler = scheduler
    let arrival = ContinuousClock.now
    Task { await scheduler.trigger(.launch, at: arrival) }
  }

  /// `arrival` is stamped when macOS reports the event, so the scheduler can drop it by that time.
  fileprivate func handle(_ trigger: RecoveryTrigger, at arrival: ContinuousClock.Instant) {
    logger.notice("trigger \(trigger.rawValue, privacy: .public)")
    let scheduler = scheduler
    let model = model
    Task { await scheduler.trigger(trigger, at: arrival) }
    Task { await model.refresh() }
  }
}

/// Nonisolated C callback: skips begin events and hands the rest to the main actor.
private func displaysReconfigured(
  _ display: CGDirectDisplayID, _ flags: CGDisplayChangeSummaryFlags,
  _ context: UnsafeMutableRawPointer?
) {
  guard !flags.contains(.beginConfigurationFlag), let context else { return }
  let observers = Unmanaged<SystemObservers>.fromOpaque(context).takeUnretainedValue()
  let arrival = ContinuousClock.now
  Task { @MainActor in observers.handle(.reconfiguration, at: arrival) }
}
