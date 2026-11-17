import Foundation
import NWCore
import NWCredentials
import Synchronization

/// Service Monitor's read API (D-013), `GET` only, through the same
/// versioned endpoints and Bearer authorization every other client uses:
/// `GET /readyz`, `GET /version`, `GET /api/monitors`,
/// `GET /api/monitors/{id}/checks?limit=`, `GET /api/incidents?limit=`.
///
/// Under the development exception (D-015) the token is admin-class, so the
/// adapter refuses any endpoint that is not loopback.
public final class ServiceMonitorAdapter: ServiceAdapter {
  public struct Limits: Sendable, Equatable {
    /// Monitors read per poll (Service Monitor caps itself at 100).
    public var maxMonitors = 100
    /// Checks read per monitor per poll (the service clamps to 500).
    public var checksPerMonitor = 50
    public var incidents = 50
    /// Concurrent requests within one poll.
    public var concurrency = 4

    public init() {}
  }

  public let id: ServiceID
  public let displayName: String
  public let endpoint: URL
  public let limits: Limits
  private let token: SecretToken?
  private let transport: any ReadOnlyTransport
  private let cursor = Mutex(Cursor())

  /// Per monitor: the newest `slot_at` already handed out. In memory only —
  /// after a restart the store's de-duplication absorbs the re-read.
  private struct Cursor {
    var newestSlot: [String: Date] = [:]
    /// Incident keys already handed out; bounded (reset past 4,096 — the
    /// store's de-duplication is the guarantee, this only saves work).
    var seenIncidents = Set<String>()
    var version: String?
  }

  /// The check that the process on the loopback port is the paired one,
  /// run before every poll (D-015).
  public let identityGate: ServerIdentityGate

  public init(
    endpoint: URL, token: SecretToken?, transport: any ReadOnlyTransport,
    id: ServiceID = .serviceMonitor, displayName: String = "Service Monitor",
    limits: Limits = Limits(), pin: ServerPin = .trustOnFirstUse,
    identifier: any ListenerIdentifying = LibprocListenerIdentifier()
  ) throws(AdapterError) {
    let endpoint = try EndpointPolicy.requireLoopbackForAdminToken(endpoint)
    let port = endpoint.port ?? (endpoint.scheme == "https" ? 443 : 80)
    self.identityGate = ServerIdentityGate(
      port: UInt16(clamping: port), pin: pin, identifier: identifier)
    self.endpoint = endpoint
    self.token = token
    self.transport = transport
    self.id = id
    self.displayName = displayName
    self.limits = limits
  }

  // MARK: wire shapes (crates/monitor-server/src/lib.rs)

  struct Readiness: Decodable {
    let status: String
    let faults: [String]?
    let reason: String?
  }

  struct Version: Decodable { let version: String }

  struct MonitorList: Decodable {
    struct Monitoring: Decodable {
      let status: String
      let faults: [String]?
    }
    let monitoring: Monitoring?
    let monitors: [Monitor]
  }

  struct Monitor: Decodable {
    let id: String
    let name: String
    let url: String
    let interval_s: UInt64
    let paused: Bool
    let status: String
  }

  struct CheckList: Decodable { let checks: [Check] }

  struct Check: Decodable {
    let slot_at: String
    let outcome: String
    let http_status: Int?
    let latency_ms: Int?
    let detail: String?
  }

  struct IncidentList: Decodable { let incidents: [Incident] }

  struct Incident: Decodable {
    let id: Int64
    let monitor_id: String
    let opened_at: String
    let first_fail_at: String?
    let resolved_at: String?
    let state: String
  }

  // MARK: requests

  private func get(_ path: [String], query: [URLQueryItem] = [], authorized: Bool)
    async throws(AdapterError) -> HTTPReply
  {
    let request = ReadOnlyRequest(
      url: try Wire.url(endpoint, path, query: query), token: authorized ? token : nil)
    let reply: HTTPReply
    do {
      reply = try await transport.get(request)
    } catch {
      throw AdapterError.transport(error)
    }
    if reply.status == 401 { throw AdapterError.unauthorized }
    return reply
  }

