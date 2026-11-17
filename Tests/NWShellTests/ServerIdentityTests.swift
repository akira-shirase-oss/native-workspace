import Foundation
import NWAdapters
import NWCore
import NWCredentials
import NWFixtures
import XCTest

@testable import NWShell

/// F4: the admin token goes only to the process the pairing named. While
/// the real Service Monitor is down, any local process can bind its port;
/// it must receive nothing — no token, no request at all.
@MainActor
final class ServerIdentityTests: XCTestCase {
  func testNothingIsSentToAListenerThatIsNotThePairedService() async throws {
    let smon = ServiceMonitorEmulator(.init(token: shellToken, monitors: 1))
    let impostor = FixtureHTTPServer { smon.handle($0) }  // this test process, not monitor-server
    try await impostor.start()
    let store = temporaryStore()
    defer { try? FileManager.default.removeItem(at: store) }
    let config = AppConfiguration.fromEnvironment([
      "NW_SMON_URL": impostor.baseURL.absoluteString,
      "NW_SMON_EXPECT_EXECUTABLE": "/opt/smon/current/bin/monitor-server",
      "NW_STORE_DIR": store.path, "NW_POLL_INTERVAL_S": "0.2",
    ])
    let model = AppModel(configuration: config, credentials: credentials(shellToken))
    model.start()
    try await Task.sleep(for: .seconds(1.5))
    XCTAssertEqual(impostor.recorded.filter(\.authorized).count, 0, "the token reached an impostor")
    XCTAssertEqual(impostor.requestCount, 0, "anything at all reached an impostor")
    XCTAssertFalse(model.services.first?.freshness().isLive ?? true)
    await model.stop()
    await impostor.stop()
  }

  func testLocalhostIsUsedAsTheLiteralLoopbackAddress() throws {
    let adapter = try ServiceMonitorAdapter(
      endpoint: URL(string: "http://localhost:60499")!, token: SecretToken(shellToken),
      transport: BoundedURLSessionTransport())
    XCTAssertEqual(adapter.endpoint.host, "127.0.0.1", "never resolved by name")
  }
}
