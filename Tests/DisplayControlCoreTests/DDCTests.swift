import IOKit
import XCTest

@testable import DisplayControlCore

final class DDCTests: XCTestCase {
  func testLiveControllerConstructionIsLazy() {
    _ = DDCBrightnessController()

    let resolver = FakeDDCServiceResolver(result: .failure(.ddcServiceNotFound))
    let liveTransport = IOAVDDCTransport(resolver: resolver)
    _ = DDCBrightnessController(transport: liveTransport)

    XCTAssertTrue(resolver.displays.isEmpty)
  }

  func testControllerGetReturnsBrightnessFromTransport() async throws {
    let transport = FakeDDCTransport(readResults: [.success(DDCValue(current: 37, maximum: 200))])
    let controller = makeController(transport: transport)

    let value = try await controller.get(display: externalDisplay())
    XCTAssertEqual(value, DDCValue(current: 37, maximum: 200))
    XCTAssertEqual(transport.operations, [.read(0x10, externalDisplay())])
  }

  func testControllerSerializesTransportOperations() async throws {
    let transport = FakeDDCTransport(
      readResults: Array(repeating: .success(DDCValue(current: 1, maximum: 100)), count: 8),
      operationDelay: 0.01
    )
    let controller = makeController(transport: transport)
    let display = externalDisplay()

    try await withThrowingTaskGroup(of: Void.self) { group in
      for _ in 0..<8 {
        group.addTask {
          _ = try await controller.get(display: display)
        }
      }
      try await group.waitForAll()
    }

    XCTAssertEqual(transport.maximumConcurrentOperations, 1)
  }

  func testControllerRejectsInternalDisplayWithoutUsingTransport() async {
    let transport = FakeDDCTransport()
    let controller = makeController(transport: transport)

    await assertThrowsError(try await controller.get(display: internalDisplay())) {
      guard case .invalidArguments = $0 as? DisplayControlError else {
        return XCTFail("Expected invalidArguments, got \($0)")
      }
    }
    XCTAssertTrue(transport.operations.isEmpty)
  }

  func testControllerRejectsPercentOutsideClosedRange() async {
    for percent in [-1, 101] {
      let transport = FakeDDCTransport()
      let controller = makeController(transport: transport)

      await assertThrowsError(
        try await controller.set(percent: percent, display: externalDisplay())
      ) {
        guard case .invalidArguments = $0 as? DisplayControlError else {
          return XCTFail("Expected invalidArguments, got \($0)")
        }
      }
      XCTAssertTrue(transport.operations.isEmpty)
    }
  }

  func testControllerScalesPercentToReportedMaximum() async throws {
    let transport = FakeDDCTransport(readResults: [.success(DDCValue(current: 0, maximum: 255))])
    let controller = makeController(transport: transport)

    try await controller.set(percent: 50, display: externalDisplay())

    XCTAssertEqual(
      transport.operations,
      [.read(0x10, externalDisplay()), .write(0x10, 128, externalDisplay())]
    )
  }

  func testControllerRejectsZeroReportedMaximumWithoutWriting() async {
    let transport = FakeDDCTransport(readResults: [.success(DDCValue(current: 0, maximum: 0))])
    let controller = makeController(transport: transport)

    await assertThrowsError(try await controller.set(percent: 73, display: externalDisplay())) {
      guard case .ddcInvalidResponse = $0 as? DisplayControlError else {
        return XCTFail("Expected ddcInvalidResponse, got \($0)")
      }
    }
    XCTAssertEqual(transport.operations, [.read(0x10, externalDisplay())])
  }

  func testControllerUsesMaximum100OnlyWhenReadIsUnsupported() async throws {
    let transport = FakeDDCTransport(readResults: [.failure(.ddcUnsupported)])
    let controller = makeController(transport: transport)

    try await controller.set(percent: 42, display: externalDisplay())

    XCTAssertEqual(transport.operations.last, .write(0x10, 42, externalDisplay()))
  }

