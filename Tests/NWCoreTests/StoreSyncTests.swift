import Darwin
import Foundation
import Synchronization
import XCTest

@testable import NWCore

/// F6: acknowledged means synced. Each test injects the sync calls, so a
/// store that skipped the sync, or retried a failed F_FULLFSYNC with a
/// weaker fsync, fails here.
final class StoreSyncTests: XCTestCase {
  var directory: URL!

  override func setUp() {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("nw-sync-\(UUID().uuidString)")
  }

  override func tearDown() { try? FileManager.default.removeItem(at: directory) }

  final class Calls: Sendable {
    let log = Mutex<[String]>([])
    let fullResult: Int32
    let fsyncResult: Int32
    init(full: Int32 = 0, fsync: Int32 = 0) {
      fullResult = full
      fsyncResult = fsync
    }
    var syncCalls: SyncCalls {
      SyncCalls(
        fullFsync: { [self] fd in
          // The batch's bytes must already be written when the sync runs.
          var info = stat()
          fstat(fd, &info)
          log.withLock { $0.append("full@\(info.st_size)") }
          return fullResult
        },
        fsync: { [self] _ in
          log.withLock { $0.append("fsync") }
          return fsyncResult
        })
    }
  }

  func testAnAppendIsAcknowledgedOnlyAfterItsBatchIsSynced() throws {
    let calls = Calls()
    let store = try EventStore(
      .init(directory: directory, durability: .fullFsync, syncCalls: calls.syncCalls))
    let first = try store.append([makeEvent(1), makeEvent(2)])
    XCTAssertEqual(first.accepted.count, 2)
    let afterFirst = calls.log.withLock { $0 }
    XCTAssertEqual(afterFirst.count, 1, "one sync per acknowledged batch: \(afterFirst)")
    guard afterFirst.count == 1 else { return }
    XCTAssertTrue(afterFirst[0].hasPrefix("full@"), "\(afterFirst)")
    XCTAssertGreaterThan(Int(afterFirst[0].dropFirst(5)) ?? 0, 0, "synced after writing")
    _ = try store.append([makeEvent(3)])
    XCTAssertEqual(calls.log.withLock { $0.count }, 2)
  }

  func testAFailedFullSyncFailsTheBatchAndIsNeverRetriedWeaker() throws {
    let calls = Calls(full: EIO)
    let store = try EventStore(
      .init(directory: directory, durability: .fullFsync, syncCalls: calls.syncCalls))
    XCTAssertThrowsError(try store.append([makeEvent(1)]))
    XCTAssertFalse(calls.log.withLock { $0 }.contains("fsync"), "an EIO must not fall back")
    XCTAssertFalse(store.contains(makeEvent(1).identity))
    XCTAssertThrowsError(try store.append([makeEvent(2)])) { error in
      XCTAssertEqual(error as? StoreError, .poisoned)
    }
  }

  func testAnUnsupportedFullSyncFallsBackToFsyncAndSaysSo() throws {
    for errno in [ENOTSUP, EINVAL, ENOTTY] {
      let calls = Calls(full: errno)
      let dir = directory.appendingPathComponent("\(errno)")
      let store = try EventStore(
        .init(directory: dir, durability: .fullFsync, syncCalls: calls.syncCalls))
      XCTAssertEqual(try store.append([makeEvent(1)]).accepted.count, 1)
      XCTAssertEqual(calls.log.withLock { $0 }.last, "fsync")
      XCTAssertEqual(store.stats.fullSyncFallbacks, 1, "the weaker durability is recorded")
    }
  }

  func testAFailedFsyncFailsTheBatch() throws {
    let calls = Calls(fsync: EIO)
    let store = try EventStore(
      .init(directory: directory, durability: .fsync, syncCalls: calls.syncCalls))
    XCTAssertThrowsError(try store.append([makeEvent(1)]))
    XCTAssertFalse(store.contains(makeEvent(1).identity))
  }
}
