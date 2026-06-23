import CoreFoundation
import CoreGraphics
import Foundation
import IOKit
import XCTest

@testable import DisplayControlCore

private let displayEnableStub: CGSConfigureDisplayEnabledFn = { _, _, _ in .success }
private let serviceCreateStub: IOAVServiceCreateWithServiceFn = { _, _ in nil }
private let writeI2CStub: IOAVServiceWriteI2CFn = { _, _, _, _, _ in kIOReturnSuccess }
private let readI2CStub: IOAVServiceReadI2CFn = { _, _, _, _, _ in kIOReturnSuccess }

final class PrivateAPIBridgeTests: XCTestCase {
  func testInitializationDoesNotResolveSymbols() {
    let resolver = FakeResolver(symbols: [:])

    _ = PrivateAPIBridge(resolver: resolver)

    XCTAssertEqual(resolver.requests, [])
  }

  func testPresentDisplayEnableSymbolIsResolvedLazilyAndCached() throws {
    let resolver = FakeResolver(
      symbols: [
        "CGSConfigureDisplayEnabled": functionPointer(displayEnableStub)
      ]
    )
    let bridge = PrivateAPIBridge(resolver: resolver)

    _ = try bridge.requireDisplayEnable()
    _ = try bridge.requireDisplayEnable()

    XCTAssertEqual(
      resolver.requests,
      [.init(symbol: "CGSConfigureDisplayEnabled", frameworkPath: nil)]
    )
  }

  func testMissingDisplayEnableSymbolThrowsUnsupportedAPI() {
    let bridge = PrivateAPIBridge(resolver: FakeResolver(symbols: [:]))

    XCTAssertThrowsError(try bridge.requireDisplayEnable()) {
      XCTAssertEqual(
        $0 as? DisplayControlError,
        .unsupportedAPI("CGSConfigureDisplayEnabled")
      )
    }
  }

  func testIOAVSymbolsUseIOMobileFramebufferFrameworkPath() throws {
    let resolver = FakeResolver(
      symbols: [
        "IOAVServiceCreateWithService": functionPointer(serviceCreateStub),
        "IOAVServiceWriteI2C": functionPointer(writeI2CStub),
        "IOAVServiceReadI2C": functionPointer(readI2CStub),
      ]
    )
    let bridge = PrivateAPIBridge(resolver: resolver)

    _ = try bridge.requireIOAVServiceCreateWithService()
    _ = try bridge.requireIOAVServiceWriteI2C()
    _ = try bridge.requireIOAVServiceReadI2C()

    XCTAssertEqual(
      resolver.requests,
      [
        .init(
          symbol: "IOAVServiceCreateWithService",
          frameworkPath: PrivateAPIBridge.ioMobileFramebufferPath
        ),
        .init(
          symbol: "IOAVServiceWriteI2C",
          frameworkPath: PrivateAPIBridge.ioMobileFramebufferPath
        ),
        .init(
          symbol: "IOAVServiceReadI2C",
          frameworkPath: PrivateAPIBridge.ioMobileFramebufferPath
        ),
      ]
    )
    XCTAssertEqual(
      PrivateAPIBridge.ioMobileFramebufferPath,
      "/System/Library/PrivateFrameworks/IOMobileFramebuffer.framework/IOMobileFramebuffer"
    )
  }

  func testDifferentSymbolsAreCachedIndependently() throws {
    let resolver = FakeResolver(
      symbols: [
        "IOAVServiceWriteI2C": functionPointer(writeI2CStub),
        "IOAVServiceReadI2C": functionPointer(readI2CStub),
      ]
    )
    let bridge = PrivateAPIBridge(resolver: resolver)

    _ = try bridge.requireIOAVServiceWriteI2C()
    _ = try bridge.requireIOAVServiceWriteI2C()
    _ = try bridge.requireIOAVServiceReadI2C()
    _ = try bridge.requireIOAVServiceReadI2C()

    XCTAssertEqual(resolver.requestCount(for: "IOAVServiceWriteI2C"), 1)
    XCTAssertEqual(resolver.requestCount(for: "IOAVServiceReadI2C"), 1)
  }
}

private struct ResolveRequest: Equatable {
  let symbol: String
  let frameworkPath: String?
}

private final class FakeResolver: SymbolResolving, @unchecked Sendable {
  private let lock = NSLock()
  private let symbols: [String: UnsafeMutableRawPointer]
  private var storedRequests: [ResolveRequest] = []

  init(symbols: [String: UnsafeMutableRawPointer]) {
    self.symbols = symbols
  }

  var requests: [ResolveRequest] {
    lock.withLock { storedRequests }
  }

  func requestCount(for symbol: String) -> Int {
    lock.withLock { storedRequests.count { $0.symbol == symbol } }
  }

  func resolve(_ symbol: String, frameworkPath: String?) -> UnsafeMutableRawPointer? {
    lock.withLock {
      storedRequests.append(.init(symbol: symbol, frameworkPath: frameworkPath))
      return symbols[symbol]
    }
  }
}

private func functionPointer<T>(_ function: T) -> UnsafeMutableRawPointer {
  unsafeBitCast(function, to: UnsafeMutableRawPointer.self)
}
