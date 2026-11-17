import Foundation
import Synchronization

/// Hostile log lines (fixture `hostile-log-lines`): terminal escapes, bidi
/// overrides, C1 controls, invisible characters, forged line breaks and
/// markup. Shared by the emulator and the inert-text tests.
public enum HostileLines {
  public static let all: [String] = [
    "\u{1B}[2J\u{1B}[H\u{1B}[32mALL SYSTEMS OK\u{1B}[0m",  // clear screen, fake green
    "\u{1B}]8;;https://evil.example/\u{07}click me\u{1B}]8;;\u{07}",  // OSC 8 hyperlink
    "\u{1B}]0;fake window title\u{07}",  // OSC title
    "invoice\u{202E}fdp.exe",  // right-to-left override
    "admin\u{2066}\u{2069} is fine",  // isolates
    "\u{9B}31mC1 CSI\u{9B}0m",  // one-byte CSI
    "zero\u{200B}width\u{FEFF}joiner\u{200D}",
    "first line\nFORGED: second row looks like a new event",
    "carriage\rreturn overwrite",
    "**bold** [link](https://evil.example) <script>alert(1)</script> `code`",
    "tag\u{E0041}\u{E0042}chars",
    "back\\slash \\u{1B} literal",
    "nul\u{0}byte and bell\u{07}",
  ]
}

/// Emulates Service Monitor's read API for tests and the fixture server:
/// `GET /readyz`, `/version`, `/api/monitors`, `/api/monitors/{id}/checks`,
/// `/api/incidents`, with Bearer auth on `/api/**`. Check slots are generated
/// lazily from the clock at a fixed cadence per monitor; `burst` adds extra
/// slots at once. Any method other than GET is answered 405 and counted.
public final class ServiceMonitorEmulator: Sendable {
  public struct Configuration: Sendable {
    public var token: String
    public var monitors: Int
    /// Seconds between slots per monitor.
    public var slotInterval: TimeInterval
    /// Every n-th slot fails (0: never). A failing slot carries a hostile
    /// detail line.
    public var failEvery: Int
    /// Newest slots kept per monitor (Service Monitor answers at most 500).
    public var keepPerMonitor: Int

    public init(
      token: String, monitors: Int = 3, slotInterval: TimeInterval = 0.05, failEvery: Int = 7,
      keepPerMonitor: Int = 500
    ) {
      self.token = token
      self.monitors = monitors
      self.slotInterval = slotInterval
      self.failEvery = failEvery
      self.keepPerMonitor = keepPerMonitor
    }
  }

  public let configuration: Configuration
  private let state: Mutex<State>
  private let monitorIDs: [String]

  private struct Slot {
    var at: Date
    var index: Int
  }

  private struct State {
    var revoked = false
    var ready = true
    var nextSlot: [Date]
    var slots: [[Slot]]
    var counters: [Int]
    var nonGET = 0
    var slotsGenerated = 0
  }

  public init(_ configuration: Configuration, start: Date = Date()) {
    self.configuration = configuration
    monitorIDs = (0..<configuration.monitors).map {
      String(format: "00000000-0000-7000-8000-%012d", $0 + 1)
    }
    state = Mutex(
      State(
        nextSlot: Array(repeating: start, count: configuration.monitors),
        slots: Array(repeating: [], count: configuration.monitors),
        counters: Array(repeating: 0, count: configuration.monitors)))
  }

  /// The service starts answering 401 to the paired token (revocation).
  public func revoke() { state.withLock { $0.revoked = true } }
  public func setReady(_ ready: Bool) { state.withLock { $0.ready = ready } }
  /// Requests that used a method other than GET.
  public var nonGETRequests: Int { state.withLock { $0.nonGET } }
  public var slotsGenerated: Int { state.withLock { $0.slotsGenerated } }

  /// Adds `count` slots at once, spread over the monitors.
  public func burst(_ count: Int, at now: Date = Date()) {
    state.withLock { s in
      generate(&s, until: now)
      for i in 0..<count {
        let m = i % configuration.monitors
        let last = s.slots[m].last?.at ?? now
        let at = max(now, last.addingTimeInterval(0.000_001))
        append(&s, monitor: m, at: at)
      }
    }
  }

