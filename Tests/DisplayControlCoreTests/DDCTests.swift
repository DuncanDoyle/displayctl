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

  func testRejectsMalformedVCPReplies() {
    var badChecksum = validReply(current: 50, maximum: 100)
    badChecksum[badChecksum.count - 1] ^= 0xFF
    let malformedReplies = [
      [0x6E, 0x88, 0x02],
      invalidReply(changing: 1, to: 0x87),
      invalidReply(changing: 0, to: 0x50),
      invalidReply(changing: 2, to: 0x03),
      invalidReply(changing: 4, to: 0x12),
      invalidReply(changing: 3, to: 0x01),
      badChecksum,
    ]

    for reply in malformedReplies {
      assertInvalidResponse(reply, expectedCode: 0x10)
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
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertThrowsError(
      try DDCPacket.parseVCPReply(reply, expectedCode: expectedCode),
      file: file,
      line: line
    ) {
      guard case .ddcInvalidResponse = $0 as? DisplayControlError else {
        return XCTFail("Expected ddcInvalidResponse, got \($0)", file: file, line: line)
      }
    }
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
