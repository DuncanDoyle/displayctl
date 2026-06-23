import CoreFoundation
import CoreGraphics
import Darwin
import Foundation
import IOKit

protocol SymbolResolving: Sendable {
  func resolve(_ symbol: String, frameworkPath: String?) -> UnsafeMutableRawPointer?
}

typealias CGSConfigureDisplayEnabledFn =
  @convention(c) (
    CGDisplayConfigRef?,
    CGDirectDisplayID,
    Bool
  ) -> CGError

typealias IOAVServiceCreateWithServiceFn =
  @convention(c) (
    CFAllocator?,
    io_service_t
  ) -> Unmanaged<CFTypeRef>?

typealias IOAVServiceWriteI2CFn =
  @convention(c) (
    CFTypeRef,
    UInt32,
    UInt32,
    UnsafeMutableRawPointer?,
    UInt32
  ) -> IOReturn

typealias IOAVServiceReadI2CFn =
  @convention(c) (
    CFTypeRef,
    UInt32,
    UInt32,
    UnsafeMutableRawPointer?,
    UInt32
  ) -> IOReturn

final class PrivateAPIBridge: @unchecked Sendable {
  static let ioMobileFramebufferPath =
    "/System/Library/PrivateFrameworks/IOMobileFramebuffer.framework/IOMobileFramebuffer"

  private let resolver: any SymbolResolving
  private let cache = SymbolCache()

  init(resolver: any SymbolResolving = SystemSymbolResolver()) {
    self.resolver = resolver
  }

  func requireDisplayEnable() throws -> CGSConfigureDisplayEnabledFn {
    let pointer = try requireSymbol("CGSConfigureDisplayEnabled", frameworkPath: nil)
    return unsafeBitCast(pointer, to: CGSConfigureDisplayEnabledFn.self)
  }

  func requireIOAVServiceCreateWithService() throws -> IOAVServiceCreateWithServiceFn {
    let pointer = try requireSymbol(
      "IOAVServiceCreateWithService",
      frameworkPath: Self.ioMobileFramebufferPath
    )
    return unsafeBitCast(pointer, to: IOAVServiceCreateWithServiceFn.self)
  }

  func requireIOAVServiceWriteI2C() throws -> IOAVServiceWriteI2CFn {
    let pointer = try requireSymbol(
      "IOAVServiceWriteI2C",
      frameworkPath: Self.ioMobileFramebufferPath
    )
    return unsafeBitCast(pointer, to: IOAVServiceWriteI2CFn.self)
  }

  func requireIOAVServiceReadI2C() throws -> IOAVServiceReadI2CFn {
    let pointer = try requireSymbol(
      "IOAVServiceReadI2C",
      frameworkPath: Self.ioMobileFramebufferPath
    )
    return unsafeBitCast(pointer, to: IOAVServiceReadI2CFn.self)
  }

  private func requireSymbol(
    _ symbol: String,
    frameworkPath: String?
  ) throws -> UnsafeMutableRawPointer {
    let resolution = cache.resolution(for: symbol) {
      guard let pointer = resolver.resolve(symbol, frameworkPath: frameworkPath) else {
        return .missing
      }
      return .found(pointer)
    }

    switch resolution {
    case .found(let pointer):
      return pointer
    case .missing:
      throw DisplayControlError.unsupportedAPI(symbol)
    }
  }
}

private enum SymbolResolution {
  case found(UnsafeMutableRawPointer)
  case missing
}

private final class SymbolCache: @unchecked Sendable {
  private let lock = NSLock()
  private var resolutions: [String: SymbolResolution] = [:]

  func resolution(
    for symbol: String,
    resolve: () -> SymbolResolution
  ) -> SymbolResolution {
    lock.withLock {
      if let resolution = resolutions[symbol] {
        return resolution
      }

      let resolution = resolve()
      resolutions[symbol] = resolution
      return resolution
    }
  }
}

private final class SystemSymbolResolver: SymbolResolving, @unchecked Sendable {
  private static let coreGraphicsPath =
    "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics"

  private let lock = NSLock()
  private var handles: [String: UnsafeMutableRawPointer] = [:]

  func resolve(_ symbol: String, frameworkPath: String?) -> UnsafeMutableRawPointer? {
    lock.withLock {
      if let frameworkPath {
        guard let handle = frameworkHandle(for: frameworkPath) else {
          return nil
        }
        return dlsym(handle, symbol)
      }

      if let processHandle = frameworkHandle(for: "") {
        if let pointer = dlsym(processHandle, symbol) {
          return pointer
        }
      }

      guard let coreGraphicsHandle = frameworkHandle(for: Self.coreGraphicsPath) else {
        return nil
      }
      return dlsym(coreGraphicsHandle, symbol)
    }
  }

  private func frameworkHandle(for path: String) -> UnsafeMutableRawPointer? {
    if let handle = handles[path] {
      return handle
    }

    let handle =
      path.isEmpty
      ? dlopen(nil, RTLD_LAZY | RTLD_LOCAL)
      : dlopen(path, RTLD_LAZY | RTLD_LOCAL)
    guard let handle else {
      return nil
    }

    handles[path] = handle
    return handle
  }
}
