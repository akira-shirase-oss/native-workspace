import XCTest

@testable import NWCore

final class EventStoreTests: XCTestCase {
  var directory: URL!

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("nw-store-\(UUID().uuidString)")
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: directory)
  }

  func store(retention: Int = 100, segment: Int = 10) throws -> EventStore {
    try EventStore(
      .init(directory: directory, retention: retention, segmentEvents: segment, durability: .fsync))
  }

  func testAssignsSequenceAndRefusesDuplicates() throws {
    let store = try store()
    let first = try store.append([makeEvent(1), makeEvent(2), makeEvent(1)])
    XCTAssertEqual(first.accepted.map(\.seq), [1, 2])
    XCTAssertEqual(first.duplicates, 1)
    let again = try store.append([makeEvent(2), makeEvent(3)])
    XCTAssertEqual(again.accepted.map(\.key), ["check:m:3"])
    XCTAssertEqual(again.accepted.map(\.seq), [3])
    XCTAssertEqual(store.stats.duplicates, 2)
  }

  func testSameKeyFromAnotherServiceIsNotADuplicate() throws {
    let store = try store()
    let result = try store.append([makeEvent(1), makeEvent(1, service: .durableRunner)])
    XCTAssertEqual(result.accepted.count, 2)
  }

  func testAcknowledgedEventsSurviveReopen() throws {
    var acked: [Event] = []
    do {
      let store = try store()
      for chunk in stride(from: 0, to: 35, by: 7) {
        acked += try store.append((chunk..<chunk + 7).map { makeEvent($0) }).accepted
      }
      store.close()
    }
    let reopened = try store()
    XCTAssertEqual(reopened.recent(1_000), acked)
    XCTAssertEqual(reopened.stats.loadedFromDisk, 35)
    // Re-reading the same history after the "restart" adds nothing.
    XCTAssertEqual(try reopened.append((0..<35).map { makeEvent($0) }).accepted.count, 0)
    // And numbering continues.
    XCTAssertEqual(try reopened.append([makeEvent(99)]).accepted.first?.seq, 36)
  }

  func testMemoryAndDiskAreBounded() throws {
    let store = try store(retention: 50, segment: 10)
    for chunk in stride(from: 0, to: 1_000, by: 25) {
      _ = try store.append((chunk..<chunk + 25).map { makeEvent($0) })
    }
    XCTAssertEqual(store.stats.retained, 50)
    XCTAssertEqual(store.stats.evicted, 950)
    XCTAssertEqual(store.recent(10).map(\.key), (990..<1_000).map { "check:m:\($0)" })
    store.close()
    let lines = try FileManager.default.contentsOfDirectory(atPath: directory.path)
      .map { try String(contentsOf: directory.appendingPathComponent($0), encoding: .utf8) }
      .reduce(0) { $0 + $1.split(separator: "\n").count }
    XCTAssertLessThanOrEqual(
      lines, 50 + 2 * 25 + 10, "disk keeps about retention plus two segments")
    let reopened = try self.store(retention: 50, segment: 10)
    XCTAssertEqual(reopened.stats.retained, 50)
    XCTAssertEqual(reopened.recent(1).first?.key, "check:m:999")
  }

  func testTornTailIsUnacknowledgedAndRepaired() throws {
    do {
      let store = try store()
      _ = try store.append((0..<3).map { makeEvent($0) })
      store.close()
    }
    let segment = try XCTUnwrap(
      FileManager.default.contentsOfDirectory(atPath: directory.path).first {
        $0.hasPrefix("segment-")
      })
    let handle = try FileHandle(forWritingTo: directory.appendingPathComponent(segment))
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("{\"s\":4,\"v\":\"service-mon".utf8))  // cut mid-write
    try handle.close()
    let reopened = try store()
    XCTAssertEqual(reopened.stats.retained, 3)
    XCTAssertEqual(try reopened.append([makeEvent(3)]).accepted.first?.seq, 4)
    reopened.close()
    XCTAssertEqual(try self.store().stats.retained, 4, "the repaired log reads back cleanly")
  }

  func testCorruptionMidLogFailsTheOpen() throws {
    do {
      let store = try store()
      _ = try store.append((0..<3).map { makeEvent($0) })
      store.close()
    }
    let segment = try XCTUnwrap(
      FileManager.default.contentsOfDirectory(atPath: directory.path).first {
        $0.hasPrefix("segment-")
      })
    let url = directory.appendingPathComponent(segment)
    var text = try String(contentsOf: url, encoding: .utf8)
    text = "not json\n" + text
    try text.write(to: url, atomically: false, encoding: .utf8)
    XCTAssertThrowsError(try store()) { error in
      guard case StoreError.corrupt = error else { return XCTFail("\(error)") }
    }
  }

  func testAFailedWriteIsNotAcknowledgedAndPoisonsTheStore() throws {
    let store = try store()
    _ = try store.append([makeEvent(0)])
    store.injectWriteFailureForTesting()
    XCTAssertThrowsError(try store.append([makeEvent(1)]))
    XCTAssertFalse(store.contains(makeEvent(1).identity), "an unwritten event is not in memory")
    XCTAssertThrowsError(try store.append([makeEvent(2)])) { error in
      XCTAssertEqual(error as? StoreError, .poisoned)
    }
    XCTAssertEqual(store.stats.accepted, 1)
  }

  func testInMemoryStoreNeedsNoDirectory() throws {
    let store = try EventStore(.init(directory: nil, retention: 3))
    _ = try store.append((0..<5).map { makeEvent($0) })
    XCTAssertEqual(store.recent(10).map(\.seq), [3, 4, 5])
  }
}