  public func poll(observedAt: Date) async throws(AdapterError) -> PollOutcome {
    // Nothing — no request, no token — goes to a process that is not the
    // paired service.
    try identityGate.verify()
    // Readiness is open (no token sent): 200 ready/degraded, 503 not observing.
    let readyReply = try await get(["readyz"], authorized: false)
    guard readyReply.status == 200 || readyReply.status == 503 else {
      throw AdapterError.httpStatus(readyReply.status, Wire.errorCode(readyReply))
    }
    let readiness = try Wire.decode(Readiness.self, readyReply, what: "readyz")

    let listReply = try await get(["api", "monitors"], authorized: true)
    guard listReply.status == 200 else {
      throw AdapterError.httpStatus(listReply.status, Wire.errorCode(listReply))
    }
    let list = try Wire.decode(MonitorList.self, listReply, what: "monitors")
    // Service Monitor's ids are UUIDs. Anything else is not put in a URL —
    // it is skipped and said, never sent (with the token) as a path.
    let wellFormed = list.monitors.filter { UUID(uuidString: $0.id) != nil }
    let invalidIDs = list.monitors.count - wellFormed.count
    let monitors = Array(wellFormed.prefix(limits.maxMonitors))

    let version = try await currentVersion()
    let checks = try await fetchChecks(monitors)
    let incidentsReply = try await get(
      ["api", "incidents"], query: [URLQueryItem(name: "limit", value: "\(limits.incidents)")],
      authorized: true)
    guard incidentsReply.status == 200 else {
      throw AdapterError.httpStatus(incidentsReply.status, Wire.errorCode(incidentsReply))
    }
    let incidents = try Wire.decode(IncidentList.self, incidentsReply, what: "incidents")

    let names = Dictionary(monitors.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
    var events: [Event] = []
    cursor.withLock { cursor in
      for (monitorID, list) in checks {
        let name = names[monitorID] ?? monitorID
        var newest = cursor.newestSlot[monitorID]
        for check in list.reversed() {  // the API answers newest first
          guard let slot = Wire.rfc3339(check.slot_at) else { continue }
          if let seen = cursor.newestSlot[monitorID], slot <= seen { continue }
          events.append(Self.event(check, slot: slot, monitorID: monitorID, name: name, observedAt))
          newest = max(newest ?? slot, slot)
        }
        cursor.newestSlot[monitorID] = newest
      }
    }
    cursor.withLock { cursor in
      if cursor.seenIncidents.count > 4_096 { cursor.seenIncidents.removeAll() }
      for incident in incidents.incidents.reversed() {
        let event = Self.event(incident, name: names[incident.monitor_id], observedAt)
        if cursor.seenIncidents.insert(event.key).inserted { events.append(event) }
      }
    }

    let verdictOK: Bool? =
      readyReply.status == 503 ? false : (readiness.status == "ready" ? true : nil)
    var verdict = readiness.status
    if let faults = readiness.faults, !faults.isEmpty {
      verdict += ": " + faults.joined(separator: ", ")
    }
    // `/readyz` says "ready" where the monitor list says "ok": the same verdict.
    if invalidIDs > 0 {
      verdict += " · skipped \(invalidIDs) monitors with an invalid id"
    }
    if let monitoring = list.monitoring, monitoring.status != "ok",
      monitoring.status != readiness.status
    {
      verdict += " (monitoring \(monitoring.status))"
    }
    let items = monitors.map { monitor -> ItemStatus in
      // Only the service's own three states are read from the wire; the
      // app-internal `paused`/`info` come from typed fields, never a string.
      let state: ItemState
      if monitor.paused {
        state = .paused
      } else {
        switch monitor.status {
        case "up": state = .up
        case "down": state = .down
        default: state = .unknown
        }
      }
      return ItemStatus(
        id: monitor.id, name: monitor.name, state: state,
        detail: "\(monitor.url) every \(monitor.interval_s) s")
    }
    let snapshot = ServiceSnapshot(
      verdict: verdict, verdictOK: verdictOK, version: version, items: items, asOf: observedAt)
    return PollOutcome(snapshot: snapshot, events: events)
  }

  private func currentVersion() async throws(AdapterError) -> String? {
    if let known = cursor.withLock({ $0.version }) { return known }
    let reply = try await get(["version"], authorized: false)
    guard reply.status == 200, let version = try? Wire.decode(Version.self, reply, what: "version")
    else { return nil }
    cursor.withLock { $0.version = version.version }
    return version.version
  }

  /// One request per monitor, at most `concurrency` in flight.
  private func fetchChecks(_ monitors: [Monitor]) async throws(AdapterError) -> [(String, [Check])]
  {
    let limit = limits.checksPerMonitor
    let width = max(1, limits.concurrency)
    do {
      return try await withThrowingTaskGroup(of: (String, [Check]).self) { group in
        var results: [(String, [Check])] = []
        var next = 0
        func launch() {
          guard next < monitors.count else { return }
          let monitor = monitors[next]
          next += 1
          group.addTask { [self] in
            let reply = try await get(
              ["api", "monitors", monitor.id, "checks"],
              query: [URLQueryItem(name: "limit", value: "\(limit)")], authorized: true)
            if reply.status == 404 { return (monitor.id, []) }  // deleted between reads
            guard reply.status == 200 else {
              throw AdapterError.httpStatus(reply.status, Wire.errorCode(reply))
            }
            return (monitor.id, try Wire.decode(CheckList.self, reply, what: "checks").checks)
          }
        }
        for _ in 0..<width { launch() }
        while let result = try await group.next() {
          results.append(result)
          launch()
        }
        return results
      }
    } catch let error as AdapterError {
      throw error
    } catch {
      throw AdapterError.transport(.cancelled)
    }
  }

  static func event(
    _ check: Check, slot: Date, monitorID: String, name: String, _ observedAt: Date
  ) -> Event {
    let severity: Severity
    switch check.outcome {
    case "pass": severity = .ok
    case "missed": severity = .unknown
    default: severity = .failure
    }
    var text = "\(name): \(check.outcome)"
    if let status = check.http_status { text += " HTTP \(status)" }
    if let latency = check.latency_ms { text += " \(latency) ms" }
    if let detail = check.detail, !detail.isEmpty { text += " — \(detail)" }
    return Event(
      service: .serviceMonitor, kind: .check, key: "check:\(monitorID):\(check.slot_at)",
      occurredAt: slot, observedAt: observedAt, severity: severity, text: text)
  }

  static func event(_ incident: Incident, name: String?, _ observedAt: Date) -> Event {
    let resolved = incident.state == "resolved"
    let at =
      Wire.rfc3339((resolved ? incident.resolved_at : nil) ?? incident.opened_at) ?? observedAt
    let who = name ?? incident.monitor_id
    var text = "\(who): incident \(incident.id) \(resolved ? "resolved" : "opened")"
    if let first = incident.first_fail_at { text += " (first failure \(first))" }
    return Event(
      service: .serviceMonitor, kind: .incident, key: "incident:\(incident.id):\(incident.state)",
      occurredAt: at, observedAt: observedAt, severity: resolved ? .ok : .failure, text: text)
  }
}
