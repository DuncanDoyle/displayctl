import XCTest

@testable import DisplayControlCore

final class DDCTests: XCTestCase {
  func testWriteVCPPackets() {
    XCTAssertEqual(DDCPacket.writeVCP(code: 0x10, value: 0), [0x84, 0x03, 0x10, 0x00, 0x00, 0xA8])
    XCTAssertEqual(DDCPacket.writeVCP(code: 0x10, value: 50), [0x84, 0x03, 0x10, 0x00, 0x32, 0x9A])
    XCTAssertEqual(
      DDCPacket.writeVCP(code: 0x10, value: 100), [0x84, 0x03, 0x10, 0x00, 0x64, 0xCC])
  }

  func testReadVCPPacketIncludesChecksum() {
    XCTAssertEqual(DDCPacket.readVCP(code: 0x10), [0x82, 0x01, 0x10, 0xAC])
  }

  func testParsesValidVCPReply() throws {
    XCTAssertEqual(
      try DDCPacket.parseVCPReply(validReply(current: 50, maximum: 100), expectedCode: 0x10),
      DDCValue(current: 50, maximum: 100)
    )
  }

  func testParsesHighByteVCPValues() throws {
    XCTAssertEqual(
      try DDCPacket.parseVCPReply(
        validReply(current: 0x1234, maximum: 0xABCD), expectedCode: 0x10),
      DDCValue(current: 0x1234, maximum: 0xABCD)
    )
  }

  func testUnsupportedVCPResultThrowsUnsupported() {
    let reply = invalidReply(changing: 3, to: 0x01)

    XCTAssertThrowsError(try DDCPacket.parseVCPReply(reply, expectedCode: 0x10)) {
      XCTAssertEqual($0 as? DisplayControlError, .ddcUnsupported)
    }
  }

  func testUnknownNonzeroVCPResultIsInvalid() {
    assertInvalidResponse(invalidReply(changing: 3, to: 0x02), expectedCode: 0x10)
  }

  func testRejectsMalformedVCPReplies() {
    var badChecksum = validReply(current: 50, maximum: 100)
    badChecksum[badChecksum.count - 1] ^= 0xFF
    let trailingByte = validReply(current: 50, maximum: 100) + [0x00]
    let malformedReplies = [
      ("short", [0x6E, 0x88, 0x02]),
      ("unencoded length", invalidReply(changing: 1, to: 0x08)),
      ("length mismatch", invalidReply(changing: 1, to: 0x87)),
      ("trailing byte", trailingByte),
      ("wrong source", invalidReply(changing: 0, to: 0x50)),
      ("wrong opcode", invalidReply(changing: 2, to: 0x03)),
      ("wrong VCP code", invalidReply(changing: 4, to: 0x12)),
      ("bad checksum", badChecksum),
    ]

    for (name, reply) in malformedReplies {
      assertInvalidResponse(reply, expectedCode: 0x10, label: name)
    }
  }

  func testSelectsUniqueHighestScoringExternalService() throws {
    let identity = displayIdentity()
    let weaker = service(id: 1, productName: "Other Display", serial: "SERIAL-1")
    let exact = service(id: 2, productName: "  reference   DISPLAY ")

    XCTAssertEqual(try DDCServiceMatcher.select(for: identity, from: [weaker, exact]), exact)
  }

  func testRejectsTiedBestCandidatesAsAmbiguous() {
    let identity = displayIdentity()
    let first = service(id: 1)
    let second = service(id: 2)

    XCTAssertThrowsError(try DDCServiceMatcher.select(for: identity, from: [first, second])) {
      XCTAssertEqual($0 as? DisplayControlError, .ddcServiceAmbiguous)
    }
  }

  func testRejectsNonExternalCandidate() {
    let identity = displayIdentity()
    let internalCandidate = service(id: 1, isExternal: false)

    XCTAssertThrowsError(try DDCServiceMatcher.select(for: identity, from: [internalCandidate])) {
      XCTAssertEqual($0 as? DisplayControlError, .ddcServiceNotFound)
    }
  }

  func testRejectsWeakCandidateAboveOldThreshold() {
    let identity = displayIdentity()
    let weak = service(id: 1, edidUUID: nil, serial: nil, displayLocation: nil)

    XCTAssertGreaterThan(DDCServiceMatcher.score(weak, for: identity), 50)
    assertServiceNotFound(identity, candidates: [weak])
  }

