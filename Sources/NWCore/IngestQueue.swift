import Foundation
import Synchronization

/// The pseudo-service that owns gap markers: a gap can span several services.
extension ServiceID {
  public static let ingest = ServiceID("ingest")
}

/// The bounded ingest queue (D-021).
///
/// At most `capacity` events wait here. When it is full, new events are
/// dropped — never buffered without bound — and every drop is counted into
/// the gap marker at the tail of the queue, which travels to the store and
/// the view like any other row. Consecutive drops share one marker, so the
/// markers stay bounded too (at most one between any two admitted events).
/// The ledger always holds: `offered == admitted + dropped`, and the sum of
/// all gap-marker counts equals `dropped`.
public final class IngestQueue: Sendable {
  public let capacity: Int
  private let state: Mutex<State>

  public init(capacity: Int = 10_000) {
    precondition(capacity > 0, "capacity must be positive")
    self.capacity = capacity
    self.state = Mutex(State(slots: 2 * capacity + 2))
  }

  @discardableResult
  public func offer(_ events: [Event], at now: Date = Date()) -> OfferResult {
    state.withLock { s in
      var admitted = 0
      var dropped = 0
      for event in events {
        s.stats.offered += 1
        if s.eventDepth < capacity {
          s.openGap = nil
          s.push(.event(event))
          s.eventDepth += 1
          s.stats.admitted += 1
          admitted += 1
        } else {
          s.stats.dropped += 1
          dropped += 1
          s.recordDrop(of: event, at: now)
        }
      }
      s.stats.depth = s.eventDepth
      s.stats.maxDepth = max(s.stats.maxDepth, s.eventDepth)
      return OfferResult(admitted: admitted, dropped: dropped)
    }
  }

  /// Takes up to `max` entries (events and gap markers) in arrival order.
  public func drain(max: Int = .max) -> [Event] {
    state.withLock { s in
      var out: [Event] = []
      out.reserveCapacity(Swift.min(max, s.count))
      while out.count < max, let entry = s.pop() {
        switch entry {
        case .event(let event):
          s.eventDepth -= 1
          out.append(event)
        case .gap(let gap):
          if s.openGap == gap.id { s.openGap = nil }
          s.stats.gapMarkers += 1
          s.stats.gapCountEmitted += gap.count
          out.append(gap.marker())
        }
      }
      s.stats.depth = s.eventDepth
      return out
    }
  }

  public var stats: IngestStats { state.withLock { $0.stats } }

  /// Events dropped into gaps that have not been drained yet.
  public var pendingGapCount: UInt64 {
    state.withLock { s in
      var total: UInt64 = 0
      for entry in s.entries { if case .gap(let gap) = entry { total += gap.count } }
      return total
    }
  }
}

public struct OfferResult: Sendable, Equatable {
  public var admitted: Int
  public var dropped: Int
}

public struct IngestStats: Sendable, Equatable, Codable {
  public var offered: UInt64 = 0
  public var admitted: UInt64 = 0
  public var dropped: UInt64 = 0
  /// Gap markers handed to the consumer.
  public var gapMarkers: UInt64 = 0
  /// Sum of the counts on gap markers handed to the consumer.
  public var gapCountEmitted: UInt64 = 0
  /// Events waiting now, and the most that ever waited (never above capacity).
  public var depth: Int = 0
  public var maxDepth: Int = 0

  public init() {}
}

private struct Gap: Sendable {
  var id: UInt64
  var first: Date
  var last: Date
  var count: UInt64
  var perService: [ServiceID: UInt64]

  func marker() -> Event {
    let parts = perService.sorted { $0.key.rawValue < $1.key.rawValue }
      .map { "\($0.key.rawValue) \($0.value)" }
      .joined(separator: ", ")
    return Event(
      service: .ingest,
      kind: .gap,
      key: "gap:\(UUID().uuidString)",
      occurredAt: first,
      observedAt: last,
      severity: .warning,
      text: "\(count) events dropped: ingest queue full (\(parts))",
      gapCount: count,
      gapEnd: last
    )
  }
}

private enum Entry: Sendable {
  case event(Event)
  case gap(Gap)
}

private struct State: Sendable {
  var buffer: [Entry?]
  var head = 0
  var count = 0
  var eventDepth = 0
  /// The id of the gap marker at the tail that further drops join, if any.
  var openGap: UInt64?
  var nextGapID: UInt64 = 1
  var stats = IngestStats()

  init(slots: Int) { buffer = Array(repeating: nil, count: slots) }

  mutating func push(_ entry: Entry) {
    precondition(count < buffer.count, "ingest ring overflow")
    buffer[(head + count) % buffer.count] = entry
    count += 1
  }

  mutating func pop() -> Entry? {
    guard count > 0 else { return nil }
    let entry = buffer[head]
    buffer[head] = nil
    head = (head + 1) % buffer.count
    count -= 1
    return entry
  }

  mutating func recordDrop(of event: Event, at now: Date) {
    let tail = (head + count - 1 + buffer.count) % buffer.count
    if let open = openGap, count > 0, case .gap(var gap) = buffer[tail], gap.id == open {
      gap.count += 1
      gap.last = now
      gap.perService[event.service, default: 0] += 1
      buffer[tail] = .gap(gap)
      return
    }
    let gap = Gap(
      id: nextGapID, first: now, last: now, count: 1, perService: [event.service: 1])
    nextGapID += 1
    openGap = gap.id
    push(.gap(gap))
  }

  var entries: [Entry] {
    (0..<count).compactMap { buffer[(head + $0) % buffer.count] }
  }
}
