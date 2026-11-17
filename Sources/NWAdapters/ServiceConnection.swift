import Foundation
import NWCore
import Synchronization

/// Drives one adapter: bounded polling on a fixed cadence while healthy,
/// backoff with jitter while failing, and a full stop on 401. Every poll has
/// a deadline; a poll that misses it is a failure, not a wait.
///
/// The connection never decides what the user sees: it hands each tracker
/// state and snapshot to `onUpdate` (the main-actor status model), and the
/// view derives freshness from the tracker and the current time.
public final class ServiceConnection: Sendable {
  public typealias Update = @MainActor @Sendable (ConnectionTracker, ServiceSnapshot?) -> Void

  public let adapter: any ServiceAdapter
  public let queue: IngestQueue
  public let pump: IngestPump?
  /// Whole-poll deadline (all of a poll's requests together).
  public let pollDeadline: TimeInterval
  private let onUpdate: Update
  private let random: @Sendable () -> Double
  private let shared: Mutex<Shared>

  private struct Shared {
    var tracker: ConnectionTracker
    var task: Task<Void, Never>?
    var polls: UInt64 = 0
    var eventsOffered: UInt64 = 0
  }

  public init(
    adapter: any ServiceAdapter, queue: IngestQueue, pump: IngestPump?,
    tracker: ConnectionTracker = ConnectionTracker(), pollDeadline: TimeInterval = 1,
    random: @escaping @Sendable () -> Double = { Double.random(in: 0..<1) },
    onUpdate: @escaping Update
  ) {
    self.adapter = adapter
    self.queue = queue
    self.pump = pump
    self.pollDeadline = pollDeadline
    self.random = random
    self.onUpdate = onUpdate
    self.shared = Mutex(Shared(tracker: tracker))
  }

  public var tracker: ConnectionTracker { shared.withLock { $0.tracker } }
  public var polls: UInt64 { shared.withLock { $0.polls } }
  public var eventsOffered: UInt64 { shared.withLock { $0.eventsOffered } }
  public var isRunning: Bool { shared.withLock { $0.task != nil } }

  public func start() {
    shared.withLock { shared in
      guard shared.task == nil else { return }
      shared.task = Task.detached(priority: .utility) { [self] in await run() }
    }
  }

  public func stop() async {
    let task = shared.withLock { shared -> Task<Void, Never>? in
      defer { shared.task = nil }
      return shared.task
    }
    task?.cancel()
    await task?.value
  }

  private func run() async {
    let clock = ContinuousClock()
    while !Task.isCancelled {
      let startedAt = Date()
      let startedInstant = clock.now
      let result = await pollOnce(observedAt: startedAt)
      if Task.isCancelled { return }
      let (tracker, snapshot) = shared.withLock { shared -> (ConnectionTracker, ServiceSnapshot?) in
        shared.polls += 1
        switch result {
        case .success(let outcome):
          shared.tracker.recordSuccess(asOf: startedAt)
          shared.eventsOffered += UInt64(outcome.events.count)
          return (shared.tracker, outcome.snapshot)
        case .failure(let error):
          shared.tracker.recordFailure(error.pollFailure, at: Date())
          return (shared.tracker, nil)
        }
      }
      if case .success(let outcome) = result, !outcome.events.isEmpty {
        queue.offer(outcome.events)
        pump?.notify()
      }
      await onUpdate(tracker, snapshot)
      guard let delay = tracker.nextDelay(unit: random()) else { return }  // revoked: stop
      // Healthy: a fixed cadence measured from the poll's start. Failing:
      // backoff measured from now.
      let due: ContinuousClock.Instant =
        tracker.consecutiveFailures == 0
        ? startedInstant + .seconds(delay) : clock.now + .seconds(delay)
      do {
        try await Task.sleep(until: due, clock: clock)
      } catch {
        return
      }
    }
  }

  private func pollOnce(observedAt: Date) async -> Result<PollOutcome, AdapterError> {
    let adapter = self.adapter
    let deadline = pollDeadline
    return await withTaskGroup(of: Result<PollOutcome, AdapterError>?.self) { group in
      group.addTask {
        do throws(AdapterError) {
          return .success(try await adapter.poll(observedAt: observedAt))
        } catch {
          return .failure(error)
        }
      }
      group.addTask {
        try? await Task.sleep(for: .seconds(deadline))
        return Task.isCancelled ? nil : .failure(.transport(.timeout))
      }
      var outcome: Result<PollOutcome, AdapterError> = .failure(.transport(.cancelled))
      while let next = await group.next() {
        if let next {
          outcome = next
          break
        }
      }
      group.cancelAll()
      return outcome
    }
  }
}
