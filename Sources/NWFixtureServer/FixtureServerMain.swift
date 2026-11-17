import Dispatch
import Foundation
import NWFixtures

/// `nw-fixture-server`: the local replay fixture server (D-022). It emulates
/// Service Monitor's read API on a loopback port so the app can be loaded
/// without ever making the paired service the load target.
///
///     NW_FIXTURE_TOKEN=<token> nw-fixture-server --port 60450 --monitors 20 \
///       --slot-interval 0.02 --burst-every 5 --burst-size 10000
///
/// `--slot-interval` is per monitor, so 20 monitors at 0.02 s is 1,000
/// events/s. The token comes from the environment, never argv.
@main
struct FixtureServerMain {
  static func main() async throws {
    var port: UInt16 = 60450
    var monitors = 20
    var slotInterval = 0.02
    var burstEvery = 0.0
    var burstSize = 10_000
    var args = Array(CommandLine.arguments.dropFirst())
    while !args.isEmpty {
      let flag = args.removeFirst()
      guard let value = args.first else { fail("missing value for \(flag)") }
      args.removeFirst()
      switch flag {
      case "--port": port = UInt16(value) ?? port
      case "--monitors": monitors = Int(value) ?? monitors
      case "--slot-interval": slotInterval = Double(value) ?? slotInterval
      case "--burst-every": burstEvery = Double(value) ?? burstEvery
      case "--burst-size": burstSize = Int(value) ?? burstSize
      default: fail("unknown flag \(flag)")
      }
    }
    guard let token = ProcessInfo.processInfo.environment["NW_FIXTURE_TOKEN"], token.count >= 32
    else { fail("NW_FIXTURE_TOKEN (at least 32 characters) is required") }
    let emulator = ServiceMonitorEmulator(
      .init(token: token, monitors: monitors, slotInterval: slotInterval))
    let server = FixtureHTTPServer(port: port) { emulator.handle($0) }
    // Handlers first, so a SIGTERM that arrives during startup still reports.
    for sig in [SIGINT, SIGTERM] {
      signal(sig, SIG_IGN)
      let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
      source.setEventHandler {
        let authorized = server.recorded.filter(\.authorized).count
        print(
          "nw-fixture-server stopping: \(server.requestCount) requests, "
            + "\(authorized) with Authorization, \(emulator.slotsGenerated) slots, "
            + "non-GET \(emulator.nonGETRequests)")
        exit(0)
      }
      source.resume()
      keep.append(source)
    }
    let bound = try await server.start()
    print("nw-fixture-server listening on 127.0.0.1:\(bound)")
    fflush(stdout)
    while true {
      if burstEvery > 0 {
        try await Task.sleep(for: .seconds(burstEvery))
        emulator.burst(burstSize)
      } else {
        try await Task.sleep(for: .seconds(3600))
      }
    }
  }

  nonisolated(unsafe) static var keep: [any DispatchSourceSignal] = []

  static func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("nw-fixture-server: \(message)\n".utf8))
    exit(2)
  }
}
