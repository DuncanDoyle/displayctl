import DisplayControlCore
import Foundation

/// The panel's fixed copy and the short line shown under a row when an operation fails.
public enum ErrorText {
  public static let busy = "Busy — another displayctl is running. Try again."
  public static let ledgerUnreadable = "Saved display list unreadable. See README › Recovery."
  public static let safetyNetOff = "Safety net off: display changes are not being watched."

  public static func short(_ error: any Error) -> String {
    guard let error = error as? DisplayControlError else { return error.localizedDescription }
    switch error {
    case .lastActiveDisplay: return "Cannot turn off the only active display"
    case .lockTimeout: return busy
    case .inventoryChanged: return "Displays changed while reading them. Try again."
    case .displayNotFound: return "Display not found"
    case .ambiguousSelector: return "Display selector is ambiguous"
    case .invalidArguments(let message), .invalidState(let message),
      .unsupportedAPI(let message), .configurationFailed(let message),
      .postconditionFailed(let message), .recoverySkipped(let message),
      .ddcTransport(let message), .ddcInvalidResponse(let message):
      return message
    case .ddcServiceNotFound: return "DDC service not found"
    case .ddcServiceAmbiguous: return "DDC service match is ambiguous"
    case .ddcUnsupported: return "DDC is unsupported"
    case .ddcTimeout: return "DDC operation timed out"
    }
  }
}
