public enum DisplayControlError: Error, Equatable, Sendable {
  case invalidArguments(String)
  case displayNotFound(String)
  case ambiguousSelector(String)
  case invalidState(String)
  case lastActiveDisplay
  case unsupportedAPI(String)
  case configurationFailed(String)
  case postconditionFailed(String)
  case recoverySkipped(String)
  /// The display operation lock stayed held by another process for its whole bounded wait.
  case lockTimeout
  /// The display list kept changing while it was read, on every bounded retry.
  case inventoryChanged
  case ddcServiceNotFound
  case ddcServiceAmbiguous
  case ddcUnsupported
  case ddcTimeout
  case ddcTransport(String)
  case ddcInvalidResponse(String)
}
