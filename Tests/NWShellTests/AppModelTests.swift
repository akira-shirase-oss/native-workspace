import NWAdapters
import NWCore
import NWCredentials
import NWFixtures
import XCTest

@testable import NWShell

let shellToken = "fedcba9876543210fedcba9876543210fedcba9876543210"

func credentials(_ token: String?) -> EnvironmentCredentials {
  EnvironmentCredentials(
    variables: [ServiceID.serviceMonitor.rawValue: "NW_SMON_TOKEN"],
    environment: token.map { ["NW_SMON_TOKEN": $0] } ?? [:])
}

func temporaryStore() -> URL {
  FileManager.default.temporaryDirectory.appendingPathComponent("nw-shell-\(UUID().uuidString)")
}

/// The shell's model against the in-process fixture services: the same
/// wiring the window shows.
@MainActor
final class AppModelTests: XCTestCase {
  func testPairsBothServicesAndFillsTheBoundedList() async throws {
    let smon = ServiceMonitorEmulator(.init(token: shellToken, monitors: 2, slotInterval: 0.02))
    let smonServer = FixtureHTTPServer { smon.handle($0) }
    try await smonServer.start()
    let durable = DurableRunnerEmulator(runs: [
      .init(id: 1, key: "k", state: "failed:step:0", steps: 1)
    ])
    let durableServer = FixtureHTTPServer { durable.handle($0) }
    try await durableServer.start()
    var config = AppConfiguration()
    config.serviceMonitorURL = smonServer.baseURL
    config.durableRunnerURL = durableServer.baseURL
    config.storeDirectory = temporaryStore()
    config.pollInterval = 0.1
    config.grace = 0.2
    config.viewRows = 100
    defer { try? FileManager.default.removeItem(at: config.storeDirectory!) }

    let model = AppModel(configuration: config, credentials: credentials(shellToken))
    model.start()
    XCTAssertEqual(model.problems, [])
    XCTAssertEqual(model.services.map(\.id), [.serviceMonitor, .durableRunner])
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline,
      !(model.services.allSatisfy { $0.freshness().isLive } && model.events.rows.count >= 100)
    {
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertTrue(model.services.allSatisfy { $0.freshness().isLive })
    XCTAssertEqual(model.events.rows.count, 100, "the view is bounded")
    XCTAssertGreaterThan(model.events.trimmed, 0)
    XCTAssertGreaterThan(model.counters.store.retained, 100)
    await model.stop()
    // Killing a service turns it stale on screen without any poll returning.
    await smonServer.stop()
    await durableServer.stop()
    let after = Date().addingTimeInterval(config.pollInterval + config.grace + 0.01)
    XCTAssertTrue(model.services.allSatisfy { !$0.freshness(now: after).isLive })
  }

  func testRowsOnDiskComeBackAtLaunch() async throws {
    let smon = ServiceMonitorEmulator(.init(token: shellToken, monitors: 1, slotInterval: 0.01))
    let server = FixtureHTTPServer { smon.handle($0) }
    try await server.start()
    var config = AppConfiguration()
    config.serviceMonitorURL = server.baseURL
    config.storeDirectory = temporaryStore()
    config.pollInterval = 0.1
    config.durability = .fsync
    defer { try? FileManager.default.removeItem(at: config.storeDirectory!) }
    let first = AppModel(configuration: config, credentials: credentials(shellToken))
    first.recordAcknowledged = true
    first.start()
    while first.acknowledged.count < 20 { try await Task.sleep(for: .milliseconds(20)) }
    await first.stop()
    await server.stop()
    let acknowledged = first.acknowledged

    var offline = config
    offline.serviceMonitorURL = nil
    offline.durableRunnerURL = nil
    let second = AppModel(configuration: offline, credentials: credentials(nil))
    second.start()
    let back = Set(second.storedIdentities())
    XCTAssertTrue(acknowledged.allSatisfy { back.contains($0) })
    XCTAssertGreaterThanOrEqual(second.events.rows.count, 20)
    XCTAssertEqual(second.problems.count, 1, "no service paired is said, not hidden")
  }

  func testPairingProblemsAreShownNotLogged() {
    var config = AppConfiguration()
    config.storeDirectory = nil
    config.serviceMonitorURL = URL(string: "https://monitor.example.com")
    let remote = AppModel(configuration: config, credentials: credentials(shellToken))
    remote.start()
    XCTAssertEqual(remote.services.count, 0)
    XCTAssertTrue(remote.problems.first?.contains("loopback") ?? false, "\(remote.problems)")

    config.serviceMonitorURL = URL(string: "http://127.0.0.1:60499")
    let tokenless = AppModel(configuration: config, credentials: credentials(nil))
    tokenless.start()
    XCTAssertTrue(tokenless.problems.first?.contains("no token") ?? false)
    for problem in remote.problems + tokenless.problems {
      XCTAssertFalse(problem.contains(shellToken))
    }
  }

  func testEnvironmentConfigurationIsBounded() {
    let config = AppConfiguration.fromEnvironment([
      "NW_SMON_URL": "http://127.0.0.1:60410", "NW_SMON_CHECKS_PER_MONITOR": "100000",
      "NW_POLL_INTERVAL_S": "0.001", "NW_STORE_DIR": "/tmp/x",
    ])
    XCTAssertEqual(config.checksPerMonitor, 500)
    XCTAssertEqual(config.pollInterval, 2, "an unreasonably short interval is ignored")
    XCTAssertEqual(config.storeDirectory?.path, "/tmp/x")
    XCTAssertEqual(config.durability, .fullFsync)
  }
}