  // Design §6.5: a set still writes when read-back fails, as over USB-C on a Dell U2720Q.
  func testControllerUsesMaximum100WhenReadBackKeepsFailing() async throws {
    let readFailures: [DisplayControlError] = [
      .ddcInvalidResponse("VCP reply is too short"), .ddcTimeout, .ddcTransport("read failed"),
    ]
    for error in readFailures {
      let transport = FakeDDCTransport(readResults: Array(repeating: .failure(error), count: 3))
      let controller = makeController(transport: transport)

      try await controller.set(percent: 42, display: externalDisplay())

      XCTAssertEqual(transport.operations.last, .write(0x10, 42, externalDisplay()))
    }
  }

  func testControllerDoesNotUseMaximumFallbackForOtherReadFailures() async {
    let expected = DisplayControlError.ddcServiceNotFound
    let transport = FakeDDCTransport(readResults: [.failure(expected)])
    let controller = makeController(transport: transport)

    await assertThrowsError(try await controller.set(percent: 42, display: externalDisplay())) {
      XCTAssertEqual($0 as? DisplayControlError, expected)
    }
    XCTAssertFalse(
      transport.operations.contains { operation in
        if case .write = operation { return true }
        return false
      })
  }

  func testControllerRetriesRetryableFailuresWithinBound() async throws {
    let retryableErrors: [DisplayControlError] = [
      .ddcTimeout,
      .ddcTransport("temporary transport failure"),
      .ddcInvalidResponse("temporary malformed response"),
    ]

    for error in retryableErrors {
      let transport = FakeDDCTransport(readResults: [
        .failure(error), .success(DDCValue(current: 9, maximum: 100)),
      ])
      let controller = makeController(transport: transport)

      let value = try await controller.get(display: externalDisplay())
      XCTAssertEqual(value.current, 9)
      XCTAssertEqual(transport.operations.count, 2)
    }
  }

  func testControllerDoesNotRetryPermanentFailures() async {
    let permanentErrors: [DisplayControlError] = [
      .ddcUnsupported,
      .ddcServiceNotFound,
      .ddcServiceAmbiguous,
      .invalidArguments("invalid display"),
      .displayNotFound("missing display"),
      .ambiguousSelector("ambiguous display"),
    ]

    for error in permanentErrors {
      let transport = FakeDDCTransport(readResults: [.failure(error)])
      let controller = makeController(transport: transport)

      await assertThrowsError(try await controller.get(display: externalDisplay())) {
        XCTAssertEqual($0 as? DisplayControlError, error)
      }
      XCTAssertEqual(transport.operations.count, 1)
    }
  }

  func testControllerExposesWriteFailure() async {
    let expected = DisplayControlError.ddcServiceNotFound
    let transport = FakeDDCTransport(
      readResults: [.success(DDCValue(current: 10, maximum: 100))],
      writeResults: [.failure(expected)]
    )
    let controller = makeController(transport: transport)

    await assertThrowsError(try await controller.set(percent: 20, display: externalDisplay())) {
      XCTAssertEqual($0 as? DisplayControlError, expected)
    }
  }

  func testControllerReturnsFinalTypedErrorWhenRetriesAreExhausted() async {
    let first = DisplayControlError.ddcTimeout
    let final = DisplayControlError.ddcTransport("final transport failure")
    let transport = FakeDDCTransport(readResults: [.failure(first), .failure(final)])
    let controller = DDCBrightnessController(
      transport: transport,
      retryPolicy: DDCRetryPolicy(maxAttempts: 2, delayMicroseconds: 0),
      sleeper: { _ in }
    )

    await assertThrowsError(try await controller.get(display: externalDisplay())) {
      XCTAssertEqual($0 as? DisplayControlError, final)
    }
    XCTAssertEqual(transport.operations.count, 2)
  }

  func testDisplayIdentityUsesSafeCGMetadataWithoutAssumingEDIDUUID() {
    let identity = DDCDisplayIdentity(
      display: externalDisplay(),
      cgMetadata: DDCDisplayCGMetadata(
        serialNumber: 1_113_146_188, vendorID: 4268, productID: 16816)
    )

    XCTAssertNil(identity.edidUUID)
    XCTAssertEqual(identity.productName, "External Display")
    XCTAssertEqual(identity.serial, "1113146188")
    XCTAssertEqual(identity.vendorID, 4268)
    XCTAssertEqual(identity.productID, 16816)
    XCTAssertNil(identity.displayLocation)
    XCTAssertNil(identity.manufactureWeek)
    XCTAssertNil(identity.manufactureYear)
  }

