import DisplayControlCore
import Foundation
import XCTest

@testable import displayctl

final class CLIParserTests: XCTestCase {
  private let display = Display(
    uuid: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!, runtimeID: 42,
    name: "Desk Display", kind: .external, isOnline: true, isActive: true,
    isMain: false, ddcCapability: .confirmed)
  private var inactiveDisplay: Display {
    Display(
      uuid: display.uuid, runtimeID: 42, name: "Desk Display", kind: .external,
      isOnline: true, isActive: false, isMain: false, ddcCapability: .confirmed)
  }

  func testParsesEveryDocumentedCommand() throws {
    let cases: [([String], CLICommand)] = [
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
    for (arguments, expected) in cases {
      XCTAssertEqual(try CLIParser.parse(arguments), expected, "arguments: \(arguments)")
    }
  }

  func testRejectsInvalidCommandsAsInvalidArguments() {
    let cases = [
      ["list", "--yaml"], ["list", "--json", "extra"], ["connect"],
      ["connect", "all", "extra"], ["disconnect"], ["brightness"],
      ["brightness", "get"], ["brightness", "set", "external"],
      ["brightness", "set", "external", "nope"],
      ["brightness", "set", "external", "-1"],
      ["brightness", "set", "external", "101"], ["connect", "--force"],
      ["brightness", "get", "--json"], ["unknown"], ["--version"],
    ]
    for arguments in cases {
      XCTAssertThrowsError(try CLIParser.parse(arguments)) { error in
        guard case DisplayControlError.invalidArguments = error else {
          return XCTFail("Expected invalidArguments for \(arguments), got \(error)")
        }
      }
    }
  }

  func testHelpContainsCompleteSynopsis() async {
    let result = await CLIApplication(service: StubService()).execute(.help)
    XCTAssertEqual(result.exitCode, 0)
    for command in [
      "displayctl list [--json]", "displayctl connect <selector>",
      "displayctl connect all", "displayctl disconnect <selector>",
      "displayctl brightness get <selector>",
      "displayctl brightness set <selector> <0...100>",
    ] { XCTAssertTrue(result.stdout.contains(command)) }
  }

  func testParsingHelpAndErrorsDoesNotCreateLiveService() async {
    var creations = 0
    for arguments in [[], ["--help"], ["unknown"]] {
      let result = await CLIApplication.run(arguments: arguments) {
        creations += 1
        return StubService()
      }
      XCTAssertEqual(result.exitCode, arguments == ["unknown"] ? 64 : 0)
    }
    XCTAssertEqual(creations, 0)
  }

  func testRendersStableHumanAndJSONLists() async throws {
    let service = StubService(displays: [display])
    let human = await CLIApplication(service: service).execute(.list(json: false))
    for value in [
      "UUID", "runtimeID", "name", "kind", "online", "active", "main", "DDC",
      display.uuid.uuidString, "42", "Desk Display", "external", "confirmed",
    ] {
      XCTAssertTrue(human.stdout.contains(value), "missing \(value)")
    }
    let json = await CLIApplication(service: service).execute(.list(json: true))
    XCTAssertEqual(json.exitCode, 0)
    XCTAssertTrue(json.stdout.contains("\"ddcCapability\":\"confirmed\",\"isActive\":true"))
    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(json.stdout.utf8)) as? [[String: Any]])
    XCTAssertEqual(
      Set(object[0].keys),
      ["uuid", "runtimeID", "name", "kind", "isOnline", "isActive", "isMain", "ddcCapability"])
  }

  func testRendersMutationAndBrightnessSuccesses() async {
    let app = CLIApplication(service: StubService(displays: [display, inactiveDisplay]))
    let connected = await app.execute(.connect(selector: "external"))
    let disconnected = await app.execute(.disconnect(selector: "external"))
    XCTAssertTrue(connected.stdout.contains("runtimeID=42 name=Desk Display active=true"))
    XCTAssertTrue(disconnected.stdout.contains("runtimeID=42 name=Desk Display active=false"))
    let get = await app.execute(.brightnessGet(selector: "external"))
    XCTAssertTrue(get.stdout.contains("brightness=40/80"))
    let set = await app.execute(.brightnessSet(selector: "external", percent: 75))
    XCTAssertTrue(set.stdout.contains("brightness=75%"))
  }

  func testConnectAllReportsEveryIdentityAndFailsIfAnyOutcomeFails() async {
    let failed = Display(
      uuid: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!, runtimeID: 9,
      name: "Failed", kind: .external, isOnline: true, isActive: false,
      isMain: false, ddcCapability: .unknown)
    let outcomes = [
      DisplayConnectionOutcome(display: display, result: .success(display)),
      DisplayConnectionOutcome(display: failed, result: .failure(.configurationFailed("boom"))),
    ]
    let result = await CLIApplication(service: StubService(outcomes: outcomes)).execute(.connectAll)
    XCTAssertEqual(result.exitCode, 1)
    XCTAssertTrue(result.stdout.contains(display.uuid.uuidString))
    XCTAssertTrue(result.stderr.contains(failed.uuid.uuidString))
    XCTAssertTrue(result.stderr.contains("boom"))
  }

  func testWritesErrorsToStderrAndMapsExitCodes() async {
    let cases: [(DisplayControlError, Int32)] = [
      (.invalidArguments("usage"), 64), (.unsupportedAPI("missing"), 69),
      (.ddcUnsupported, 69), (.ddcServiceNotFound, 69), (.ddcServiceAmbiguous, 69),
      (.ddcTimeout, 75), (.ddcTransport("I2C"), 75),
      (.configurationFailed("failed"), 1), (.postconditionFailed("failed"), 1),
    ]
    for (error, code) in cases {
      let result = await CLIApplication(service: StubService(error: error)).execute(
        .list(json: false))
      XCTAssertEqual(result.exitCode, code, "error: \(error)")
      XCTAssertTrue(result.stdout.isEmpty)
      XCTAssertFalse(result.stderr.isEmpty)
    }
  }
}

private struct StubService: CLIService {
  var displays: [Display] = []
  var outcomes: [DisplayConnectionOutcome] = []
  var error: DisplayControlError?
  func list() async throws -> [Display] { try value(displays) }
  func connect(_ selector: String) async throws -> Display { try value(displays[0]) }
  func connectAll() async throws -> [DisplayConnectionOutcome] { try value(outcomes) }
  func disconnect(_ selector: String) async throws -> Display { try value(displays.last!) }
  func brightnessGet(_ selector: String) async throws -> BrightnessReading {
    try value(BrightnessReading(display: displays[0], value: DDCValue(current: 40, maximum: 80)))
  }
  func brightnessSet(_ selector: String, percent: Int) async throws -> Display {
    try value(displays[0])
  }
  private func value<T>(_ value: T) throws -> T {
    if let error { throw error }
    return value
  }
}
