import Foundation

/// What a view may say about a service's data. Freshness is a label derived
/// from time, never a property of the data (ARCHITECTURE §Consistency).
public enum Freshness: Sendable, Equatable {
  /// Paired but no answer yet.
  case connecting
  /// The service answered at `asOf` and that is recent enough to call live.
  case live(asOf: Date)
  /// Not current. `since` is when it stopped being current; `lastGood` is
  /// the time the data on screen is from (`nil`: nothing was ever received).
  case stale(since: Date, lastGood: Date?, reason: InertString)
  /// The service refused the credential (401). Polling has stopped; data on
  /// screen is from `lastGood`; renewed authority (re-pairing) is required.
  case revoked(at: Date, lastGood: Date?)

  public var isLive: Bool {
    if case .live = self { return true }
    return false
  }

  /// One short label for the sidebar and status line.
  public var label: String {
    switch self {
    case .connecting: return "Connecting"
    case .live: return "Live"
    case .stale(let since, _, _): return "Unavailable — stale since \(Self.clock(since))"
    case .revoked(let at, _): return "Authority revoked at \(Self.clock(at))"
    }
  }

  public static func clock(_ date: Date) -> String {
    date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
  }
}

/// Why a poll did not produce current data.
public enum PollFailure: Sendable, Equatable {
  case unreachable(String)
  case timeout
  case unauthorized
  case protocolError(String)

  public var summary: String {
    switch self {
    case .unreachable(let detail): return "unreachable: \(detail)"
    case .timeout: return "timed out"
    case .unauthorized: return "credential refused (401)"
    case .protocolError(let detail): return "unexpected response: \(detail)"
    }
  }
}

/// Reconnect backoff: 1 s doubling to a 30 s cap, with jitter (END_GOAL
/// failure case 1). Jitter only shortens a delay, so the cap is a real cap.
public struct Backoff: Sendable, Equatable {
  public var base: TimeInterval
  public var cap: TimeInterval
  /// Fraction of the delay that jitter may remove, in `0..<1`.
  public var jitter: Double

  public static let contract = Backoff(base: 1, cap: 30, jitter: 0.2)

  public init(base: TimeInterval, cap: TimeInterval, jitter: Double) {
    self.base = base
    self.cap = cap
    self.jitter = jitter
  }

  /// Delay before retry number `attempt` (1-based), with `unit` in `0..<1`.
  public func delay(attempt: Int, unit: Double) -> TimeInterval {
    let exponent = Double(max(0, min(attempt - 1, 62)))
    let raw = min(cap, base * pow(2, exponent))
    return raw * (1 - jitter * min(max(unit, 0), 0.999_999))
  }
}

/// The per-service connection state machine. A value type with no clock of
/// its own: every transition and every question takes `now`, which keeps it
/// exhaustively testable.
///
/// The live rule: a service is live only while its last successful poll is
/// at most `pollInterval + grace` old *and* nothing has failed since. So a
/// killed service turns stale within one poll interval plus the grace even
/// if no request has come back yet — and stale data is never labeled live.
public struct ConnectionTracker: Sendable, Equatable {
  public var pollInterval: TimeInterval
  public var grace: TimeInterval
  public var backoff: Backoff

  public private(set) var lastGood: Date?
  public private(set) var firstFailureSinceGood: Date?
  public private(set) var lastFailure: PollFailure?
  public private(set) var consecutiveFailures = 0
  public private(set) var revokedAt: Date?
  public private(set) var successes = 0
  /// How many times the service came back after being stale.
  public private(set) var recoveries = 0

  public init(pollInterval: TimeInterval = 2, grace: TimeInterval = 1, backoff: Backoff = .contract)
  {
    self.pollInterval = pollInterval
    self.grace = grace
    self.backoff = backoff
  }

  public var isRevoked: Bool { revokedAt != nil }

  /// Data from a poll that *started* at `asOf` arrived. The start time is
  /// the conservative age of what the service returned.
  public mutating func recordSuccess(asOf: Date) {
    guard revokedAt == nil else { return }
    if consecutiveFailures > 0 { recoveries += 1 }
    lastGood = max(lastGood ?? asOf, asOf)
    firstFailureSinceGood = nil
    lastFailure = nil
    consecutiveFailures = 0
    successes += 1
  }

  public mutating func recordFailure(_ failure: PollFailure, at now: Date) {
    guard revokedAt == nil else { return }
    if failure == .unauthorized {
      revokedAt = now
      lastFailure = failure
      return
    }
    if firstFailureSinceGood == nil { firstFailureSinceGood = now }
    lastFailure = failure
    consecutiveFailures += 1
  }

  public func freshness(now: Date) -> Freshness {
    if let revokedAt { return .revoked(at: revokedAt, lastGood: lastGood) }
    let threshold = pollInterval + grace
    if let failedAt = firstFailureSinceGood {
      let since: Date
      if let lastGood {
        since = min(failedAt, lastGood.addingTimeInterval(threshold))
      } else {
        since = failedAt
      }
      return .stale(
        since: since, lastGood: lastGood, reason: InertString(lastFailure?.summary ?? "failed"))
    }
    guard let lastGood else { return .connecting }
    let expiry = lastGood.addingTimeInterval(threshold)
    if now > expiry {
      return .stale(
        since: expiry, lastGood: lastGood,
        reason: InertString("no answer for \(Int((now.timeIntervalSince(lastGood)).rounded())) s"))
    }
    return .live(asOf: lastGood)
  }

  /// How long to wait before the next poll: the poll interval while healthy,
  /// backoff while failing, `nil` once revoked (polling stops — no retry loop
  /// with a dead credential).
  public func nextDelay(unit: Double) -> TimeInterval? {
    if revokedAt != nil { return nil }
    if consecutiveFailures == 0 { return pollInterval }
    return backoff.delay(attempt: consecutiveFailures, unit: unit)
  }
}
