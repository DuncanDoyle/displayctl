import CoreFoundation
import CoreGraphics
import Foundation
import IOKit

public struct DDCValue: Equatable, Sendable {
  public let current: UInt16
  public let maximum: UInt16

  public init(current: UInt16, maximum: UInt16) {
    self.current = current
    self.maximum = maximum
  }
}

public protocol DDCTransport: Sendable {
  func readVCP(_ code: UInt8, for display: Display) throws -> DDCValue
  func writeVCP(_ code: UInt8, value: UInt16, for display: Display) throws
}

struct DDCRetryPolicy: Sendable {
  let maxAttempts: Int
  let delayMicroseconds: UInt32

  static let `default` = DDCRetryPolicy(maxAttempts: 3, delayMicroseconds: 40_000)
}

public actor DDCBrightnessController {
  private static let brightnessCode: UInt8 = 0x10

  private let transport: any DDCTransport
  private let retryPolicy: DDCRetryPolicy
  private let sleeper: @Sendable (UInt32) -> Void

  public init(transport: any DDCTransport) {
    self.init(
      transport: transport,
      retryPolicy: .default,
      sleeper: { delay in usleep(delay) }
    )
  }

  init(
    transport: any DDCTransport,
    retryPolicy: DDCRetryPolicy,
    sleeper: @escaping @Sendable (UInt32) -> Void
  ) {
    self.transport = transport
    self.retryPolicy = retryPolicy
    self.sleeper = sleeper
  }

  public func get(display: Display) throws -> DDCValue {
    try validate(display: display)
    return try retrying {
      try transport.readVCP(Self.brightnessCode, for: display)
    }
  }

  public func set(percent: Int, display: Display) throws {
    try validate(display: display)
    guard 0...100 ~= percent else {
      throw DisplayControlError.invalidArguments("Brightness percent must be between 0 and 100")
    }

    let maximum: UInt16
    do {
      maximum = try retrying {
        try transport.readVCP(Self.brightnessCode, for: display).maximum
      }
    } catch DisplayControlError.ddcUnsupported {
      maximum = 100
    }

    let scaled = UInt16((UInt32(maximum) * UInt32(percent) + 50) / 100)
    try retrying {
      try transport.writeVCP(Self.brightnessCode, value: scaled, for: display)
    }
  }

  private func validate(display: Display) throws {
    guard display.kind == .external else {
      throw DisplayControlError.invalidArguments("DDC brightness requires an external display")
    }
  }

  private func retrying<T>(_ operation: () throws -> T) throws -> T {
    let attempts = max(1, retryPolicy.maxAttempts)
    for attempt in 1...attempts {
      do {
        return try operation()
      } catch {
        guard isRetryable(error), attempt < attempts else {
          throw error
        }
        sleeper(retryPolicy.delayMicroseconds)
      }
    }
    fatalError("Retry loop always returns or throws")
  }

  private func isRetryable(_ error: Error) -> Bool {
    switch error as? DisplayControlError {
    case .ddcTimeout, .ddcTransport, .ddcInvalidResponse:
      return true
    default:
      return false
    }
  }
}

enum DDCPacket {
  private static let chipAddress: UInt8 = 0x37
  private static let dataAddress: UInt8 = 0x51
  private static let displaySourceAddress: UInt8 = chipAddress << 1
  private static let replyChecksumSeed: UInt8 = 0x50

  static func writeVCP(code: UInt8, value: UInt16) -> [UInt8] {
    withWriteChecksum([
      0x84,
      0x03,
      code,
      UInt8(value >> 8),
      UInt8(value & 0xFF),
    ])
  }

  static func readVCP(code: UInt8) -> [UInt8] {
    withWriteChecksum([0x82, 0x01, code])
  }

