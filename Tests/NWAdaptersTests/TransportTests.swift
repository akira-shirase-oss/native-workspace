import NWCredentials
import NWFixtures
import Synchronization
import XCTest

@testable import NWAdapters

/// The bounded, GET-only transport: deadlines, size caps, redirect policy,
/// cancellation — and the server-side witness that only GET is ever sent.
final class TransportTests: XCTestCase {
  var server: FixtureHTTPServer!
  let routes = RouteTable()

  final class RouteTable: Sendable {
    private let table = Mutex<[String: FixtureResponse]>([:])
    func set(_ path: String, _ response: FixtureResponse) { table.withLock { $0[path] = response } }
    func get(_ path: String) -> FixtureResponse {
      table.withLock { $0[path] } ?? FixtureResponse(status: 404)
    }
  }

  override func setUp() async throws {
    let routes = self.routes
    server = FixtureHTTPServer { request in routes.get(request.path) }
    try await server.start()
  }

  override func tearDown() async throws {
    await server.stop()
  }

  func request(_ path: String, token: SecretToken? = nil) -> ReadOnlyRequest {
    ReadOnlyRequest(url: server.baseURL.appendingPathComponent(path), token: token)
  }

  func testTheOnlyRequestTheBuilderMakesIsABodylessGET() throws {
    let token = try XCTUnwrap(SecretToken("abcdefabcdefabcdefabcdefabcdefab"))
    for request in [request("/a"), request("/b", token: token)] {
      let built = request.urlRequest
      XCTAssertEqual(built.httpMethod, "GET")
      XCTAssertNil(built.httpBody)
      XCTAssertNil(built.httpBodyStream)
      let names = Set((built.allHTTPHeaderFields ?? [:]).keys.map { $0.lowercased() })
      XCTAssertTrue(names.isSubset(of: ["accept", "authorization"]), "\(names)")
    }
    XCTAssertNil(request("/a").urlRequest.value(forHTTPHeaderField: "Authorization"))
    XCTAssertEqual(
      request("/b", token: token).urlRequest.value(forHTTPHeaderField: "Authorization"),
      "Bearer abcdefabcdefabcdefabcdefabcdefab")
  }

  func testFetchesAndTheServerSeesOnlyGET() async throws {
    routes.set("/ok", .json(200, ["ok": true]))
    let transport = BoundedURLSessionTransport()
    for _ in 0..<5 {
      let reply = try await transport.get(request("/ok"))
      XCTAssertEqual(reply.status, 200)
    }
    XCTAssertEqual(server.methodCounts, ["GET": 5])
  }

  func testABodyOverTheCapIsCutWhileArriving() async throws {
    routes.set("/big", FixtureResponse(status: 200, body: Data(count: 300_000)))
    let transport = BoundedURLSessionTransport(
      limits: .init(idleTimeout: 2, deadline: 2, maxResponseBytes: 100_000, maxRedirects: 0))
    do {
      _ = try await transport.get(request("/big"))
      XCTFail("expected tooLarge")
    } catch {
      XCTAssertEqual(error, .tooLarge(limit: 100_000))
    }
  }

  func testADeclaredLengthOverTheCapIsRefusedBeforeTheBody() async throws {
    routes.set(
      "/liar",
      FixtureResponse(
        status: 200, headers: [("Content-Type", "application/octet-stream")],
        body: Data(count: 10), declaredLength: 50_000_000, keepOpen: true))
    let transport = BoundedURLSessionTransport(
      limits: .init(idleTimeout: 2, deadline: 2, maxResponseBytes: 100_000, maxRedirects: 0))
    do {
      _ = try await transport.get(request("/liar"))
      XCTFail("expected tooLarge")
    } catch {
      XCTAssertEqual(error, .tooLarge(limit: 100_000))
    }
  }

  func testATrickledBodyHitsTheHardDeadline() async throws {
    routes.set(
      "/slow",
      FixtureResponse(
        status: 200, headers: [("Content-Type", "application/json")], body: Data("{".utf8),
        declaredLength: 1_000, keepOpen: true))
    let transport = BoundedURLSessionTransport(
      limits: .init(idleTimeout: 5, deadline: 0.4, maxResponseBytes: 100_000, maxRedirects: 0))
    let started = Date()
    do {
      _ = try await transport.get(request("/slow"))
      XCTFail("expected timeout")
    } catch {
      XCTAssertEqual(error, .timeout)
    }
    XCTAssertLessThan(Date().timeIntervalSince(started), 1.0)
  }

