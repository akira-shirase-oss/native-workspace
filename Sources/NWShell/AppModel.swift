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
  /// Which program may receive the Service Monitor token (D-015):
  /// `NW_SMON_EXPECT_EXECUTABLE` (and optionally `NW_SMON_EXPECT_CDHASH`),
  /// else the first listener seen is pinned for the session.
  public var serviceMonitorPin: ServerPin = .trustOnFirstUse
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
    if let executable = env["NW_SMON_EXPECT_EXECUTABLE"], !executable.isEmpty {
      config.serviceMonitorPin = .expected(
        ServerIdentity(executable: executable, cdhash: env["NW_SMON_EXPECT_CDHASH"]))
    }
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
  /// Inert: they quote URLs and errors that can carry service text.
  public private(set) var problems: [InertString] = []
  public private(set) var counters = IngestCounters()
  public private(set) var started = false
  /// Whether events are being recorded; shown in the window and on every
  /// service badge, never green while failed.
  public private(set) var recording = RecordingHealth.recording
  /// True while the store opens and the first rows are prepared, off the
  /// main actor; the window says "loading history".
  public private(set) var loadingHistory = false
  /// How long opening the store and preparing the first rows took.
  public private(set) var historyLoadMilliseconds: Double?

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

  /// Opens the store and prepares the first rows off the main actor — a
  /// full store is tens of thousands of lines to decode and 10,000 rows to
  /// format — then pairs the services. The main actor only assigns the
  /// prepared rows.
  public func start() async {
    guard !started else { return }
    started = true
    loadingHistory = true
    let config = configuration
    let queue = IngestQueue(capacity: config.queueCapacity)
    let clock = ContinuousClock()
    let began = clock.now
    let opened = await Task.detached(priority: .userInitiated) {
      () -> Result<(EventStore, [EventRow]), StoreError> in
      do throws(StoreError) {
        let store = try EventStore(
          .init(
            directory: config.storeDirectory, retention: config.retention,
            durability: config.durability))
        return .success((store, store.recent(config.viewRows).map(EventRow.init)))
      } catch {
        return .failure(error)
      }
    }.value
    loadingHistory = false
    let elapsed = clock.now - began
    historyLoadMilliseconds =
      Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
    let store: EventStore
    let previous: [EventRow]
    switch opened {
    case .success(let (opened, rows)):
      store = opened
      previous = rows
    case .failure(let error):
      problem("Event store unavailable (\(error)); events are not being kept.")
      return
    }
    self.queue = queue
    self.store = store
    let storeConfig = store.configuration
    let recovery = StoreRecovery { () throws(StoreError) -> EventStore in
      try EventStore(storeConfig, freshSegment: true)
    }
    let pump = IngestPump(queue: queue, store: store, recovery: recovery) { [weak self] batch in
      guard let self else { return }
      if self.recordAcknowledged { self.acknowledged += batch.accepted.map(\.identity) }
      self.events.apply(batch.rows)
      self.recording = batch.recording
      self.refreshCounters()
    }
    self.pump = pump
    pump.start()
    // Rows already on disk come back into view at launch (prepared above).
    events.apply(previous)
    refreshCounters()

    let transport = BoundedURLSessionTransport(limits: config.transport)
    var adapters: [any ServiceAdapter] = []
    if let url = config.serviceMonitorURL {
      do {
        let token = try credentials.token(account: ServiceID.serviceMonitor.rawValue)
        // Exploration-only pairing (D-015): a token taken from the environment
        // does not stay there once read. The app spawns no processes, but
        // nothing else in it should find the variable either. N1 pairs through
        // the Keychain and drops the environment source.
        unsetenv("NW_SMON_TOKEN")
        if token == nil {
          problem("Service Monitor at \(url.absoluteString): no token paired.")
        }
        var limits = ServiceMonitorAdapter.Limits()
        limits.checksPerMonitor = config.checksPerMonitor
        adapters.append(
          try ServiceMonitorAdapter(
            endpoint: url, token: token, transport: transport, limits: limits,
            pin: config.serviceMonitorPin))
      } catch {
        problem("Service Monitor at \(url.absoluteString) refused: \(error)")
      }
    }
    if let url = config.durableRunnerURL {
      do {
        adapters.append(try DurableRunnerAdapter(endpoint: url, transport: transport))
      } catch {
        problem("Durable Runner at \(url.absoluteString) refused: \(error)")
      }
    }
    if adapters.isEmpty, problems.isEmpty {
      problem(
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
    (pump?.store ?? store)?.close()
    refreshCounters()
  }

  /// Stop and start one service's polling (the user's "reconnect").
  public func service(_ id: ServiceID) -> ServiceStatusModel? {
    services.first { $0.id == id }
  }

  /// Flush queued events through the store into the view (tests).
  public func flush() async { await pump?.flush() }

  public func storedIdentities() -> [EventIdentity] {
    (pump?.store ?? store)?.recent(Int.max).map(\.identity) ?? []
  }

  /// Test seam: the next store write fails as an I/O error would.
  func injectStoreFailureForTesting() { (pump?.store ?? store)?.injectWriteFailureForTesting() }

  private func problem(_ text: String) {
    problems.append(InertString(text, maxScalars: 512))
  }

  private func refreshCounters() {
    counters = IngestCounters(
      queue: queue?.stats ?? IngestStats(), store: (pump?.store ?? store)?.stats ?? StoreStats(),
      pump: pump?.stats ?? PumpStats())
  }
}
