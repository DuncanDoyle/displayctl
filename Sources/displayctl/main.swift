import Darwin
import DisplayControlCore
import Foundation

enum CLICommand: Equatable {
  case help
  case list(json: Bool)
  case connect(selector: String)
  case connectAll
  case disconnect(selector: String)
  case forget(uuid: UUID)
  case forgetAll
  case brightnessGet(selector: String)
  case brightnessSet(selector: String, percent: Int)
}
enum CLIParser {
  static func parse(_ arguments: [String]) throws -> CLICommand {
    switch arguments {
    case [], ["--help"]:
      return .help
    case ["list"]:
      return .list(json: false)
    case ["list", "--json"]:
      return .list(json: true)
    case ["connect", "all"]:
      return .connectAll
    default:
      break
    }
    if arguments.count == 2, arguments[0] == "connect" {
      return .connect(selector: try parseSelector(arguments[1]))
    }
    if arguments.count == 2, arguments[0] == "disconnect" {
      return .disconnect(selector: try parseSelector(arguments[1]))
    }
    if arguments == ["forget", "all"] {
      return .forgetAll
    }
    if arguments.count == 2, arguments[0] == "forget" {
      guard let uuid = UUID(uuidString: arguments[1]) else {
        throw DisplayControlError.invalidArguments("forget needs a display UUID or all")
      }
      return .forget(uuid: uuid)
    }
    if arguments.count == 3, arguments[0...1] == ["brightness", "get"] {
      return .brightnessGet(selector: try parseSelector(arguments[2]))
    }
    if arguments.count == 4, arguments[0...1] == ["brightness", "set"] {
      let selector = try parseSelector(arguments[2])
      let rawPercent = arguments[3]
      guard let percent = Int(rawPercent), 0...100 ~= percent else {
        throw DisplayControlError.invalidArguments(
          "Brightness percent must be an integer between 0 and 100")
      }
      return .brightnessSet(selector: selector, percent: percent)
    }
    throw DisplayControlError.invalidArguments("Invalid command or arguments")
  }
  private static func parseSelector(_ value: String) throws -> String {
    guard !value.isEmpty, !value.hasPrefix("-"), value != "all" else {
      throw DisplayControlError.invalidArguments("Invalid display selector")
    }
    return value
  }
}
protocol CLIService: Sendable {
  func list() async throws -> [Display]
  func connect(_ selector: String) async throws -> Display
  func connectAll() async throws -> [DisplayConnectionOutcome]
  func disconnect(_ selector: String) async throws -> Display
  func forget(_ uuid: UUID?) async throws -> [DisabledDisplayEntry]
  func disabledDisplays() async throws -> [DisabledDisplayEntry]
  func brightnessGet(_ selector: String) async throws -> (Display, DDCValue)
  func brightnessSet(_ selector: String, percent: Int) async throws -> Display
}
struct LiveCLIService: CLIService {
  private let inventory: any DisplaySnapshotProviding
  private let connection: ConnectionController
  private let brightness: DDCBrightnessController
  init(
    inventory: any DisplaySnapshotProviding = DisplayInventory(),
    transaction: CoreGraphicsDisplayTransactionFunctions = .live(),
    stateDirectory: URL = DisplayControlState.defaultDirectory
  ) {
    self.inventory = inventory
    connection = ConnectionController(
      snapshot: inventory,
      hardware: CoreGraphicsDisplayConnectionHardware(api: transaction),
      stateDirectory: stateDirectory)
    brightness = DDCBrightnessController()
  }
  func list() async throws -> [Display] { try inventory.snapshot() }
  func connect(_ selector: String) async throws -> Display { try connection.connect(selector) }
  func connectAll() async throws -> [DisplayConnectionOutcome] { try connection.connectAll() }
  func disconnect(_ selector: String) async throws -> Display {
    try connection.disconnect(selector)
  }
  func forget(_ uuid: UUID?) async throws -> [DisabledDisplayEntry] {
    guard let uuid else { return try connection.forgetAll() }
    return [try connection.forget(uuid)]
  }
  func disabledDisplays() async throws -> [DisabledDisplayEntry] {
    try connection.disabledDisplays()
  }
  func brightnessGet(_ selector: String) async throws -> (Display, DDCValue) {
    let display = try DisplaySelector.resolve(selector, in: inventory.snapshot())
    return try await (display, brightness.get(display: display))
  }
  func brightnessSet(_ selector: String, percent: Int) async throws -> Display {
    let display = try DisplaySelector.resolve(selector, in: inventory.snapshot())
    try await brightness.set(percent: percent, display: display)
    return display
  }
}
struct CLIResult: Equatable, Sendable {
  var stdout = ""
  var stderr = ""
  var exitCode: Int32 = 0
}
struct CLIApplication: Sendable {
  static let help = """
    Usage:
      displayctl --help
      displayctl list [--json]
      displayctl connect <selector>
      displayctl connect all
      displayctl disconnect <selector>
      displayctl forget <uuid|all>
      displayctl brightness get <selector>
      displayctl brightness set <selector> <0...100>

    Selectors: display UUID, runtime display ID, internal, or external.
    A disconnected display leaves macOS's display list; connect still finds it by
    UUID, internal, or external. connect all brings back every display it turned off.
    forget drops recorded displays without changing any display.
    The last active display is never disconnected.

    Examples:
      displayctl disconnect internal         # turn off the built-in screen
      displayctl connect internal            # turn it back on
      displayctl brightness set external 40  # hardware brightness via DDC/CI
      displayctl brightness get external

    Exit codes: 0 ok, 64 usage, 69 unsupported, 75 temporary (DDC, busy, displays changing; retry), 1 other.
    """
  private let service: any CLIService
  init(service: any CLIService) { self.service = service }
  static func run(
    arguments: [String],
    serviceFactory: () -> any CLIService
  ) async -> CLIResult {
    do {
      let command = try CLIParser.parse(arguments)
      if command == .help { return CLIResult(stdout: help + "\n") }
      return await CLIApplication(service: serviceFactory()).execute(command)
    } catch {
      return failure(error)
    }
  }
  func execute(_ command: CLICommand) async -> CLIResult {
    do {
      switch command {
      case .help:
        return CLIResult(stdout: Self.help + "\n")
      case .list(let json):
        let displays = try await service.list()
        // The macOS placeholder (D-012) is not a usable display: noted on stderr only.
        let placeholderNote = displays.filter(\.isPlaceholder).map {
          "note: macOS placeholder display present (id \($0.runtimeID))\n"
        }.joined()
        return CLIResult(
          stdout: try renderList(displays.filter { !$0.isPlaceholder }, json: json),
          stderr: placeholderNote + (await ledgerOnlyNote(displays)) + Self.debugNote())
      case .connect(let selector):
        return CLIResult(stdout: mutation("connected", try await service.connect(selector)))
      case .disconnect(let selector):
        return CLIResult(stdout: mutation("disconnected", try await service.disconnect(selector)))
      case .connectAll:
        return try await connectAll()
      case .forget(let uuid):
        return CLIResult(stdout: forgotten(try await service.forget(uuid)))
      case .forgetAll:
        return CLIResult(stdout: forgotten(try await service.forget(nil)))
      case .brightnessGet(let selector):
        let (display, value) = try await service.brightnessGet(selector)
        return CLIResult(
          stdout: "\(identity(display)) brightness=\(value.current)/\(value.maximum)\n"
        )
      case .brightnessSet(let selector, let percent):
        let display = try await service.brightnessSet(selector, percent: percent)
        return CLIResult(stdout: "\(identity(display)) brightness=\(percent)%\n")
      }
    } catch {
      return Self.failure(error)
    }
  }
  private func connectAll() async throws -> CLIResult {
    var result = CLIResult()
    for outcome in try await service.connectAll() {
      switch outcome.result {
      case .success(let connected):
        result.stdout += "connected \(identity(connected)) active=\(connected.isActive)\n"
      case .failure(let error):
        let subject = outcome.display.map(identity) ?? "ledger"
        result.stderr += "\(subject): \(Self.describe(error))\n"
        result.exitCode = max(result.exitCode, Self.exitCode(for: error))
      }
    }
    return result
  }
  private func renderList(_ displays: [Display], json: Bool) throws -> String {
    if json {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      return String(decoding: try encoder.encode(displays), as: UTF8.self) + "\n"
    }
    var lines = ["UUID\truntimeID\tname\tkind\tonline\tactive\tmain\tDDC"]
    lines += displays.map {
      "\($0.uuid.uuidString)\t\($0.runtimeID)\t\(escape($0.name))\t\($0.kind.rawValue)\t"
        + "\($0.isOnline)\t\($0.isActive)\t\($0.isMain)\t\($0.ddcCapability.rawValue)"
    }
    return lines.joined(separator: "\n") + "\n"
  }
  /// Names ledger displays macOS no longer lists; a ledger read failure is not a list failure.
  private func ledgerOnlyNote(_ displays: [Display]) async -> String {
    let online = Set(displays.map(\.uuid))
    let entries = (try? await service.disabledDisplays()) ?? []
    return entries.filter { !online.contains($0.uuid) }.map {
      "note: disabled by displayctl and not online: uuid=\($0.uuid.uuidString) "
        + "runtimeID=\($0.runtimeID) name=\(escape($0.name))\n"
    }.joined()
  }
  private func forgotten(_ entries: [DisabledDisplayEntry]) -> String {
    entries.map {
      "forgot uuid=\($0.uuid.uuidString) runtimeID=\($0.runtimeID) name=\(escape($0.name))\n"
    }.joined()
  }
  private func mutation(_ verb: String, _ display: Display) -> String {
    "\(verb) \(identity(display)) active=\(display.isActive)\n"
  }
  private func identity(_ display: Display) -> String {
    "uuid=\(display.uuid.uuidString) runtimeID=\(display.runtimeID) name=\(escape(display.name))"
  }
  private func escape(_ value: String) -> String {
    String(String(reflecting: value).dropFirst().dropLast())
  }
  /// With DISPLAYCTL_DEBUG set, `list` also prints the raw placeholder signals (D-012).
  private static func debugNote() -> String {
    guard ProcessInfo.processInfo.environment["DISPLAYCTL_DEBUG"] != nil else { return "" }
    return DisplayInventory.placeholderDiagnostics().map { "debug: \($0)\n" }.joined()
  }

