import Foundation
import NWCore
import NWCredentials
import NWFixtures
import XCTest

@testable import NWAdapters

/// The oracle is Unicode's own properties, not `InertText`'s list: a scalar
/// that is a control, format, separator, unassigned, private-use, surrogate,
/// default-ignorable, bidi-control, variation-selector or noncharacter code
/// point must never reach a view unescaped.
func activeScalars(_ text: String, multiline: Bool = false) -> [Unicode.Scalar] {
  text.unicodeScalars.filter { scalar in
    if scalar == "\t" || (multiline && scalar == "\n") { return false }
    let p = scalar.properties
    switch p.generalCategory {
    case .control, .format, .lineSeparator, .paragraphSeparator, .surrogate, .unassigned,
      .privateUse:
      return true
    default:
      break
    }
    return p.isDefaultIgnorableCodePoint || p.isBidiControl || p.isVariationSelector
      || p.isNoncharacterCodePoint
  }
}

/// Every string a value exposes, found by reflection — so a new field added
/// to a view model is checked without anyone remembering to list it.
func allStrings(in value: Any, depth: Int = 0) -> [String] {
  if let string = value as? String { return [string] }
  guard depth < 12 else { return [] }
  var out: [String] = []
  for child in Mirror(reflecting: value).children {
    out += allStrings(in: child.value, depth: depth + 1)
  }
  return out
}

/// F1: every string the status views show is inert and bounded, whichever
/// service field it came from (verdict, faults, version, monitor names, URLs,
/// wire states, Durable codes and states, failure reasons).
@MainActor
final class ViewStringsTests: XCTestCase {
  nonisolated static let long = String(repeating: "L", count: 20_000)
  nonisolated static let hostile = "x\u{202E}gnp.exe\u{1B}[2J\u{07}\nFORGED second line\u{2066}"

  func hostileServiceMonitor() -> FixtureHTTPServer {
    let h = Self.hostile
    let long = Self.long
    return FixtureHTTPServer { request in
      switch request.path {
      case "/readyz":
        return .json(200, ["status": "ready\(h)", "faults": ["fault\(h)", long]])
      case "/version":
        return .json(200, ["version": "1.0\(h)\(long)"])
      case "/api/monitors":
        return .json(
          200,
          [
            "monitoring": ["status": "degraded\(h)", "faults": ["f\(h)"]],
            "monitors": [
              [
                "id": "0193a0c4-0000-7000-8000-000000000001", "name": "api\(h)\(long)",
                "url": "http://127.0.0.1:9/\(h)", "interval_s": 15, "paused": false,
                "status": "info",
              ],
              [
                "id": "0193a0c4-0000-7000-8000-000000000002", "name": "second\(h)",
                "url": "http://127.0.0.1:9/two", "interval_s": 15, "paused": false,
                "status": "paused",
              ],
            ],
          ])
      case let path where path.hasSuffix("/checks"):
        return .json(200, ["checks": []])
      case "/api/incidents":
        return .json(200, ["incidents": []])
      default:
        return .json(404, ["error": ["code": "not_found\(h)", "message": "no"]])
      }
    }
  }

  func hostileDurable() -> FixtureHTTPServer {
    let h = Self.hostile
    return FixtureHTTPServer { request in
      switch request.path {
      case "/ready": return .json(503, ["ready": false, "code": "no_space\(h)\(Self.long)"])
      case "/jobs":
        return .json(
          200,
          [
            "runs": [["id": 1, "key": "k\(h)", "state": "running\(h)", "steps": 1]],
            "next_before": NSNull(),
          ])
      default: return .json(404, ["error": "no\(h)", "code": "not_found\(h)"])
      }
    }
  }

  func check(_ strings: [String], _ context: String, cap: Int = 1_100) {
    XCTAssertFalse(strings.isEmpty, context)
    for string in strings {
      let active = activeScalars(string)
      XCTAssertTrue(
        active.isEmpty,
        "\(context): active scalars \(active.map { String($0.value, radix: 16) }) in \(string.prefix(80))"
      )
      XCTAssertLessThanOrEqual(string.count, cap, "\(context): \(string.count) characters")
    }
  }

  func displayed(_ status: ServiceStatusModel, now: Date) -> [String] {
    var strings: [String] = []
    strings += allStrings(in: status.snapshot as Any)
    strings += allStrings(in: status.name)
    strings += allStrings(in: status.endpoint)
    let freshness = status.freshness(now: now)
    strings += allStrings(in: freshness)
    strings.append(freshness.label)
    var old = ConnectionTracker()
    old.recordSuccess(asOf: now.addingTimeInterval(-60))
    for f in [freshness, old.freshness(now: now)] {
      for item in status.snapshot?.items ?? [] { strings.append(item.display(f).label) }
    }
    return strings
  }

  func testEveryStatusStringFromServiceMonitorIsInertAndBounded() async throws {
    let server = hostileServiceMonitor()
    try await server.start()
    defer { Task { await server.stop() } }
    let adapter = try ServiceMonitorAdapter(
      endpoint: server.baseURL, token: SecretToken(fixtureToken),
      transport: BoundedURLSessionTransport())
    let outcome = try await adapter.poll(observedAt: Date())
    let status = ServiceStatusModel(
      id: .serviceMonitor, name: "Service Monitor", endpoint: server.baseURL.absoluteString,
      tracker: ConnectionTracker())
    var tracker = ConnectionTracker()
    tracker.recordSuccess(asOf: Date())
    status.update(tracker: tracker, snapshot: outcome.snapshot)
    check(displayed(status, now: Date()), "service monitor")
    // Wire states the app uses internally are never taken from the wire.
    XCTAssertEqual(outcome.snapshot.items.map(\.state), [.unknown, .unknown])
  }

  func testEveryStatusStringFromDurableRunnerIsInertAndBounded() async throws {
    let server = hostileDurable()
    try await server.start()
    defer { Task { await server.stop() } }
    let adapter = try DurableRunnerAdapter(
      endpoint: server.baseURL, transport: BoundedURLSessionTransport())
    let outcome = try await adapter.poll(observedAt: Date())
    let status = ServiceStatusModel(
      id: .durableRunner, name: "Durable Runner", endpoint: server.baseURL.absoluteString,
      tracker: ConnectionTracker())
    var tracker = ConnectionTracker()
    tracker.recordSuccess(asOf: Date())
    status.update(tracker: tracker, snapshot: outcome.snapshot)
    check(displayed(status, now: Date()), "durable runner")
  }

  func testFailureReasonsShownAsStaleAreInertAndBounded() async throws {
    // A service that answers with an error code and body full of hostile text.
    let h = Self.hostile
    let server = FixtureHTTPServer { _ in
      .json(500, ["error": ["code": "boom\(h)\(Self.long)", "message": "m\(h)"]])
    }
    try await server.start()
    defer { Task { await server.stop() } }
    let adapter = try ServiceMonitorAdapter(
      endpoint: server.baseURL, token: SecretToken(fixtureToken),
      transport: BoundedURLSessionTransport())
    var tracker = ConnectionTracker()
    do {
      _ = try await adapter.poll(observedAt: Date())
      XCTFail("expected a failure")
    } catch {
      tracker.recordFailure(error.pollFailure, at: Date())
    }
    let status = ServiceStatusModel(
      id: .serviceMonitor, name: "Service Monitor", endpoint: "loopback", tracker: tracker)
    check(displayed(status, now: Date()), "failure reason")
  }
}
