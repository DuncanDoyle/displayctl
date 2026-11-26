import DisplayControlCore
import Foundation

public struct DisplayRow: Equatable, Identifiable, Sendable {
  public let id: UUID
  public let name: String
  public let kind: DisplayKind
  public let isOn: Bool
  public let isSwitchEnabled: Bool
  public let isBusy: Bool
  public let caption: String?
  public let error: String?
  /// External, online, active and DDC capability not `unsupported`.
  public let showsBrightness: Bool
}

public enum PanelRows {
  public static let onlyActiveCaption = "Only active display"

  /// Ledger entries from another boot and the macOS placeholder get no row (design §6.1).
  public static func make(
    displays: [Display], ledger: [DisabledDisplayEntry], currentBoot: String,
    busy: UUID?, errors: [UUID: String]
  ) -> [DisplayRow] {
    // The ledger check uses every online UUID, the placeholder's included.
    let onlineIDs = Set(displays.filter(\.isOnline).map(\.uuid))
    let online = displays.filter { $0.isOnline && !$0.isPlaceholder }
    let activeCount = online.filter(\.isActive).count

    func row(_ id: UUID, _ name: String, _ kind: DisplayKind, isOn: Bool, brightness: Bool)
      -> DisplayRow
    {
      let isOnlyActive = isOn && activeCount == 1
      return DisplayRow(
        id: id, name: name, kind: kind, isOn: isOn,
        isSwitchEnabled: busy == nil && !isOnlyActive, isBusy: busy == id,
        caption: isOnlyActive ? onlyActiveCaption : nil, error: errors[id],
        showsBrightness: brightness)
    }

    let onlineRows = online.map { display in
      row(
        display.uuid, display.name, display.kind, isOn: display.isActive,
        brightness: display.kind == .external && display.isActive
          && display.ddcCapability != .unsupported)
    }
    let ledgerRows =
      ledger
      .filter { $0.bootSession == currentBoot && !onlineIDs.contains($0.uuid) }
      .map { row($0.uuid, $0.name, $0.kind, isOn: false, brightness: false) }

    // Built-in first, then externals by name; the UUID breaks ties so the order is stable.
    return (onlineRows + ledgerRows).sorted { lhs, rhs in
      if lhs.kind != rhs.kind { return lhs.kind == .internal }
      let order = lhs.name.localizedStandardCompare(rhs.name)
      if order != .orderedSame { return order == .orderedAscending }
      return lhs.id.uuidString < rhs.id.uuidString
    }
  }
}
