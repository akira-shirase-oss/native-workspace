import Darwin
import Foundation
import Observation

/// A display-ready row, built off the main actor: the text is already inert
/// and the time already formatted, so the main actor only appends.
public struct EventRow: Sendable, Identifiable, Equatable {
  public let id: UInt64
  public let service: ServiceID
  public let kind: EventKind
  public let severity: Severity
  public let time: String
  public let text: String
  public let gapCount: UInt64?
  /// When the app took the event in (latency measurement).
  public let observedAt: Date

  public init(_ event: Event) {
    id = event.seq
    service = event.service
    kind = event.kind
    severity = event.severity
    time = ClockText.local(event.occurredAt)
    text = InertText.render(event.text)
    gapCount = event.gapCount
    observedAt = event.observedAt
  }

  public var isGap: Bool { kind == .gap }
}

/// Fast local-time formatting for rows (`MM-dd HH:mm:ss.SSS`), cheaper than
/// a formatter per row on the ingest path.
public enum ClockText {
  public static func local(_ date: Date) -> String {
    let seconds = date.timeIntervalSince1970
    var whole = time_t(seconds.rounded(.down))
    let millis = Int((seconds - Double(whole)) * 1000)
    var parts = tm()
    localtime_r(&whole, &parts)
    return String(
      format: "%02d-%02d %02d:%02d:%02d.%03d", parts.tm_mon + 1, parts.tm_mday, parts.tm_hour,
      parts.tm_min, parts.tm_sec, millis)
  }
}

/// The bounded event list the shell shows. Main-actor state; every update
/// is one batch (at most every 100 ms, D-021) and one assignment, so the
/// view diffs once per batch. Older rows leave the view (they stay in the
/// store) — the count is shown, never hidden.
@MainActor
@Observable
public final class EventListModel {
  public let capacity: Int
  /// Oldest first.
  public private(set) var rows: [EventRow] = []
  public private(set) var appliedTotal: UInt64 = 0
  /// Rows that left the view window because it is bounded.
  public private(set) var trimmed: UInt64 = 0
  /// Sum of the counts on gap rows applied (events the ingest queue dropped).
  public private(set) var droppedShown: UInt64 = 0
  public private(set) var batches: UInt64 = 0

  public init(capacity: Int = 10_000) {
    precondition(capacity > 0)
    self.capacity = capacity
  }

  public func apply(_ newRows: [EventRow]) {
    guard !newRows.isEmpty else { return }
    var next: [EventRow]
    if newRows.count >= capacity {
      next = Array(newRows.suffix(capacity))
      trimmed += UInt64(rows.count + newRows.count - capacity)
    } else {
      let overflow = rows.count + newRows.count - capacity
      if overflow > 0 {
        next = Array(rows.dropFirst(overflow))
        trimmed += UInt64(overflow)
      } else {
        next = rows
      }
      next.append(contentsOf: newRows)
    }
    rows = next
    appliedTotal += UInt64(newRows.count)
    for row in newRows { droppedShown += row.gapCount ?? 0 }
    batches += 1
  }
}

/// Service-reported status, as of the poll that produced it.
public struct ServiceSnapshot: Sendable, Equatable {
  /// The service's own readiness words (for example `ready`, `degraded`).
  public var verdict: String
  /// `true` ready, `false` not ready, `nil` the service did not say.
  public var verdictOK: Bool?
  public var version: String?
  public var items: [ItemStatus]
  public var asOf: Date

  public init(
    verdict: String, verdictOK: Bool?, version: String? = nil, items: [ItemStatus], asOf: Date
  ) {
    self.verdict = verdict
    self.verdictOK = verdictOK
    self.version = version
    self.items = items
    self.asOf = asOf
  }
}

public enum ItemState: String, Sendable, Equatable, Codable {
  case up, down, unknown, paused, info
}

public struct ItemStatus: Sendable, Equatable, Identifiable {
  public var id: String
  public var name: String
  public var state: ItemState
  public var detail: String

  public init(id: String, name: String, state: ItemState, detail: String) {
    self.id = id
    self.name = name
    self.state = state
    self.detail = detail
  }
}

/// How a status is drawn. `good` (green) only ever comes from live data.
public enum Tone: String, Sendable, Equatable {
  case good, bad, neutral, warning
}

public struct DisplayState: Sendable, Equatable {
  public var label: String
  public var tone: Tone
}

extension ItemStatus {
  /// The never-stale-green rule in one place: a status read while the
  /// service is not live is shown as history ("was up, as of T") in a
  /// neutral tone.
  public func display(_ freshness: Freshness) -> DisplayState {
    guard freshness.isLive else {
      let asOf: String
      switch freshness {
      case .stale(_, let lastGood?, _), .revoked(_, let lastGood?):
        asOf = " as of \(Freshness.clock(lastGood))"
      default:
        asOf = ""
      }
      return DisplayState(label: "was \(state.rawValue)\(asOf) (stale)", tone: .neutral)
    }
    switch state {
    case .up: return DisplayState(label: "up", tone: .good)
    case .down: return DisplayState(label: "down", tone: .bad)
    case .unknown: return DisplayState(label: "unknown", tone: .warning)
    case .paused: return DisplayState(label: "paused", tone: .neutral)
    case .info: return DisplayState(label: detail, tone: .neutral)
    }
  }
}

/// One paired service as the shell shows it: the connection state machine
/// and the last good snapshot. Freshness is asked with a time, so a view
/// that re-evaluates on a timer turns stale even when no poll comes back.
@MainActor
@Observable
public final class ServiceStatusModel: Identifiable {
  public let id: ServiceID
  public let name: String
  public let endpoint: String
  public private(set) var tracker: ConnectionTracker
  public private(set) var snapshot: ServiceSnapshot?
  public private(set) var polls: UInt64 = 0

  public init(id: ServiceID, name: String, endpoint: String, tracker: ConnectionTracker) {
    self.id = id
    self.name = name
    self.endpoint = endpoint
    self.tracker = tracker
  }

  public func update(tracker: ConnectionTracker, snapshot: ServiceSnapshot?) {
    self.tracker = tracker
    if let snapshot { self.snapshot = snapshot }
    polls += 1
  }

  public func freshness(now: Date = Date()) -> Freshness { tracker.freshness(now: now) }
}
