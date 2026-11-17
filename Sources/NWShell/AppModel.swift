import Foundation
import NWAdapters
import NWCore
import NWCredentials
import Observation

/// Everything the shell needs to run, read once at launch. The process
/// environment is the exploration's pairing mechanism (D-015: a loopback
/// Service Monitor and its admin token); the pairing UI and Keychain-backed
/// pairing are N1.
public struct AppConfiguration: Sendable {
  public var serviceMonitorURL: URL?
  public var durableRunnerURL: URL?
  public var storeDirectory: URL?
  public var pollInterval: TimeInterval = 2
  public var grace: TimeInterval = 1
  public var backoff: Backoff = .contract
  public var pollDeadline: TimeInterval = 1
  public var transport: TransportLimits = .standard
  public var checksPerMonitor = 50
  public var queueCapacity = 10_000
  public var retention = 50_000
  public var viewRows = 10_000
  public var durability: Durability = .fullFsync
  /// Measurement mode: run this long, write the report, quit.
  public var measureSeconds: Double?
  public var measureOutput: URL?
  /// Which event list the window draws. `.table` (AppKit, the default) only
  /// builds visible rows; `.swiftUIList` is the version the profiling drill
  /// caught stalling the main thread for over a minute with 10,000 rows,
  /// kept so the drill can be reproduced (`NW_EVENT_LIST=swiftui-list`).
  public var eventList: EventListKind = .table

  public init() {}

  /// `NW_SMON_URL`, `NW_SMON_TOKEN` (or the Keychain item), `NW_DURABLE_URL`,
  /// `NW_STORE_DIR`, `NW_SMON_CHECKS_PER_MONITOR`, `NW_POLL_INTERVAL_S`, `NW_POLL_DEADLINE_S`,
  /// `NW_MEASURE_SECONDS`, `NW_MEASURE_OUT`, `NW_EVENT_LIST=swiftui-list`.
  public static func fromEnvironment(
    _ env: [String: String] = ProcessInfo.processInfo.environment
  ) -> AppConfiguration {
    var config = AppConfiguration()
    config.serviceMonitorURL = env["NW_SMON_URL"].flatMap(URL.init(string:))
    config.durableRunnerURL = env["NW_DURABLE_URL"].flatMap(URL.init(string:))
    if let dir = env["NW_STORE_DIR"] {
      config.storeDirectory = URL(fileURLWithPath: dir, isDirectory: true)
    } else if let support = FileManager.default.urls(
      for: .applicationSupportDirectory, in: .userDomainMask
    ).first {
      config.storeDirectory = support.appendingPathComponent(
        "NativeWorkspace/events", isDirectory: true)
    }
    if let n = env["NW_SMON_CHECKS_PER_MONITOR"].flatMap(Int.init) {
      config.checksPerMonitor = max(1, min(n, 500))
    }
    if let s = env["NW_POLL_INTERVAL_S"].flatMap(Double.init), s >= 0.1 {
      config.pollInterval = s
    }
    // Freshness is derived from time, so a longer deadline never delays the
    // stale label; it only lets a slow poll finish. Bounded either way.
    if let s = env["NW_POLL_DEADLINE_S"].flatMap(Double.init), (0.2...10).contains(s) {
      config.pollDeadline = s
      config.transport.deadline = s
      config.transport.idleTimeout = s
    }
    config.measureSeconds = env["NW_MEASURE_SECONDS"].flatMap(Double.init)
    config.measureOutput = env["NW_MEASURE_OUT"].map { URL(fileURLWithPath: $0) }
    config.eventList = env["NW_EVENT_LIST"] == "swiftui-list" ? .swiftUIList : .table
    return config
  }
}

public enum EventListKind: String, Sendable, Codable {
  case table
  case swiftUIList = "swiftui-list"
}

/// Counters the footer shows, refreshed once per batch.
public struct IngestCounters: Sendable, Equatable {
  public var queue = IngestStats()
  public var store = StoreStats()
  public var pump = PumpStats()
}

/// The shell's root model: one bounded pipeline (queue → store → event
/// list) shared by every paired service, one connection per service.
@MainActor
@Observable
public final class AppModel {
  public let configuration: AppConfiguration
  public private(set) var services: [ServiceStatusModel] = []
  public let events: EventListModel
  /// Pairing or storage problems, shown in the window — never only logged.
  public private(set) var problems: [String] = []
  public private(set) var counters = IngestCounters()
  public private(set) var started = false

