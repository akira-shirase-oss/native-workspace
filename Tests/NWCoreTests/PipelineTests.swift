import Synchronization
import XCTest

@testable import NWCore

@MainActor
final class EventListModelTests: XCTestCase {
  func row(_ n: Int, gap: UInt64? = nil) -> EventRow {
    var event = makeEvent(n)
    event.seq = UInt64(n)
    if let gap {
      event.kind = .gap
      event.gapCount = gap
    }
    return EventRow(event)
  }

  func testRowsStayBoundedAndTrimsAreCounted() {
    let model = EventListModel(capacity: 10)
    model.apply((0..<6).map { row($0) })
    model.apply((6..<15).map { row($0) })
    XCTAssertEqual(model.rows.map(\.id), (5..<15).map(UInt64.init))
    XCTAssertEqual(model.trimmed, 5)
    model.apply((15..<40).map { row($0) })
    XCTAssertEqual(model.rows.count, 10)
    XCTAssertEqual(model.rows.first?.id, 30)
    XCTAssertEqual(model.trimmed, 30)
    XCTAssertEqual(model.appliedTotal, 40)
  }

  func testGapRowsAreCountedAsShownDrops() {
    let model = EventListModel(capacity: 10)
    model.apply([row(1), row(2, gap: 40), row(3, gap: 2)])
    XCTAssertEqual(model.droppedShown, 42)
    XCTAssertTrue(model.rows[1].isGap)
  }

  func testRowsAreInertAndPreformatted() {
    var event = makeEvent(1)
    event.text = "\u{1B}[32mOK\u{1B}[0m\nforged"
    let row = EventRow(event)
    XCTAssertEqual(row.text, "\\u{1B}[32mOK\\u{1B}[0m\\u{0A}forged")
    XCTAssertEqual(row.time.count, "MM-dd HH:mm:ss.SSS".count)
  }
}

final class IngestPumpTests: XCTestCase {
  @MainActor
  final class Collector {
    var batches: [PumpBatch] = []
  }

  func testDeliversStoredBatchesInOrderAndCountsDuplicates() async throws {
    let queue = IngestQueue(capacity: 1_000)
    let store = try EventStore(.init(directory: nil, retention: 1_000))
    let collector = Collector()
    let pump = IngestPump(queue: queue, store: store, interval: .milliseconds(5)) { batch in
      collector.batches.append(batch)
    }
    pump.start()
    for round in 0..<20 {
      queue.offer((0..<10).map { makeEvent(round * 10 + $0) } + [makeEvent(0)])
      pump.notify()
    }
    await pump.flush()
    await pump.stop()
    let seqs = await collector.batches.flatMap { $0.accepted.map(\.seq) }
    XCTAssertEqual(queue.stats.dropped, 0)
    XCTAssertEqual(seqs, (1...200).map(UInt64.init), "every event once, in order")
    XCTAssertEqual(
      pump.stats.duplicates, 20, "event 0 offered twice in round 0, once per later round")
    XCTAssertEqual(pump.stats.stored, 200)
    let rows = await collector.batches.flatMap(\.rows).map(\.id)
    XCTAssertEqual(rows, seqs)
  }

  func testStoreFailureIsCountedNotHidden() async throws {
    let store = try EventStore(
      .init(
        directory: FileManager.default.temporaryDirectory
          .appendingPathComponent("nw-pump-\(UUID().uuidString)"), durability: .none))
    defer { try? FileManager.default.removeItem(at: store.configuration.directory!) }
    store.injectWriteFailureForTesting()
    let queue = IngestQueue(capacity: 10)
    let pump = IngestPump(queue: queue, store: store) { _ in }
    pump.start()
    queue.offer([makeEvent(1), makeEvent(2)])
    await pump.flush()
    await pump.stop()
    XCTAssertEqual(pump.stats.notStored, 2)
    XCTAssertNotNil(pump.stats.storeError)
  }
}

final class HistogramTests: XCTestCase {
  func testPercentilesAreUpperBucketEdges() {
    var histogram = LatencyHistogram()
    for ms in 1...100 { histogram.record(Double(ms)) }
    XCTAssertEqual(histogram.percentile(0.5), 50.1, accuracy: 0.001)
    XCTAssertEqual(histogram.percentile(0.99), 99.1, accuracy: 0.001)
    histogram.record(2_500)
    XCTAssertEqual(histogram.summary().max, 2_500)
    XCTAssertEqual(histogram.percentile(1.0), 2_500)
  }
}