  static func parseVCPReply(_ reply: [UInt8], expectedCode: UInt8) throws -> DDCValue {
    guard reply.count >= 11 else {
      throw invalidResponse("VCP reply is too short")
    }
    guard reply[0] == displaySourceAddress else {
      throw invalidResponse("VCP reply has an unexpected source address")
    }

    let encodedLength = reply[1]
    guard encodedLength & 0x80 != 0 else {
      throw invalidResponse("VCP reply length is not encoded")
    }
    let payloadLength = Int(encodedLength & 0x7F)
    guard payloadLength == 8, reply.count == payloadLength + 3 else {
      throw invalidResponse("VCP reply length does not match its payload")
    }
    guard reply.dropLast().reduce(replyChecksumSeed, ^) == reply.last else {
      throw invalidResponse("VCP reply checksum is invalid")
    }
    guard reply[2] == 0x02 else {
      throw invalidResponse("VCP reply has an unexpected opcode")
    }
    guard reply[4] == expectedCode else {
      throw invalidResponse("VCP reply contains an unexpected VCP code")
    }
    switch reply[3] {
    case 0x00:
      break
    case 0x01:
      throw DisplayControlError.ddcUnsupported
    default:
      throw invalidResponse("VCP reply contains an unknown result code")
    }

    let maximum = UInt16(reply[6]) << 8 | UInt16(reply[7])
    let current = UInt16(reply[8]) << 8 | UInt16(reply[9])
    return DDCValue(current: current, maximum: maximum)
  }

  private static func withWriteChecksum(_ packet: [UInt8]) -> [UInt8] {
    let checksumSeed = displaySourceAddress ^ dataAddress
    return packet + [packet.reduce(checksumSeed, ^)]
  }

  private static func invalidResponse(_ reason: String) -> DisplayControlError {
    .ddcInvalidResponse(reason)
  }
}

struct DDCDisplayIdentity: Equatable, Sendable {
  let edidUUID: String?
  let productName: String?
  let serial: String?
  let displayLocation: UInt64?
  let vendorID: UInt32?
  let productID: UInt32?
  let manufactureWeek: UInt8?
  let manufactureYear: UInt16?
  let physicalWidthMM: UInt16?
  let physicalHeightMM: UInt16?

  init(
    edidUUID: String?,
    productName: String?,
    serial: String?,
    displayLocation: UInt64?,
    vendorID: UInt32?,
    productID: UInt32?,
    manufactureWeek: UInt8?,
    manufactureYear: UInt16?,
    physicalWidthMM: UInt16?,
    physicalHeightMM: UInt16?
  ) {
    self.edidUUID = edidUUID
    self.productName = productName
    self.serial = serial
    self.displayLocation = displayLocation
    self.vendorID = vendorID
    self.productID = productID
    self.manufactureWeek = manufactureWeek
    self.manufactureYear = manufactureYear
    self.physicalWidthMM = physicalWidthMM
    self.physicalHeightMM = physicalHeightMM
  }

  init(display: Display) {
    self.init(
      display: display,
      cgMetadata: DDCDisplayCGMetadata(
        serialNumber: CGDisplaySerialNumber(display.runtimeID),
        vendorID: CGDisplayVendorNumber(display.runtimeID),
        productID: CGDisplayModelNumber(display.runtimeID)
      )
    )
  }

  init(display: Display, cgMetadata: DDCDisplayCGMetadata) {
    edidUUID = nil
    productName = display.name
    serial = cgMetadata.serialNumber == 0 ? nil : String(cgMetadata.serialNumber)
    displayLocation = nil
    vendorID = cgMetadata.vendorID == 0 ? nil : cgMetadata.vendorID
    productID = cgMetadata.productID == 0 ? nil : cgMetadata.productID
    manufactureWeek = nil
    manufactureYear = nil
    physicalWidthMM = nil
    physicalHeightMM = nil
  }
}

struct DDCDisplayCGMetadata: Sendable {
  let serialNumber: UInt32
  let vendorID: UInt32
  let productID: UInt32
}

struct DDCServiceCandidate: Equatable, Sendable {
  let serviceID: UInt64
  let isExternal: Bool
  let edidUUID: String?
  let productName: String?
  let serial: String?
  let displayLocation: UInt64?
  let vendorID: UInt32?
  let productID: UInt32?
  let manufactureWeek: UInt8?
  let manufactureYear: UInt16?
  let physicalWidthMM: UInt16?
  let physicalHeightMM: UInt16?
}

protocol DDCServiceResolving: Sendable {
  func resolve(for display: Display) throws -> DDCServiceCandidate
}

