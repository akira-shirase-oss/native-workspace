import Darwin
import Foundation
import Synchronization

/// How hard an append pushes bytes to disk before it is acknowledged.
public enum Durability: String, Sendable, Codable {
  /// `write(2)` only: survives an app crash, not a power loss. Tests.
  case none
  /// `fsync(2)`: on macOS this reaches the drive, not necessarily its media.
  case fsync
  /// `fcntl(F_FULLFSYNC)`: through the drive's cache. The app's default.
  case fullFsync
}

public enum StoreError: Error, Equatable, Sendable {
  case io(String)
  case corrupt(String)
  /// A write or sync failed earlier; the store refuses further appends
  /// rather than guess what reached the disk (a failed sync is never retried).
  case poisoned
}

public struct StoreStats: Sendable, Equatable, Codable {
  /// Events accepted since open (gap markers included).
  public var accepted: UInt64 = 0
  /// Offered events refused because `(service, key)` was already stored.
  public var duplicates: UInt64 = 0
  /// Events that left memory because retention was full (still on disk
  /// until their segment ages out).
  public var evicted: UInt64 = 0
  /// Events in memory now (≤ retention).
  public var retained: Int = 0
  /// Events read back from disk at open.
  public var loadedFromDisk: Int = 0
  public var segmentsOnDisk: Int = 0
  public var lastSeq: UInt64 = 0

  public init() {}
}

public struct AppendResult: Sendable {
  /// The accepted events with their sequence numbers, in order. These are
  /// acknowledged: written (and synced per `Durability`) before this returns.
  public var accepted: [Event]
  public var duplicates: Int
}

/// The bounded event store: an in-memory window over an append-only,
/// segmented JSON Lines log.
///
/// - Bounded: at most `retention` events in memory; on disk at most
///   `retention + segmentEvents` (whole segments age out).
/// - Acknowledged means durable: `append` returns only after the batch is
///   written and synced; a batch that fails is not in memory either, and the
///   store refuses further appends.
/// - No duplicates: a second event with the same `(service, key)` is refused,
///   so a reconnect that re-reads recent history adds nothing.
/// - Crash-safe: a torn final line (a write cut short) is unacknowledged by
///   construction and is truncated at the next open; any other undecodable
///   line is corruption and fails the open.
/// - Disposable (ARCHITECTURE §Sources of truth): the services are the
///   authority; deleting the directory loses no truth.
public final class EventStore: Sendable {
  public struct Configuration: Sendable {
    /// `nil` keeps everything in memory (tests, the headless replay's
    /// in-memory mode).
    public var directory: URL?
    public var retention: Int
    public var segmentEvents: Int
    public var durability: Durability

    public init(
      directory: URL?, retention: Int = 50_000, segmentEvents: Int = 10_000,
      durability: Durability = .fullFsync
    ) {
      self.directory = directory
      self.retention = retention
      self.segmentEvents = segmentEvents
      self.durability = durability
    }
  }

  public let configuration: Configuration
  private let state: Mutex<StoreState>

  /// - Parameter freshSegment: write into a new segment rather than append
  ///   to the last one — how a recovery avoids the file whose write or sync
  ///   failed.
  public init(_ configuration: Configuration, freshSegment: Bool = false) throws(StoreError) {
    precondition(configuration.retention > 0 && configuration.segmentEvents > 0)
    self.configuration = configuration
    var s = StoreState(retention: configuration.retention)
    if let directory = configuration.directory {
      try s.open(
        directory: directory, segmentEvents: configuration.segmentEvents,
        freshSegment: freshSegment)
    }
    self.state = Mutex(s)
  }

  deinit { state.withLock { $0.closeFile() } }

