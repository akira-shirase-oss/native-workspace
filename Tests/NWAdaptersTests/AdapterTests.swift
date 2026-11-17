import NWCore
import NWCredentials
import NWFixtures
import Synchronization
import XCTest

@testable import NWAdapters

let fixtureToken = "0123456789abcdef0123456789abcdef0123456789abcdef"

final class ServiceMonitorAdapterTests: XCTestCase {
  var server: FixtureHTTPServer!
  var emulator: ServiceMonitorEmulator!

  override func setUp() async throws {
    emulator = ServiceMonitorEmulator(
      .init(token: fixtureToken, monitors: 3, slotInterval: 0.01),
      start: Date().addingTimeInterval(-1))
    let emulator = self.emulator!
    server = FixtureHTTPServer { emulator.handle($0) }
    try await server.start()
  }

  override func tearDown() async throws { await server.stop() }

  func adapter(token: String = fixtureToken) throws -> ServiceMonitorAdapter {
    try ServiceMonitorAdapter(
      endpoint: server.baseURL, token: SecretToken(token), transport: BoundedURLSessionTransport())
  }

  func testAPollReadsStatusChecksAndIncidentsThroughGETOnly() async throws {
    let adapter = try adapter()
    let outcome = try await adapter.poll(observedAt: Date())
    XCTAssertEqual(outcome.snapshot.verdict.value, "ready")
    XCTAssertEqual(outcome.snapshot.verdictOK, true)
    XCTAssertEqual(outcome.snapshot.version?.value, "fixture-0.1")
    XCTAssertEqual(outcome.snapshot.items.count, 3)
    let checks = outcome.events.filter { $0.kind == .check }
    XCTAssertEqual(checks.count, 3 * 50, "the first poll reads each monitor's newest 50")
    XCTAssertEqual(Set(checks.map(\.key)).count, checks.count)
    XCTAssertEqual(
      outcome.events.filter { $0.kind == .incident }.map(\.key).sorted(),
      [
        "incident:1:resolved", "incident:2:open",
      ])
    for monitor in Set(checks.map { $0.key.split(separator: ":")[1] }) {
      let times = checks.filter { $0.key.split(separator: ":")[1] == monitor }.map(\.occurredAt)
      XCTAssertEqual(times, times.sorted(), "oldest first within a monitor")
    }
    XCTAssertEqual(server.methodCounts.keys.sorted(), ["GET"])
    XCTAssertEqual(emulator.nonGETRequests, 0)
  }

  func testTheTokenGoesOnlyToTheAuthenticatedAPI() async throws {
    _ = try await adapter().poll(observedAt: Date())
    for request in server.recorded {
      XCTAssertEqual(request.authorized, request.path.hasPrefix("/api/"), request.path)
    }
  }

  func testTheNextPollReturnsOnlyNewChecks() async throws {
    let adapter = try adapter()
    let first = try await adapter.poll(observedAt: Date())
    try await Task.sleep(for: .milliseconds(120))
    let second = try await adapter.poll(observedAt: Date())
    let firstKeys = Set(first.events.map(\.key))
    let fresh = second.events.filter { $0.kind == .check }
    XCTAssertFalse(fresh.isEmpty)
    XCTAssertTrue(fresh.allSatisfy { !firstKeys.contains($0.key) })
    XCTAssertTrue(second.events.filter { $0.kind == .incident }.isEmpty, "incidents once")
  }

  func testUntrustedDetailIsCarriedVerbatimForInertRendering() async throws {
    let outcome = try await adapter().poll(observedAt: Date())
    let failing = outcome.events.filter { $0.severity == .failure && $0.kind == .check }
    XCTAssertFalse(failing.isEmpty)
    XCTAssertTrue(failing.contains { $0.text.unicodeScalars.contains { InertText.mustEscape($0) } })
    for event in failing {
      let rendered = InertText.render(event.text)
      XCTAssertFalse(rendered.unicodeScalars.contains { InertText.mustEscape($0) })
    }
  }

  func testAWrongOrRevokedTokenIsUnauthorized() async throws {
    let wrong = try adapter(token: "ffffffffffffffffffffffffffffffff")
    do {
      _ = try await wrong.poll(observedAt: Date())
      XCTFail("expected unauthorized")
    } catch {
      XCTAssertEqual(error, .unauthorized)
    }
    let adapter = try adapter()
    _ = try await adapter.poll(observedAt: Date())
    emulator.revoke()
    do {
      _ = try await adapter.poll(observedAt: Date())
      XCTFail("expected unauthorized")
    } catch {
      XCTAssertEqual(error, .unauthorized)
    }
  }