  func testDisplayIdentityDoesNotCreateStrongSerialFromZero() {
    let identity = DDCDisplayIdentity(
      display: externalDisplay(),
      cgMetadata: DDCDisplayCGMetadata(serialNumber: 0, vendorID: 0, productID: 0)
    )

    XCTAssertNil(identity.serial)
    XCTAssertNil(identity.vendorID)
    XCTAssertNil(identity.productID)
  }

  func testCandidateDetectorMarksUniqueExternalResolutionAsCandidate() {
    let resolver = FakeDDCServiceResolver(result: .success(service(id: 7)))
    let detector = ResolverDDCCandidateDetector(resolver: resolver)

    XCTAssertEqual(detector.capability(for: externalDisplay()), .candidate)
    XCTAssertEqual(resolver.displays, [externalDisplay()])
  }

  func testCandidateDetectorMapsNotFoundToUnsupported() {
    let resolver = FakeDDCServiceResolver(result: .failure(.ddcServiceNotFound))
    let detector = ResolverDDCCandidateDetector(resolver: resolver)

    XCTAssertEqual(detector.capability(for: externalDisplay()), .unsupported)
  }

  func testCandidateDetectorMapsAmbiguityAndDiscoveryFailuresToUnknown() {
    let errors: [DisplayControlError] = [
      .ddcServiceAmbiguous,
      .ddcTransport("registry unavailable"),
      .unsupportedAPI("IOAVServiceCreateWithService"),
    ]

    for error in errors {
      let detector = ResolverDDCCandidateDetector(
        resolver: FakeDDCServiceResolver(result: .failure(error)))
      XCTAssertEqual(detector.capability(for: externalDisplay()), .unknown)
    }
  }

  func testCandidateDetectorLeavesInternalDisplayUnknownWithoutResolving() {
    let resolver = FakeDDCServiceResolver(result: .failure(.ddcServiceNotFound))
    let detector = ResolverDDCCandidateDetector(resolver: resolver)

    XCTAssertEqual(detector.capability(for: internalDisplay()), .unknown)
    XCTAssertTrue(resolver.displays.isEmpty)
  }

  func testInventoryCapabilityPassPreservesInternalAndClassifiesExternalDisplays() {
    let detector = FakeDDCCandidateDetector(capabilities: [externalDisplay().uuid: .candidate])

    let result = DisplayInventory.applyingDDCCapabilities(
      to: [internalDisplay(), externalDisplay()],
      detector: detector
    )

    XCTAssertEqual(result.first { $0.kind == .internal }?.ddcCapability, .unknown)
    XCTAssertEqual(result.first { $0.kind == .external }?.ddcCapability, .candidate)
    XCTAssertEqual(detector.displays, [externalDisplay()])
  }

  func testRegistryMetadataParserCapturesObservedExternalDisplayIdentity() {
    let candidate = DDCRegistryMetadataParser.candidate(
      serviceID: 99,
      proxyProperties: ["Location": "External", "Unit": 0],
      framebufferProperties: [
        "EDID UUID": "10ACB041-0000-0000-0000-000000000000",
        "DisplayAttributes": [
          "PortID": 48,
          "ProductAttributes": [
            "ProductName": "DELL U2720Q",
            "SerialNumber": 1_113_146_188,
            "LegacyManufacturerID": 4268,
            "ProductID": 16816,
            "WeekOfManufacture": 20,
            "YearOfManufacture": 2020,
          ],
          "MaxHorizontalImageSize": 60,
          "MaxVerticalImageSize": 34,
        ],
      ]
    )

    XCTAssertEqual(
      candidate,
      DDCServiceCandidate(
        serviceID: 99,
        isExternal: true,
        edidUUID: "10ACB041-0000-0000-0000-000000000000",
        productName: "DELL U2720Q",
        serial: "1113146188",
        displayLocation: 48,
        vendorID: 4268,
        productID: 16816,
        manufactureWeek: 20,
        manufactureYear: 2020,
        physicalWidthMM: 600,
        physicalHeightMM: 340
      )
    )
  }

