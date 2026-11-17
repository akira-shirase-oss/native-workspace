import Foundation
import NWCore
import Synchronization

/// Durable Runner's read API, `GET` only: `GET /ready` and
/// `GET /jobs?order=desc&limit=` (newest runs first), plus `GET /jobs/{id}`
/// for one run. Those reads are unauthenticated on the service (D-015), so
/// this adapter holds no credential at all — it could not send the API key
/// even by mistake.
public final class DurableRunnerAdapter: ServiceAdapter {
  public let id: ServiceID
  public let displayName: String
  public let endpoint: URL
  /// Runs read per poll (the service clamps to 1..=1000).
  public let pageSize: Int
  private let transport: any ReadOnlyTransport
  private let seen = Mutex(Set<String>())

  public init(
    endpoint: URL, transport: any ReadOnlyTransport, id: ServiceID = .durableRunner,
    displayName: String = "Durable Runner", pageSize: Int = 200
  ) throws(AdapterError) {
    guard endpoint.scheme == "http" || endpoint.scheme == "https" else {
      throw AdapterError.refusedEndpoint("only http(s) endpoints can be paired")
    }
    self.endpoint = endpoint
    self.transport = transport
    self.id = id
    self.displayName = displayName
    self.pageSize = max(1, min(pageSize, 1000))
  }

  struct Ready: Decodable {
    let ready: Bool
    let code: String?
  }

  public struct Run: Decodable, Sendable, Equatable {
    public let id: UInt64
    public let key: String
    public let state: String
    public let steps: Int
    public let finished_at: UInt64?
  }

  struct Page: Decodable {
    let runs: [Run]
  }

  private func get(_ path: [String], query: [URLQueryItem] = []) async throws(AdapterError)
    -> HTTPReply
  {
    let request = ReadOnlyRequest(url: try Wire.url(endpoint, path, query: query), token: nil)
    do {
      return try await transport.get(request)
    } catch {
      throw AdapterError.transport(error)
    }
  }

  public func poll(observedAt: Date) async throws(AdapterError) -> PollOutcome {
    let readyReply = try await get(["ready"])
    guard readyReply.status == 200 || readyReply.status == 503 else {
      throw AdapterError.httpStatus(readyReply.status, Wire.errorCode(readyReply))
    }
    let ready = try Wire.decode(Ready.self, readyReply, what: "ready")
    let pageReply = try await get(
      ["jobs"],
      query: [
        URLQueryItem(name: "order", value: "desc"),
        URLQueryItem(name: "limit", value: "\(pageSize)"),
      ])
    guard pageReply.status == 200 else {
      throw AdapterError.httpStatus(pageReply.status, Wire.errorCode(pageReply))
    }
    let page = try Wire.decode(Page.self, pageReply, what: "jobs")

    var events: [Event] = []
    seen.withLock { seen in
      if seen.count > 8_192 { seen.removeAll() }  // bounded; the store de-duplicates
      for run in page.runs.reversed() {
        let event = Self.event(run, observedAt)
        if seen.insert(event.key).inserted { events.append(event) }
      }
    }
    var counts: [String: Int] = [:]
    for run in page.runs { counts[Self.phase(run.state), default: 0] += 1 }
    let order = [
      "running", "queued", "retry_waiting", "reconciling", "failed", "cancelled", "done",
    ]
    let items = order.compactMap { phase -> ItemStatus? in
      guard let n = counts[phase] else { return nil }
      return ItemStatus(
        id: phase, name: phase, state: .info, detail: "\(n) of the newest \(page.runs.count) runs")
    }
    let snapshot = ServiceSnapshot(
      verdict: ready.ready ? "ready" : "not ready: \(ready.code ?? "unknown")",
      verdictOK: ready.ready, items: items, asOf: observedAt)
    return PollOutcome(snapshot: snapshot, events: events)
  }

  /// One run, for an inspection view.
  public func run(id runID: UInt64) async throws(AdapterError) -> Run? {
    let reply = try await get(["jobs", String(runID)])
    if reply.status == 404 { return nil }
    guard reply.status == 200 else {
      throw AdapterError.httpStatus(reply.status, Wire.errorCode(reply))
    }
    return try Wire.decode(Run.self, reply, what: "job")
  }

  static func phase(_ state: String) -> String {
    String(state.split(separator: ":", maxSplits: 1).first ?? Substring(state))
  }

  static func event(_ run: Run, _ observedAt: Date) -> Event {
    let phase = phase(run.state)
    let severity: Severity
    switch phase {
    case "done": severity = .ok
    case "failed": severity = .failure
    case "cancelled", "reconciling", "retry_waiting": severity = .warning
    default: severity = .info
    }
    let occurred = run.finished_at.map { Date(timeIntervalSince1970: Double($0) / 1000) }
    return Event(
      service: .durableRunner, kind: .run, key: "run:\(run.id):\(run.state)",
      occurredAt: occurred ?? observedAt, observedAt: observedAt, severity: severity,
      text: "run \(run.id) \(run.key): \(run.state) (\(run.steps) steps)")
  }
}
