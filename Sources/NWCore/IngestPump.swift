import Foundation
import Synchronization

/// Whether events are being recorded. Not recording is a displayed state,
/// never green (AGENTS invariant 5: silent loss that looks complete is a
/// defect).
public enum RecordingHealth: Sendable, Equatable {
  case recording
  /// The store failed at `since`; `unrecorded` events since then reached the
  /// view only as gap rows.
  case failed(since: Date, reason: InertString, unrecorded: UInt64)

  public var isRecording: Bool {
    if case .recording = self { return true }
    return false
  }
}

/// How the pump gets a working store back after a failure: reopen (a fresh
/// segment, never the bytes whose write or sync failed) with backoff.
public struct StoreRecovery: Sendable {
  public var initialDelay: Duration
  public var maxDelay: Duration
  public var reopen: @Sendable () throws(StoreError) -> EventStore

  public init(
    initialDelay: Duration = .seconds(1), maxDelay: Duration = .seconds(30),
    reopen: @escaping @Sendable () throws(StoreError) -> EventStore
  ) {
    self.initialDelay = initialDelay
    self.maxDelay = maxDelay
    self.reopen = reopen
  }
}

/// One batch on its way to the main actor: acknowledged events, or — when
/// the store has failed — a gap row for the events that were not recorded.
public struct PumpBatch: Sendable {
  /// Acknowledged events, with sequence numbers.
  public var accepted: [Event]
  /// Display rows (built off the main actor): the accepted events, or one
  /// unstored gap row whose count is the events lost to the store.
  public var rows: [EventRow]
  public var duplicates: Int
  /// When the batch left the pump.
  public var storedAt: Date
  public var recording: RecordingHealth
}

public struct PumpStats: Sendable, Equatable, Codable {
  public var flushes: UInt64 = 0
  public var batches: UInt64 = 0
  public var stored: UInt64 = 0
  public var duplicates: UInt64 = 0
  /// Events drained but not acknowledged because the store failed. Each
  /// one is in a gap row the view shows; the sum of those rows' counts is
  /// this number.
  public var notStored: UInt64 = 0
  public var storeError: String?
  /// Times the pump got a working store back without a restart.
  public var recoveries: UInt64 = 0

  public init() {}
}

/// Moves events from the bounded ingest queue into the store and then, as
/// one batch per flush, onto the main actor. Queue, disk and formatting work
/// all happen here, off the main actor.
///
/// One task does every flush, so batches reach the sink in sequence order.
/// Flushes are coalesced to at most one per `interval` (D-021: 100 ms), and
/// none happen while nothing arrives — an idle app does not wake up to poll
/// its own queue.
public final class IngestPump: Sendable {
  public typealias Sink = @MainActor @Sendable (PumpBatch) -> Void

  public let queue: IngestQueue
  public let interval: Duration
  public let maxBatch: Int
  private let recovery: StoreRecovery?
  private let sink: Sink
  private let requests: AsyncStream<Request>
  private let requester: AsyncStream<Request>.Continuation
  private let shared: Mutex<Shared>

  private enum Request: Sendable {
    case tick
    case flush(CheckedContinuation<Void, Never>)
  }

  private struct Shared {
    var task: Task<Void, Never>?
    var tickPending = false
    var stats = PumpStats()
    var store: EventStore
    var health = RecordingHealth.recording
    var nextRecovery = ContinuousClock.now
    var recoveryDelay = Duration.zero
    /// Ids for unstored gap rows, counting down from the top so they can
    /// never meet a store sequence number.
    var unstoredID = UInt64.max
  }

  public init(
    queue: IngestQueue, store: EventStore, interval: Duration = .milliseconds(100),
    maxBatch: Int = 10_000, recovery: StoreRecovery? = nil, sink: @escaping Sink
  ) {
    self.queue = queue
    self.interval = interval
    self.maxBatch = maxBatch
    self.recovery = recovery
    self.sink = sink
    self.shared = Mutex(Shared(store: store))
    (requests, requester) = AsyncStream.makeStream(of: Request.self)
  }

  public func start() {
    shared.withLock { shared in
      guard shared.task == nil else { return }
      shared.task = Task.detached(priority: .userInitiated) { [self] in
        let clock = ContinuousClock()
        var last = clock.now - interval
        for await request in requests {
          switch request {
          case .tick:
            let due = last + interval
            if clock.now < due { try? await Task.sleep(until: due, clock: clock) }
            self.shared.withLock { $0.tickPending = false }
            await drainAll()
            last = clock.now
          case .flush(let done):
            await drainAll()
            last = clock.now
            done.resume()
          }
        }
        await drainAll()
      }
    }
  }

  /// Tell the pump that events were offered. Cheap; coalesced to one
  /// pending tick.
  public func notify() {
    let send = shared.withLock { shared -> Bool in
      if shared.tickPending { return false }
      shared.tickPending = true
      return true
    }
    if send { requester.yield(.tick) }
  }

