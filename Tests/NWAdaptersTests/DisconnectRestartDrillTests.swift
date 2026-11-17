import Foundation
import NWCore
import NWCredentials
import NWFixtures
import XCTest

@testable import NWAdapters

/// Drill `disconnect-restart`, package level (END_GOAL failure case 1, stale
/// half): the fixture service is killed and restarted at random points
/// `NW_DRILL_ITERATIONS` times (CI: 100; the recorded full run: 1,000), and
/// twice along the way the "app" itself restarts (store closed and reopened
/// from disk, a fresh adapter with no cursor). Pass conditions:
///
/// - from one poll interval plus the grace after a kill until the restart,
///   the status model never reports live, and no item is ever drawn green
///   while the service is not live;
/// - after a restart it is live again within backoff cap + poll interval +
///   poll deadline + 0.5 s whenever the service stayed up that long;
/// - every event the store acknowledged is still there after every reopen,
///   and no `(service, key)` is ever stored twice;
/// - the service only ever saw GET.
@MainActor
final class DisconnectRestartDrillTests: XCTestCase {
  struct Sample {
    var t: Date
    var live: Bool
    var stale: Bool
    var greenWhileNotLive: Bool
  }

  @MainActor
  final class Harness {
    let status: ServiceStatusModel
    let list = EventListModel(capacity: 10_000)
    var acked: [Event] = []
    var samples: [Sample] = []

    init(tracker: ConnectionTracker) {
      status = ServiceStatusModel(
        id: .serviceMonitor, name: "fixture", endpoint: "loopback", tracker: tracker)
    }

    func sample() {
      let now = Date()
      let freshness = status.freshness(now: now)
      let items = status.snapshot?.items ?? []
      var stale = false
      if case .stale = freshness { stale = true }
      let green = !freshness.isLive && items.contains { $0.display(freshness).tone == .good }
      samples.append(
        Sample(t: now, live: freshness.isLive, stale: stale, greenWhileNotLive: green))
    }
  }

  struct Window {
    var down: Date
    var up: Date
  }

