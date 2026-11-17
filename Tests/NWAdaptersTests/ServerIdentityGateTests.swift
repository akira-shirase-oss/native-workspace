import Darwin
import Foundation
import NWCore
import NWCredentials
import NWFixtures
import Synchronization
import XCTest

@testable import NWAdapters

final class ServerIdentityGateTests: XCTestCase {
  func ownExecutable() -> String {
    var path = [CChar](repeating: 0, count: 4096)
    _ = proc_pidpath(getpid(), &path, 4096)
    return String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
  }

  func testLibprocFindsTheProcessThatOwnsTheListeningSocket() async throws {
    let server = FixtureHTTPServer { _ in .json(200, [:]) }
    let port = try await server.start()
    let identifier = LibprocListenerIdentifier()
    let found = identifier.identify(port: port)
    XCTAssertEqual(found?.pid, getpid())
    XCTAssertEqual(found?.identity.executable, ownExecutable())
    let start = try XCTUnwrap(identifier.startTime(of: getpid()))
    XCTAssertTrue(identifier.stillListening(pid: getpid(), startTime: start, port: port))
    await server.stop()
    XCTAssertNil(identifier.identify(port: port), "nobody listens after a stop")
    XCTAssertFalse(identifier.stillListening(pid: getpid(), startTime: start, port: port))
  }

  final class Current: Sendable {
    let value = Mutex<ServerIdentity?>(nil)
    func set(_ identity: ServerIdentity?) { value.withLock { $0 = identity } }
  }

  struct Fake: ListenerIdentifying {
    let current: Current
    func identify(port: UInt16) -> (pid: pid_t, identity: ServerIdentity)? {
      current.value.withLock { $0 }.map { (pid: 4242, identity: $0) }
    }
    func stillListening(pid: pid_t, startTime: UInt64, port: UInt16) -> Bool { false }
    func startTime(of pid: pid_t) -> UInt64? { 1 }
  }

  func testTrustOnFirstUsePinsTheFirstListenerAndRefusesAnotherOne() throws {
    let real = ServerIdentity(executable: "/opt/smon/bin/monitor-server", cdhash: "aa")
    let current = Current()
    current.set(real)
    let gate = ServerIdentityGate(
      port: 60410, pin: .trustOnFirstUse, identifier: Fake(current: current))
    try gate.verify()
    XCTAssertEqual(gate.pinned, real)
    current.set(ServerIdentity(executable: "/tmp/impostor", cdhash: "bb"))
    XCTAssertThrowsError(try gate.verify())
    current.set(ServerIdentity(executable: real.executable, cdhash: "cc"))
    XCTAssertThrowsError(try gate.verify(), "same path, different code: refused")
    current.set(nil)
    XCTAssertThrowsError(try gate.verify(), "no listener to verify: refused")
    current.set(real)
    XCTAssertNoThrow(try gate.verify())
  }

  func testAnExpectedPinRefusesTheListenerAndNothingIsSent() async throws {
    let emulator = ServiceMonitorEmulator(.init(token: fixtureToken, monitors: 1))
    let server = FixtureHTTPServer { emulator.handle($0) }
    try await server.start()
    defer { Task { await server.stop() } }
    let adapter = try ServiceMonitorAdapter(
      endpoint: server.baseURL, token: SecretToken(fixtureToken),
      transport: BoundedURLSessionTransport(),
      pin: .expected(ServerIdentity(executable: "/opt/smon/bin/monitor-server", cdhash: nil)))
    do {
      _ = try await adapter.poll(observedAt: Date())
      XCTFail("polled an impostor")
    } catch {
      guard case .untrustedServer(let detail) = error else { return XCTFail("\(error)") }
      XCTAssertTrue(detail.contains(ownExecutable()), detail)
      XCTAssertEqual(error.pollFailure, .untrustedServer(detail))
    }
    XCTAssertEqual(server.requestCount, 0)
    // The right pin is accepted.
    let paired = try ServiceMonitorAdapter(
      endpoint: server.baseURL, token: SecretToken(fixtureToken),
      transport: BoundedURLSessionTransport(),
      pin: .expected(ServerIdentity(executable: ownExecutable(), cdhash: nil)))
    _ = try await paired.poll(observedAt: Date())
    XCTAssertGreaterThan(server.requestCount, 0)
  }

  /// The pin names a path through a symlink (/tmp is /private/tmp); the
  /// kernel reports the real path. They must still match.
  func testAPinThroughASymlinkMatchesTheRealPath() throws {
    let real = "/private/tmp/nw-pin-\(UUID().uuidString)"
    FileManager.default.createFile(atPath: real, contents: Data())
    defer { try? FileManager.default.removeItem(atPath: real) }
    let viaSymlink = real.replacingOccurrences(of: "/private/tmp/", with: "/tmp/")
    let current = Current()
    current.set(ServerIdentity(executable: real, cdhash: nil))
    let gate = ServerIdentityGate(
      port: 60410, pin: .expected(ServerIdentity(executable: viaSymlink, cdhash: nil)),
      identifier: Fake(current: current))
    XCTAssertNoThrow(try gate.verify())
  }

  /// Recorded, not judged: what a full scan and the fast path cost here.
  func testTheCheckIsCheapBetweenFullScans() async throws {
    let server = FixtureHTTPServer { _ in .json(200, [:]) }
    let port = try await server.start()
    defer { Task { await server.stop() } }
    let gate = ServerIdentityGate(
      port: port, pin: .trustOnFirstUse, identifier: LibprocListenerIdentifier())
    let clock = ContinuousClock()
    let full = try clock.measure { try gate.verify() }
    var fast = Duration.zero
    for _ in 0..<100 { fast += try clock.measure { try gate.verify() } }
    print("identity check: full scan \(full), fast path \(fast / 100) each")
    XCTAssertLessThan(fast / 100, .milliseconds(5))
  }
}
