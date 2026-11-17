import Foundation
import NWCore
import NWCredentials
import NWFixtures
import Synchronization
import XCTest

@testable import NWAdapters

/// F3: hostile service data never crashes the app and never steers a
/// request: ids are validated, a path segment is percent-encoded, and the
/// adapters' decoding and URL building survive a seeded fuzz.
final class HostileDataTests: XCTestCase {
  static let valid = "0193a0c4-0000-7000-8000-00000000000a"
  static let hostileIDs = [
    "has space", "a?b=c", "../../version", "..", ".", "%2e%2e%2fversion", "", "a/b", "#frag",
    "\u{202E}id", String(repeating: "f", count: 10_000), "0193A0C4-0000-7000-8000-00000000000B",
  ]

  func server(ids: [String]) -> FixtureHTTPServer {
    FixtureHTTPServer { request in
      switch request.path {
      case "/readyz": return .json(200, ["status": "ready"])
      case "/version": return .json(200, ["version": "x"])
      case "/api/monitors":
        return .json(
          200,
          [
            "monitors": ids.map { id in
              [
                "id": id, "name": "m", "url": "http://127.0.0.1:9/", "interval_s": 15,
                "paused": false, "status": "up",
              ] as [String: Any]
            }
          ])
      case "/api/incidents": return .json(200, ["incidents": []])
      default:
        if request.path.hasPrefix("/api/monitors/"), request.path.hasSuffix("/checks") {
          return .json(200, ["checks": []])
        }
        return .json(404, ["error": ["code": "not_found", "message": "no"]])
      }
    }
  }

  func testHostileMonitorIDsAreRefusedNeverSentAndNeverCrash() async throws {
    let server = server(ids: Self.hostileIDs + [Self.valid])
    try await server.start()
    defer { Task { await server.stop() } }
    let adapter = try ServiceMonitorAdapter(
      endpoint: server.baseURL, token: SecretToken(fixtureToken),
      transport: BoundedURLSessionTransport())
    let outcome = try await adapter.poll(observedAt: Date())
    let allowed: Set<String> = [
      "/readyz", "/version", "/api/monitors", "/api/incidents",
      "/api/monitors/\(Self.valid)/checks",
      "/api/monitors/0193A0C4-0000-7000-8000-00000000000B/checks",
    ]
    for request in server.recorded {
      XCTAssertTrue(allowed.contains(request.path), "requested \(request.path)")
    }
    XCTAssertTrue(
      outcome.snapshot.verdict.value.contains("invalid id"),
      "skipped monitors are said: \(outcome.snapshot.verdict.value)")
  }

  func testPathSegmentsAreEncodedAndDotSegmentsRefused() throws {
    let base = URL(string: "http://127.0.0.1:60400/prefix")!
    var rng = SeededRandom(seed: 0x5eed)
    for _ in 0..<2_000 {
      let segment = rng.string(maxLength: 40)
      do {
        let url = try Wire.url(base, ["api", "monitors", segment, "checks"])
        let path = url.path(percentEncoded: true)
        XCTAssertTrue(path.hasPrefix("/prefix/api/monitors/"), path)
        XCTAssertTrue(path.hasSuffix("/checks"), path)
        let encoded = path.dropFirst("/prefix/api/monitors/".count).dropLast("/checks".count)
        XCTAssertFalse(encoded.contains("/"), path)
        XCTAssertEqual(percentDecoded(String(encoded)), segment)
        XCTAssertNil(url.query)
        XCTAssertNil(url.fragment)
      } catch {
        XCTAssertTrue(
          segment.isEmpty || segment == "." || segment == "..",
          "refused \(segment.debugDescription)")
      }
    }
  }

