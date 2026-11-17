import Darwin
import Foundation
import NWCore
import NWCredentials
import NWFixtures
import Synchronization
import XCTest

@testable import NWAdapters

final class ServerIdentityGateTests: XCTestCase {
  static let real = ServerIdentity(executable: "/opt/smon/bin/monitor-server", cdhash: "aa")
  static let impostor = ServerIdentity(executable: "/tmp/impostor", cdhash: "bb")
  static let loopback = ListenAddress.v4(0x7F00_0001)

  func ownExecutable() -> String {
    var path = [CChar](repeating: 0, count: 4096)
    _ = proc_pidpath(getpid(), &path, 4096)
    return String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
  }

  /// A scripted view of the port: who listens where, and who they are.
  final class Fake: ListenerIdentifying, Sendable {
    struct World: Sendable {
      var sockets: [ListenerSocket]
      var identities: [pid_t: ServerIdentity]
    }
    let world: Mutex<World>
    let scans = Mutex(0)
    init(_ sockets: [ListenerSocket], _ identities: [pid_t: ServerIdentity]) {
      world = Mutex(World(sockets: sockets, identities: identities))
    }
    func set(_ sockets: [ListenerSocket], _ identities: [pid_t: ServerIdentity]) {
      world.withLock { $0 = World(sockets: sockets, identities: identities) }
    }
    func listeners(port: UInt16) -> [ListenerSocket] {
      scans.withLock { $0 += 1 }
      return world.withLock { $0.sockets }
    }
    func identity(of pid: pid_t) -> ServerIdentity? { world.withLock { $0.identities[pid] } }
  }

  func testLibprocReportsTheOwnerOfTheFixtureListener() async throws {
    let server = FixtureHTTPServer { _ in .json(200, [:]) }
    let port = try await server.start()
    let identifier = LibprocListenerIdentifier()
    let sockets = identifier.listeners(port: port)
    // NWListener binds the wildcard, limited to the loopback interface.
    XCTAssertEqual(sockets, [ListenerSocket(pid: getpid(), address: .anyV4)])
    XCTAssertEqual(identifier.identity(of: getpid())?.executable, ownExecutable())
    XCTAssertEqual(ServerIdentityGate.owner(of: Self.loopback, among: sockets), getpid())
    await server.stop()
    XCTAssertTrue(identifier.listeners(port: port).isEmpty, "nobody listens after a stop")
  }

