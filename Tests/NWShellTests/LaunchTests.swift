import Foundation
import NWCore
import XCTest

@testable import NWShell

/// F8: launching with a full store never stalls the main actor.
@MainActor
final class LaunchTests: XCTestCase {
  func testLaunchWithAFullStoreNeverStallsTheMainActor() async throws {
    let directory = temporaryStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    do {
      let store = try EventStore(.init(directory: directory, durability: .none))
      for chunk in stride(from: 0, to: 50_000, by: 5_000) {
        _ = try store.append(
          (chunk..<chunk + 5_000).map { n in
            Event(
              service: .serviceMonitor, kind: .check, key: "check:m:\(n)",
              occurredAt: Date(timeIntervalSince1970: 1_000 + Double(n)),
              observedAt: Date(timeIntervalSince1970: 1_000 + Double(n)), severity: .ok,
              text: "api-\(n % 20): pass HTTP 200 \(n % 40) ms — "
                + String(repeating: "detail ", count: 15))
          })
      }
      store.close()
    }
    var config = AppConfiguration()
    config.storeDirectory = directory
    let model = AppModel(configuration: config, credentials: credentials(nil))
    let watchdog = MainThreadWatchdog(interval: 0.005, hangThreshold: 0.25)
    watchdog.start()
    await model.start()
    let end = Date().addingTimeInterval(30)
    while model.events.rows.count < 10_000, Date() < end {
      try await Task.sleep(for: .milliseconds(10))
    }
    try await Task.sleep(for: .milliseconds(100))
    let report = watchdog.stop()
    XCTAssertEqual(model.events.rows.count, 10_000, "history came back")
    XCTAssertEqual(report.hangs, 0, "main thread stalled \(report.latencyMs.max) ms during launch")
    XCTAssertLessThan(report.latencyMs.max, 250)
    await model.stop()
  }
}