  private static func failure(_ error: Error) -> CLIResult {
    let typed = error as? DisplayControlError
    return CLIResult(
      stderr: "error: \(typed.map(describe) ?? String(describing: error))\n",
      exitCode: typed.map(exitCode) ?? 1)
  }
  private static func exitCode(for error: DisplayControlError) -> Int32 {
    switch error {
    case .invalidArguments: 64
    case .unsupportedAPI, .ddcUnsupported, .ddcServiceNotFound, .ddcServiceAmbiguous: 69
    case .ddcTimeout, .ddcTransport, .ddcInvalidResponse, .lockTimeout, .inventoryChanged: 75
    default: 1
    }
  }
  private static func describe(_ error: DisplayControlError) -> String {
    switch error {
    case .invalidArguments(let message): "Invalid arguments: \(message)"
    case .displayNotFound(let selector): "Display not found: \(selector)"
    case .ambiguousSelector(let selector): "Ambiguous display selector: \(selector)"
    case .invalidState(let message): "Invalid display state: \(message)"
    case .lastActiveDisplay: "Cannot disconnect the last active display"
    case .unsupportedAPI(let message): "Unsupported API: \(message)"
    case .configurationFailed(let message): "Display configuration failed: \(message)"
    case .postconditionFailed(let message): "Display postcondition failed: \(message)"
    case .recoverySkipped(let message): "Recovery skipped: \(message)"
    case .lockTimeout: "Another displayctl command is running; try again"
    case .inventoryChanged: "Display setup changed while reading it; try again"
    case .ddcServiceNotFound: "DDC service not found"
    case .ddcServiceAmbiguous: "DDC service match is ambiguous"
    case .ddcUnsupported: "DDC is unsupported"
    case .ddcTimeout: "DDC operation timed out"
    case .ddcTransport(let message): "DDC transport failed: \(message)"
    case .ddcInvalidResponse(let message): "Invalid DDC response: \(message)"
    }
  }
}
let cliResult = await CLIApplication.run(
  arguments: Array(CommandLine.arguments.dropFirst()),
  serviceFactory: { LiveCLIService() })
if !cliResult.stdout.isEmpty { FileHandle.standardOutput.write(Data(cliResult.stdout.utf8)) }
if !cliResult.stderr.isEmpty { FileHandle.standardError.write(Data(cliResult.stderr.utf8)) }
exit(cliResult.exitCode)
