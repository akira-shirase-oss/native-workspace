import Darwin
import Foundation
import NWCore
import NWFixtures
import XCTest

@testable import NWShell

/// F17: a token taken from the environment does not stay there.
@MainActor
final class EnvironmentTokenTests: XCTestCase {
  func testTheEnvironmentTokenIsRemovedOnceRead() async throws {
    let smon = ServiceMonitorEmulator(.init(token: shellToken, monitors: 1))
    let server = FixtureHTTPServer { smon.handle($0) }
    try await server.start()
    setenv("NW_SMON_TOKEN", shellToken, 1)
    defer { unsetenv("NW_SMON_TOKEN") }
    var config = AppConfiguration()
    config.serviceMonitorURL = server.baseURL
    config.storeDirectory = temporaryStore()
    config.pollInterval = 0.1
    defer { try? FileManager.default.removeItem(at: config.storeDirectory!) }
    let model = AppModel(configuration: config)  // the default chain: Keychain, then environment
    await model.start()
    XCTAssertNil(getenv("NW_SMON_TOKEN"), "the token stayed in the environment")
    let end = Date().addingTimeInterval(5)
    while model.services.first?.freshness().isLive != true, Date() < end {
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertEqual(model.services.first?.freshness().isLive, true, "the token was still used")
    await model.stop()
    await server.stop()
  }
}
