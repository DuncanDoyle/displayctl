import DisplayControlCore
import Foundation
import Observation

/// The panel's rows, notes and busy state, driven by refreshes and switch operations.
@MainActor @Observable
public final class PanelModel {
  public private(set) var rows: [DisplayRow] = []
  /// Set when the ledger cannot be read.
  public private(set) var panelNote: String?
  /// Set by the app when the display observer cannot be registered.
  public var safetyNetNote: String?
  public private(set) var isBusy = false
  public private(set) var isOpen = false

  @ObservationIgnored private let operations: any DisplayOperating
  @ObservationIgnored private let brightness: any BrightnessOperating
  @ObservationIgnored private var busyID: UUID?
  @ObservationIgnored private var errors: [UUID: String] = [:]
  @ObservationIgnored private var published = Loaded(displays: [], ledger: [], boot: "")
  @ObservationIgnored private var seq = 0
  @ObservationIgnored private var publishedSeq = 0

  private struct Loaded {
    var displays: [Display]
    var ledger: [DisabledDisplayEntry]
    var boot: String
    var ledgerUnreadable = false
  }

  public init(operations: any DisplayOperating, brightness: any BrightnessOperating) {
    self.operations = operations
    self.brightness = brightness
  }

  /// Clears every row error, then refreshes.
  public func panelOpened() async {
    isOpen = true
    errors = [:]
    rebuild()
    await refresh()
  }

  public func panelClosed() {
    isOpen = false
  }

  /// Takes a new snapshot; row errors stay.
  public func refresh() async {
    seq += 1
    let request = seq
    publish(await load(), request: request)
  }

  /// Turns one display on or off; ignored while another operation runs.
  public func setDisplay(_ id: UUID, on: Bool) async {
    guard busyID == nil else { return }
    busyID = id
    isBusy = true
    rebuild()

    var failure: String?
    do {
      if on {
        _ = try await operations.connect(id)
      } else {
        _ = try await operations.disconnect(id)
      }
    } catch {
      failure = ErrorText.short(error)
    }
    seq += 1
    let request = seq
    publish(await load(), request: request)

    // The operation owns its row's busy flag and error, whatever snapshot won.
    busyID = nil
    isBusy = false
    errors[id] = failure
    rebuild()
  }

  /// Returns nil when the snapshot fails; an unreadable ledger or boot ID only drops ledger rows.
  private func load() async -> Loaded? {
    guard let displays = try? await operations.snapshot() else { return nil }
    guard let ledger = try? await operations.disabledDisplays() else {
      return Loaded(displays: displays, ledger: [], boot: "", ledgerUnreadable: true)
    }
    guard !ledger.isEmpty, let boot = try? await operations.bootSession() else {
      return Loaded(displays: displays, ledger: [], boot: "")
    }
    return Loaded(displays: displays, ledger: ledger, boot: boot)
  }

  /// Publishes only if no later snapshot request has been published.
  private func publish(_ loaded: Loaded?, request: Int) {
    guard let loaded, request > publishedSeq else { return }
    publishedSeq = request
    published = loaded
    panelNote = loaded.ledgerUnreadable ? ErrorText.ledgerUnreadable : nil
    rebuild()
  }

  private func rebuild() {
    rows = PanelRows.make(
      displays: published.displays, ledger: published.ledger, currentBoot: published.boot,
      busy: busyID, errors: errors)
    // A display that left takes its error with it.
    let ids = Set(rows.map(\.id))
    errors = errors.filter { ids.contains($0.key) }
  }
}