protocol DDCCandidateDetecting: Sendable {
  func capability(for display: Display) -> DDCCapability
}

struct ResolverDDCCandidateDetector: DDCCandidateDetecting {
  let resolver: any DDCServiceResolving

  func capability(for display: Display) -> DDCCapability {
    guard display.kind == .external else { return .unknown }
    do {
      _ = try resolver.resolve(for: display)
      return .candidate
    } catch DisplayControlError.ddcServiceNotFound {
      return .unsupported
    } catch {
      return .unknown
    }
  }
}

enum DDCServiceMatcher {
  // Any conflict-free location, serial, or EDID match passes the strong-identity gate;
  // EDID carries the lowest qualifying score.
  static let minimumScore = 60

  private static let displayLocationWeight = 100
  private static let serialWeight = 80
  private static let hardwareIdentityWeight = 60
  private static let normalizedNameWeight = 30
  private static let manufactureDateWeight = 20
  private static let physicalSizeWeight = 15

  static func select(
    for display: DDCDisplayIdentity,
    from candidates: [DDCServiceCandidate]
  ) throws -> DDCServiceCandidate {
    let scored =
      candidates
      .filter { $0.isExternal && isEligible($0, for: display) }
      .map { ($0, score($0, for: display)) }
    guard let bestScore = scored.map(\.1).max(), bestScore >= minimumScore else {
      throw DisplayControlError.ddcServiceNotFound
    }

    let bestCandidates = scored.filter { $0.1 == bestScore }.map(\.0)
    guard bestCandidates.count == 1, let bestCandidate = bestCandidates.first else {
      throw DisplayControlError.ddcServiceAmbiguous
    }
    return bestCandidate
  }

  static func score(_ candidate: DDCServiceCandidate, for display: DDCDisplayIdentity) -> Int {
    var score = 0

    if nonzeroEqual(candidate.displayLocation, display.displayLocation) {
      score += displayLocationWeight
    }
    if identityTokenEqual(candidate.serial, display.serial) {
      score += serialWeight
    }
    let edidMatches = identityTokenEqual(candidate.edidUUID, display.edidUUID)
    let vendorAndProductMatch =
      nonzeroEqual(candidate.vendorID, display.vendorID)
      && nonzeroEqual(candidate.productID, display.productID)
    if edidMatches || vendorAndProductMatch {
      score += hardwareIdentityWeight
    }
    let candidateName = normalizedName(candidate.productName)
    let displayName = normalizedName(display.productName)
    if let candidateName, candidateName == displayName {
      score += normalizedNameWeight
    }
    if nonzeroEqual(candidate.manufactureWeek, display.manufactureWeek),
      nonzeroEqual(candidate.manufactureYear, display.manufactureYear)
    {
      score += manufactureDateWeight
    }
    if nonzeroEqual(candidate.physicalWidthMM, display.physicalWidthMM),
      nonzeroEqual(candidate.physicalHeightMM, display.physicalHeightMM)
    {
      score += physicalSizeWeight
    }

    return score
  }

  private static func isEligible(
    _ candidate: DDCServiceCandidate,
    for display: DDCDisplayIdentity
  ) -> Bool {
    let hasConflict =
      nonzeroConflict(candidate.displayLocation, display.displayLocation)
      || identityTokenConflict(candidate.serial, display.serial)
      || identityTokenConflict(candidate.edidUUID, display.edidUUID)
    guard !hasConflict else { return false }

    return nonzeroEqual(candidate.displayLocation, display.displayLocation)
      || identityTokenEqual(candidate.serial, display.serial)
      || identityTokenEqual(candidate.edidUUID, display.edidUUID)
  }

  private static func identityTokenEqual(_ lhs: String?, _ rhs: String?) -> Bool {
    guard let lhs = normalizedIdentityToken(lhs), let rhs = normalizedIdentityToken(rhs) else {
      return false
    }
    return lhs == rhs
  }

  private static func identityTokenConflict(_ lhs: String?, _ rhs: String?) -> Bool {
    guard let lhs = normalizedIdentityToken(lhs), let rhs = normalizedIdentityToken(rhs) else {
      return false
    }
    return lhs != rhs
  }

