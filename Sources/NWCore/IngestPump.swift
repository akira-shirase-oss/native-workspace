import Foundation
import Synchronization

/// One store-acknowledged batch on its way to the main actor.
public struct PumpBatch: Sendable {
  /// Acknowledged events, with sequence numbers.
  public var accepted: [Event]
  /// The same events as display rows (built off the main actor).
  public var rows: [EventRow]
  public var duplicates: Int
  /// When the store acknowledged the batch.
  public var storedAt: Date
}

public struct PumpStats: Sendable, Equatable, Codable {
  public var flushes: UInt64 = 0
  public var batches: UInt64 = 0
  public var stored: UInt64 = 0
  public var duplicates: UInt64 = 0
  /// Events drained but not acknowledged because the store failed. Counted
  /// and shown, never hidden (the store is then poisoned and says so).
  public var notStored: UInt64 = 0
  public var storeError: String?
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
  public let store: EventStore
  public let interval: Duration
  public let maxBatch: Int
  private let sink: Sink
  private let requests: AsyncStream<Request>
  private let requester: AsyncStream<Request>.Continuation
  private let shared = Mutex(Shared())

  private enum Request: Sendable {
    case tick
    case flush(CheckedContinuation<Void, Never>)
  }

  private struct Shared {
    var task: Task<Void, Never>?
    var tickPending = false
    var stats = PumpStats()
  }

  public init(
    queue: IngestQueue, store: EventStore, interval: Duration = .milliseconds(100),
    maxBatch: Int = 10_000, sink: @escaping Sink
  ) {
    self.queue = queue
    self.store = store
    self.interval = interval
    self.maxBatch = maxBatch
    self.sink = sink
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

  private func drainAll() async {
    shared.withLock { $0.stats.flushes += 1 }
    while true {
      let drained = queue.drain(max: maxBatch)
      if drained.isEmpty { return }
      let result: AppendResult
      do {
        result = try store.append(drained)
      } catch {
        shared.withLock {
          $0.stats.notStored += UInt64(drained.count)
          $0.stats.storeError = "\(error)"
        }
        continue
      }
      let batch = PumpBatch(
        accepted: result.accepted, rows: result.accepted.map(EventRow.init),
        duplicates: result.duplicates, storedAt: Date())
      shared.withLock {
        $0.stats.batches += 1
        $0.stats.stored += UInt64(result.accepted.count)
        $0.stats.duplicates += UInt64(result.duplicates)
      }
      if !batch.accepted.isEmpty { await sink(batch) }
    }
  }
}