  func testANotObservingServiceIsReachableButNotReady() async throws {
    emulator.setReady(false)
    let outcome = try await adapter().poll(observedAt: Date())
    XCTAssertEqual(outcome.snapshot.verdictOK, false)
    XCTAssertTrue(outcome.snapshot.verdict.value.hasPrefix("unavailable"))
  }

  func testAnAdminClassTokenIsRefusedForANonLoopbackEndpoint() throws {
    let token = SecretToken(fixtureToken)
    for endpoint in ["https://monitor.example.com", "http://10.0.0.5:58400", "http://128.0.0.1"] {
      XCTAssertThrowsError(
        try ServiceMonitorAdapter(
          endpoint: URL(string: endpoint)!, token: token, transport: BoundedURLSessionTransport())
      ) { error in
        guard case AdapterError.refusedEndpoint = error else { return XCTFail("\(error)") }
      }
    }
    for endpoint in ["http://127.0.0.1:60400", "http://localhost:60400", "http://[::1]:60400"] {
      XCTAssertNoThrow(
        try ServiceMonitorAdapter(
          endpoint: URL(string: endpoint)!, token: token, transport: BoundedURLSessionTransport()))
    }
  }
}

final class DurableRunnerAdapterTests: XCTestCase {
  func testReadsRunsAndEmitsOneEventPerStateReached() async throws {
    let emulator = DurableRunnerEmulator(runs: [
      .init(id: 1, key: "nightly-backup", state: "done", steps: 2, finishedAt: 1_700_000_000_000),
      .init(id: 2, key: "rebuild", state: "running:step:0:attempt:1", steps: 3),
      .init(id: 3, key: "\u{1B}[31mhostile\u{202E}key", state: "failed:step:1", steps: 2),
    ])
    let server = FixtureHTTPServer { emulator.handle($0) }
    try await server.start()
    defer { Task { await server.stop() } }
    let adapter = try DurableRunnerAdapter(
      endpoint: server.baseURL, transport: BoundedURLSessionTransport())
    let first = try await adapter.poll(observedAt: Date())
    XCTAssertEqual(first.snapshot.verdictOK, true)
    XCTAssertEqual(
      first.events.map(\.key),
      ["run:1:done", "run:2:running:step:0:attempt:1", "run:3:failed:step:1"])
    XCTAssertEqual(first.events.map(\.severity), [.ok, .info, .failure])
    XCTAssertEqual(
      first.events[0].occurredAt, Date(timeIntervalSince1970: 1_700_000_000))
    XCTAssertEqual(first.snapshot.items.map(\.name.value), ["running", "failed", "done"])

    emulator.update(2, state: "done", finishedAt: 1_700_000_100_000)
    let second = try await adapter.poll(observedAt: Date())
    XCTAssertEqual(second.events.map(\.key), ["run:2:done"])
    let one = try await adapter.run(id: 3)
    XCTAssertEqual(one?.state, "failed:step:1")
    let missing = try await adapter.run(id: 99)
    XCTAssertNil(missing)
    XCTAssertTrue(server.recorded.allSatisfy { !$0.authorized }, "no credential is ever sent")
    XCTAssertEqual(server.methodCounts.keys.sorted(), ["GET"])
  }
}

final class WireTests: XCTestCase {
  func testRFC3339AsTheServicesEmitIt() {
    let base = Date(timeIntervalSince1970: 1_763_322_728)  // 2025-11-16T19:52:08Z
    XCTAssertEqual(Wire.rfc3339("2025-11-16T19:52:08Z"), base)
    XCTAssertEqual(
      Wire.rfc3339("2025-11-16T19:52:08.123456789Z")!.timeIntervalSince1970,
      base.timeIntervalSince1970 + 0.123456789, accuracy: 1e-6)
    XCTAssertEqual(Wire.rfc3339("2025-11-16T21:52:08+02:00"), base)
    XCTAssertEqual(
      Wire.rfc3339("2025-11-16T14:52:08.5-05:00")!.timeIntervalSince1970,
      base.timeIntervalSince1970 + 0.5, accuracy: 1e-9)
    XCTAssertEqual(Wire.rfc3339("2024-02-29T00:00:00Z"), Date(timeIntervalSince1970: 1_709_164_800))
    for bad in [
      "", "2025-11-16", "2025-11-16T19:52:08", "2025-13-16T19:52:08Z",
      "2025-11-16T19:52:08.Z", "2025-11-16T19:52:08Zjunk", "x025-11-16T19:52:08Z",
    ] {
      XCTAssertNil(Wire.rfc3339(bad), bad)
    }
  }