  public func handle(_ request: FixtureRequest) -> FixtureResponse {
    guard request.method == "GET" else {
      state.withLock { $0.nonGET += 1 }
      return .json(
        405, ["error": ["code": "method_not_allowed", "message": "fixture is GET-only"]])
    }
    switch request.path {
    case "/readyz":
      let ready = state.withLock { $0.ready }
      return ready
        ? .json(200, ["status": "ready"])
        : .json(503, ["status": "unavailable", "reason": "writer_dead", "faults": ["writer_dead"]])
    case "/version":
      return .json(200, ["version": "fixture-0.1"])
    default:
      break
    }
    guard request.path.hasPrefix("/api/") else {
      return .json(404, ["error": ["code": "not_found", "message": "no route"]])
    }
    let authorized =
      request.headers["authorization"] == "Bearer \(configuration.token)"
      && !state.withLock { $0.revoked }
    guard authorized else {
      return .json(
        401, ["error": ["code": "unauthenticated", "message": "missing or invalid token"]])
    }
    let parts = request.path.split(separator: "/").map(String.init)
    if parts == ["api", "monitors"] { return monitors() }
    if parts == ["api", "incidents"] { return incidents() }
    if parts.count == 4, parts[0] == "api", parts[1] == "monitors", parts[3] == "checks",
      let m = monitorIDs.firstIndex(of: parts[2])
    {
      let limit = min(max(Int(request.query["limit"] ?? "50") ?? 50, 1), 500)
      return checks(monitor: m, limit: limit)
    }
    return .json(404, ["error": ["code": "not_found", "message": "no such monitor"]])
  }

  private func monitors() -> FixtureResponse {
    let now = Date()
    let list: [[String: Any]] = state.withLock { s in
      generate(&s, until: now)
      return (0..<configuration.monitors).map { m in
        let failing = s.slots[m].last.map { isFailing($0.index) } ?? false
        return [
          "id": monitorIDs[m], "name": "fixture-\(m + 1)",
          "url": "http://127.0.0.1:9/target-\(m + 1)", "interval_s": 15, "timeout_s": 5,
          "failures_to_open": 3, "passes_to_recover": 2, "generation": 1, "paused": false,
          "status": s.slots[m].isEmpty ? "unknown" : (failing ? "down" : "up"),
          "created_at": Self.rfc3339(now.addingTimeInterval(-3600)),
        ]
      }
    }
    return .json(200, ["monitoring": ["status": "ok", "faults": []], "monitors": list])
  }

  private func checks(monitor m: Int, limit: Int) -> FixtureResponse {
    let now = Date()
    let rows: [[String: Any]] = state.withLock { s in
      generate(&s, until: now)
      return s.slots[m].suffix(limit).reversed().map { slot in
        let failing = isFailing(slot.index)
        var row: [String: Any] = [
          "slot_at": Self.rfc3339(slot.at), "outcome": failing ? "transport" : "pass",
          "recorded_at": Self.rfc3339(slot.at),
        ]
        if failing {
          row["detail"] = HostileLines.all[slot.index % HostileLines.all.count]
        } else {
          row["http_status"] = 200
          row["latency_ms"] = 3 + slot.index % 40
        }
        return row
      }
    }
    return .json(200, ["checks": rows])
  }

  private func incidents() -> FixtureResponse {
    let start = Self.rfc3339(Date().addingTimeInterval(-600))
    let end = Self.rfc3339(Date().addingTimeInterval(-300))
    return .json(
      200,
      [
        "incidents": [
          [
            "id": 2, "monitor_id": monitorIDs[0], "opened_at": end, "first_fail_at": end,
            "last_fail_at": end, "resolved_at": NSNull(), "state": "open",
          ],
          [
            "id": 1, "monitor_id": monitorIDs[min(1, monitorIDs.count - 1)], "opened_at": start,
            "first_fail_at": start, "last_fail_at": start, "resolved_at": end, "state": "resolved",
          ],
        ]
      ])
  }

  private func isFailing(_ index: Int) -> Bool {
    configuration.failEvery > 0 && index % configuration.failEvery == configuration.failEvery - 1
  }

