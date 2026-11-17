import Foundation
import NWCore
import Synchronization

/// Headless package replay (ROADMAP §N0 load scenario): N events through the
/// bounded ingest queue, the on-disk store and the main-actor event list
/// model, in 10,000-event bursts, with overload bursts that must drop into
/// gap markers and re-offered duplicates the store must refuse. Records
/// throughput, end-to-end latency (offered → visible in the model), the
/// main actor's per-batch work, main-thread stalls, peak memory and the
/// ledger, and fails on a ledger mismatch or a main-thread hang ≥ 250 ms.
@main
struct Replay {
  struct Options {
    var events = 1_000_000
    var burst = 10_000
    var rate = 20_000.0
    var overloadEvery = 10
    var duplicateEvery = 20
    var storeDirectory: URL?
    var durability: Durability = .fullFsync
    var output: URL?
    var commit = ProcessInfo.processInfo.environment["NW_COMMIT"] ?? "unknown"
    var note = ""
    var smoke = false

    static func parse(_ args: [String]) -> Options {
      var o = Options()
      var i = 0
      func value() -> String {
        i += 1
        guard i < args.count else {
          FileHandle.standardError.write(Data("missing value for \(args[i - 1])\n".utf8))
          exit(2)
        }
        return args[i]
      }
      while i < args.count {
        switch args[i] {
        case "--events": o.events = Int(value()) ?? o.events
        case "--burst": o.burst = Int(value()) ?? o.burst
        case "--rate": o.rate = Double(value()) ?? o.rate
        case "--overload-every": o.overloadEvery = Int(value()) ?? o.overloadEvery
        case "--duplicate-every": o.duplicateEvery = Int(value()) ?? o.duplicateEvery
        case "--store-dir": o.storeDirectory = URL(fileURLWithPath: value(), isDirectory: true)
        case "--durability": o.durability = Durability(rawValue: value()) ?? o.durability
        case "--out": o.output = URL(fileURLWithPath: value())
        case "--commit": o.commit = value()
        case "--note": o.note = value()
        case "--smoke":
          o.smoke = true
          o.events = 30_000
          o.burst = 2_000
          o.rate = 40_000
          o.overloadEvery = 5
          o.duplicateEvery = 2
        default:
          FileHandle.standardError.write(Data("unknown argument \(args[i])\n".utf8))
          exit(2)
        }
        i += 1
      }
      return o
    }
  }

  @MainActor
  final class Sink {
    let model = EventListModel(capacity: 10_000)
    var latency = LatencyHistogram()
    var applyMs = LatencyHistogram()
    var acknowledgedEvents = 0
    var gapCountSum: UInt64 = 0
    var gapRows = 0
    var lastSeq: UInt64 = 0
    var outOfOrder = 0

    func receive(_ batch: PumpBatch) {
      let clock = ContinuousClock()
      let started = clock.now
      model.apply(batch.rows)
      let elapsed = clock.now - started
      applyMs.record(
        Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000)
      let now = Date()
      for event in batch.accepted {
        if event.seq <= lastSeq { outOfOrder += 1 }
        lastSeq = event.seq
        if event.kind == .gap {
          gapRows += 1
          gapCountSum += event.gapCount ?? 0
        } else {
          acknowledgedEvents += 1
          latency.record(now.timeIntervalSince(event.observedAt) * 1000)
        }
      }
    }
  }