  func testAcceptsEachStrongIdentityMatchIndependently() throws {
    let cases = [
      (
        sparseIdentity(displayLocation: 0x1234),
        sparseService(id: 1, displayLocation: 0x1234)
      ),
      (sparseIdentity(serial: " Serial-1 "), sparseService(id: 2, serial: "serial-1")),
      (sparseIdentity(edidUUID: " EDID-1 "), sparseService(id: 3, edidUUID: "edid-1")),
    ]

    for (identity, candidate) in cases {
      XCTAssertEqual(try DDCServiceMatcher.select(for: identity, from: [candidate]), candidate)
    }
    XCTAssertEqual(
      DDCServiceMatcher.score(cases[2].1, for: cases[2].0), DDCServiceMatcher.minimumScore)
  }

  func testRejectsConflictInAnyProvidedStrongIdentity() {
    let identity = sparseIdentity(edidUUID: "EDID-1", serial: "SERIAL-1", displayLocation: 0x1234)
    let conflicts = [
      sparseService(id: 1, edidUUID: "EDID-1", serial: "SERIAL-1", displayLocation: 0x9999),
      sparseService(id: 2, edidUUID: "EDID-1", serial: "OTHER", displayLocation: 0x1234),
      sparseService(id: 3, edidUUID: "OTHER", serial: "SERIAL-1", displayLocation: 0x1234),
    ]

    for conflict in conflicts {
      assertServiceNotFound(identity, candidates: [conflict])
    }
  }

  func testConflictFreeCandidateWinsRegardlessOfInputOrder() throws {
    let identity = displayIdentity()
    let conflicting = service(id: 1, displayLocation: 0x9999)
    let correct = sparseService(id: 2, serial: " serial-1 ")

    XCTAssertGreaterThan(
      DDCServiceMatcher.score(conflicting, for: identity),
      DDCServiceMatcher.score(correct, for: identity)
    )
    XCTAssertEqual(
      try DDCServiceMatcher.select(for: identity, from: [conflicting, correct]), correct)
    XCTAssertEqual(
      try DDCServiceMatcher.select(for: identity, from: [correct, conflicting]), correct)
  }

  func testBelowThresholdWeakCandidateIsRejected() {
    let identity = sparseIdentity(productName: "Reference Display")
    let weak = sparseService(id: 1, productName: " reference  display ")

    XCTAssertLessThan(DDCServiceMatcher.score(weak, for: identity), DDCServiceMatcher.minimumScore)
    assertServiceNotFound(identity, candidates: [weak])
  }

  func testEmptyAndZeroCandidateIdentityFieldsDoNotAddScore() {
    let identity = DDCDisplayIdentity(
      edidUUID: "",
      productName: "",
      serial: "",
      displayLocation: 0,
      vendorID: 0,
      productID: 0,
      manufactureWeek: 0,
      manufactureYear: 0,
      physicalWidthMM: 0,
      physicalHeightMM: 0
    )
    let candidate = service(
      id: 1,
      edidUUID: "",
      productName: "",
      serial: "",
      displayLocation: 0,
      vendorID: 0,
      productID: 0,
      manufactureWeek: 0,
      manufactureYear: 0,
      physicalWidthMM: 0,
      physicalHeightMM: 0
    )

    XCTAssertEqual(DDCServiceMatcher.score(candidate, for: identity), 0)
    XCTAssertThrowsError(try DDCServiceMatcher.select(for: identity, from: [candidate])) {
      XCTAssertEqual($0 as? DisplayControlError, .ddcServiceNotFound)
    }
  }

  private func validReply(current: UInt16, maximum: UInt16, code: UInt8 = 0x10) -> [UInt8] {
    var reply: [UInt8] = [
      0x6E,
      0x88,
      0x02,
      0x00,
      code,
      0x00,
      UInt8(maximum >> 8),
      UInt8(maximum & 0xFF),
      UInt8(current >> 8),
      UInt8(current & 0xFF),
    ]
    reply.append(replyChecksum(for: reply))
    return reply
  }

  private func replyChecksum<S: Sequence>(for bytes: S) -> UInt8 where S.Element == UInt8 {
    bytes.reduce(0x50, ^)
  }