  private func generate(_ s: inout State, until now: Date) {
    guard configuration.slotInterval > 0 else { return }
    for m in 0..<configuration.monitors {
      // Never generate more than the window keeps: a long pause costs O(window).
      let behind = now.timeIntervalSince(s.nextSlot[m]) / configuration.slotInterval
      if behind > Double(configuration.keepPerMonitor) {
        s.nextSlot[m] = now.addingTimeInterval(
          -Double(configuration.keepPerMonitor) * configuration.slotInterval)
      }
      while s.nextSlot[m] <= now {
        let last = s.slots[m].last?.at ?? .distantPast
        append(&s, monitor: m, at: max(s.nextSlot[m], last.addingTimeInterval(0.000_001)))
        s.nextSlot[m] = s.nextSlot[m].addingTimeInterval(configuration.slotInterval)
      }
    }
  }

  private func append(_ s: inout State, monitor m: Int, at: Date) {
    s.slots[m].append(Slot(at: at, index: s.counters[m]))
    s.counters[m] += 1
    s.slotsGenerated += 1
    if s.slots[m].count > configuration.keepPerMonitor {
      s.slots[m].removeFirst(s.slots[m].count - configuration.keepPerMonitor)
    }
  }

  /// RFC 3339 with microseconds, UTC — the shape the service emits.
  public static func rfc3339(_ date: Date) -> String {
    let seconds = date.timeIntervalSince1970
    var whole = time_t(seconds.rounded(.down))
    let micros = Int(((seconds - Double(whole)) * 1_000_000).rounded(.down))
    var parts = tm()
    gmtime_r(&whole, &parts)
    return String(
      format: "%04d-%02d-%02dT%02d:%02d:%02d.%06dZ", parts.tm_year + 1900, parts.tm_mon + 1,
      parts.tm_mday, parts.tm_hour, parts.tm_min, parts.tm_sec, micros)
  }
}

/// Emulates Durable Runner's open reads: `GET /ready`, `GET /jobs`,
/// `GET /jobs/{id}`.
public final class DurableRunnerEmulator: Sendable {
  public struct Run: Sendable {
    public var id: UInt64
    public var key: String
    public var state: String
    public var steps: Int
    public var finishedAt: UInt64?

    public init(id: UInt64, key: String, state: String, steps: Int, finishedAt: UInt64? = nil) {
      self.id = id
      self.key = key
      self.state = state
      self.steps = steps
      self.finishedAt = finishedAt
    }
  }

  private let state: Mutex<[Run]>
  private let nonGETCount = Mutex(0)

  public init(runs: [Run]) { state = Mutex(runs) }

  public func update(_ id: UInt64, state newState: String, finishedAt: UInt64? = nil) {
    state.withLock { runs in
      if let i = runs.firstIndex(where: { $0.id == id }) {
        runs[i].state = newState
        runs[i].finishedAt = finishedAt
      }
    }
  }

  public func add(_ run: Run) { state.withLock { $0.append(run) } }
  public var nonGETRequests: Int { nonGETCount.withLock { $0 } }

  public func handle(_ request: FixtureRequest) -> FixtureResponse {
    guard request.method == "GET" else {
      nonGETCount.withLock { $0 += 1 }
      return .json(405, ["error": "fixture is GET-only", "code": "method_not_allowed"])
    }
    if request.path == "/ready" { return .json(200, ["ready": true, "code": NSNull()]) }
    if request.path == "/health" { return .json(200, ["ok": true]) }
    let runs = state.withLock { $0 }
    func view(_ run: Run) -> [String: Any] {
      [
        "id": run.id, "key": run.key, "state": run.state, "steps": run.steps,
        "finished_at": run.finishedAt.map { $0 as Any } ?? NSNull(),
      ]
    }
    if request.path == "/jobs" {
      let limit = min(max(Int(request.query["limit"] ?? "100") ?? 100, 1), 1000)
      let newest = runs.sorted { $0.id > $1.id }.prefix(limit)
      return .json(200, ["runs": newest.map(view), "next_before": NSNull()])
    }
    if request.path.hasPrefix("/jobs/"), let id = UInt64(request.path.dropFirst("/jobs/".count)) {
      guard let run = runs.first(where: { $0.id == id }) else {
        return .json(404, ["error": "no such run", "code": "not_found"])
      }
      return .json(200, view(run))
    }
    return .json(404, ["error": "no route", "code": "not_found"])
  }
}
