import AppKit
import Foundation
import NWCore

/// Measurement mode (`NW_MEASURE_SECONDS`): the running app watches its own
/// main thread, waits, writes a report and quits. Instruments' Hangs track
/// records the same window when the app is launched under `xctrace`; this
/// report is the development observation committed next to it.
@MainActor
public final class MeasurementSession {
  public struct Report: Codable, Sendable {
    public var seconds: Double
    public var eventList: String
    public var launchToFirstTaskMs: Double?
    public var watchdog: MainThreadWatchdog.Report
    public var memory: MemoryProbe.Reading
    public var counters: Counters
    public var services: [ServiceLine]
    public var machine: MachineSpec
    public var cpuSeconds: Double

    public struct Counters: Codable, Sendable {
      public var queue: IngestStats
      public var store: StoreStats
      public var pump: PumpStats
      public var rowsInView: Int
      public var rowsTrimmed: UInt64
      public var droppedShownInGapRows: UInt64
    }

    public struct ServiceLine: Codable, Sendable {
      public var id: String
      public var freshness: String
      public var polls: UInt64
    }
  }

  private let watchdog = MainThreadWatchdog()
  private let model: AppModel
  private let seconds: Double
  private let output: URL?
  private let launchedAt: Date

  public init(model: AppModel, seconds: Double, output: URL?, launchedAt: Date) {
    self.model = model
    self.seconds = seconds
    self.output = output
    self.launchedAt = launchedAt
  }

  public func run(firstTaskAt: Date?) async {
    watchdog.start()
    try? await Task.sleep(for: .seconds(seconds))
    let report = watchdog.stop()
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    let cpu =
      Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
      + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
    let counters = model.counters
    let full = Report(
      seconds: seconds, eventList: model.configuration.eventList.rawValue,
      launchToFirstTaskMs: firstTaskAt.map { $0.timeIntervalSince(launchedAt) * 1000 },
      watchdog: report, memory: MemoryProbe.read(),
      counters: .init(
        queue: counters.queue, store: counters.store, pump: counters.pump,
        rowsInView: model.events.rows.count, rowsTrimmed: model.events.trimmed,
        droppedShownInGapRows: model.events.droppedShown),
      services: model.services.map {
        .init(id: $0.id.rawValue, freshness: $0.freshness().label, polls: $0.polls)
      },
      machine: .current(), cpuSeconds: cpu)
    if let output {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      encoder.dateEncodingStrategy = .iso8601
      if let data = try? encoder.encode(full) { try? data.write(to: output) }
    }
    await model.stop()
    NSApplication.shared.terminate(nil)
  }
}
