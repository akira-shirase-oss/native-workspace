// swift-tools-version: 6.2
// The Native Developer Workspace exploration package (N0). Pure logic lives in
// library targets so `swift test` covers it without an app bundle; the SwiftUI
// shell is a thin executable on top. Deployment target: the previous major
// macOS (D-023) — the runner's SDK compiles nothing newer.

import PackageDescription

let package = Package(
  name: "NativeWorkspace",
  platforms: [.macOS("26.0")],
  products: [
    .executable(name: "NativeWorkspace", targets: ["NWApp"]),
    .executable(name: "nw-replay", targets: ["NWReplay"]),
    .executable(name: "nw-fixture-server", targets: ["NWFixtureServer"]),
  ],
  targets: [
    // Pure: event model, inert text, bounded ingest, event store, freshness,
    // view models. Imports neither SwiftUI nor AppKit (architecture check).
    .target(name: "NWCore"),
    // Credentials: Keychain (this device only) or the process environment.
    .target(name: "NWCredentials"),
    // GET-only service adapters over a bounded, deadline-guarded URLSession.
    .target(name: "NWAdapters", dependencies: ["NWCore", "NWCredentials"]),
    // An in-process HTTP fixture server (Network.framework) that emulates the
    // services' read APIs and can be killed and restarted; tests and the
    // fixture-server executable share it.
    .target(name: "NWFixtures", dependencies: ["NWCore"]),
    // The SwiftUI shell: views and the app model that wires connections.
    .target(name: "NWShell", dependencies: ["NWCore", "NWAdapters", "NWCredentials"]),
    .executableTarget(name: "NWApp", dependencies: ["NWShell"]),
    .executableTarget(name: "NWReplay", dependencies: ["NWCore"]),
    .executableTarget(name: "NWFixtureServer", dependencies: ["NWFixtures"]),
    .testTarget(name: "NWCoreTests", dependencies: ["NWCore"]),
    .testTarget(name: "NWCredentialsTests", dependencies: ["NWCredentials"]),
    .testTarget(
      name: "NWAdaptersTests",
      dependencies: ["NWAdapters", "NWCore", "NWCredentials", "NWFixtures"]
    ),
    .testTarget(
      name: "NWShellTests",
      dependencies: ["NWShell", "NWCore", "NWAdapters", "NWFixtures"]
    ),
  ]
)
