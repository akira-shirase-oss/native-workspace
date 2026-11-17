import Foundation
import NWCore
import NWCredentials
import NWFixtures
import XCTest

@testable import NWAdapters

/// F12: one bad string or item never fails a whole poll. Invalid UTF-8 and
/// lone surrogate escapes become U+FFFD; an item that still cannot be read
/// is skipped and counted.
final class LossyDecodeTests: XCTestCase {
  static let monitorID = "0193a0c4-0000-7000-8000-0000000000c1"

  static func raw(_ text: String, inserting bytes: [UInt8] = [], at marker: String = "@@")
    -> Data
  {
    let parts = text.components(separatedBy: marker)
    var data = Data(parts[0].utf8)
    for part in parts.dropFirst() {
      data.append(contentsOf: bytes)
      data.append(Data(part.utf8))
    }
    return data
  }

  static func json(_ data: Data) -> FixtureResponse {
    FixtureResponse(status: 200, headers: [("Content-Type", "application/json")], body: data)
  }

  func testAServiceMonitorPollSurvivesBadTextAndBadItems() async throws {
    let id = Self.monitorID
    let server = FixtureHTTPServer { request in
      switch request.path {
      case "/readyz": return .json(200, ["status": "ready"])
      case "/version": return .json(200, ["version": "x"])
      case "/api/monitors":
        return Self.json(
          Self.raw(
            #"{"monitors":[{"id":"\#(id)","name":"api \ud800 lone","url":"u","interval_s":15,"paused":false,"status":"up"},"#
              + #"{"id":"\#(id)x","name":7}]}"#))
      case "/api/incidents": return .json(200, ["incidents": []])
      default:
        return Self.json(
          Self.raw(
            #"{"checks":["#
              + #"{"slot_at":"2026-11-16T19:52:01Z","outcome":"pass","detail":"ok"},"#
              + #"{"slot_at":"2026-11-16T19:52:02Z","outcome":"transport","detail":"bad @@ byte"},"#
              + #"{"slot_at":"2026-11-16T19:52:03Z","outcome":"transport","detail":"lone \udc00 low"},"#
              + #"{"slot_at":12345,"outcome":"pass"}"#
              + #"]}"#, inserting: [0xFF, 0xFE]))
      }
    }
    try await server.start()
    defer { Task { await server.stop() } }
    let adapter = try ServiceMonitorAdapter(
      endpoint: server.baseURL, token: SecretToken(fixtureToken),
      transport: BoundedURLSessionTransport())
    let outcome = try await adapter.poll(observedAt: Date())
    let checks = outcome.events.filter { $0.kind == .check }
    XCTAssertEqual(checks.count, 3, "the three readable checks arrive")
    XCTAssertTrue(checks.contains { $0.text.contains("bad \u{FFFD}\u{FFFD} byte") })
    XCTAssertTrue(checks.contains { $0.text.contains("lone \u{FFFD} low") })
    XCTAssertEqual(outcome.snapshot.items.first?.name.value, "api \u{FFFD} lone")
    XCTAssertTrue(
      outcome.snapshot.verdict.value.contains("unreadable"), outcome.snapshot.verdict.value)
  }

  func testADurableRunnerPollSurvivesABadRunKey() async throws {
    let server = FixtureHTTPServer { request in
      switch request.path {
      case "/ready": return .json(200, ["ready": true])
      default:
        return Self.json(
          Self.raw(
            #"{"runs":[{"id":1,"key":"k \ud83d","state":"done","steps":1},"#
              + #"{"id":2,"key":"k@@2","state":"failed:step:0","steps":1},{"id":"three"}]}"#,
            inserting: [0xC3]))
      }
    }
    try await server.start()
    defer { Task { await server.stop() } }
    let adapter = try DurableRunnerAdapter(
      endpoint: server.baseURL, transport: BoundedURLSessionTransport())
    let outcome = try await adapter.poll(observedAt: Date())
    XCTAssertEqual(outcome.events.map(\.key), ["run:2:failed:step:0", "run:1:done"])
    XCTAssertTrue(outcome.events.contains { $0.text.contains("k \u{FFFD}") })
    XCTAssertTrue(outcome.snapshot.verdict.value.contains("unreadable"))
  }

  func testTheRepairOnlyTouchesWhatIsBroken() {
    // JSON escapes are built from a backslash so no literal escape is parsed here.
    let bs = "\\"
    func json(_ value: String) -> Data { Data(("{\"a\":\"" + value + "\"}").utf8) }
    let pair = bs + "u" + "d83d" + bs + "u" + "de00"
    let good = json(pair + " " + bs + bs + "u" + "d800 é")
    XCTAssertEqual(Wire.repaired(good), good, "a valid pair and an escaped backslash are kept")
    let fffd = bs + "u" + "fffd"
    XCTAssertEqual(Wire.repaired(json(bs + "u" + "d800" + "x")), json(fffd + "x"))
    XCTAssertEqual(
      Wire.repaired(json(bs + "u" + "dc00" + bs + "u" + "d800")), json(fffd + fffd))
    XCTAssertEqual(Wire.repaired(Data([0x22, 0xFF, 0x22])), Data("\"\u{FFFD}\"".utf8))
  }
}
