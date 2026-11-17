import Darwin
import Foundation
import XCTest

@testable import NWCore

/// F15: the store's directory is private to the user, and one store
/// instance at a time holds it (two would interleave segments and reuse
/// sequence numbers).
final class StoreInstanceTests: XCTestCase {
  func testTheDirectoryIsMadePrivateAndOnlyOneInstanceOpensIt() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("nw-instance-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
    let first = try EventStore(.init(directory: directory, durability: .none))
    var info = stat()
    stat(directory.path, &info)
    XCTAssertEqual(info.st_mode & 0o777, 0o700, "group/other access removed")
    XCTAssertThrowsError(try EventStore(.init(directory: directory, durability: .none)))
    first.close()
    XCTAssertNoThrow(try EventStore(.init(directory: directory, durability: .none)))
  }
}
