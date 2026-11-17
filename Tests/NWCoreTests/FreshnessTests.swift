import XCTest

@testable import NWCore

/// Failure case 1, package half: stale with timestamps, never stale-green,
/// backoff 1 s doubling to a 30 s cap with jitter, polling stops on 401.
final class FreshnessTests: XCTestCase {
  let t0 = Date(timeIntervalSince1970: 1_000_000)

  func testConnectingUntilTheFirstAnswer() {
    XCTAssertEqual(ConnectionTracker().freshness(now: t0), .connecting)
  }

  func testLiveOnlyWithinOnePollIntervalPlusGrace() {
    var tracker = ConnectionTracker(pollInterval: 2, grace: 1)
    tracker.recordSuccess(asOf: t0)
    XCTAssertEqual(tracker.freshness(now: t0.addingTimeInterval(3)), .live(asOf: t0))
    let late = tracker.freshness(now: t0.addingTimeInterval(3.001))
    guard case .stale(let since, let lastGood, _) = late else { return XCTFail("\(late)") }
    XCTAssertEqual(since, t0.addingTimeInterval(3))
    XCTAssertEqual(lastGood, t0)
  }

  func testAFailureIsStaleImmediatelyWithTheLastGoodTime() {
    var tracker = ConnectionTracker(pollInterval: 2, grace: 1)
    tracker.recordSuccess(asOf: t0)
    tracker.recordFailure(.unreachable("refused"), at: t0.addingTimeInterval(1))
    let state = tracker.freshness(now: t0.addingTimeInterval(1))
    guard case .stale(let since, let lastGood, let reason) = state else {
      return XCTFail("\(state)")
    }
    XCTAssertEqual(since, t0.addingTimeInterval(1))
    XCTAssertEqual(lastGood, t0)
    XCTAssertTrue(reason.value.contains("refused"))
    XCTAssertFalse(state.isLive)
  }

  func testStaleDataIsNeverLabeledLive() {
    // Exhaustive over a grid of event orders and query times.
    var rng = SystemRandomNumberGenerator()
    for _ in 0..<2_000 {
      var tracker = ConnectionTracker(pollInterval: 2, grace: 1)
      var now = t0
      for _ in 0..<20 {
        now = now.addingTimeInterval(Double.random(in: 0..<4, using: &rng))
        if Bool.random(using: &rng) {
          tracker.recordSuccess(asOf: now.addingTimeInterval(-Double.random(in: 0..<0.5)))
        } else {
          tracker.recordFailure(.timeout, at: now)
        }
        let query = now.addingTimeInterval(Double.random(in: 0..<5, using: &rng))
        if case .live(let asOf) = tracker.freshness(now: query) {
          XCTAssertLessThanOrEqual(query.timeIntervalSince(asOf), 3 + 1e-9)
          XCTAssertEqual(tracker.consecutiveFailures, 0)
        }
      }
    }
  }

  func testRecoveryAfterFailureIsLiveAgainAndCounted() {
    var tracker = ConnectionTracker(pollInterval: 2, grace: 1)
    tracker.recordSuccess(asOf: t0)
    tracker.recordFailure(.timeout, at: t0.addingTimeInterval(2))
    tracker.recordFailure(.timeout, at: t0.addingTimeInterval(3))
    tracker.recordSuccess(asOf: t0.addingTimeInterval(5))
    XCTAssertEqual(
      tracker.freshness(now: t0.addingTimeInterval(5.5)), .live(asOf: t0.addingTimeInterval(5)))
    XCTAssertEqual(tracker.recoveries, 1)
    XCTAssertEqual(tracker.nextDelay(unit: 0.5), 2)
  }

  func testBackoffDoublesFromOneSecondToAThirtySecondCap() {
    let backoff = Backoff.contract
    XCTAssertEqual(
      (1...8).map { backoff.delay(attempt: $0, unit: 0) }, [1, 2, 4, 8, 16, 30, 30, 30])
    for attempt in 1...40 {
      for unit in stride(from: 0.0, to: 1.0, by: 0.05) {
        let delay = backoff.delay(attempt: attempt, unit: unit)
        let nominal = min(30, pow(2, Double(attempt - 1)))
        XCTAssertLessThanOrEqual(delay, nominal)
        XCTAssertGreaterThan(delay, nominal * 0.8 - 1e-9, "jitter removes at most 20%")
      }
    }
    XCTAssertLessThanOrEqual(backoff.delay(attempt: 10_000, unit: 0), 30)
  }

  func testFailingTrackerUsesBackoff() {
    var tracker = ConnectionTracker(pollInterval: 2, grace: 1)
    tracker.recordFailure(.unreachable("x"), at: t0)
    XCTAssertEqual(tracker.nextDelay(unit: 0), 1)
    tracker.recordFailure(.unreachable("x"), at: t0)
    XCTAssertEqual(tracker.nextDelay(unit: 0), 2)
  }

  func testUnauthorizedRevokesStopsPollingAndKeepsLastGood() {
    var tracker = ConnectionTracker(pollInterval: 2, grace: 1)
    tracker.recordSuccess(asOf: t0)
    tracker.recordFailure(.unauthorized, at: t0.addingTimeInterval(1))
    XCTAssertEqual(
      tracker.freshness(now: t0.addingTimeInterval(1)),
      .revoked(at: t0.addingTimeInterval(1), lastGood: t0))
    XCTAssertNil(tracker.nextDelay(unit: 0), "no retry loop with a dead credential")
    tracker.recordSuccess(asOf: t0.addingTimeInterval(2))
    XCTAssertTrue(tracker.isRevoked, "only re-pairing restores authority")
  }

  func testStaleItemsAreNeverDrawnGreen() {
    let item = ItemStatus(id: "m", name: "api", state: .up, detail: "")
    XCTAssertEqual(item.display(.live(asOf: t0)).tone, .good)
    let stale = Freshness.stale(since: t0, lastGood: t0, reason: InertString("x"))
    for freshness in [stale, .revoked(at: t0, lastGood: t0), .connecting] {
      for state in [ItemState.up, .down, .unknown, .paused, .info] {
        let display = ItemStatus(id: "m", name: "api", state: state, detail: "d").display(freshness)
        XCTAssertNotEqual(display.tone, .good)
        XCTAssertTrue(display.label.contains("stale"))
      }
    }
  }
}