  func testRegistryMetadataParserLeavesMissingIdentityFieldsEmpty() {
    let candidate = DDCRegistryMetadataParser.candidate(
      serviceID: 7,
      proxyProperties: ["Location": "External", "Unit": 0],
      framebufferProperties: [:]
    )

    XCTAssertEqual(candidate.serviceID, 7)
    XCTAssertTrue(candidate.isExternal)
    XCTAssertNil(candidate.edidUUID)
    XCTAssertNil(candidate.serial)
    XCTAssertNil(candidate.displayLocation)
    XCTAssertNil(candidate.vendorID)
    XCTAssertNil(candidate.productID)
  }

  func testIOReturnMapperClassifiesIdentifiableTimeouts() {
    for result in [kIOReturnTimeout, kIOReturnNotResponding] {
      XCTAssertEqual(
        DDCIOReturnMapper.error(
          for: result,
          api: "IOAVServiceReadI2C",
          display: externalDisplay()
        ),
        .ddcTimeout
      )
    }
  }

  func testIOReturnUnsupportedEnablesSetFallbackWithoutRetry() async throws {
    let mappedError = try XCTUnwrap(
      DDCIOReturnMapper.error(
        for: kIOReturnUnsupported,
        api: "IOAVServiceReadI2C",
        display: externalDisplay()
      )
    )
    XCTAssertEqual(mappedError, .ddcUnsupported)

    let transport = FakeDDCTransport(readResults: [.failure(mappedError)])
    let controller = makeController(transport: transport)
    try await controller.set(percent: 42, display: externalDisplay())

    XCTAssertEqual(
      transport.operations,
      [.read(0x10, externalDisplay()), .write(0x10, 42, externalDisplay())]
    )
  }

  func testEndpointIndexExtractionIsExactAndCaseInsensitive() {
    XCTAssertEqual(DDCEndpointIndex.extract(from: ["DCPEXT0"], prefix: "dcpext"), 0)
    XCTAssertEqual(DDCEndpointIndex.extract(from: ["dispext12"], prefix: "dispext"), 12)
    XCTAssertNil(DDCEndpointIndex.extract(from: ["dcpext"], prefix: "dcpext"))
    XCTAssertNil(DDCEndpointIndex.extract(from: ["dcpext0-extra"], prefix: "dcpext"))
    XCTAssertNil(DDCEndpointIndex.extract(from: ["dcpext0", "dcpext1"], prefix: "dcpext"))
  }

  func testTopologyPairerMapsExactEndpointZero() throws {
    let candidates = try DDCRegistryTopologyPairer.candidates(
      proxies: [proxyRecord(id: 10, endpointIndex: 0)],
      framebuffers: [framebufferRecord(endpointIndex: 0, productName: "DISPLAY ZERO")]
    )

    XCTAssertEqual(candidates.first?.serviceID, 10)
    XCTAssertEqual(candidates.first?.productName, "DISPLAY ZERO")
  }

  func testTopologyPairerMapsMultipleEndpointIndicesWithoutCrossPairing() throws {
    let candidates = try DDCRegistryTopologyPairer.candidates(
      proxies: [proxyRecord(id: 10, endpointIndex: 0), proxyRecord(id: 11, endpointIndex: 1)],
      framebuffers: [
        framebufferRecord(endpointIndex: 1, productName: "DISPLAY ONE"),
        framebufferRecord(endpointIndex: 0, productName: "DISPLAY ZERO"),
      ]
    )

    XCTAssertEqual(candidates.first { $0.serviceID == 10 }?.productName, "DISPLAY ZERO")
    XCTAssertEqual(candidates.first { $0.serviceID == 11 }?.productName, "DISPLAY ONE")
  }

  func testTopologyPairerLeavesMissingAndMismatchedEndpointMetadataEmpty() throws {
    let candidates = try DDCRegistryTopologyPairer.candidates(
      proxies: [proxyRecord(id: 10, endpointIndex: nil), proxyRecord(id: 11, endpointIndex: 1)],
      framebuffers: [framebufferRecord(endpointIndex: 0, productName: "WRONG DISPLAY")]
    )

    XCTAssertTrue(candidates.allSatisfy { $0.productName == nil && $0.serial == nil })
  }