  static func main() async {
    let options = Options.parse(Array(CommandLine.arguments.dropFirst()))
    let machineAtStart = MachineSpec.current()
    let wallStart = Date()
    let directory =
      options.storeDirectory
      ?? FileManager.default.temporaryDirectory.appendingPathComponent(
        "nw-replay-\(UUID().uuidString)", isDirectory: true)
    let ownsDirectory = options.storeDirectory == nil
    defer { if ownsDirectory { try? FileManager.default.removeItem(at: directory) } }

    let store: EventStore
    do {
      store = try EventStore(
        .init(
          directory: directory, retention: 50_000, segmentEvents: 10_000,
          durability: options.durability))
    } catch {
      FileHandle.standardError.write(Data("store: \(error)\n".utf8))
      exit(1)
    }
    let queue = IngestQueue(capacity: 10_000)
    let sink = Sink()
    let pump = IngestPump(queue: queue, store: store, interval: .milliseconds(100)) { batch in
      sink.receive(batch)
    }
    let watchdog = MainThreadWatchdog(interval: 0.01, hangThreshold: 0.25)
    let peak = Mutex(MemoryProbe.read())
    let sampling = Mutex(true)
    let sampler = Thread {
      while sampling.withLock({ $0 }) {
        let reading = MemoryProbe.read()
        peak.withLock { p in
          p.footprintBytes = max(p.footprintBytes, reading.footprintBytes)
          p.residentBytes = max(p.residentBytes, reading.residentBytes)
          p.footprintPeakBytes = max(p.footprintPeakBytes, reading.footprintPeakBytes)
        }
        Thread.sleep(forTimeInterval: 0.05)
      }
    }
    sampler.start()
    watchdog.start()
    pump.start()

    // Producer, off the main actor.
    let producer = Task.detached(priority: .userInitiated) { () -> (offered: Int, unique: Int) in
      let clock = ContinuousClock()
      let begin = clock.now
      var sent = 0
      var offered = 0
      var burstIndex = 0
      while sent < options.events {
        burstIndex += 1
        var size = min(options.burst, options.events - sent)
        if options.overloadEvery > 0, burstIndex % options.overloadEvery == 0 {
          // Overload: more than the whole queue at once, so it must drop.
          size = min(queue.capacity + options.burst, options.events - sent)
        }
        let now = Date()
        if options.duplicateEvery > 0, burstIndex % options.duplicateEvery == 0, sent > 1_000 {
          // Already offered: the store must refuse every one that is admitted.
          let duplicates = ((sent - 1_000)..<sent).map { n in
            Event(
              service: n % 3 == 0 ? .durableRunner : .serviceMonitor, kind: .check,
              key: "replay:\(n)", occurredAt: now, observedAt: now, severity: .ok,
              text: "duplicate \(n)")
          }
          offered += duplicates.count
          queue.offer(duplicates, at: now)
        }
        var batch: [Event] = []
        batch.reserveCapacity(size)
        for n in sent..<(sent + size) {
          batch.append(
            Event(
              service: n % 3 == 0 ? .durableRunner : .serviceMonitor, kind: .check,
              key: "replay:\(n)", occurredAt: now, observedAt: now,
              severity: n % 7 == 6 ? .failure : .ok,
              text: n % 97 == 0 ? "\u{1B}[31mhostile\u{202E} line \(n)" : "replayed check \(n)"))
        }
        sent += size
        offered += batch.count
        queue.offer(batch, at: now)
        pump.notify()
        let due = begin + .seconds(Double(sent) / options.rate)
        if clock.now < due { try? await Task.sleep(until: due, clock: clock) }
      }
      return (offered, sent)
    }
    let produced = await producer.value
    await pump.flush()
    await pump.stop()
    let wall = Date().timeIntervalSince(wallStart)
    let hangs = watchdog.stop()
    sampling.withLock { $0 = false }
    let memory = peak.withLock { $0 }
    let q = queue.stats
    let p = pump.stats
    let s = store.stats
    store.close()

    // The ledger (END_GOAL failure case 2).
    var failures: [String] = []
    if q.offered != UInt64(produced.offered) {
      failures.append("offered \(q.offered) ≠ \(produced.offered)")
    }
    if q.offered != q.admitted + q.dropped { failures.append("offered ≠ admitted + dropped") }
    if sink.gapCountSum != q.dropped {
      failures.append("gap counts \(sink.gapCountSum) ≠ drops \(q.dropped)")
    }
    // A dropped event may itself be a re-offered duplicate, so the exact
    // identities are: offered = admitted + dropped, admitted = acknowledged +
    // refused duplicates, and offered − acknowledged = dropped + refused.
    let retained = UInt64(sink.acknowledgedEvents)
    if q.admitted != retained + p.duplicates {
      failures.append(
        "admitted \(q.admitted) ≠ acknowledged \(retained) + duplicates \(p.duplicates)")
    }
    if UInt64(produced.offered) - retained != q.dropped + p.duplicates {
      failures.append("offered − acknowledged ≠ dropped + duplicates refused")
    }
    if retained > UInt64(produced.unique) { failures.append("more acknowledged than unique sent") }
    if options.duplicateEvery > 0, p.duplicates == 0, options.events > 5 * options.burst {
      failures.append("no duplicate was refused")
    }
    if q.maxDepth > queue.capacity {
      failures.append("queue depth \(q.maxDepth) > \(queue.capacity)")
    }
    if sink.outOfOrder > 0 { failures.append("\(sink.outOfOrder) batches out of order") }
    if p.notStored > 0 {
      failures.append("\(p.notStored) events not stored: \(p.storeError ?? "")")
    }
    if hangs.hangs > 0 { failures.append("\(hangs.hangs) main-thread hangs ≥ 250 ms") }
    if q.dropped == 0, options.overloadEvery > 0 {
      failures.append("overload bursts dropped nothing")
    }

    let rowsInView = await MainActor.run { sink.model.rows.count }
    let latency = await MainActor.run { sink.latency.summary() }
    let apply = await MainActor.run { sink.applyMs.summary() }
    let gapRows = await MainActor.run { sink.gapRows }
    let gapSum = await MainActor.run { sink.gapCountSum }
    let result: [String: Any] = [
      "scenario": "headless package replay (store + view model)",
      "smoke": options.smoke,
      "note": options.note,
      "commit": options.commit,
      "date": ISO8601DateFormatter().string(from: wallStart),
      "machine": [
        "model": machineAtStart.model, "cpu": machineAtStart.cpu, "cores": machineAtStart.cores,
        "memory_bytes": machineAtStart.memoryBytes, "macos": machineAtStart.macOS,
        "load_average_at_start": machineAtStart.loadAverage,
        "load_average_at_end": MachineSpec.current().loadAverage,
      ],
      "build": buildDescription(),
      "toolchain": ProcessInfo.processInfo.environment["NW_TOOLCHAIN"] ?? "unrecorded",
      "config": [
        "events": options.events, "burst": options.burst, "offered_rate_per_s": options.rate,
        "overload_every": options.overloadEvery, "duplicate_every": options.duplicateEvery,
        "queue_capacity": queue.capacity, "store_retention": 50_000, "segment_events": 10_000,
        "view_rows": 10_000, "ui_batch_interval_ms": 100, "durability": options.durability.rawValue,
      ],
      "wall_seconds": wall,
      "throughput_acknowledged_per_s": Double(retained) / wall,
      "ledger": [
        "unique_events_sent": produced.unique, "offered_including_duplicates": produced.offered,
        "admitted": q.admitted, "dropped": q.dropped, "gap_markers": gapRows,
        "gap_count_sum": gapSum, "acknowledged_events": retained,
        "duplicates_refused": p.duplicates, "max_queue_depth": q.maxDepth,
        "store_batches": p.batches, "store_retained_at_end": s.retained,
        "store_evicted": s.evicted, "rows_in_view": rowsInView,
      ],
      "latency_offer_to_visible_ms": summary(latency),
      "main_actor_apply_ms": summary(apply),
      "main_thread": [
        "pings": hangs.pings, "hangs_ge_250ms": hangs.hangs,
        "stall_ms": summary(hangs.latencyMs),
      ],
      "memory_peak": [
        "footprint_bytes": memory.footprintBytes,
        "kernel_footprint_peak_bytes": memory.footprintPeakBytes,
        "resident_bytes": memory.residentBytes,
      ],
      "pass": failures.isEmpty,
      "failures": failures,
    ]
    let data =
      (try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]))
      ?? Data()
    if let output = options.output {
      try? data.write(to: output)
    }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
    exit(failures.isEmpty ? 0 : 1)
  }

  static func summary(_ s: LatencySummary) -> [String: Any] {
    ["count": s.count, "p50": s.p50, "p95": s.p95, "p99": s.p99, "max": s.max, "mean": s.mean]
  }

  static func buildDescription() -> String {
    #if DEBUG
      return "debug"
    #else
      return "release"
    #endif
  }
}