  /// Assigns sequence numbers, refuses duplicates, persists, then admits to
  /// memory. Returns only acknowledged events.
  public func append(_ events: [Event]) throws(StoreError) -> AppendResult {
    let config = configuration
    return try state.withLock { s throws(StoreError) -> AppendResult in
      guard !s.poisoned else { throw StoreError.poisoned }
      var fresh: [Event] = []
      fresh.reserveCapacity(events.count)
      var batchIDs = Set<EventIdentity>()
      var duplicates = 0
      var seq = s.stats.lastSeq
      for var event in events {
        let id = event.identity
        if s.identities.contains(id) || !batchIDs.insert(id).inserted {
          duplicates += 1
          continue
        }
        seq += 1
        event.seq = seq
        fresh.append(event)
      }
      s.stats.duplicates += UInt64(duplicates)
      guard !fresh.isEmpty else { return AppendResult(accepted: [], duplicates: duplicates) }
      if config.directory != nil {
        try s.persist(fresh, config: config)
      }
      s.admit(fresh)
      s.stats.lastSeq = seq
      s.stats.accepted += UInt64(fresh.count)
      return AppendResult(accepted: fresh, duplicates: duplicates)
    }
  }

  public func contains(_ identity: EventIdentity) -> Bool {
    state.withLock { $0.identities.contains(identity) }
  }

  /// The newest `count` retained events, oldest first.
  public func recent(_ count: Int) -> [Event] {
    state.withLock { $0.recent(count) }
  }

  public var stats: StoreStats { state.withLock { $0.stats } }

  public func close() { state.withLock { $0.closeFile() } }

  /// Test seam: the next disk write fails as an I/O error would.
  package func injectWriteFailureForTesting() { state.withLock { $0.injectWriteFailure = true } }
}

private struct Segment {
  var url: URL
  var firstSeq: UInt64
  var count: Int
}