  func testTopologyPairerReportsDuplicateProxyIndexAsAmbiguous() {
    XCTAssertThrowsError(
      try DDCRegistryTopologyPairer.candidates(
        proxies: [proxyRecord(id: 10, endpointIndex: 0), proxyRecord(id: 11, endpointIndex: 0)],
        framebuffers: [framebufferRecord(endpointIndex: 0, productName: "DISPLAY ZERO")]
      )
    ) {
      XCTAssertEqual($0 as? DisplayControlError, .ddcServiceAmbiguous)
    }
  }

  func testTopologyPairerReportsDuplicateFramebufferIndexAsAmbiguous() {
    XCTAssertThrowsError(
      try DDCRegistryTopologyPairer.candidates(
        proxies: [proxyRecord(id: 12, endpointIndex: 1)],
        framebuffers: [
          framebufferRecord(endpointIndex: 1, productName: "FIRST"),
          framebufferRecord(endpointIndex: 1, productName: "SECOND"),
        ]
      )
    ) {
      XCTAssertEqual($0 as? DisplayControlError, .ddcServiceAmbiguous)
    }
  }

  func testRegistryServiceSelectorSkipsUnreadableIDsBeforeTarget() {
    XCTAssertEqual(
      DDCRegistryServiceSelector.firstMatchingIndex(
        expectedID: 77,
        entries: [
          DDCRegistryServiceDescriptor(serviceID: nil, className: "DCPAVServiceProxy"),
          DDCRegistryServiceDescriptor(serviceID: 77, className: "DCPAVServiceProxy"),
        ]
      ),
      1
    )
  }

  func testIOReturnMapperPreservesTransportContextAndRawCode() {
    XCTAssertEqual(
      DDCIOReturnMapper.error(
        for: kIOReturnError,
        api: "IOAVServiceWriteI2C",
        display: externalDisplay()
      ),
      .ddcTransport(
        "IOAVServiceWriteI2C failed with code \(kIOReturnError) for display 2 "
          + "(22222222-2222-2222-2222-222222222222)"
      )
    )
    XCTAssertNil(
      DDCIOReturnMapper.error(
        for: kIOReturnSuccess,
        api: "IOAVServiceReadI2C",
        display: externalDisplay()
      )
    )
  }

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

  func testRejectsSharedSerialWhenVendorProductPairsConflict() {
    let identity = sparseIdentity(serial: "GENERIC-SERIAL")
    let display = DDCDisplayIdentity(
      edidUUID: identity.edidUUID,
      productName: identity.productName,
      serial: identity.serial,
      displayLocation: identity.displayLocation,
      vendorID: 4268,
      productID: 16816,
      manufactureWeek: nil,
      manufactureYear: nil,
      physicalWidthMM: nil,
      physicalHeightMM: nil
    )
    let collision = service(
      id: 1,
      edidUUID: nil,
      productName: "Generic Display",
      serial: "generic-serial",
      displayLocation: nil,
      vendorID: 1111,
      productID: 2222,
      manufactureWeek: nil,
      manufactureYear: nil,
      physicalWidthMM: nil,
      physicalHeightMM: nil
    )

    assertServiceNotFound(display, candidates: [collision])
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

  private func makeController(transport: FakeDDCTransport) -> DDCBrightnessController {
    DDCBrightnessController(
      transport: transport,
      retryPolicy: DDCRetryPolicy(maxAttempts: 3, delayMicroseconds: 0),
      sleeper: { _ in }
    )
  }

  private func externalDisplay() -> Display {
    Display(
      uuid: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
      runtimeID: 2,
      name: "External Display",
      kind: .external,
      isOnline: true,
      isActive: true,
      isMain: false,
      ddcCapability: .candidate
    )
  }

  private func internalDisplay() -> Display {
    Display(
      uuid: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
      runtimeID: 1,
      name: "Built-in Display",
      kind: .internal,
      isOnline: true,
      isActive: true,
      isMain: true,
      ddcCapability: .unknown
    )
  }

  private func proxyRecord(id: UInt64, endpointIndex: Int?) -> DDCRegistryProxyRecord {
    DDCRegistryProxyRecord(
      serviceID: id,
      endpointIndex: endpointIndex,
      properties: ["Location": "External", "Unit": 0]
    )
  }

  private func framebufferRecord(
    endpointIndex: Int?,
    productName: String
  ) -> DDCRegistryFramebufferRecord {
    DDCRegistryFramebufferRecord(
      endpointIndex: endpointIndex,
      properties: [
        "DisplayAttributes": [
          "ProductAttributes": [
            "ProductName": productName,
            "SerialNumber": 1234,
          ]
        ]
      ]
    )
  }

  private func assertThrowsError<T>(
    _ expression: @autoclosure () async throws -> T,
    _ handler: (Error) -> Void
  ) async {
    do {
      _ = try await expression()
      XCTFail("Expected expression to throw")
    } catch {
      handler(error)
    }
  }
}

private enum FakeDDCOperation: Equatable {
  case read(UInt8, Display)
  case write(UInt8, UInt16, Display)
}

private final class FakeDDCTransport: DDCTransport, @unchecked Sendable {
  private let lock = NSLock()
  private var storedReadResults: [Result<DDCValue, DisplayControlError>]
  private var storedWriteResults: [Result<Void, DisplayControlError>]
  private var storedOperations: [FakeDDCOperation] = []
  private var concurrentOperations = 0
  private var storedMaximumConcurrentOperations = 0
  private let operationDelay: TimeInterval

