import Foundation
import NWAdapters
import NWCore
import NWCredentials
import XCTest

@testable import NWShell

/// Drill `disconnect-restart` against real scratch services (driven by
/// `scripts/drill-real-services.sh`, which builds Service Monitor and Durable
/// Runner from their `main`, starts them on loopback ports 60400–60499 with
/// data under /tmp, and kills (SIGKILL) and restarts them when this test asks).
/// Skipped unless `NW_REAL_DRILL_DIR` is set.
///
/// Uses the shell's own `AppModel` with the contract's timings (2 s polls,
/// 1 s grace, backoff 1 s doubling to 30 s). Pass conditions per cycle:
/// every service is labeled stale — never live — from kill + 3 s until the
/// restart, no item is drawn green while not live, the service is live again
/// after the restart without re-pairing, and every acknowledged event is in
/// the store (and in a fresh store opened from disk) exactly once.
@MainActor
final class RealServiceDrillTests: XCTestCase {
  func testRealServicesKilledAndRestarted() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let dir = env["NW_REAL_DRILL_DIR"] else {
      throw XCTSkip("run by scripts/drill-real-services.sh (NW_REAL_DRILL_DIR unset)")
    }
    let control = URL(fileURLWithPath: dir, isDirectory: true)
    let cycles = Int(env["NW_REAL_DRILL_CYCLES"] ?? "") ?? 3
    var config = AppConfiguration.fromEnvironment(env)
    config.storeDirectory = control.appendingPathComponent("store", isDirectory: true)
    config.pollInterval = 2
    config.grace = 1
    config.backoff = .contract
    XCTAssertNotNil(config.serviceMonitorURL)
    XCTAssertNotNil(config.durableRunnerURL)

    let model = AppModel(configuration: config)
    model.recordAcknowledged = true
    model.start()
    XCTAssertEqual(model.problems, [], "pairing problems: \(model.problems)")
    let threshold = config.pollInterval + config.grace

