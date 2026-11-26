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

  private var brightnessStates: [UUID: BrightnessState] = [:]
  @ObservationIgnored private(set) var coalescers: [UUID: BrightnessCoalescer] = [:]
  /// Rows that showed a slider at the last rebuild, and those still waiting for a read.
  @ObservationIgnored private var sliderIDs: Set<UUID> = []
  @ObservationIgnored private var unreadIDs: Set<UUID> = []
  /// Last value seen per display this run, kept after its row leaves.
  @ObservationIgnored private var lastKnown: [UUID: Int] = [:]
  /// A read result applies only if no newer read or slider value came after it and no write runs.
  @ObservationIgnored private var readTokens: [UUID: Int] = [:]
  @ObservationIgnored private var nextReadToken = 0

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

  /// Clears every row error, refreshes, then reads brightness for every row with a slider.
  public func panelOpened() async {
    isOpen = true
    errors = [:]
    rebuild()
    unreadIDs = sliderIDs
    await refresh()
  }

  public func panelClosed() {
    isOpen = false
    unreadIDs = []
  }

  /// Takes a new snapshot; row errors stay.
  public func refresh() async {
    seq += 1
    let request = seq
    publish(await load(), request: request)
    await readUnread()
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
    await readUnread()
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
    syncSliders()
  }

  /// Drops brightness for rows that lost their slider; queues a read for new ones while open.
  private func syncSliders() {
    let now = Set(rows.filter(\.showsBrightness).map(\.id))
    for id in sliderIDs.subtracting(now) {
      coalescers.removeValue(forKey: id)?.invalidate()
      brightnessStates[id] = nil
      readTokens[id] = nil
    }
    if isOpen { unreadIDs.formUnion(now.subtracting(sliderIDs)) }
    unreadIDs.formIntersection(now)
    sliderIDs = now
  }

  private func readUnread() async {
    while isOpen, let id = unreadIDs.sorted(by: { $0.uuidString < $1.uuidString }).first {
      unreadIDs.remove(id)
      await read(id)
    }
  }

  private func read(_ id: UUID) async {
    let token = takeReadToken(for: id)
    let result: Result<Int, any Error>
    do {
      result = .success(try await brightness.percent(for: id))
    } catch {
      result = .failure(error)
    }
    // A write still in flight makes the read stale; the slider keeps the submitted value.
    guard readTokens[id] == token, coalescers[id]?.isWriting != true else { return }
    switch result {
    case .success(let percent):
      lastKnown[id] = percent
      brightnessStates[id] = BrightnessState(percent: percent, sliderValue: percent, error: nil)
    case .failure(let error):
      brightnessStates[id] = BrightnessState(
        percent: nil, sliderValue: lastKnown[id] ?? 50, error: ErrorText.short(error))
    }
  }

  private func takeReadToken(for id: UUID) -> Int {
    nextReadToken += 1
    readTokens[id] = nextReadToken
    return nextReadToken
  }

  private func makeCoalescer(for id: UUID) -> BrightnessCoalescer {
    let brightness = brightness
    return BrightnessCoalescer(
      write: { try await brightness.set($0, for: id) },
      onError: { [weak self] message in
        // The coalescer reports from the main actor.
        MainActor.assumeIsolated { self?.writeFinished(id, error: message) }
      })
  }

  private func writeFinished(_ id: UUID, error: String?) {
    guard let state = brightnessStates[id] else { return }
    brightnessStates[id] = BrightnessState(
      percent: state.percent, sliderValue: state.sliderValue, error: error)
  }
}

/// Brightness shown under a row: `percent` is nil until a read succeeds (label "—").
public struct BrightnessState: Equatable, Sendable {
  public let percent: Int?
  /// Last value this app run saw, else 50.
  public let sliderValue: Int
  public let error: String?

  public init(percent: Int?, sliderValue: Int, error: String?) {
    self.percent = percent
    self.sliderValue = sliderValue
    self.error = error
  }
}

extension PanelModel {
  public func brightness(for id: UUID) -> BrightnessState? {
    brightnessStates[id]
  }

  /// Sends a slider value; ignored for rows without a slider.
  public func setBrightness(_ percent: Int, for id: UUID) {
    guard sliderIDs.contains(id) else { return }
    // A read still in flight must not move the slider back.
    _ = takeReadToken(for: id)
    lastKnown[id] = percent
    brightnessStates[id] = BrightnessState(
      percent: percent, sliderValue: percent, error: brightnessStates[id]?.error)
    let coalescer = coalescers[id] ?? makeCoalescer(for: id)
    coalescers[id] = coalescer
    coalescer.submit(percent)
  }
}
