import AppKit
import NWShell
import SwiftUI

/// The exploration shell (N0). Development-signed, never distributed
/// (D-011, D-019). Pairing comes from the process environment for now
/// (see `AppConfiguration.fromEnvironment`).
@main
struct NativeWorkspaceApp: App {
  @State private var model = AppModel(configuration: .fromEnvironment())
  private let launchedAt = Date()

  init() {
    // A SwiftPM executable has no bundle Info.plist; ask to be a regular app
    // so the window and menu bar appear (measurement runs stay in the
    // background and never take focus).
    let measuring = ProcessInfo.processInfo.environment["NW_MEASURE_SECONDS"] != nil
    NSApplication.shared.setActivationPolicy(measuring ? .accessory : .regular)
  }

  var body: some Scene {
    WindowGroup("Native Workspace (exploration)") {
      RootView(model: model)
        .frame(minWidth: 820, minHeight: 520)
        .task {
          model.start()
          if let seconds = model.configuration.measureSeconds {
            let session = MeasurementSession(
              model: model, seconds: seconds, output: model.configuration.measureOutput,
              launchedAt: launchedAt)
            await session.run(firstTaskAt: Date())
          }
        }
    }
  }
}