  func testAHungServiceHitsTheDeadline() async throws {
    routes.set("/hang", FixtureResponse(status: 200, hang: true))
    let transport = BoundedURLSessionTransport(
      limits: .init(idleTimeout: 0.3, deadline: 0.3, maxResponseBytes: 1_000, maxRedirects: 0))
    let started = Date()
    do {
      _ = try await transport.get(request("/hang"))
      XCTFail("expected timeout")
    } catch {
      XCTAssertEqual(error, .timeout)
    }
    XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
  }

  func testCancellingTheTaskCancelsTheTransfer() async throws {
    routes.set("/hang", FixtureResponse(status: 200, hang: true))
    let transport = BoundedURLSessionTransport(
      limits: .init(idleTimeout: 30, deadline: 30, maxResponseBytes: 1_000, maxRedirects: 0))
    let req = request("/hang")
    let task = Task { () -> TransportError? in
      do throws(TransportError) {
        _ = try await transport.get(req)
        return nil
      } catch {
        return error
      }
    }
    try await Task.sleep(for: .milliseconds(150))
    let started = Date()
    task.cancel()
    let error = await task.value
    XCTAssertEqual(error, .cancelled)
    XCTAssertLessThan(Date().timeIntervalSince(started), 1)
  }

  func testARedirectToAnotherOriginIsRefused() async throws {
    routes.set(
      "/away", FixtureResponse(status: 302, headers: [("Location", "http://evil.example/steal")]))
    let transport = BoundedURLSessionTransport()
    do {
      _ = try await transport.get(request("/away"))
      XCTFail("expected redirectRefused")
    } catch {
      XCTAssertEqual(error, .redirectRefused("redirect to another origin"))
    }
    XCTAssertEqual(server.requestCount, 1, "nothing followed the redirect")
  }

  func testASameOriginRedirectIsFollowedWithinTheHopCap() async throws {
    let base = server.baseURL.absoluteString
    routes.set("/moved", FixtureResponse(status: 307, headers: [("Location", "\(base)/here")]))
    routes.set("/here", .json(200, ["ok": true]))
    routes.set("/loop", FixtureResponse(status: 302, headers: [("Location", "\(base)/loop")]))
    let transport = BoundedURLSessionTransport()
    let reply = try await transport.get(request("/moved"))
    XCTAssertEqual(reply.status, 200)
    do {
      _ = try await transport.get(request("/loop"))
      XCTFail("expected redirectRefused")
    } catch {
      XCTAssertEqual(error, .redirectRefused("more than 2 redirects"))
    }
    XCTAssertEqual(Set(server.methodCounts.keys), ["GET"])
  }

  func testAStoppedServiceIsUnreachableFast() async throws {
    await server.stop()
    let transport = BoundedURLSessionTransport()
    let started = Date()
    do {
      _ = try await transport.get(request("/ok"))
      XCTFail("expected unreachable")
    } catch {
      guard case .unreachable = error else { return XCTFail("\(error)") }
    }
    XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    try await server.start()  // tearDown stops it again
  }
}

/// The fixture server itself must be bounded: a kill and an immediate
/// restart on the same port, many times, never waits forever (the first
/// 1,000-iteration drill hung on an unbounded wait here).
final class FixtureServerTests: XCTestCase {
  func testStartingOnAPortInUseFailsWithinItsTimeout() async throws {
    let holder = FixtureHTTPServer { _ in .json(200, ["ok": true]) }
    let port = try await holder.start()
    let second = FixtureHTTPServer(port: port) { _ in .json(200, ["ok": true]) }
    let started = Date()
    do {
      try await second.start(timeout: 1)
      XCTFail("two listeners on one port")
      await second.stop()
    } catch {
      XCTAssertLessThan(Date().timeIntervalSince(started), 4, "start must be bounded")
    }
    await holder.stop()
  }

  func testRapidKillAndRestartOnTheSamePortIsBounded() async throws {
    let server = FixtureHTTPServer { _ in .json(200, ["ok": true]) }
    let port = try await server.start()
    let transport = BoundedURLSessionTransport()
    let started = Date()
    for i in 0..<200 {
      await server.stop()
      let again = try await server.start(timeout: 5)
      XCTAssertEqual(again, port)
      if i % 20 == 0 {
        let reply = try await transport.get(
          ReadOnlyRequest(url: server.baseURL.appendingPathComponent("/x"), token: nil))
        XCTAssertEqual(reply.status, 200)
      }
    }
    XCTAssertLessThan(Date().timeIntervalSince(started), 60)
    // A started server stays up: nothing cancels it behind the caller's back.
    try await Task.sleep(for: .seconds(2.5))
    let reply = try await transport.get(
      ReadOnlyRequest(url: server.baseURL.appendingPathComponent("/x"), token: nil))
    XCTAssertEqual(reply.status, 200)
    await server.stop()
  }
}