  func testLibprocReportsTheExactAddressASocketIsBoundTo() throws {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    XCTAssertGreaterThanOrEqual(fd, 0)
    defer { Darwin.close(fd) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = in_addr_t(0x7F00_0001).bigEndian
    address.sin_port = 0
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    XCTAssertEqual(bound, 0)
    XCTAssertEqual(Darwin.listen(fd, 4), 0)
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.getsockname(fd, $0, &length) }
    }
    let port = UInt16(bigEndian: address.sin_port)
    XCTAssertEqual(
      LibprocListenerIdentifier().listeners(port: port),
      [ListenerSocket(pid: getpid(), address: Self.loopback)])
  }

  /// Item 3: the connection goes to the most specific listener, so that is
  /// the owner checked — a process holding 0.0.0.0 does not vouch for a
  /// different process holding 127.0.0.1.
  func testTheOwnerIsTheProcessOnTheExactAddressTheRequestGoesTo() {
    let wildcardA = ListenerSocket(pid: 100, address: .anyV4)
    let exactB = ListenerSocket(pid: 200, address: Self.loopback)
    XCTAssertEqual(ServerIdentityGate.owner(of: Self.loopback, among: [wildcardA, exactB]), 200)
    XCTAssertEqual(ServerIdentityGate.owner(of: Self.loopback, among: [wildcardA]), 100)
    XCTAssertEqual(
      ServerIdentityGate.owner(of: Self.loopback, among: [ListenerSocket(pid: 7, address: .anyV6)]),
      7, ":: takes IPv4 connections too")
    XCTAssertNil(
      ServerIdentityGate.owner(
        of: Self.loopback, among: [wildcardA, ListenerSocket(pid: 300, address: .anyV6)]),
      "two wildcard owners: ambiguous")
    XCTAssertNil(
      ServerIdentityGate.owner(
        of: Self.loopback, among: [exactB, ListenerSocket(pid: 300, address: Self.loopback)]),
      "two exact owners (SO_REUSEPORT): ambiguous")
    let mapped = ListenAddress.v6([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0xFF, 127, 0, 0, 1])
    XCTAssertEqual(
      ServerIdentityGate.owner(of: Self.loopback, among: [ListenerSocket(pid: 9, address: mapped)]),
      9, "an IPv4-mapped address is the IPv4 address")
    XCTAssertNil(ServerIdentityGate.owner(of: Self.loopback, among: []))
    XCTAssertEqual(
      ServerIdentityGate.owner(
        of: Self.loopback,
        among: [exactB, ListenerSocket(pid: 200, address: ListenAddress(literal: "::1")!)]),
      200, "one process on both loopbacks")
  }

  func testAProcessBindingAMoreSpecificAddressIsRefusedEvenWhileThePairedOneStillListens() throws {
    let fake = Fake([ListenerSocket(pid: 100, address: .anyV4)], [100: Self.real])
    let gate = ServerIdentityGate(port: 60410, pin: .expected(Self.real), identifier: fake)
    try gate.verify()
    fake.set(
      [
        ListenerSocket(pid: 100, address: .anyV4), ListenerSocket(pid: 200, address: Self.loopback),
      ],
      [100: Self.real, 200: Self.impostor])
    XCTAssertThrowsError(try gate.verify(), "the paired process's 0.0.0.0 vouched for another")
  }

  func testTrustOnFirstUsePinsTheFirstListenerAndRefusesAnotherOne() throws {
    let fake = Fake([ListenerSocket(pid: 100, address: Self.loopback)], [100: Self.real])
    let gate = ServerIdentityGate(port: 60410, pin: .trustOnFirstUse, identifier: fake)
    try gate.verify()
    XCTAssertEqual(gate.pinned, Self.real)
    fake.set([ListenerSocket(pid: 200, address: Self.loopback)], [200: Self.impostor])
    XCTAssertThrowsError(try gate.verify())
    fake.set(
      [ListenerSocket(pid: 300, address: Self.loopback)],
      [300: ServerIdentity(executable: Self.real.executable, cdhash: "cc")])
    XCTAssertThrowsError(try gate.verify(), "same path, different code: refused")
    fake.set([], [:])
    XCTAssertThrowsError(try gate.verify(), "no listener to verify: refused")
    fake.set([ListenerSocket(pid: 400, address: Self.loopback)], [400: Self.real])
    XCTAssertNoThrow(try gate.verify(), "the paired program again (a restart): accepted")
  }

  func testAPinThroughASymlinkMatchesTheRealPath() throws {
    let real = "/private/tmp/nw-pin-\(UUID().uuidString)"
    FileManager.default.createFile(atPath: real, contents: Data())
    defer { try? FileManager.default.removeItem(atPath: real) }
    let viaSymlink = real.replacingOccurrences(of: "/private/tmp/", with: "/tmp/")
    let fake = Fake(
      [ListenerSocket(pid: 1, address: Self.loopback)],
      [1: ServerIdentity(executable: real, cdhash: nil)])
    let gate = ServerIdentityGate(
      port: 60410, pin: .expected(ServerIdentity(executable: viaSymlink, cdhash: nil)),
      identifier: fake)
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
    let paired = try ServiceMonitorAdapter(
      endpoint: server.baseURL, token: SecretToken(fixtureToken),
      transport: BoundedURLSessionTransport(),
      pin: .expected(ServerIdentity(executable: ownExecutable(), cdhash: nil)))
    _ = try await paired.poll(observedAt: Date())
    XCTAssertGreaterThan(server.requestCount, 0)
  }

  /// Item 2: the check runs before every request, so a listener that
  /// changes in the middle of a poll gets nothing after the change.
  func testNothingIsSentAfterTheListenerChangesMidPoll() async throws {
    let emulator = ServiceMonitorEmulator(.init(token: fixtureToken, monitors: 3))
    let server = FixtureHTTPServer { emulator.handle($0) }
    try await server.start()
    defer { Task { await server.stop() } }
    final class Switching: ListenerIdentifying, Sendable {
      let calls = Mutex(0)
      func listeners(port: UInt16) -> [ListenerSocket] {
        let n = calls.withLock { n -> Int in
          n += 1
          return n
        }
        return [ListenerSocket(pid: n <= 2 ? 100 : 200, address: .v4(0x7F00_0001))]
      }
      func identity(of pid: pid_t) -> ServerIdentity? {
        pid == 100 ? ServerIdentityGateTests.real : ServerIdentityGateTests.impostor
      }
    }
    let switching = Switching()
    let adapter = try ServiceMonitorAdapter(
      endpoint: server.baseURL, token: SecretToken(fixtureToken),
      transport: BoundedURLSessionTransport(), pin: .expected(Self.real), identifier: switching)
    _ = try? await adapter.poll(observedAt: Date())
    XCTAssertEqual(server.requestCount, 2, "one request per check, none after the change")
    XCTAssertGreaterThanOrEqual(switching.calls.withLock { $0 }, 3)
  }

  /// Recorded, not judged: what one check costs here (it runs per request).
  func testTheCostOfACheck() async throws {
    let server = FixtureHTTPServer { _ in .json(200, [:]) }
    let port = try await server.start()
    defer { Task { await server.stop() } }
    let gate = ServerIdentityGate(
      port: port, pin: .trustOnFirstUse, identifier: LibprocListenerIdentifier())
    try gate.verify()
    let clock = ContinuousClock()
    var total = Duration.zero
    for _ in 0..<20 { total += try clock.measure { try gate.verify() } }
    print("identity check: \(total / 20) per request")
    XCTAssertLessThan(total / 20, .milliseconds(50))
  }
}