  @ObservationIgnored private let credentials: any CredentialSource
  @ObservationIgnored private var queue: IngestQueue?
  @ObservationIgnored private var store: EventStore?
  @ObservationIgnored private var pump: IngestPump?
  @ObservationIgnored private var connections: [ServiceConnection] = []
  @ObservationIgnored public private(set) var acknowledged: [EventIdentity] = []
  @ObservationIgnored public var recordAcknowledged = false

  public init(
    configuration: AppConfiguration,
    credentials: any CredentialSource = ChainedCredentials([
      KeychainCredentials(),
      EnvironmentCredentials(variables: [ServiceID.serviceMonitor.rawValue: "NW_SMON_TOKEN"]),
    ])
  ) {
    self.configuration = configuration
    self.credentials = credentials
    self.events = EventListModel(capacity: configuration.viewRows)
  }

  public func start() {
    guard !started else { return }
    started = true
    let config = configuration
    let queue = IngestQueue(capacity: config.queueCapacity)
    let store: EventStore
    do {
      store = try EventStore(
        .init(
          directory: config.storeDirectory, retention: config.retention,
          durability: config.durability))
    } catch {
      problems.append("Event store unavailable (\(error)); events are not being kept.")
      return
    }
    self.queue = queue
    self.store = store
    let pump = IngestPump(queue: queue, store: store) { [weak self] batch in
      guard let self else { return }
      if self.recordAcknowledged { self.acknowledged += batch.accepted.map(\.identity) }
      self.events.apply(batch.rows)
      self.refreshCounters()
    }
    self.pump = pump
    pump.start()
    // Rows already on disk come back into view at launch.
    let previous = store.recent(config.viewRows).map(EventRow.init)
    events.apply(previous)
    refreshCounters()

    let transport = BoundedURLSessionTransport(limits: config.transport)
    var adapters: [any ServiceAdapter] = []
    if let url = config.serviceMonitorURL {
      do {
        let token = try credentials.token(account: ServiceID.serviceMonitor.rawValue)
        if token == nil {
          problems.append("Service Monitor at \(url.absoluteString): no token paired.")
        }
        var limits = ServiceMonitorAdapter.Limits()
        limits.checksPerMonitor = config.checksPerMonitor
        adapters.append(
          try ServiceMonitorAdapter(
            endpoint: url, token: token, transport: transport, limits: limits))
      } catch {
        problems.append("Service Monitor at \(url.absoluteString) refused: \(error)")
      }
    }
    if let url = config.durableRunnerURL {
      do {
        adapters.append(try DurableRunnerAdapter(endpoint: url, transport: transport))
      } catch {
        problems.append("Durable Runner at \(url.absoluteString) refused: \(error)")
      }
    }
    if adapters.isEmpty, problems.isEmpty {
      problems.append(
        "No service paired. Set NW_SMON_URL (loopback) and NW_SMON_TOKEN, or NW_DURABLE_URL.")
    }
    for adapter in adapters {
      let tracker = ConnectionTracker(
        pollInterval: config.pollInterval, grace: config.grace, backoff: config.backoff)
      let status = ServiceStatusModel(
        id: adapter.id, name: adapter.displayName, endpoint: adapter.endpoint.absoluteString,
        tracker: tracker)
      services.append(status)
      let connection = ServiceConnection(
        adapter: adapter, queue: queue, pump: pump, tracker: tracker,
        pollDeadline: config.pollDeadline
      ) { tracker, snapshot in
        status.update(tracker: tracker, snapshot: snapshot)
      }
      connections.append(connection)
      connection.start()
    }
  }

  public func stop() async {
    for connection in connections { await connection.stop() }
    await pump?.flush()
    await pump?.stop()
    store?.close()
    refreshCounters()
  }

  /// Stop and start one service's polling (the user's "reconnect").
  public func service(_ id: ServiceID) -> ServiceStatusModel? {
    services.first { $0.id == id }
  }

  /// Flush queued events through the store into the view (tests).
  public func flush() async { await pump?.flush() }

  public func storedIdentities() -> [EventIdentity] {
    store?.recent(Int.max).map(\.identity) ?? []
  }

  private func refreshCounters() {
    counters = IngestCounters(
      queue: queue?.stats ?? IngestStats(), store: store?.stats ?? StoreStats(),
      pump: pump?.stats ?? PumpStats())
  }
}