    func allLive() -> Bool { model.services.allSatisfy { $0.freshness().isLive } }
    func waitFor(_ name: String, timeout: TimeInterval) async throws -> Date? {
      let url = control.appendingPathComponent(name)
      let end = Date().addingTimeInterval(timeout)
      while Date() < end {
        if let text = try? String(contentsOf: url, encoding: .utf8),
          let t = Double(text.trimmingCharacters(in: .whitespacesAndNewlines))
        {
          return Date(timeIntervalSince1970: t)
        }
        try await Task.sleep(for: .milliseconds(20))
      }
      return nil
    }
    func signal(_ name: String) throws {
      try "\(Date().timeIntervalSince1970)\n".write(
        to: control.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    var end = Date().addingTimeInterval(30)
    while !allLive(), Date() < end { try await Task.sleep(for: .milliseconds(50)) }
    XCTAssertTrue(allLive(), "the scratch services never became live")

    var cycleResults: [[String: Any]] = []
    var liveWhileDown = 0
    var greenWhileNotLive = 0
    for cycle in 1...cycles {
      // Kill at a random phase of the poll cycle.
      try await Task.sleep(for: .milliseconds(Int.random(in: 200...4_000)))
      let ackedBefore = model.acknowledged.count
      try signal("want-kill-\(cycle)")
      guard let killedAt = try await waitFor("killed-\(cycle)", timeout: 30) else {
        return XCTFail("the driver never killed the services (cycle \(cycle))")
      }
      // Sample until the driver says the restart finished; judge afterwards,
      // against the moment the restart began.
      var samples: [(t: Date, id: String, live: Bool, green: Bool)] = []
      var restartedAt: Date?
      while restartedAt == nil {
        let now = Date()
        for service in model.services {
          let freshness = service.freshness(now: now)
          let green =
            !freshness.isLive
            && (service.snapshot?.items ?? []).contains { $0.display(freshness).tone == .good }
          samples.append((now, service.id.rawValue, freshness.isLive, green))
        }
        if let text = try? String(
          contentsOf: control.appendingPathComponent("restarted-\(cycle)"), encoding: .utf8),
          let t = Double(text.trimmingCharacters(in: .whitespacesAndNewlines))
        {
          restartedAt = Date(timeIntervalSince1970: t)
        }
        try await Task.sleep(for: .milliseconds(50))
      }
      guard let restartingAt = try await waitFor("restarting-\(cycle)", timeout: 1) else {
        return XCTFail("no restarting marker (cycle \(cycle))")
      }
      var firstStale: [String: Double] = [:]
      for sample in samples where sample.t >= killedAt && sample.t < restartingAt {
        if sample.t >= killedAt.addingTimeInterval(threshold), sample.live { liveWhileDown += 1 }
        if !sample.live, firstStale[sample.id] == nil {
          firstStale[sample.id] = sample.t.timeIntervalSince(killedAt)
        }
      }
      greenWhileNotLive += samples.filter(\.green).count
      // Live samples after the restart began but before the driver's marker:
      // expected (a poll can land first); recorded, not judged.
      let liveDuringRestart = samples.filter {
        $0.t >= restartingAt && $0.t < restartedAt! && $0.live
      }.count
      let downSeconds = restartingAt.timeIntervalSince(killedAt)
      end = Date().addingTimeInterval(config.backoff.cap + threshold + 5)
      while !allLive(), Date() < end { try await Task.sleep(for: .milliseconds(50)) }
      let recovered = allLive()
      XCTAssertTrue(recovered, "not live again after restart \(cycle)")
      let recovery = Date().timeIntervalSince(restartedAt!)
      for service in model.services {
        let seconds = firstStale[service.id.rawValue] ?? .infinity
        XCTAssertLessThanOrEqual(
          seconds, threshold + 0.1, "\(service.id) took \(seconds) s to turn stale")
      }
      cycleResults.append([
        "cycle": cycle, "down_s": downSeconds, "stale_after_kill_s": firstStale,
        "recovered": recovered, "recovery_after_restart_s": recovery,
        "acknowledged_before_kill": ackedBefore,
        "live_samples_between_restart_begin_and_marker": liveDuringRestart,
      ])
    }
    // Let a few post-restart polls land, then check the store.
    try await Task.sleep(for: .seconds(5))
    await model.flush()
    let acknowledged = model.acknowledged
    let stored = model.storedIdentities()
    await model.stop()
    let reopened = try EventStore(.init(directory: config.storeDirectory, retention: 50_000))
    let fromDisk = reopened.recent(Int.max).map(\.identity)
    reopened.close()

    // The impostor that held Service Monitor's port in cycle 1 got nothing.
    let impostor =
      (try? String(contentsOf: control.appendingPathComponent("impostor"), encoding: .utf8))?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? "missing"
    XCTAssertEqual(impostor, "0 requests", "the impostor was sent something")

    XCTAssertEqual(liveWhileDown, 0, "a killed service was labeled live")
    XCTAssertEqual(greenWhileNotLive, 0, "stale data drawn green")
    XCTAssertEqual(Set(stored).count, stored.count, "duplicate rows")
    XCTAssertEqual(Set(fromDisk).count, fromDisk.count, "duplicate rows on disk")
    let storedSet = Set(stored)
    let diskSet = Set(fromDisk)
    let lost = acknowledged.filter { !storedSet.contains($0) }.count
    let lostOnDisk = acknowledged.filter { !diskSet.contains($0) }.count
    XCTAssertEqual(lost, 0, "acknowledged events missing from the store")
    XCTAssertEqual(lostOnDisk, 0, "acknowledged events missing after reopening from disk")
    XCTAssertGreaterThan(acknowledged.count, 0, "the drill saw no events at all")

    let byService = Dictionary(grouping: acknowledged, by: { $0.service.rawValue }).mapValues(
      \.count)
    let result: [String: Any] = [
      "drill": "disconnect-restart against real scratch services (SIGKILL + restart)",
      "poll_interval_s": config.pollInterval, "grace_s": config.grace,
      "backoff": ["base_s": 1, "cap_s": 30, "jitter": config.backoff.jitter],
      "cycles": cycleResults,
      "live_while_down_samples": liveWhileDown,
      "green_while_not_live_samples": greenWhileNotLive,
      "impostor_in_cycle_1_saw": impostor,
      "service_monitor_pinned": "\(config.serviceMonitorPin)",
      "acknowledged_events": acknowledged.count,
      "acknowledged_by_service": byService,
      "stored_events": stored.count,
      "duplicate_rows": stored.count - Set(stored).count,
      "acknowledged_lost": lost,
      "acknowledged_lost_after_reopen": lostOnDisk,
      "duplicates_refused": model.counters.pump.duplicates,
      "polls": Dictionary(
        uniqueKeysWithValues: model.services.map { ($0.id.rawValue, $0.polls) }),
    ]
    let data = try JSONSerialization.data(
      withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: control.appendingPathComponent("result.json"))
  }
}
