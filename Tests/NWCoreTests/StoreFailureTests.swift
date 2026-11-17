import Foundation
import Synchronization
import XCTest

@testable import NWCore

/// F5: a store failure is never silent. Events that could not be recorded
/// reach the view as gap rows whose counts equal the loss, the recording
/// state is not green, and the pump recovers onto a fresh store without a
/// restart.
final class StoreFailureTests: XCTestCase {
  @MainActor
  final class Sink {
    var rows: [EventRow] = []
    var stored: [Event] = []
    var health: [RecordingHealth] = []
  }

  var directory: URL!

  override func setUp() {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("nw-storefail-\(UUID().uuidString)")
  }

  override func tearDown() { try? FileManager.default.removeItem(at: directory) }

  func testAFailedStoreShowsGapRowsAndRecoversWithoutRestart() async throws {
    let config = EventStore.Configuration(directory: directory, durability: .none)
    let store = try EventStore(config)
    _ = try store.append([makeEvent(0)])
    store.injectWriteFailureForTesting()
    let attempts = Mutex(0)
    let queue = IngestQueue(capacity: 1_000)
    let sink = Sink()
    let pump = IngestPump(
      queue: queue, store: store, interval: .milliseconds(5),
      recovery: .init(initialDelay: .milliseconds(50), maxDelay: .milliseconds(200)) {
        () throws(StoreError) -> EventStore in
        // The first reopen fails too; the second works.
        let n = attempts.withLock { n -> Int in
          n += 1
          return n
        }
        if n == 1 { throw StoreError.io("still failing") }
        return try EventStore(config, freshSegment: true)
      }
    ) { batch in
      sink.rows += batch.rows
      sink.stored += batch.accepted
      sink.health.append(batch.recording)
    }
    pump.start()
    queue.offer((1...10).map { makeEvent($0) })
    await pump.flush()
    queue.offer((11...15).map { makeEvent($0) })
    await pump.flush()
    try await Task.sleep(for: .milliseconds(400))
    queue.offer((16...20).map { makeEvent($0) })
    await pump.flush()
    await pump.stop()

    let gapRows = await sink.rows.filter(\.isGap)
    let lost = gapRows.reduce(UInt64(0)) { $0 + ($1.gapCount ?? 0) }
    XCTAssertEqual(pump.stats.notStored, lost, "every unrecorded event is in a gap row")
    XCTAssertGreaterThanOrEqual(lost, 10)
    let healths = await sink.health
    XCTAssertTrue(healths.contains { !$0.isRecording }, "failure was reported")
    XCTAssertEqual(healths.last?.isRecording, true, "recovered without a restart")
    let storedKeys = await sink.stored.map(\.key)
    XCTAssertEqual(storedKeys, (16...20).map { "check:m:\($0)" })
    // What was stored after recovery is on disk, in a fresh segment.
    let reopened = try EventStore(config)
    XCTAssertTrue(reopened.contains(makeEvent(20).identity))
    XCTAssertFalse(reopened.contains(makeEvent(5).identity), "an unrecorded event is not on disk")
  }

  func testNotRecordingIsNeverDrawnGreen() {
    let live = Freshness.live(asOf: Date())
    let failed = RecordingHealth.failed(
      since: Date(), reason: InertString("disk full"), unrecorded: 3)
    XCTAssertEqual(StatusBadge.display(live, recording: .recording).tone, .good)
    let badge = StatusBadge.display(live, recording: failed)
    XCTAssertNotEqual(badge.tone, .good)
    XCTAssertTrue(badge.label.contains("not recording"), badge.label)
  }
}