private struct StoreState {
  let retention: Int
  var ring: [Event] = []
  var head = 0
  var identities = Set<EventIdentity>()
  var stats = StoreStats()
  var poisoned = false
  var injectWriteFailure = false
  var segments: [Segment] = []
  var fd: Int32 = -1
  var directory: URL?
  let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    return encoder
  }()

  init(retention: Int) {
    self.retention = retention
    ring.reserveCapacity(Swift.min(retention, 65_536))
  }

  // MARK: memory window

  mutating func admit(_ events: [Event]) {
    for event in events {
      if ring.count < retention {
        ring.append(event)
      } else {
        let old = ring[head]
        identities.remove(old.identity)
        ring[head] = event
        head = (head + 1) % retention
        stats.evicted += 1
      }
      identities.insert(event.identity)
    }
    stats.retained = ring.count
  }

  func recent(_ count: Int) -> [Event] {
    let n = Swift.min(count, ring.count)
    guard n > 0 else { return [] }
    if ring.count < retention {
      return Array(ring[(ring.count - n)...])
    }
    var out: [Event] = []
    out.reserveCapacity(n)
    let start = (head + ring.count - n) % ring.count
    for offset in 0..<n { out.append(ring[(start + offset) % ring.count]) }
    return out
  }

  // MARK: disk

  mutating func open(directory: URL, segmentEvents: Int, freshSegment: Bool) throws(StoreError) {
    self.directory = directory
    do {
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
    } catch {
      throw StoreError.io("create \(directory.path): \(error.localizedDescription)")
    }
    let names: [String]
    do {
      names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    } catch {
      throw StoreError.io("list \(directory.path): \(error.localizedDescription)")
    }
    let found =
      names
      .compactMap { name -> (String, UInt64)? in
        guard name.hasPrefix("segment-"), name.hasSuffix(".jsonl") else { return nil }
        let digits = name.dropFirst("segment-".count).dropLast(".jsonl".count)
        guard let first = UInt64(digits) else { return nil }
        return (name, first)
      }
      .sorted { $0.1 < $1.1 }
    let decoder = JSONDecoder()
    for (index, (name, first)) in found.enumerated() {
      let url = directory.appendingPathComponent(name)
      let isLast = index == found.count - 1
      let events = try readSegment(url, decoder: decoder, repairTail: isLast)
      segments.append(Segment(url: url, firstSeq: first, count: events.count))
      admit(events)
      stats.loadedFromDisk += events.count
      if let last = events.last { stats.lastSeq = Swift.max(stats.lastSeq, last.seq) }
    }
    stats.evicted = 0
    stats.segmentsOnDisk = segments.count
    if !freshSegment, let last = segments.last, last.count < segmentEvents {
      try openForAppend(last.url)
    }
  }

  private func readSegment(_ url: URL, decoder: JSONDecoder, repairTail: Bool) throws(StoreError)
    -> [Event]
  {
    let data: Data
    do { data = try Data(contentsOf: url) } catch {
      throw StoreError.io("read \(url.lastPathComponent): \(error.localizedDescription)")
    }
    var events: [Event] = []
    var lineStart = data.startIndex
    var goodEnd = data.startIndex
    while lineStart < data.endIndex {
      guard let newline = data[lineStart...].firstIndex(of: 0x0A) else {
        // No terminating newline: the last write was cut short. It was never
        // acknowledged, so it is dropped — but only at the very end of the log.
        guard repairTail else {
          throw StoreError.corrupt("\(url.lastPathComponent): unterminated line mid-log")
        }
        break
      }
      let line = data[lineStart..<newline]
      do {
        events.append(try decoder.decode(Event.self, from: line))
      } catch {
        let atEnd = newline == data.index(before: data.endIndex)
        guard repairTail, atEnd else {
          throw StoreError.corrupt("\(url.lastPathComponent): undecodable line")
        }
        break
      }
      goodEnd = data.index(after: newline)
      lineStart = goodEnd
    }
    if goodEnd < data.endIndex {
      guard truncate(url.path, off_t(goodEnd - data.startIndex)) == 0 else {
        throw StoreError.io("truncate torn tail of \(url.lastPathComponent): errno \(errno)")
      }
    }
    return events
  }

  mutating func persist(_ events: [Event], config: EventStore.Configuration) throws(StoreError) {
    if fd < 0 || (segments.last?.count ?? 0) >= config.segmentEvents {
      try roll(firstSeq: events[0].seq, config: config)
    }
    var bytes = Data()
    bytes.reserveCapacity(events.count * 160)
    do {
      for event in events {
        bytes.append(try encoder.encode(event))
        bytes.append(0x0A)
      }
    } catch {
      throw StoreError.io("encode: \(error.localizedDescription)")
    }
    let before = lseek(fd, 0, SEEK_END)
    let written = bytes.withUnsafeBytes { raw -> Bool in
      var offset = 0
      while offset < raw.count {
        let n = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
        if n < 0 {
          if errno == EINTR { continue }
          return false
        }
        offset += n
      }
      return true
    }
    guard written, !injectWriteFailure, sync(fd, config.durability) else {
      let failure = errno
      poisoned = true
      // Best effort: take the unacknowledged bytes back off the disk, so a
      // reopen never reads them as if they had been acknowledged.
      if before >= 0 { _ = ftruncate(fd, before) }
      throw StoreError.io("append failed: errno \(failure)")
    }
    segments[segments.count - 1].count += events.count
  }

  private mutating func roll(firstSeq: UInt64, config: EventStore.Configuration) throws(StoreError)
  {
    guard let directory else { return }
    closeFile()
    let name = String(format: "segment-%020llu.jsonl", firstSeq)
    let url = directory.appendingPathComponent(name)
    try openForAppend(url)
    segments.append(Segment(url: url, firstSeq: firstSeq, count: 0))
    syncDirectory(directory)
    // Age out whole segments once the newer ones alone cover retention.
    while segments.count > 1,
      segments.dropFirst().reduce(0, { $0 + $1.count }) >= retention
    {
      let old = segments.removeFirst()
      unlink(old.url.path)
    }
    syncDirectory(directory)
    stats.segmentsOnDisk = segments.count
  }

  private mutating func openForAppend(_ url: URL) throws(StoreError) {
    let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else {
      throw StoreError.io("open \(url.lastPathComponent): errno \(errno)")
    }
    fd = descriptor
  }

  mutating func closeFile() {
    if fd >= 0 {
      Darwin.close(fd)
      fd = -1
    }
  }

  private func sync(_ fd: Int32, _ durability: Durability) -> Bool {
    switch durability {
    case .none: return true
    case .fsync: return fsync(fd) == 0
    case .fullFsync:
      // Some file systems refuse F_FULLFSYNC; fsync is the honest fallback.
      return fcntl(fd, F_FULLFSYNC) == 0 || fsync(fd) == 0
    }
  }

  private func syncDirectory(_ directory: URL) {
    let dfd = Darwin.open(directory.path, O_RDONLY | O_CLOEXEC)
    guard dfd >= 0 else { return }
    _ = fsync(dfd)
    Darwin.close(dfd)
  }
}
