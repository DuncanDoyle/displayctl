public enum DisplayControlError: Error, Equatable, Sendable {
    case invalidArguments(String)
    case displayNotFound(String)
    case ambiguousSelector(String)
    case invalidState(String)
    case lastActiveDisplay
    case unsupportedAPI(String)
    case configurationFailed(String)
    case postconditionFailed(String)
    case ddcServiceNotFound
    case ddcServiceAmbiguous
    case ddcUnsupported
    case ddcTimeout
    case ddcTransport(String)
    case ddcInvalidResponse(String)
}
