import DisplayControlCore
import Foundation
import XCTest

@testable import displayctl

final class CLIParserTests: XCTestCase {
  private let uuid = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
  private func display(
    uuid: UUID? = nil, id: UInt32 = 42, name: String = "Desk Display", active: Bool = true
  ) -> Display {
    Display(
      uuid: uuid ?? self.uuid, runtimeID: id, name: name, kind: .external,
      isOnline: true, isActive: active, isMain: false, ddcCapability: .confirmed)
  }
  func testParsesDocumentedCommandsAndRejectsInvalidArguments() throws {
    let valid: [([String], CLICommand)] = [
      ([], .help), (["--help"], .help), (["list"], .list(json: false)),
      (["list", "--json"], .list(json: true)),
      (["connect", "external"], .connect(selector: "external")),
      (["connect", "all"], .connectAll),
      (["disconnect", "42"], .disconnect(selector: "42")),
      (["brightness", "get", "external"], .brightnessGet(selector: "external")),
      (["brightness", "set", "external", "0"], .brightnessSet(selector: "external", percent: 0)),
      (
        ["brightness", "set", "external", "100"], .brightnessSet(selector: "external", percent: 100)
      ),
    ]
    for (arguments, command) in valid { XCTAssertEqual(try CLIParser.parse(arguments), command) }
    let invalid = [
      ["list", "--yaml"], ["list", "--json", "extra"], ["connect"], ["disconnect"],
      ["brightness", "get"], ["brightness", "set", "external"],
      ["brightness", "set", "external", "nope"], ["brightness", "set", "external", "-1"],
      ["brightness", "set", "external", "101"], ["connect", "--force"],
      ["disconnect", "all"], ["brightness", "get", "all"],
      ["brightness", "set", "all", "50"], ["unknown"],
    ]
    for arguments in invalid {
      XCTAssertThrowsError(try CLIParser.parse(arguments)) {
        guard case DisplayControlError.invalidArguments = $0 else { return XCTFail("\($0)") }
      }
    }
  }
  func testHelpIsCompleteAndParsingDoesNotCreateService() async {
    var creations = 0
    for arguments in [[], ["--help"], ["unknown"], ["disconnect", "all"]] {
      let result = await CLIApplication.run(arguments: arguments) {
        creations += 1
        return StubService()
      }
      XCTAssertEqual(result.exitCode, arguments.isEmpty || arguments == ["--help"] ? 0 : 64)
    }
    XCTAssertEqual(creations, 0)
    let help = await CLIApplication(service: StubService()).execute(.help)
    for synopsis in [
      "displayctl --help", "displayctl list [--json]", "displayctl connect <selector>",
      "displayctl connect all", "displayctl disconnect <selector>",
      "displayctl brightness get <selector>", "displayctl brightness set <selector> <0...100>",
    ] {
      XCTAssertTrue(help.stdout.contains(synopsis), synopsis)
    }
  }
  func testListOutputIsExactEscapedAndEmptyInventoryIsValid() async {
    let named = display(name: "Desk\\\t\n\r\u{1}")
    let app = CLIApplication(service: StubService(displays: [named]))
    let human = await app.execute(.list(json: false))
    XCTAssertEqual(
      human.stdout,
      "UUID\truntimeID\tname\tkind\tonline\tactive\tmain\tDDC\n"
        + "\(uuid.uuidString)\t42\tDesk\\\\\\t\\n\\r\\u{01}\texternal\ttrue\ttrue\tfalse\tconfirmed\n"
    )
    let json = await app.execute(.list(json: true))
    XCTAssertEqual(
      json.stdout,
      "[{\"ddcCapability\":\"confirmed\",\"isActive\":true,\"isMain\":false,\"isOnline\":true,"
        + "\"kind\":\"external\",\"name\":\"Desk\\\\\\t\\n\\r\\u0001\",\"runtimeID\":42,"
        + "\"uuid\":\"\(uuid.uuidString)\"}]\n")
    let empty = CLIApplication(service: StubService())
    let emptyJSON = await empty.execute(.list(json: true))
    let emptyHuman = await empty.execute(.list(json: false))
    XCTAssertEqual(emptyJSON, CLIResult(stdout: "[]\n"))
    XCTAssertEqual(
      emptyHuman,
      CLIResult(
        stdout: "UUID\truntimeID\tname\tkind\tonline\tactive\tmain\tDDC\n"))
  }
  func testDispatchForwardsArgumentsAndRendersVerifiedResults() async {
    let service = StubService(displays: [
      display(name: "Desk\\\t\n"), display(name: "Desk\\\t\n", active: false),
    ])
    let app = CLIApplication(service: service)
    let connect = await app.execute(.connect(selector: "external"))
    let disconnect = await app.execute(.disconnect(selector: "42"))
    let get = await app.execute(.brightnessGet(selector: "external"))
    let set = await app.execute(.brightnessSet(selector: "42", percent: 75))
    let identity = "uuid=\(uuid.uuidString) runtimeID=42 name=Desk\\\\\\t\\n"
    XCTAssertEqual(connect.stdout, "connected \(identity) active=true\n")
    XCTAssertEqual(disconnect.stdout, "disconnected \(identity) active=false\n")
    XCTAssertTrue(get.stdout.contains("brightness=40/80"))
    XCTAssertTrue(set.stdout.contains("brightness=75%"))
    let calls = await service.calls
    XCTAssertEqual(
      calls, ["connect:external", "disconnect:42", "get:external", "set:42:75"])
  }
  func testConnectAllUsesVerifiedSuccessIdentityAndCandidateFailureIdentity() async {
    let candidate = display(id: 9, name: "Candidate", active: false)
    let connected = display(id: 10, name: "Verified")
    let failed = display(
      uuid: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
      id: 11, name: "Failed", active: false)
    let outcomes = [
      DisplayConnectionOutcome(display: candidate, result: .success(connected)),
      DisplayConnectionOutcome(display: failed, result: .failure(.configurationFailed("boom"))),
    ]
    let result = await CLIApplication(service: StubService(outcomes: outcomes)).execute(.connectAll)
    XCTAssertEqual(
      result.stdout,
      "connected uuid=\(uuid.uuidString) runtimeID=10 name=Verified active=true\n")
    XCTAssertEqual(
      result.stderr,
      "uuid=\(failed.uuid.uuidString) runtimeID=11 name=Failed: Display configuration failed: boom\n"
    )
    XCTAssertEqual(result.exitCode, 1)
  }
  func testEveryTypedErrorHasExactContextAndExitCode() async {
    let cases: [(DisplayControlError, String, Int32)] = [
      (.invalidArguments("bad"), "Invalid arguments: bad", 64),
      (.displayNotFound("x"), "Display not found: x", 1),
      (.ambiguousSelector("external"), "Ambiguous display selector: external", 1),
      (.invalidState("active"), "Invalid display state: active", 1),
      (.lastActiveDisplay, "Cannot disconnect the last active display", 1),
      (.unsupportedAPI("CGS"), "Unsupported API: CGS", 69),
      (.configurationFailed("CG"), "Display configuration failed: CG", 1),
      (.postconditionFailed("state"), "Display postcondition failed: state", 1),
      (.recoverySkipped("boot"), "Recovery skipped: boot", 1),
      (.ddcServiceNotFound, "DDC service not found", 69),
      (.ddcServiceAmbiguous, "DDC service match is ambiguous", 69),
      (.ddcUnsupported, "DDC is unsupported", 69), (.ddcTimeout, "DDC operation timed out", 75),
      (.ddcTransport("I2C"), "DDC transport failed: I2C", 75),
      (.ddcInvalidResponse("checksum"), "Invalid DDC response: checksum", 1),
    ]
    for (error, message, code) in cases {
      let result = await CLIApplication(service: StubService(error: error)).execute(
        .list(json: false))
      XCTAssertEqual(result, CLIResult(stderr: "error: \(message)\n", exitCode: code))
    }
  }
  // Acceptance test 9 (CLI part).
  func testParsesTrialAndForgetAndRejectsBadTrialValues() async throws {
    let valid: [([String], CLICommand)] = [
      (["disconnect", "42", "--trial", "1"], .disconnectTrial(selector: "42", seconds: 1)),
      (
        ["disconnect", "internal", "--trial", "60"],
        .disconnectTrial(selector: "internal", seconds: 60)
      ),
      (["forget", "all"], .forgetAll),
      (["forget", uuid.uuidString.lowercased()], .forget(uuid: uuid)),
    ]
    for (arguments, command) in valid { XCTAssertEqual(try CLIParser.parse(arguments), command) }
    let invalid = [
      ["disconnect", "42", "--trial"], ["disconnect", "42", "--trial", "0"],
      ["disconnect", "42", "--trial", "61"], ["disconnect", "42", "--trial", "x"],
      ["disconnect", "42", "--trial", "5", "extra"], ["disconnect", "--trial", "5"],
      ["disconnect", "all", "--trial", "5"], ["forget"], ["forget", "42"],
      ["forget", "all", "extra"],
    ]
    for arguments in invalid {
      let result = await CLIApplication.run(arguments: arguments) { StubService() }
      XCTAssertEqual(result.exitCode, 64, "\(arguments)")
    }
  }
  func testTrialDisconnectUsesAppOnlyHardwareAndHoldsProcess() async {
    XCTAssertEqual(LiveCLIService.hardware(trial: true).scope, .appOnly)
    XCTAssertEqual(LiveCLIService.hardware(trial: false).scope, .session)
    let service = StubService(displays: [display(active: false)])
    let result = await CLIApplication(service: service).execute(
      .disconnectTrial(selector: "42", seconds: 5))
    XCTAssertEqual(
      result,
      CLIResult(
        stdout:
          "disconnected uuid=\(uuid.uuidString) runtimeID=42 name=Desk Display active=false\n",
        holdSeconds: 5))
    let calls = await service.calls
    XCTAssertEqual(calls, ["trial:42"])
    let help = await CLIApplication(service: service).execute(.help)
    XCTAssertTrue(help.stdout.contains("displayctl disconnect <selector> [--trial <1...60>]"))
    XCTAssertTrue(help.stdout.contains("displayctl forget <uuid|all>"))
  }
  func testForgetReportsRemovedEntries() async {
    let entry = DisabledDisplayEntry(
      uuid: uuid, runtimeID: 3, name: "Dell", kind: .external, bootTime: 1)
    let service = StubService(entries: [entry])
    let app = CLIApplication(service: service)
    let one = await app.execute(.forget(uuid: uuid))
    let all = await app.execute(.forgetAll)
    let line = "forgot uuid=\(uuid.uuidString) runtimeID=3 name=Dell\n"
    XCTAssertEqual(one, CLIResult(stdout: line))
    XCTAssertEqual(all, CLIResult(stdout: line))
    let calls = await service.calls
    XCTAssertEqual(calls, ["forget:\(uuid.uuidString)", "forget:all"])
  }
  func testListNotesLedgerDisplaysThatAreNotOnline() async {
    let hidden = DisabledDisplayEntry(
      uuid: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!, runtimeID: 3,
      name: "Dell", kind: .external, bootTime: 1)
    let online = DisabledDisplayEntry(
      uuid: uuid, runtimeID: 42, name: "Desk Display", kind: .external, bootTime: 1)
    let app = CLIApplication(
      service: StubService(displays: [display()], entries: [hidden, online]))
    let result = await app.execute(.list(json: false))
    XCTAssertEqual(
      result.stderr,
      "note: disabled by displayctl and not online: uuid=\(hidden.uuid.uuidString) runtimeID=3 "
        + "name=Dell\n")
    XCTAssertEqual(result.exitCode, 0)
  }
}
private actor StubService: CLIService {
  let displays: [Display]
  let outcomes: [DisplayConnectionOutcome]
  let error: DisplayControlError?
  let entries: [DisabledDisplayEntry]
  var calls: [String] = []
  init(
    displays: [Display] = [], outcomes: [DisplayConnectionOutcome] = [],
    error: DisplayControlError? = nil, entries: [DisabledDisplayEntry] = []
  ) {
    self.displays = displays
    self.outcomes = outcomes
    self.error = error
    self.entries = entries
  }
  func disconnectTrial(_ selector: String) async throws -> Display {
    calls.append("trial:\(selector)")
    return try checked(displays.last)
  }
  func forget(_ uuid: UUID?) async throws -> [DisabledDisplayEntry] {
    calls.append("forget:\(uuid?.uuidString ?? "all")")
    return try checked(entries)
  }
  func disabledDisplays() async throws -> [DisabledDisplayEntry] { try checked(entries) }
  func list() async throws -> [Display] { try checked(displays) }
  func connect(_ selector: String) async throws -> Display {
    calls.append("connect:\(selector)")
    return try checked(displays.first)
  }
  func connectAll() async throws -> [DisplayConnectionOutcome] { try checked(outcomes) }
  func disconnect(_ selector: String) async throws -> Display {
    calls.append("disconnect:\(selector)")
    return try checked(displays.last)
  }
  func brightnessGet(_ selector: String) async throws -> (Display, DDCValue) {
    calls.append("get:\(selector)")
    return try (checked(displays.first), DDCValue(current: 40, maximum: 80))
  }
  func brightnessSet(_ selector: String, percent: Int) async throws -> Display {
    calls.append("set:\(selector):\(percent)")
    return try checked(displays.first)
  }
  private func checked<T>(_ value: T?) throws -> T {
    if let error { throw error }
    guard let value else { throw DisplayControlError.configurationFailed("stub missing value") }
    return value
  }
}
