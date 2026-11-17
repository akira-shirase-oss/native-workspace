import Darwin
import Dispatch
import Foundation
import Synchronization

/// Percentiles over recorded samples (nearest-rank on a sorted copy).
public struct LatencySummary: Sendable, Codable, Equatable {
  public var count: Int
  public var p50: Double
  public var p95: Double
  public var p99: Double
  public var max: Double
  public var mean: Double

  public init(_ samples: [Double]) {
    count = samples.count
    guard !samples.isEmpty else {
      p50 = 0
      p95 = 0
      p99 = 0
      max = 0
      mean = 0
      return
    }
    let sorted = samples.sorted()
    func rank(_ p: Double) -> Double {
      let index = Int((p * Double(sorted.count)).rounded(.up)) - 1
      return sorted[Swift.min(Swift.max(index, 0), sorted.count - 1)]
    }
    p50 = rank(0.50)
    p95 = rank(0.95)
    p99 = rank(0.99)
    max = sorted[sorted.count - 1]
    mean = sorted.reduce(0, +) / Double(sorted.count)
  }
}

/// A fixed-size latency histogram (0.1 ms buckets up to 1 s, then exact
/// values for at most 10,000 outliers): bounded memory however long it runs.
/// Percentiles report a bucket's upper edge, so they never flatter.
public struct LatencyHistogram: Sendable, Equatable {
  public static let bucketMs = 0.1
  public static let buckets = 10_000
  private var counts = [UInt32](repeating: 0, count: LatencyHistogram.buckets)
  private var outliers: [Double] = []
  public private(set) var count = 0
  public private(set) var maxMs = 0.0
  private var sumMs = 0.0
  /// Outliers beyond the cap are still counted and still raise `maxMs`.
  public private(set) var outliersDropped = 0

  public init() {}

  public mutating func record(_ ms: Double) {
    count += 1
    sumMs += ms
    maxMs = Swift.max(maxMs, ms)
    let index = Int(ms / Self.bucketMs)
    if index < Self.buckets {
      counts[Swift.max(index, 0)] += 1
    } else if outliers.count < 10_000 {
      outliers.append(ms)
    } else {
      outliersDropped += 1
    }
  }

  public func percentile(_ p: Double) -> Double {
    guard count > 0 else { return 0 }
    let target = Swift.max(1, Int((p * Double(count)).rounded(.up)))
    var seen = 0
    for (index, n) in counts.enumerated() where n > 0 {
      seen += Int(n)
      if seen >= target { return Double(index + 1) * Self.bucketMs }
    }
    let sorted = outliers.sorted()
    let rest = target - seen - 1
    if rest < sorted.count { return sorted[Swift.max(rest, 0)] }
    return maxMs
  }

  public func summary() -> LatencySummary {
    var summary = LatencySummary([])
    summary.count = count
    guard count > 0 else { return summary }
    summary.p50 = percentile(0.50)
    summary.p95 = percentile(0.95)
    summary.p99 = percentile(0.99)
    summary.max = maxMs
    summary.mean = sumMs / Double(count)
    return summary
  }
}

/// Process memory, from the kernel's own accounting.
public enum MemoryProbe {
  public struct Reading: Sendable, Codable, Equatable {
    /// What Activity Monitor calls "Memory" (phys_footprint).
    public var footprintBytes: UInt64
    /// The kernel's lifetime peak of the footprint.
    public var footprintPeakBytes: UInt64
    public var residentBytes: UInt64
  }

  public static func read() -> Reading {
    var vm = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
      MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &vm) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }
    guard kr == KERN_SUCCESS else {
      return Reading(footprintBytes: 0, footprintPeakBytes: 0, residentBytes: 0)
    }
    return Reading(
      footprintBytes: vm.phys_footprint,
      footprintPeakBytes: UInt64(vm.ledger_phys_footprint_peak),
      residentBytes: vm.resident_size)
  }
}

/// Measures main-thread responsiveness from outside it: a background thread
/// posts a no-op to the main queue every `interval` and records how long the
/// main thread took to run it. A stall of `hangThreshold` (250 ms, D-021) or
/// more is a hang. This is a development observation alongside Instruments'
/// Hangs instrument, not a replacement for it.
public final class MainThreadWatchdog: Sendable {
  public struct Report: Sendable, Codable, Equatable {
    public var pings: Int
    public var hangs: Int
    public var hangThresholdMs: Double
    public var latencyMs: LatencySummary
  }

  public let interval: TimeInterval
  public let hangThreshold: TimeInterval
  private let state = Mutex(State())

  private struct State {
    var running = false
    var histogram = LatencyHistogram()
    var hangs = 0
  }

  public init(interval: TimeInterval = 0.01, hangThreshold: TimeInterval = 0.25) {
    self.interval = interval
    self.hangThreshold = hangThreshold
  }

  public func start() {
    let begin = state.withLock { s -> Bool in
      if s.running { return false }
      s.running = true
      return true
    }
    guard begin else { return }
    let thread = Thread { [self] in
      while state.withLock({ $0.running }) {
        let posted = DispatchTime.now().uptimeNanoseconds
        let answered = DispatchSemaphore(value: 0)
        DispatchQueue.main.async { [self] in
          let ms = Double(DispatchTime.now().uptimeNanoseconds - posted) / 1_000_000
          state.withLock { s in
            s.histogram.record(ms)
            if ms >= hangThreshold * 1000 { s.hangs += 1 }
          }
          answered.signal()
        }
        answered.wait()
        Thread.sleep(forTimeInterval: interval)
      }
    }
    thread.name = "nw.main-thread-watchdog"
    thread.qualityOfService = .userInteractive
    thread.start()
  }

  public func stop() -> Report {
    state.withLock { s in
      s.running = false
      return Report(
        pings: s.histogram.count, hangs: s.hangs, hangThresholdMs: hangThreshold * 1000,
        latencyMs: s.histogram.summary())
    }
  }

  public func snapshot() -> Report {
    state.withLock { s in
      Report(
        pings: s.histogram.count, hangs: s.hangs, hangThresholdMs: hangThreshold * 1000,
        latencyMs: s.histogram.summary())
    }
  }
}

/// The machine a measurement ran on: every result records it (AGENTS §8).
public struct MachineSpec: Sendable, Codable, Equatable {
  public var model: String
  public var cpu: String
  public var cores: Int
  public var memoryBytes: UInt64
  public var macOS: String
  public var loadAverage: [Double]

  public static func current() -> MachineSpec {
    func sysctlString(_ name: String) -> String {
      var size = 0
      guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
      var buffer = [CChar](repeating: 0, count: size)
      guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return "unknown" }
      return String(
        decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
    var loads = [Double](repeating: 0, count: 3)
    let got = getloadavg(&loads, 3)
    return MachineSpec(
      model: sysctlString("hw.model"),
      cpu: sysctlString("machdep.cpu.brand_string"),
      cores: ProcessInfo.processInfo.processorCount,
      memoryBytes: ProcessInfo.processInfo.physicalMemory,
      macOS: ProcessInfo.processInfo.operatingSystemVersionString,
      loadAverage: got == 3 ? loads : [])
  }
}