  private static func nonemptyToken(_ value: String?) -> String? {
    guard let value else { return nil }
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return normalized.isEmpty ? nil : normalized
  }

  private static func normalizedIdentityToken(_ value: String?) -> String? {
    nonemptyToken(value)?.lowercased()
  }

  private static func normalizedName(_ value: String?) -> String? {
    guard let value else { return nil }
    let normalized =
      value
      .split(whereSeparator: \.isWhitespace)
      .joined(separator: " ")
      .lowercased()
    return normalized.isEmpty ? nil : normalized
  }

  private static func nonzeroEqual<T>(_ lhs: T?, _ rhs: T?) -> Bool where T: BinaryInteger {
    guard let lhs, let rhs, lhs != 0, rhs != 0 else { return false }
    return lhs == rhs
  }

  private static func nonzeroConflict<T>(_ lhs: T?, _ rhs: T?) -> Bool where T: BinaryInteger {
    guard let lhs, let rhs, lhs != 0, rhs != 0 else { return false }
    return lhs != rhs
  }
}

enum DDCRegistryMetadataParser {
  static func candidate(
    serviceID: UInt64,
    proxyProperties: [String: Any],
    framebufferProperties: [String: Any]
  ) -> DDCServiceCandidate {
    let displayAttributes = framebufferProperties["DisplayAttributes"] as? [String: Any] ?? [:]
    let productAttributes = displayAttributes["ProductAttributes"] as? [String: Any] ?? [:]
    let location = string(proxyProperties["Location"])
    let hasUnit = number(proxyProperties["Unit"]) != nil

    return DDCServiceCandidate(
      serviceID: serviceID,
      isExternal: location?.caseInsensitiveCompare("External") == .orderedSame && hasUnit,
      edidUUID: string(framebufferProperties["EDID UUID"]),
      productName: string(productAttributes["ProductName"]),
      serial: decimalString(productAttributes["SerialNumber"]),
      displayLocation: nonzeroUInt64(displayAttributes["PortID"]),
      vendorID: nonzeroUInt32(productAttributes["LegacyManufacturerID"]),
      productID: nonzeroUInt32(productAttributes["ProductID"]),
      manufactureWeek: nonzeroUInt8(productAttributes["WeekOfManufacture"]),
      manufactureYear: nonzeroUInt16(productAttributes["YearOfManufacture"]),
      physicalWidthMM: centimetersToMillimeters(displayAttributes["MaxHorizontalImageSize"]),
      physicalHeightMM: centimetersToMillimeters(displayAttributes["MaxVerticalImageSize"])
    )
  }

  private static func string(_ value: Any?) -> String? {
    guard let value = value as? String else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private static func number(_ value: Any?) -> NSNumber? {
    value as? NSNumber
  }

  private static func decimalString(_ value: Any?) -> String? {
    guard let value = nonzeroUInt64(value) else { return nil }
    return String(value)
  }

  private static func nonzeroUInt8(_ value: Any?) -> UInt8? {
    guard let number = number(value), let value = UInt8(exactly: number.uint64Value), value != 0
    else { return nil }
    return value
  }

  private static func nonzeroUInt16(_ value: Any?) -> UInt16? {
    guard let number = number(value), let value = UInt16(exactly: number.uint64Value), value != 0
    else { return nil }
    return value
  }

  private static func nonzeroUInt32(_ value: Any?) -> UInt32? {
    guard let number = number(value), let value = UInt32(exactly: number.uint64Value), value != 0
    else { return nil }
    return value
  }

  private static func nonzeroUInt64(_ value: Any?) -> UInt64? {
    guard let number = number(value), number.uint64Value != 0 else { return nil }
    return number.uint64Value
  }

  private static func centimetersToMillimeters(_ value: Any?) -> UInt16? {
    guard let centimeters = nonzeroUInt16(value), centimeters <= UInt16.max / 10 else {
      return nil
    }
    return centimeters * 10
  }
}

struct IORegistryDDCServiceResolver: DDCServiceResolving {
  private let registry = IORegistryDDCServiceRegistry()

