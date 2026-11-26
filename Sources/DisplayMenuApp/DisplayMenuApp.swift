import AppKit
import DisplayMenuKit
import SwiftUI

@main
struct DisplayMenuApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

  var body: some Scene {
    MenuBarExtra("Displays", systemImage: "display") {
      PanelView(model: delegate.model)
    }
    .menuBarExtraStyle(.window)
  }
}

/// Owns the model and the observers so the safety net runs before the panel first opens.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  let model: PanelModel
  private let observers: SystemObservers

  override init() {
    let live = LiveServices()
    model = PanelModel(operations: live.operations, brightness: live.brightness)
    observers = SystemObservers(scheduler: live.scheduler, model: model)
    super.init()
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApplication.shared.setActivationPolicy(.accessory)  // no Dock icon
    observers.start()
  }
}
