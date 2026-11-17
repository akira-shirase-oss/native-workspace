import CryptoKit
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

  /// Stored text per event, in UTF-8 bytes. Longer text (a check detail
  /// can be megabytes) is cut, and the cut is stated.
  public static let maxTextBytes = 8_192
  /// Longer keys are replaced by a SHA-256 of the key: stable, so
  /// de-duplication still works, and bounded.
  public static let maxKeyBytes = 512

  /// The event as it may be held and stored: text and key bounded in bytes.
  /// Idempotent.
  public func boundedForStorage() -> Event {
    var event = self
    if key.utf8.count > Self.maxKeyBytes {
      let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
      event.key = "sha256:" + digest
    }
    let bytes = text.utf8.count
    if bytes > Self.maxTextBytes {
      let suffix = " … [\(bytes - Self.maxTextBytes) bytes cut]"
      // Cut on the UTF-8 bytes, backing off to the start of a scalar.
      var prefix = Array(text.utf8.prefix(Self.maxTextBytes - suffix.utf8.count))
      var lead = prefix.count - 1
      while lead >= 0, prefix[lead] & 0xC0 == 0x80 { lead -= 1 }
      if lead >= 0 {
        let byte = prefix[lead]
        let length = byte < 0x80 ? 1 : byte >= 0xF0 ? 4 : byte >= 0xE0 ? 3 : 2
        if prefix.count - lead < length { prefix.removeSubrange(lead...) }  // incomplete scalar
      }
      event.text = String(decoding: prefix, as: UTF8.self) + suffix
    }
    return event
  }

  /// What the store counts against its byte budget for this event.
  var approximateBytes: Int { text.utf8.count + key.utf8.count + 128 }

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