  func resolve(for display: Display) throws -> DDCServiceCandidate {
    try DDCServiceMatcher.select(
      for: DDCDisplayIdentity(display: display),
      from: registry.candidates()
    )
  }
}

final class IORegistryDDCServiceRegistry: @unchecked Sendable {
  private static let proxyClass = "DCPAVServiceProxy"
  private static let framebufferClasses: Set<String> = [
    "IOMobileFramebufferShim",
    "AppleCLCD2",
  ]

  func candidates() throws -> [DDCServiceCandidate] {
    let iterator = try makeIterator(operation: "enumerate DDC services")
    defer { IOObjectRelease(iterator) }

    var candidates: [DDCServiceCandidate] = []
    while case let entry = IOIteratorNext(iterator), entry != IO_OBJECT_NULL {
      do {
        if let candidate = try candidate(from: entry) {
          candidates.append(candidate)
        }
      } catch {
        IOObjectRelease(entry)
        throw error
      }
      IOObjectRelease(entry)
    }
    return candidates
  }

  private func candidate(from entry: io_registry_entry_t) throws -> DDCServiceCandidate? {
    guard className(of: entry) == Self.proxyClass else { return nil }

    var serviceID: UInt64 = 0
    let idResult = IORegistryEntryGetRegistryEntryID(entry, &serviceID)
    guard idResult == KERN_SUCCESS else {
      throw transportError("read registry entry ID", result: idResult)
    }

    return DDCRegistryMetadataParser.candidate(
      serviceID: serviceID,
      proxyProperties: properties(of: entry, keys: ["Location", "Unit"]),
      framebufferProperties: nearestFramebufferProperties(under: entry) ?? [:]
    )
  }

  func service(withRegistryEntryID expectedID: UInt64) throws -> io_service_t {
    let iterator = try makeIterator(operation: "reacquire DDC service")
    defer { IOObjectRelease(iterator) }

    while case let entry = IOIteratorNext(iterator), entry != IO_OBJECT_NULL {
      var serviceID: UInt64 = 0
      let idResult = IORegistryEntryGetRegistryEntryID(entry, &serviceID)
      if idResult == KERN_SUCCESS, serviceID == expectedID, className(of: entry) == Self.proxyClass
      {
        return entry
      }
      IOObjectRelease(entry)
      if idResult != KERN_SUCCESS {
        throw transportError("read registry entry ID", result: idResult)
      }
    }
    throw DisplayControlError.ddcServiceNotFound
  }

  private func makeIterator(operation: String) throws -> io_iterator_t {
    var iterator: io_iterator_t = IO_OBJECT_NULL
    let result = IORegistryCreateIterator(
      kIOMainPortDefault,
      kIOServicePlane,
      IOOptionBits(kIORegistryIterateRecursively),
      &iterator
    )
    guard result == KERN_SUCCESS, iterator != IO_OBJECT_NULL else {
      throw transportError(operation, result: result)
    }
    return iterator
  }

  private func nearestFramebufferProperties(under entry: io_registry_entry_t) -> [String: Any]? {
    var current = entry

    while true {
      var parent: io_registry_entry_t = IO_OBJECT_NULL
      let result = IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent)
      if current != entry {
        IOObjectRelease(current)
      }
      guard result == KERN_SUCCESS, parent != IO_OBJECT_NULL else { return nil }
      current = parent

      guard Self.framebufferClasses.contains(className(of: current)) else { continue }
      let framebufferProperties = properties(
        of: current,
        keys: ["EDID UUID", "DisplayAttributes"]
      )
      IOObjectRelease(current)
      return framebufferProperties
    }
  }

  private func properties(of entry: io_registry_entry_t, keys: [String]) -> [String: Any] {
    keys.reduce(into: [:]) { result, key in
      guard
        let property = IORegistryEntryCreateCFProperty(
          entry,
          key as CFString,
          kCFAllocatorDefault,
          0
        )?.takeRetainedValue()
      else { return }
      result[key] = property
    }
  }

  private func className(of entry: io_object_t) -> String {
    guard let name = IOObjectCopyClass(entry)?.takeRetainedValue() else { return "" }
    return name as String
  }

  private func transportError(_ operation: String, result: kern_return_t) -> DisplayControlError {
    .ddcTransport("IORegistry failed to \(operation) with code \(result)")
  }
}