  /// Deliver everything queued now and wait until the sink has it (tests,
  /// the replay, shutdown). Requires `start()`.
  public func flush() async {
    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
      if case .terminated = requester.yield(.flush(done)) { done.resume() }
    }
  }

  /// Finish pending requests, flush once more, and end the pump task.
  public func stop() async {
    requester.finish()
    let task = shared.withLock { $0.task }
    await task?.value
  }

  public var stats: PumpStats { shared.withLock { $0.stats } }

  /// The store in use now (a recovery replaces it).
  public var store: EventStore { shared.withLock { $0.store } }

  public var recording: RecordingHealth { shared.withLock { $0.health } }

  private func drainAll() async {
    shared.withLock { $0.stats.flushes += 1 }
    if recoverIfDue() {
      // Tell the view at once, even when nothing is waiting to be stored.
      await sink(
        PumpBatch(accepted: [], rows: [], duplicates: 0, storedAt: Date(), recording: .recording))
    }
    while true {
      let drained = queue.drain(max: maxBatch)
      if drained.isEmpty { return }
      let (store, failed) = shared.withLock { s in (s.store, !s.health.isRecording) }
      if failed {
        await deliverLoss(drained, error: nil)
        continue
      }
      let result: AppendResult
      do {
        result = try store.append(drained)
      } catch {
        await deliverLoss(drained, error: error)
        continue
      }
      let health = shared.withLock { s -> RecordingHealth in
        s.stats.batches += 1
        s.stats.stored += UInt64(result.accepted.count)
        s.stats.duplicates += UInt64(result.duplicates)
        return s.health
      }
      if !result.accepted.isEmpty {
        await sink(
          PumpBatch(
            accepted: result.accepted, rows: result.accepted.map(EventRow.init),
            duplicates: result.duplicates, storedAt: Date(), recording: health))
      }
    }
  }

  /// The store failed (now, or earlier and not yet recovered): the drained
  /// events are not recorded, and the view gets one unstored gap row that
  /// says so, with their count — the loss is shown, never silent.
  private func deliverLoss(_ drained: [Event], error: StoreError?) async {
    let lost = drained.reduce(UInt64(0)) { $0 + ($1.kind == .gap ? ($1.gapCount ?? 0) : 1) }
    let now = Date()
    let (health, id) = shared.withLock { s -> (RecordingHealth, UInt64) in
      s.stats.notStored += lost
      if let error {
        s.stats.storeError = "\(error)"
        s.health = .failed(
          since: now, reason: InertString("\(error)", maxScalars: 256), unrecorded: lost)
        s.recoveryDelay = recovery?.initialDelay ?? .zero
        s.nextRecovery = ContinuousClock.now + s.recoveryDelay
        scheduleRecovery(at: s.nextRecovery)
      } else if case .failed(let since, let reason, let unrecorded) = s.health {
        s.health = .failed(since: since, reason: reason, unrecorded: unrecorded + lost)
      }
      s.unstoredID -= 1
      return (s.health, s.unstoredID + 1)
    }
    guard lost > 0 else { return }
    let reason: String
    if case .failed(_, let why, _) = health { reason = why.value } else { reason = "store failed" }
    var gap = Event(
      service: .ingest, kind: .gap, key: "gap:unrecorded:\(UUID().uuidString)",
      occurredAt: drained.first?.observedAt ?? now, observedAt: now, severity: .failure,
      text: "\(lost) events not recorded: the event store failed (\(reason))", gapCount: lost,
      gapEnd: now)
    gap.seq = id
    await sink(
      PumpBatch(
        accepted: [], rows: [EventRow(gap)], duplicates: 0, storedAt: now, recording: health))
  }

  /// Reopen onto a fresh segment when the backoff allows; double the delay
  /// (to `maxDelay`) when that fails too. Returns whether it recovered.
  private func recoverIfDue() -> Bool {
    guard let recovery else { return false }
    let due = shared.withLock { s in !s.health.isRecording && ContinuousClock.now >= s.nextRecovery
    }
    guard due else { return false }
    do {
      let fresh = try recovery.reopen()
      let old = shared.withLock { s -> EventStore in
        let old = s.store
        s.store = fresh
        s.health = .recording
        s.stats.recoveries += 1
        return old
      }
      old.close()
      return true
    } catch {
      shared.withLock { s in
        s.stats.storeError = "\(error)"
        s.recoveryDelay = min(recovery.maxDelay, max(recovery.initialDelay, s.recoveryDelay * 2))
        s.nextRecovery = ContinuousClock.now + s.recoveryDelay
        scheduleRecovery(at: s.nextRecovery)
      }
      return false
    }
  }

  /// Recovery is attempted on schedule, not only when the next event
  /// arrives, so "not recording" clears as soon as the store works again.
  private func scheduleRecovery(at due: ContinuousClock.Instant) {
    Task.detached(priority: .utility) { [weak self] in
      try? await Task.sleep(until: due, clock: .continuous)
      self?.notify()
    }
  }
}
