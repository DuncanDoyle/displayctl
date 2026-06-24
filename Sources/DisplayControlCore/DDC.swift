import Foundation

struct DDCValue: Equatable, Sendable {
  let current, maximum: UInt16
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

enum DDCServiceMatcher {
  // An EDID identity match is the minimum acceptable strong match.
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
