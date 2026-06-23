import CoreFoundation
import CoreGraphics
import Dispatch
import Foundation
import IOKit
import XCTest

@testable import DisplayControlCore

private let displayEnableStub: CGSConfigureDisplayEnabledFn = { config, displayID, enabled in
  guard config == nil, displayID == 42, enabled else {
    return .illegalArgument
  }
  return .success
}
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
        .init(symbol: "CGSConfigureDisplayEnabled", frameworkPath: nil): functionPointer(
          displayEnableStub
        )
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

  func testReturnedFunctionPointerCanBeInvoked() throws {
    let resolver = FakeResolver(
      symbols: [
        .init(symbol: "CGSConfigureDisplayEnabled", frameworkPath: nil): functionPointer(
          displayEnableStub
        )
      ]
    )
    let function = try PrivateAPIBridge(resolver: resolver).requireDisplayEnable()

    XCTAssertEqual(function(nil, 42, true), .success)
    XCTAssertEqual(function(nil, 7, false), .illegalArgument)
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
        .init(
          symbol: "IOAVServiceCreateWithService",
          frameworkPath: PrivateAPIBridge.ioMobileFramebufferPath
        ): functionPointer(serviceCreateStub),
        .init(
          symbol: "IOAVServiceWriteI2C",
          frameworkPath: PrivateAPIBridge.ioMobileFramebufferPath
        ): functionPointer(writeI2CStub),
        .init(
          symbol: "IOAVServiceReadI2C",
          frameworkPath: PrivateAPIBridge.ioMobileFramebufferPath
        ): functionPointer(readI2CStub),
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
        .init(
          symbol: "IOAVServiceWriteI2C",
          frameworkPath: PrivateAPIBridge.ioMobileFramebufferPath
        ): functionPointer(writeI2CStub),
        .init(
          symbol: "IOAVServiceReadI2C",
          frameworkPath: PrivateAPIBridge.ioMobileFramebufferPath
        ): functionPointer(readI2CStub),
      ]
    )
    let bridge = PrivateAPIBridge(resolver: resolver)

    _ = try bridge.requireIOAVServiceWriteI2C()
    _ = try bridge.requireIOAVServiceWriteI2C()
    _ = try bridge.requireIOAVServiceReadI2C()
    _ = try bridge.requireIOAVServiceReadI2C()

    XCTAssertEqual(
      resolver.requestCount(
        for: .init(
          symbol: "IOAVServiceWriteI2C",
          frameworkPath: PrivateAPIBridge.ioMobileFramebufferPath
        )
      ),
      1
    )
    XCTAssertEqual(
      resolver.requestCount(
        for: .init(
          symbol: "IOAVServiceReadI2C",
          frameworkPath: PrivateAPIBridge.ioMobileFramebufferPath
        )
      ),
      1
    )
  }

  func testSameSymbolNameAtDifferentPathsHasIndependentCacheEntries() throws {
    let processPointer = functionPointer(displayEnableStub)
    let frameworkPointer = functionPointer(writeI2CStub)
    let frameworkPath = PrivateAPIBridge.ioMobileFramebufferPath
    let resolver = FakeResolver(
      symbols: [
        .init(symbol: "SharedSymbol", frameworkPath: nil): processPointer,
        .init(symbol: "SharedSymbol", frameworkPath: frameworkPath): frameworkPointer,
      ]
    )
    let bridge = PrivateAPIBridge(resolver: resolver)

    let resolvedProcessPointer = try bridge.requireSymbol("SharedSymbol", frameworkPath: nil)
    let resolvedFrameworkPointer = try bridge.requireSymbol(
      "SharedSymbol",
      frameworkPath: frameworkPath
    )

    XCTAssertEqual(resolvedProcessPointer, processPointer)
    XCTAssertEqual(resolvedFrameworkPointer, frameworkPointer)
    XCTAssertEqual(
      resolver.requests,
      [
        .init(symbol: "SharedSymbol", frameworkPath: nil),
        .init(symbol: "SharedSymbol", frameworkPath: frameworkPath),
      ]
    )
  }

  func testMissingSymbolIsCachedForSameCompositeKey() {
    let resolver = FakeResolver(symbols: [:])
    let bridge = PrivateAPIBridge(resolver: resolver)

    XCTAssertThrowsError(try bridge.requireDisplayEnable())
    XCTAssertThrowsError(try bridge.requireDisplayEnable())

    XCTAssertEqual(
      resolver.requestCount(
        for: .init(symbol: "CGSConfigureDisplayEnabled", frameworkPath: nil)
      ),
      1
    )
  }

  func testConcurrentRequiresResolveSameCompositeKeyOnce() {
    let resolver = FakeResolver(
      symbols: [
        .init(symbol: "CGSConfigureDisplayEnabled", frameworkPath: nil): functionPointer(
          displayEnableStub
        )
      ]
    )
    let bridge = PrivateAPIBridge(resolver: resolver)

    DispatchQueue.concurrentPerform(iterations: 100) { _ in
      _ = try! bridge.requireDisplayEnable()
    }

    XCTAssertEqual(
      resolver.requestCount(
        for: .init(symbol: "CGSConfigureDisplayEnabled", frameworkPath: nil)
      ),
      1
    )
  }
}

private final class FakeResolver: SymbolResolving, @unchecked Sendable {
  private let lock = NSLock()
  private let symbols: [SymbolKey: UnsafeMutableRawPointer]
  private var storedRequests: [SymbolKey] = []

  init(symbols: [SymbolKey: UnsafeMutableRawPointer]) {
    self.symbols = symbols
  }

  var requests: [SymbolKey] {
    lock.withLock { storedRequests }
  }

  func requestCount(for key: SymbolKey) -> Int {
    lock.withLock { storedRequests.count { $0 == key } }
  }

  func resolve(_ symbol: String, frameworkPath: String?) -> UnsafeMutableRawPointer? {
    lock.withLock {
      let key = SymbolKey(symbol: symbol, frameworkPath: frameworkPath)
      storedRequests.append(key)
      return symbols[key]
    }
  }
}

private func functionPointer<T>(_ function: T) -> UnsafeMutableRawPointer {
  unsafeBitCast(function, to: UnsafeMutableRawPointer.self)
}