  private func invalidReply(changing index: Int, to value: UInt8) -> [UInt8] {
    var reply = validReply(current: 50, maximum: 100)
    reply[index] = value
    reply[reply.count - 1] = replyChecksum(for: reply.dropLast())
    return reply
  }

  private func assertInvalidResponse(
    _ reply: [UInt8],
    expectedCode: UInt8,
    label: String = "invalid response",
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertThrowsError(
      try DDCPacket.parseVCPReply(reply, expectedCode: expectedCode),
      label,
      file: file,
      line: line
    ) {
      guard case .ddcInvalidResponse = $0 as? DisplayControlError else {
        return XCTFail("Expected ddcInvalidResponse, got \($0)", file: file, line: line)
      }
    }
  }

  private func assertServiceNotFound(
    _ identity: DDCDisplayIdentity,
    candidates: [DDCServiceCandidate],
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertThrowsError(
      try DDCServiceMatcher.select(for: identity, from: candidates), file: file, line: line
    ) {
      XCTAssertEqual($0 as? DisplayControlError, .ddcServiceNotFound, file: file, line: line)
    }
  }

  private func sparseIdentity(
    edidUUID: String? = nil,
    productName: String? = nil,
    serial: String? = nil,
    displayLocation: UInt64? = nil
  ) -> DDCDisplayIdentity {
    DDCDisplayIdentity(
      edidUUID: edidUUID,
      productName: productName,
      serial: serial,
      displayLocation: displayLocation,
      vendorID: nil,
      productID: nil,
      manufactureWeek: nil,
      manufactureYear: nil,
      physicalWidthMM: nil,
      physicalHeightMM: nil
    )
  }

  private func sparseService(
    id: UInt64,
    edidUUID: String? = nil,
    productName: String? = nil,
    serial: String? = nil,
    displayLocation: UInt64? = nil
  ) -> DDCServiceCandidate {
    DDCServiceCandidate(
      serviceID: id,
      isExternal: true,
      edidUUID: edidUUID,
      productName: productName,
      serial: serial,
      displayLocation: displayLocation,
      vendorID: nil,
      productID: nil,
      manufactureWeek: nil,
      manufactureYear: nil,
      physicalWidthMM: nil,
      physicalHeightMM: nil
    )
  }

  private func displayIdentity(
    edidUUID: String? = "EDID-UUID-1",
    productName: String? = "Reference Display",
    serial: String? = "SERIAL-1",
    displayLocation: UInt64? = 0x1234,
    vendorID: UInt32? = 0x1111,
    productID: UInt32? = 0x2222,
    manufactureWeek: UInt8? = 12,
    manufactureYear: UInt16? = 2025,
    physicalWidthMM: UInt16? = 600,
    physicalHeightMM: UInt16? = 340
  ) -> DDCDisplayIdentity {
    DDCDisplayIdentity(
      edidUUID: edidUUID,
      productName: productName,
      serial: serial,
      displayLocation: displayLocation,
      vendorID: vendorID,
      productID: productID,
      manufactureWeek: manufactureWeek,
      manufactureYear: manufactureYear,
      physicalWidthMM: physicalWidthMM,
      physicalHeightMM: physicalHeightMM
    )
  }

  private func service(
    id: UInt64,
    isExternal: Bool = true,
    edidUUID: String? = "EDID-UUID-1",
    productName: String? = "Reference Display",
    serial: String? = "SERIAL-1",
    displayLocation: UInt64? = 0x1234,
    vendorID: UInt32? = 0x1111,
    productID: UInt32? = 0x2222,
    manufactureWeek: UInt8? = 12,
    manufactureYear: UInt16? = 2025,
    physicalWidthMM: UInt16? = 600,
    physicalHeightMM: UInt16? = 340
  ) -> DDCServiceCandidate {
    DDCServiceCandidate(
      serviceID: id,
      isExternal: isExternal,
      edidUUID: edidUUID,
      productName: productName,
      serial: serial,
      displayLocation: displayLocation,
      vendorID: vendorID,
      productID: productID,
      manufactureWeek: manufactureWeek,
      manufactureYear: manufactureYear,
      physicalWidthMM: physicalWidthMM,
      physicalHeightMM: physicalHeightMM
    )
  }
}
