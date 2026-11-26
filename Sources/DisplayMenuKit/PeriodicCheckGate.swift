import DisplayControlCore

/// Turns the safety net's periodic check on while the ledger has a current-boot entry (D-014).
/// An unreadable ledger keeps it on: a tick only reads the display count.
@MainActor
public final class PeriodicCheckGate {
  public private(set) var isRunning = false
  private let operations: any DisplayOperating
  private let onChange: @MainActor (Bool) -> Void
  private var generation = 0

  /// `onChange` runs when the check should start (true) or stop (false).
  public init(operations: any DisplayOperating, onChange: @escaping @MainActor (Bool) -> Void) {
    self.operations = operations
    self.onChange = onChange
  }

  /// Reads the ledger again; a reload that a later one overtook is ignored.
  public func reload() async {
    generation += 1
    let id = generation
    let running: Bool
    do {
      let boot = try await operations.bootSession()
      running = try await operations.disabledDisplays().contains { $0.bootSession == boot }
    } catch {
      running = true
    }
    guard id == generation, running != isRunning else { return }
    isRunning = running
    onChange(running)
  }
}