  func testEmulatorTimesRoundTrip() {
    let now = Date()
    let parsed = Wire.rfc3339(ServiceMonitorEmulator.rfc3339(now))!
    XCTAssertEqual(parsed.timeIntervalSince1970, now.timeIntervalSince1970, accuracy: 2e-6)
  }
}

/// Fixture `revoked-credential`, package level: the first 401 stops polling.
@MainActor
final class ServiceConnectionTests: XCTestCase {
  func testRevocationStopsPollingAndKeepsTheLastSnapshot() async throws {
    let emulator = ServiceMonitorEmulator(.init(token: fixtureToken, monitors: 2))
    let server = FixtureHTTPServer { emulator.handle($0) }
    try await server.start()
    let status = ServiceStatusModel(
      id: .serviceMonitor, name: "fixture", endpoint: "loopback",
      tracker: ConnectionTracker(pollInterval: 0.05, grace: 0.05))
    let queue = IngestQueue(capacity: 1_000)
    let connection = ServiceConnection(
      adapter: try ServiceMonitorAdapter(
        endpoint: server.baseURL, token: SecretToken(fixtureToken),
        transport: BoundedURLSessionTransport()),
      queue: queue, pump: nil, tracker: status.tracker
    ) { tracker, snapshot in status.update(tracker: tracker, snapshot: snapshot) }
    connection.start()
    while !status.freshness().isLive { try await Task.sleep(for: .milliseconds(10)) }
    emulator.revoke()
    while !status.tracker.isRevoked { try await Task.sleep(for: .milliseconds(10)) }
    let requestsAtRevocation = server.requestCount
    try await Task.sleep(for: .milliseconds(500))
    XCTAssertEqual(server.requestCount, requestsAtRevocation, "no retry loop with a dead token")
    XCTAssertFalse(connection.isRunning && connection.tracker.nextDelay(unit: 0) != nil)
    guard case .revoked(_, let lastGood?) = status.freshness() else {
      return XCTFail("\(status.freshness())")
    }
    XCTAssertNotNil(status.snapshot, "data stays visible")
    for item in status.snapshot?.items ?? [] {
      XCTAssertEqual(item.display(status.freshness()).tone, .neutral)
      XCTAssertTrue(item.display(status.freshness()).label.contains(Freshness.clock(lastGood)))
    }
    await connection.stop()
    await server.stop()
  }

  func testAHungServiceTurnsStaleWithinOneIntervalPlusGrace() async throws {
    let hung = Mutex(false)
    let emulator = ServiceMonitorEmulator(.init(token: fixtureToken, monitors: 1))
    let server = FixtureHTTPServer { request in
      if hung.withLock({ $0 }) { return FixtureResponse(status: 200, hang: true) }
      return emulator.handle(request)
    }
    try await server.start()
    let status = ServiceStatusModel(
      id: .serviceMonitor, name: "fixture", endpoint: "loopback",
      tracker: ConnectionTracker(pollInterval: 0.2, grace: 0.2))
    let connection = ServiceConnection(
      adapter: try ServiceMonitorAdapter(
        endpoint: server.baseURL, token: SecretToken(fixtureToken),
        transport: BoundedURLSessionTransport()),
      queue: IngestQueue(capacity: 1_000), pump: nil, tracker: status.tracker, pollDeadline: 1
    ) { tracker, snapshot in status.update(tracker: tracker, snapshot: snapshot) }
    connection.start()
    while !status.freshness().isLive { try await Task.sleep(for: .milliseconds(10)) }
    hung.withLock { $0 = true }
    let hungAt = Date()
    try await Task.sleep(for: .milliseconds(450))
    // No poll has come back (each waits on its 1 s deadline), yet the label
    // is already stale: freshness is derived from time.
    XCTAssertFalse(status.freshness(now: hungAt.addingTimeInterval(0.4)).isLive)
    XCTAssertFalse(status.freshness().isLive)
    await connection.stop()
    await server.stop()
  }
}
