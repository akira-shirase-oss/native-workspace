import XCTest

@testable import NWCore

func makeEvent(
  _ n: Int, service: ServiceID = .serviceMonitor, at date: Date = Date(timeIntervalSince1970: 1_000)
) -> Event {
  Event(
    service: service, kind: .check, key: "check:m:\(n)", occurredAt: date, observedAt: date,
    severity: .ok, text: "event \(n)")
}

/// D-021 and failure case 2: bounded queue, gap markers whose counts equal
/// the drops.
final class IngestQueueTests: XCTestCase {
  func testAdmitsUpToCapacityThenDropsIntoOneGap() {
    let queue = IngestQueue(capacity: 5)
    let result = queue.offer((0..<12).map { makeEvent($0) })
    XCTAssertEqual(result, OfferResult(admitted: 5, dropped: 7))
    XCTAssertEqual(queue.stats.depth, 5)
    XCTAssertEqual(queue.pendingGapCount, 7)
    let drained = queue.drain()
    XCTAssertEqual(drained.count, 6, "five events and one gap marker")
    XCTAssertEqual(drained.prefix(5).map(\.key), (0..<5).map { "check:m:\($0)" })
    XCTAssertEqual(drained.last?.kind, .gap)
    XCTAssertEqual(drained.last?.gapCount, 7)
    XCTAssertEqual(drained.last?.service, .ingest)
  }

  func testGapSitsWhereTheDropsHappened() {
    let queue = IngestQueue(capacity: 2)
    queue.offer([makeEvent(0), makeEvent(1), makeEvent(2)])  // 2 admitted, 1 dropped
    XCTAssertEqual(queue.drain(max: 1).map(\.key), ["check:m:0"])
    queue.offer([makeEvent(3)])  // room again: closes the gap, lands after it
    let rest = queue.drain()
    XCTAssertEqual(rest.map(\.kind), [.check, .gap, .check])
    XCTAssertEqual(rest[1].gapCount, 1)
    XCTAssertEqual(rest[2].key, "check:m:3")
  }

  func testDepthNeverExceedsCapacityAndLedgerHoldsAcrossRepeatedBursts() {
    let capacity = 10_000
    let queue = IngestQueue(capacity: capacity)
    var gapSum: UInt64 = 0
    var retained = 0
    var sent = 0
    for burst in 0..<10 {
      let events = (0..<15_000).map { makeEvent(burst * 100_000 + $0) }
      sent += events.count
      queue.offer(events)
      XCTAssertLessThanOrEqual(queue.stats.depth, capacity)
      // Drain only part of it, as a slow consumer would.
      let drained = queue.drain(max: 7_000)
      for event in drained {
        if event.kind == .gap { gapSum += event.gapCount ?? 0 } else { retained += 1 }
      }
    }
    for event in queue.drain() {
      if event.kind == .gap { gapSum += event.gapCount ?? 0 } else { retained += 1 }
    }
    let stats = queue.stats
    XCTAssertEqual(stats.offered, UInt64(sent))
    XCTAssertEqual(stats.offered, stats.admitted + stats.dropped)
    XCTAssertEqual(gapSum, stats.dropped, "gap counts equal the drop counter")
    XCTAssertEqual(UInt64(sent - retained), stats.dropped, "drops equal sent minus retained")
    XCTAssertEqual(stats.gapCountEmitted, stats.dropped)
    XCTAssertLessThanOrEqual(stats.maxDepth, capacity)
  }

  func testGapCountsDropsPerService() {
    let queue = IngestQueue(capacity: 1)
    queue.offer([
      makeEvent(0), makeEvent(1), makeEvent(2, service: .durableRunner),
      makeEvent(3, service: .durableRunner),
    ])
    let gap = queue.drain().last
    XCTAssertEqual(gap?.gapCount, 3)
    XCTAssertEqual(
      gap?.text, "3 events dropped: ingest queue full (durable-runner 2, service-monitor 1)")
  }

  func testGapMarkersAreBoundedUnderAlternatingOverload() {
    let queue = IngestQueue(capacity: 3)
    for round in 0..<1_000 {
      queue.offer([makeEvent(round * 2), makeEvent(round * 2 + 1)])
      _ = queue.drain(max: 1)
    }
    // Entries waiting are at most capacity events plus one marker each.
    let waiting = queue.drain()
    XCTAssertLessThanOrEqual(waiting.count, 2 * 3 + 1)
  }
}