  /// Random JSON for every endpoint, from a fixed seed: the poll returns an
  /// outcome or an AdapterError, never a trap, and every request it makes
  /// stays on the known paths.
  func testFuzzedResponsesNeverCrashTheAdapters() async throws {
    let seed = Mutex(SeededRandom(seed: 0xF022))
    let server = FixtureHTTPServer { request in
      seed.withLock { rng in
        // Mostly well-shaped answers with hostile values, so polls get deep;
        // sometimes garbage bytes or random JSON.
        let roll = rng.next(100)
        if roll < 5 { return FixtureResponse(status: 200, body: rng.bytes(maxLength: 300)) }
        if roll < 12 { return .json(rng.next(10) == 0 ? 500 : 200, rng.jsonObject(depth: 3)) }
        switch request.path {
        case "/readyz": return .json(200, ["status": "ready"])
        case "/ready": return .json(200, ["ready": true, "code": rng.string(maxLength: 8)])
        case "/version": return .json(200, ["version": rng.string(maxLength: 20)])
        case "/api/monitors":
          return .json(
            200,
            [
              "monitors": (0..<rng.next(5)).map { _ in
                [
                  "id": rng.next(3) == 0 ? HostileDataTests.valid : rng.string(maxLength: 16),
                  "name": rng.string(maxLength: 20), "url": rng.string(maxLength: 20),
                  "interval_s": 15, "paused": rng.next(4) == 0, "status": rng.string(maxLength: 6),
                ] as [String: Any]
              }
            ])
        case "/api/incidents":
          return .json(
            200,
            [
              "incidents": (0..<rng.next(3)).map { n in
                [
                  "id": n, "monitor_id": rng.string(maxLength: 10),
                  "opened_at": rng.string(maxLength: 30), "state": rng.string(maxLength: 8),
                ] as [String: Any]
              }
            ])
        case "/jobs":
          return .json(
            200,
            [
              "runs": (0..<rng.next(4)).map { n in
                [
                  "id": n, "key": rng.string(maxLength: 20), "state": rng.string(maxLength: 20),
                  "steps": rng.next(5),
                ] as [String: Any]
              }
            ])
        default:
          return .json(
            200,
            [
              "checks": (0..<rng.next(4)).map { _ in
                [
                  "slot_at": rng.next(2) == 0
                    ? "2026-11-16T19:52:08.\(rng.next(1_000_000))Z" : rng.string(maxLength: 30),
                  "outcome": rng.string(maxLength: 8), "detail": rng.string(maxLength: 40),
                ] as [String: Any]
              }
            ])
        }
      }
    }
    try await server.start()
    defer { Task { await server.stop() } }
    let smon = try ServiceMonitorAdapter(
      endpoint: server.baseURL, token: SecretToken(fixtureToken),
      transport: BoundedURLSessionTransport())
    let durable = try DurableRunnerAdapter(
      endpoint: server.baseURL, transport: BoundedURLSessionTransport())
    var outcomes = 0
    var errors = 0
    for _ in 0..<300 {
      for adapter in [smon, durable] as [any ServiceAdapter] {
        do {
          _ = try await adapter.poll(observedAt: Date())
          outcomes += 1
        } catch {
          errors += 1
        }
      }
    }
    XCTAssertEqual(outcomes + errors, 600)
    for request in server.recorded {
      XCTAssertFalse(request.path.contains(".."), request.path)
    }
  }
}

/// Byte-exact percent-decoding. (`removingPercentEncoding` on older
/// Foundation drops a leading U+FEFF, which made CI disagree with this Mac.)
func percentDecoded(_ text: String) -> String? {
  var bytes: [UInt8] = []
  var iterator = Array(text.utf8).makeIterator()
  while let byte = iterator.next() {
    if byte == UInt8(ascii: "%") {
      guard let high = iterator.next(), let low = iterator.next(),
        let value = UInt8(String(decoding: [high, low], as: UTF8.self), radix: 16)
      else { return nil }
      bytes.append(value)
    } else {
      bytes.append(byte)
    }
  }
  return String(validating: bytes, as: UTF8.self)
}

/// A small deterministic generator (SplitMix64) for reproducible fuzzing.
struct SeededRandom: Sendable {
  var state: UInt64
  init(seed: UInt64) { state = seed }

  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }

  mutating func next(_ bound: Int) -> Int { Int(next() % UInt64(max(bound, 1))) }

  mutating func string(maxLength: Int) -> String {
    let pool: [Unicode.Scalar] =
      Array("abcAZ09-._~ /?#%&=+:@!$'()*,;[]\\\"<>^`{|}".unicodeScalars) + [
        "\u{0}", "\u{1B}", "\u{202E}", "\u{FEFF}", "\u{301}", "é", "日", "\u{10FFFF}",
      ]
    var out = String.UnicodeScalarView()
    for _ in 0..<next(maxLength + 1) {
      if next(4) == 0 {
        out.append(contentsOf: [".", ".", "/"].prefix(next(4)))
      } else {
        out.append(pool[next(pool.count)])
      }
    }
    return String(out)
  }

  mutating func bytes(maxLength: Int) -> Data {
    Data((0..<next(maxLength + 1)).map { _ in UInt8(truncatingIfNeeded: next()) })
  }

  mutating func jsonValue(depth: Int) -> Any {
    switch next(depth > 0 ? 8 : 5) {
    case 0: return NSNull()
    case 1: return next(2) == 0
    case 2: return Int(truncatingIfNeeded: next()) / (next(3) + 1)
    case 3: return Double(next(1_000_000)) / 7
    case 4: return string(maxLength: 30)
    case 5, 6: return jsonObject(depth: depth - 1)
    default: return (0..<next(4)).map { _ in jsonValue(depth: depth - 1) }
    }
  }

  mutating func jsonObject(depth: Int) -> [String: Any] {
    let keys = [
      "status", "faults", "version", "monitoring", "monitors", "id", "name", "url", "interval_s",
      "paused", "checks", "slot_at", "outcome", "http_status", "latency_ms", "detail",
      "incidents", "monitor_id", "opened_at", "state", "ready", "code", "runs", "key", "steps",
      "finished_at", "reason",
    ]
    var object: [String: Any] = [:]
    for _ in 0..<next(8) { object[keys[next(keys.count)]] = jsonValue(depth: depth) }
    if next(3) == 0 {
      object["monitors"] = (0..<next(4)).map { _ in
        [
          "id": next(2) == 0 ? HostileDataTests.valid : string(maxLength: 12), "name": "n",
          "url": "u", "interval_s": 15, "paused": false, "status": "up",
        ] as [String: Any]
      }
    }
    return object
  }
}