  func testDisconnectRestartDrill() async throws {
    let iterations = Int(ProcessInfo.processInfo.environment["NW_DRILL_ITERATIONS"] ?? "") ?? 100
    let pollInterval = 0.1
    let grace = 0.1
    let backoff = Backoff(base: 0.05, cap: 0.4, jitter: 0.2)
    let pollDeadline = 0.25
    let threshold = pollInterval + grace
    let recoveryBound = backoff.cap + pollInterval + pollDeadline + 0.5

    let emulator = ServiceMonitorEmulator(
      .init(token: fixtureToken, monitors: 3, slotInterval: 0.02),
      start: Date().addingTimeInterval(-2))
    let server = FixtureHTTPServer { emulator.handle($0) }
    try await server.start()
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("nw-drill-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let storeConfig = EventStore.Configuration(
      directory: directory, retention: 1_000_000, segmentEvents: 50_000, durability: .fsync)

    let tracker = ConnectionTracker(pollInterval: pollInterval, grace: grace, backoff: backoff)
    let harness = Harness(tracker: tracker)
    let transport = BoundedURLSessionTransport(
      limits: .init(
        idleTimeout: pollDeadline, deadline: pollDeadline, maxResponseBytes: 4 << 20,
        maxRedirects: 0))
    let queue = IngestQueue(capacity: 10_000)

    var store = try EventStore(storeConfig)
    var duplicatesRefused: UInt64 = 0
    var polls: UInt64 = 0
    func makePump(_ store: EventStore) -> IngestPump {
      let pump = IngestPump(queue: queue, store: store, interval: .milliseconds(20)) { batch in
        harness.acked += batch.accepted
        harness.list.apply(batch.rows)
      }
      pump.start()
      return pump
    }
    func makeConnection(_ pump: IngestPump) throws -> ServiceConnection {
      let adapter = try ServiceMonitorAdapter(
        endpoint: server.baseURL, token: SecretToken(fixtureToken), transport: transport)
      let connection = ServiceConnection(
        adapter: adapter, queue: queue, pump: pump, tracker: harness.status.tracker,
        pollDeadline: pollDeadline
      ) { tracker, snapshot in
        harness.status.update(tracker: tracker, snapshot: snapshot)
      }
      connection.start()
      return connection
    }
    var pump = makePump(store)
    var connection = try makeConnection(pump)

    let sampler = Task { @MainActor in
      while !Task.isCancelled {
        harness.sample()
        try? await Task.sleep(for: .milliseconds(5))
      }
    }

    // Wait for the first live state before the first kill.
    let firstLiveDeadline = Date().addingTimeInterval(5)
    while !harness.status.freshness().isLive, Date() < firstLiveDeadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertTrue(harness.status.freshness().isLive, "never became live")

    var windows: [Window] = []
    var reopenChecks = 0
    let appRestarts = Set([iterations / 3, (2 * iterations) / 3])
    for i in 0..<iterations {
      try await Task.sleep(for: .milliseconds(Int.random(in: 50...900)))
      await server.stop()
      let down = Date()
      try await Task.sleep(for: .milliseconds(Int.random(in: 30...400)))
      let up = Date()
      try await server.start()
      windows.append(Window(down: down, up: up))

      if appRestarts.contains(i) {
        // The app restarts: everything acknowledged must come back from disk,
        // and a cursor-less adapter re-reading history must add nothing twice.
        await connection.stop()
        await pump.flush()
        await pump.stop()
        polls += connection.polls
        duplicatesRefused += pump.stats.duplicates
        store.close()
        store = try EventStore(storeConfig)
        let back = Set(store.recent(Int.max).map(\.identity))
        XCTAssertTrue(
          harness.acked.allSatisfy { back.contains($0.identity) },
          "acknowledged events lost across an app restart")
        reopenChecks += 1
        pump = makePump(store)
        connection = try makeConnection(pump)
      }
    }
    try await Task.sleep(for: .seconds(recoveryBound))
    sampler.cancel()
    await connection.stop()
    await pump.flush()
    await pump.stop()
    polls += connection.polls
    duplicatesRefused += pump.stats.duplicates
    store.close()
    await server.stop()

    // 1. Stale within one poll interval plus grace; never live while down.
    var liveWhileDown = 0
    var notStaleWhileDown = 0
    var detection: [Double] = []
    let samples = harness.samples
    for window in windows {
      let mustBeStale = window.down.addingTimeInterval(threshold)
      for sample in samples where sample.t >= mustBeStale && sample.t < window.up {
        if sample.live { liveWhileDown += 1 }
        if !sample.stale { notStaleWhileDown += 1 }
      }
      if let first = samples.first(where: { $0.t >= window.down && !$0.live }) {
        detection.append(first.t.timeIntervalSince(window.down))
      }
    }
    XCTAssertEqual(liveWhileDown, 0, "a killed service was labeled live")
    XCTAssertEqual(notStaleWhileDown, 0, "a killed service was not labeled stale")
    XCTAssertEqual(samples.filter(\.greenWhileNotLive).count, 0, "stale data drawn green")

    // 2. Recovery with backoff after every restart that stayed up long enough.
    var recoveries: [Double] = []
    var missedRecoveries = 0
    for (index, window) in windows.enumerated() {
      let nextDown = index + 1 < windows.count ? windows[index + 1].down : Date.distantFuture
      if let first = samples.first(where: { $0.t >= window.up && $0.t < nextDown && $0.live }) {
        recoveries.append(first.t.timeIntervalSince(window.up))
      } else if nextDown.timeIntervalSince(window.up) >= recoveryBound {
        missedRecoveries += 1
      }
    }
    XCTAssertEqual(missedRecoveries, 0, "did not recover within \(recoveryBound) s")
    XCTAssertLessThanOrEqual(recoveries.max() ?? 0, recoveryBound)

    // 3. Nothing acknowledged is lost; nothing is stored twice.
    let reopened = try EventStore(storeConfig)
    let retained = reopened.recent(Int.max)
    let identities = retained.map(\.identity)
    XCTAssertEqual(Set(identities).count, identities.count, "duplicate rows in the store")
    let retainedSet = Set(identities)
    let lost = harness.acked.filter { !retainedSet.contains($0.identity) }
    XCTAssertEqual(lost.count, 0, "acknowledged events missing after the drill")
    XCTAssertEqual(Set(harness.acked.map(\.identity)).count, harness.acked.count)
    XCTAssertEqual(Set(harness.list.rows.map(\.id)).count, harness.list.rows.count)
    XCTAssertEqual(reopenChecks, appRestarts.count)

    // 4. GET only, seen from the server.
    XCTAssertEqual(server.methodCounts.keys.sorted(), ["GET"])
    XCTAssertEqual(emulator.nonGETRequests, 0)

    let summary: [String: Any] = [
      "drill": "disconnect-restart (package level, fixture server)",
      "iterations": iterations,
      "app_restarts": reopenChecks,
      "poll_interval_s": pollInterval, "grace_s": grace, "poll_deadline_s": pollDeadline,
      "backoff": ["base_s": backoff.base, "cap_s": backoff.cap, "jitter": backoff.jitter],
      "samples": samples.count,
      "live_while_down": liveWhileDown,
      "not_stale_while_down": notStaleWhileDown,
      "green_while_not_live": samples.filter(\.greenWhileNotLive).count,
      "detection_s": summaryDict(detection),
      "recovery_s": summaryDict(recoveries),
      "recovery_bound_s": recoveryBound,
      "missed_recoveries": missedRecoveries,
      "acknowledged_events": harness.acked.count,
      "retained_after_reopen": retained.count,
      "acknowledged_lost": lost.count,
      "duplicate_rows": identities.count - Set(identities).count,
      "duplicates_refused_by_store": duplicatesRefused,
      "polls": polls,
      "server_requests_by_method": server.methodCounts,
    ]
    if let path = ProcessInfo.processInfo.environment["NW_DRILL_RESULT"] {
      let data = try JSONSerialization.data(
        withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
      try data.write(to: URL(fileURLWithPath: path))
    }
  }

  private func summaryDict(_ values: [Double]) -> [String: Any] {
    let s = LatencySummary(values)
    return ["count": s.count, "p50": s.p50, "p95": s.p95, "p99": s.p99, "max": s.max]
  }
}