enum DDCIOReturnMapper {
  static func error(
    for result: IOReturn,
    api: String,
    display: Display
  ) -> DisplayControlError? {
    guard result != kIOReturnSuccess else { return nil }
    if result == kIOReturnTimeout || result == kIOReturnNotResponding {
      return .ddcTimeout
    }
    return .ddcTransport(
      "\(api) failed with code \(result) for display \(display.runtimeID) (\(display.uuid.uuidString))"
    )
  }
}

struct IOAVDDCTransport: DDCTransport {
  private static let chipAddress: UInt32 = 0x37
  private static let dataAddress: UInt32 = 0x51
  private static let maximumReplyLength = 32
  private static let protocolDelayMicroseconds: UInt32 = 40_000

  private let resolver: any DDCServiceResolving
  private let registry: IORegistryDDCServiceRegistry
  private let bridge: PrivateAPIBridge

  init(
    resolver: any DDCServiceResolving = IORegistryDDCServiceResolver(),
    registry: IORegistryDDCServiceRegistry = IORegistryDDCServiceRegistry(),
    bridge: PrivateAPIBridge = PrivateAPIBridge()
  ) {
    self.resolver = resolver
    self.registry = registry
    self.bridge = bridge
  }

  func readVCP(_ code: UInt8, for display: Display) throws -> DDCValue {
    let request = DDCPacket.readVCP(code: code)
    return try withService(for: display) { service in
      let write = try bridge.requireIOAVServiceWriteI2C()
      try callWrite(write, service: service, bytes: request, display: display)
      usleep(Self.protocolDelayMicroseconds)

      let read = try bridge.requireIOAVServiceReadI2C()
      var reply = [UInt8](repeating: 0, count: Self.maximumReplyLength)
      let result = reply.withUnsafeMutableBytes { buffer in
        read(
          service,
          Self.chipAddress,
          Self.dataAddress,
          buffer.baseAddress,
          UInt32(buffer.count)
        )
      }
      try check(result, api: "IOAVServiceReadI2C", display: display)

      guard reply[1] & 0x80 != 0 else {
        throw DisplayControlError.ddcInvalidResponse("VCP reply length is not encoded")
      }
      let exactLength = Int(reply[1] & 0x7F) + 3
      guard exactLength >= 3, exactLength <= reply.count else {
        throw DisplayControlError.ddcInvalidResponse("VCP reply length exceeds read buffer")
      }
      return try DDCPacket.parseVCPReply(Array(reply.prefix(exactLength)), expectedCode: code)
    }
  }

  func writeVCP(_ code: UInt8, value: UInt16, for display: Display) throws {
    let packet = DDCPacket.writeVCP(code: code, value: value)
    try withService(for: display) { service in
      let write = try bridge.requireIOAVServiceWriteI2C()
      try callWrite(write, service: service, bytes: packet, display: display)
    }
  }

  private func withService<T>(
    for display: Display,
    operation: (CFTypeRef) throws -> T
  ) throws -> T {
    let candidate = try resolver.resolve(for: display)
    let registryService = try registry.service(withRegistryEntryID: candidate.serviceID)
    defer { IOObjectRelease(registryService) }

    let create = try bridge.requireIOAVServiceCreateWithService()
    guard let unmanagedService = create(kCFAllocatorDefault, registryService) else {
      throw DisplayControlError.ddcTransport(
        "IOAVServiceCreateWithService returned nil for display \(display.runtimeID)"
      )
    }
    let service = unmanagedService.takeRetainedValue()
    return try operation(service)
  }

  private func callWrite(
    _ write: IOAVServiceWriteI2CFn,
    service: CFTypeRef,
    bytes: [UInt8],
    display: Display
  ) throws {
    var packet = bytes
    let result = packet.withUnsafeMutableBytes { buffer in
      write(
        service,
        Self.chipAddress,
        Self.dataAddress,
        buffer.baseAddress,
        UInt32(buffer.count)
      )
    }
    try check(result, api: "IOAVServiceWriteI2C", display: display)
  }

  private func check(_ result: IOReturn, api: String, display: Display) throws {
    if let error = DDCIOReturnMapper.error(for: result, api: api, display: display) {
      throw error
    }
  }
}
