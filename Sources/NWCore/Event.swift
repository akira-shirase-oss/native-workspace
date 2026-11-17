import Foundation

/// Which paired service an event came from. A plain string so a new adapter
/// never needs a change here.
public struct ServiceID: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
  public let rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }
  public init(_ rawValue: String) { self.rawValue = rawValue }
  public var description: String { rawValue }

  public static let serviceMonitor = ServiceID("service-monitor")
  public static let durableRunner = ServiceID("durable-runner")
}

public enum EventKind: String, Sendable, Codable, CaseIterable {
  /// One scheduled check slot (Service Monitor).
  case check
  /// An incident opened or resolved (Service Monitor).
  case incident
  /// A run reached a state (Durable Runner).
  case run
  /// Events that overflowed the bounded ingest queue (D-021). Never silent.
  case gap
}

public enum Severity: String, Sendable, Codable, CaseIterable {
  case ok
  case info
  case warning
  case failure
  case unknown
}

/// One observation from a service, as the app ingests it.
///
/// `key` is the service's own identity for the observation (for example
/// `check:<monitor>:<slot_at>`); the store refuses a second event with the
/// same `(service, key)`, so re-polling after a reconnect never duplicates a
/// row. `text` is untrusted service text, kept verbatim and rendered inert
/// only at display time (`InertText`).
public struct Event: Sendable, Codable, Hashable {
  /// Assigned by the store on acceptance; 0 until then.
  public var seq: UInt64
  public var service: ServiceID
  public var kind: EventKind
  public var key: String
  /// When the service says it happened.
  public var occurredAt: Date
  /// When the app took it from the service.
  public var observedAt: Date
  public var severity: Severity
  public var text: String
  /// Gap markers only: how many events were dropped into this gap.
  public var gapCount: UInt64?
  /// Gap markers only: the last drop's time (`occurredAt` is the first).
  public var gapEnd: Date?

  public init(
    seq: UInt64 = 0,
    service: ServiceID,
    kind: EventKind,
    key: String,
    occurredAt: Date,
    observedAt: Date,
    severity: Severity,
    text: String,
    gapCount: UInt64? = nil,
    gapEnd: Date? = nil
  ) {
    self.seq = seq
    self.service = service
    self.kind = kind
    self.key = key
    self.occurredAt = occurredAt
    self.observedAt = observedAt
    self.severity = severity
    self.text = text
    self.gapCount = gapCount
    self.gapEnd = gapEnd
  }

  /// The store's de-duplication identity.
  public var identity: EventIdentity { EventIdentity(service: service, key: key) }

  enum CodingKeys: String, CodingKey {
    case seq = "s"
    case service = "v"
    case kind = "k"
    case key = "i"
    case occurredAt = "o"
    case observedAt = "b"
    case severity = "y"
    case text = "t"
    case gapCount = "g"
    case gapEnd = "e"
  }
}

public struct EventIdentity: Hashable, Sendable {
  public let service: ServiceID
  public let key: String
}
