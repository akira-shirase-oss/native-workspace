import Foundation
import XCTest

@testable import NWCore

/// F7: the store is bounded in bytes, not only in events.
final class StoreBytesTests: XCTestCase {
  var directory: URL!

  override func setUp() {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("nw-bytes-\(UUID().uuidString)")
  }

  override func tearDown() { try? FileManager.default.removeItem(at: directory) }

  func diskBytes() -> Int {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    return names.reduce(0) { total, name in
      let path = directory.appendingPathComponent(name).path
      let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
      return total + size
    }
  }

  func huge(_ n: Int) -> Event {
    var event = makeEvent(n)
    event.text = "detail \(n): " + String(repeating: "x", count: 1 << 20)  // 1 MiB
    return event
  }

  /// Over the cap, but cheap enough to make thousands of.
  func big(_ n: Int) -> Event {
    var event = makeEvent(n)
    event.text = "detail \(n): " + String(repeating: "é", count: 8_192)  // 16 KiB, 2-byte scalars
    return event
  }

  func testMaximumSizeDetailsAreCappedAndTheStoreStaysWithinItsByteBudget() throws {
    let store = try EventStore(.init(directory: directory, durability: .none))
    for chunk in stride(from: 0, to: 200, by: 10) {
      _ = try store.append((chunk..<chunk + 10).map(huge))
    }
    let retained = store.recent(Int.max)
    XCTAssertEqual(retained.count, 200)
    for event in retained {
      XCTAssertLessThanOrEqual(event.text.utf8.count, 8_192 + 64, "text stored uncapped")
      XCTAssertTrue(event.text.hasSuffix("bytes cut]"), "the cut is stated")
    }
    let memoryText = retained.reduce(0) { $0 + $1.text.utf8.count }
    XCTAssertLessThanOrEqual(memoryText, 64 << 20)
    XCTAssertLessThanOrEqual(diskBytes(), 8 << 20, "200 capped events fit in a few MiB on disk")
    store.close()
    let reopened = try EventStore(.init(directory: directory, durability: .none))
    XCTAssertEqual(reopened.stats.retained, 200)
  }

  func testMemoryAndDiskStayWithinTheirByteBudgets() throws {
    let config = EventStore.Configuration(
      directory: directory, durability: .none, retentionBytes: 1 << 20, segmentBytes: 256 << 10)
    let store = try EventStore(config)
    for chunk in stride(from: 0, to: 3_000, by: 20) {
      _ = try store.append((chunk..<chunk + 20).map(big))
      XCTAssertLessThanOrEqual(store.stats.retainedBytes, 1 << 20)
      // One batch (20 × 8 KiB) past a segment boundary is the most it overshoots.
      XCTAssertLessThanOrEqual(diskBytes(), config.maxDiskBytes + 20 * 8_400)
    }
    XCTAssertLessThan(store.stats.retained, 3_000, "byte budget, not count, evicted")
    XCTAssertEqual(store.recent(1).first?.key, "check:m:2999")
    store.close()
    let reopened = try EventStore(config)
    XCTAssertLessThanOrEqual(reopened.stats.retainedBytes, 1 << 20)
    XCTAssertEqual(reopened.recent(1).first?.key, "check:m:2999")
  }

  func testTheCapIsAppliedAtIngestAndIsIdempotent() {
    let queue = IngestQueue(capacity: 10)
    queue.offer([huge(1)])
    let queued = queue.drain()[0]
    XCTAssertLessThanOrEqual(queued.text.utf8.count, Event.maxTextBytes)
    XCTAssertEqual(queued.boundedForStorage(), queued)
    // A cut never splits a scalar.
    let cut = big(3).boundedForStorage()
    XCTAssertTrue(cut.text.hasSuffix("bytes cut]"))
    XCTAssertFalse(cut.text.contains("\u{FFFD}"))
    XCTAssertGreaterThan(
      cut.text.utf8.count, Event.maxTextBytes - 8, "cut at the last whole scalar")
    var longKey = makeEvent(2)
    longKey.key = String(repeating: "k", count: 10_000)
    let bounded = longKey.boundedForStorage()
    XCTAssertEqual(bounded.key, longKey.boundedForStorage().key, "stable, so de-duplication works")
    XCTAssertLessThanOrEqual(bounded.key.utf8.count, Event.maxKeyBytes)
  }
}