  init(
    readResults: [Result<DDCValue, DisplayControlError>] = [],
    writeResults: [Result<Void, DisplayControlError>] = [],
    operationDelay: TimeInterval = 0
  ) {
    storedReadResults = readResults
    storedWriteResults = writeResults
    self.operationDelay = operationDelay
  }

  var operations: [FakeDDCOperation] {
    lock.withLock { storedOperations }
  }

  var maximumConcurrentOperations: Int {
    lock.withLock { storedMaximumConcurrentOperations }
  }

  func readVCP(_ code: UInt8, for display: Display) throws -> DDCValue {
    try perform(
      .read(code, display), results: &storedReadResults,
      defaultValue: DDCValue(current: 0, maximum: 100))
  }

  func writeVCP(_ code: UInt8, value: UInt16, for display: Display) throws {
    try perform(.write(code, value, display), results: &storedWriteResults, defaultValue: ())
  }

  private func perform<T>(
    _ operation: FakeDDCOperation,
    results: inout [Result<T, DisplayControlError>],
    defaultValue: T
  ) throws -> T {
    let result: Result<T, DisplayControlError> = lock.withLock {
      storedOperations.append(operation)
      concurrentOperations += 1
      storedMaximumConcurrentOperations = max(
        storedMaximumConcurrentOperations, concurrentOperations)
      return results.isEmpty ? .success(defaultValue) : results.removeFirst()
    }
    if operationDelay > 0 {
      Thread.sleep(forTimeInterval: operationDelay)
    }
    lock.withLock { concurrentOperations -= 1 }
    return try result.get()
  }
}

private final class FakeDDCServiceResolver: DDCServiceResolving, @unchecked Sendable {
  private let lock = NSLock()
  private let result: Result<DDCServiceCandidate, DisplayControlError>
  private var storedDisplays: [Display] = []

  init(result: Result<DDCServiceCandidate, DisplayControlError>) {
    self.result = result
  }

  var displays: [Display] {
    lock.withLock { storedDisplays }
  }

  func resolve(for display: Display) throws -> DDCServiceCandidate {
    lock.withLock { storedDisplays.append(display) }
    return try result.get()
  }
}

private final class FakeDDCCandidateDetector: DDCCandidateDetecting, @unchecked Sendable {
  private let lock = NSLock()
  private let capabilities: [UUID: DDCCapability]
  private var storedDisplays: [Display] = []

  init(capabilities: [UUID: DDCCapability]) {
    self.capabilities = capabilities
  }

  var displays: [Display] {
    lock.withLock { storedDisplays }
  }

  func capability(for display: Display) -> DDCCapability {
    lock.withLock { storedDisplays.append(display) }
    return capabilities[display.uuid] ?? .unknown
  }
}
