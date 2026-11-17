import Foundation
import Network
import Synchronization

/// A request as the fixture server parsed it.
public struct FixtureRequest: Sendable, Equatable {
  public var method: String
  public var path: String
  public var query: [String: String]
  /// Lower-cased names.
  public var headers: [String: String]
  public var bodyBytesDeclared: Int
}

/// What the fixture answers. `hang` never answers (a stuck service);
/// `declaredLength` lets a response lie about its size.
public struct FixtureResponse: Sendable {
  public var status: Int
  public var headers: [(String, String)]
  public var body: Data
  public var delay: TimeInterval
  public var hang: Bool
  public var declaredLength: Int?

  public init(
    status: Int, headers: [(String, String)] = [], body: Data = Data(), delay: TimeInterval = 0,
    hang: Bool = false, declaredLength: Int? = nil
  ) {
    self.status = status
    self.headers = headers
    self.body = body
    self.delay = delay
    self.hang = hang
    self.declaredLength = declaredLength
  }

  public static func json(_ status: Int, _ object: Any) -> FixtureResponse {
    let body = (try? JSONSerialization.data(withJSONObject: object, options: [])) ?? Data()
    return FixtureResponse(
      status: status, headers: [("Content-Type", "application/json")], body: body)
  }
}

public enum FixtureServerError: Error, Sendable {
  case failed(String)
}

/// A tiny HTTP/1.1 server on the loopback interface, built on
/// Network.framework, that can be killed (`stop`: the listener and every open
/// connection are cancelled at once, like a process dying) and restarted on
/// the same port. It records every request's method and path, so tests can
/// prove from the server side that the app only ever sent `GET`.
///
/// Fixture only: one request per connection (`Connection: close`), headers
/// capped at 64 KiB, bodies never read.
public final class FixtureHTTPServer: Sendable {
  public typealias Handler = @Sendable (FixtureRequest) -> FixtureResponse

  private let handler: Handler
  private let queue = DispatchQueue(label: "nw.fixture-server")
  private let state: Mutex<State>
  private static let maxHeaderBytes = 64 * 1024
  private static let maxRecorded = 100_000

  private struct State {
    var port: UInt16
    var listener: NWListener?
    var connections: [ObjectIdentifier: NWConnection] = [:]
    var recorded: [RecordedRequest] = []
    var recordedTotal = 0
    var methods: [String: Int] = [:]
    var generation = 0
  }

  public struct RecordedRequest: Sendable, Equatable {
    public var method: String
    public var path: String
    public var authorized: Bool
  }

  /// - Parameter port: 0 picks a free port at the first `start`, which is
  ///   then reused by every restart.
  public init(port: UInt16 = 0, handler: @escaping Handler) {
    self.handler = handler
    self.state = Mutex(State(port: port))
  }

  public var port: UInt16 { state.withLock { $0.port } }
  public var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }
  public var isRunning: Bool { state.withLock { $0.listener != nil } }
  /// Requests seen, by method (every one, not just the recorded window).
  public var methodCounts: [String: Int] { state.withLock { $0.methods } }
  public var requestCount: Int { state.withLock { $0.recordedTotal } }
  public var recorded: [RecordedRequest] { state.withLock { $0.recorded } }

  @discardableResult
  public func start() async throws -> UInt16 {
    let (port, generation) = state.withLock { s -> (UInt16, Int) in
      s.generation += 1
      return (s.port, s.generation)
    }
    let parameters = NWParameters.tcp
    parameters.allowLocalEndpointReuse = true
    parameters.requiredInterfaceType = .loopback
    let listener: NWListener
    do {
      listener = try NWListener(
        using: parameters, on: port == 0 ? .any : NWEndpoint.Port(rawValue: port)!)
    } catch {
      throw FixtureServerError.failed("listener: \(error)")
    }
    listener.newConnectionHandler = { [weak self] connection in
      self?.accept(connection, generation: generation)
    }
    let ready: UInt16 = try await withCheckedThrowingContinuation { continuation in
      let once = Mutex(false)
      listener.stateUpdateHandler = { newState in
        let resume: (Result<UInt16, Error>)? = {
          switch newState {
          case .ready: return .success(listener.port?.rawValue ?? 0)
          case .failed(let error): return .failure(FixtureServerError.failed("\(error)"))
          case .cancelled: return .failure(FixtureServerError.failed("cancelled before ready"))
          default: return nil
          }
        }()
        guard let resume else { return }
        let first = once.withLock { done -> Bool in
          defer { done = true }
          return !done
        }
        if first { continuation.resume(with: resume) }
      }
      listener.start(queue: queue)
    }
    state.withLock { s in
      s.port = ready
      s.listener = listener
    }
    return ready
  }

  /// Kill: the listener and every open connection go away at once; a client
  /// mid-request sees its connection reset, a new one is refused.
  public func stop() async {
    let (listener, connections) = state.withLock { s -> (NWListener?, [NWConnection]) in
      defer {
        s.listener = nil
        s.connections.removeAll()
      }
      return (s.listener, Array(s.connections.values))
    }
    for connection in connections { connection.forceCancel() }
    guard let listener else { return }
    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
      let once = Mutex(false)
      listener.stateUpdateHandler = { newState in
        switch newState {
        case .cancelled, .failed:
          let first = once.withLock { flag -> Bool in
            defer { flag = true }
            return !flag
          }
          if first { done.resume() }
        default: break
        }
      }
      listener.cancel()
    }
  }

  private func accept(_ connection: NWConnection, generation: Int) {
    let current = state.withLock { s -> Bool in
      guard s.generation == generation, s.listener != nil else { return false }
      s.connections[ObjectIdentifier(connection)] = connection
      return true
    }
    guard current else {
      connection.forceCancel()
      return
    }
    connection.stateUpdateHandler = { [weak self] newState in
      switch newState {
      case .cancelled, .failed:
        self?.state.withLock {
          _ = $0.connections.removeValue(forKey: ObjectIdentifier(connection))
        }
      default: break
      }
    }
    connection.start(queue: queue)
    receive(connection, buffer: Data())
  }

  private func receive(_ connection: NWConnection, buffer: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) {
      [weak self] content, _, isComplete, error in
      guard let self else { return }
      var buffer = buffer
      if let content { buffer.append(content) }
      if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
        let head = buffer[buffer.startIndex..<end.lowerBound]
        self.respond(connection, head: head)
        return
      }
      if error != nil || isComplete || buffer.count > Self.maxHeaderBytes {
        connection.cancel()
        return
      }
      self.receive(connection, buffer: buffer)
    }
  }

  private func respond(_ connection: NWConnection, head: Data) {
    guard let request = Self.parse(head) else {
      send(connection, FixtureResponse(status: 400))
      return
    }
    state.withLock { s in
      s.recordedTotal += 1
      s.methods[request.method, default: 0] += 1
      if s.recorded.count < Self.maxRecorded {
        s.recorded.append(
          RecordedRequest(
            method: request.method, path: request.path,
            authorized: request.headers["authorization"] != nil))
      }
    }
    let response = handler(request)
    if response.hang { return }  // never answer; the connection dies with stop()
    if response.delay > 0 {
      queue.asyncAfter(deadline: .now() + response.delay) { [weak self] in
        self?.send(connection, response)
      }
    } else {
      send(connection, response)
    }
  }

  private func send(_ connection: NWConnection, _ response: FixtureResponse) {
    var head = "HTTP/1.1 \(response.status) \(Self.reason(response.status))\r\n"
    for (name, value) in response.headers { head += "\(name): \(value)\r\n" }
    head += "Content-Length: \(response.declaredLength ?? response.body.count)\r\n"
    head += "Connection: close\r\n\r\n"
    var bytes = Data(head.utf8)
    bytes.append(response.body)
    connection.send(
      content: bytes,
      completion: .contentProcessed { _ in
        connection.cancel()
      })
  }

  static func parse(_ head: Data) -> FixtureRequest? {
    guard let text = String(data: head, encoding: .utf8) else { return nil }
    let lines = text.components(separatedBy: "\r\n")
    let parts = lines[0].split(separator: " ")
    guard parts.count == 3 else { return nil }
    let target = String(parts[1])
    let components = URLComponents(string: target)
    var query: [String: String] = [:]
    for item in components?.queryItems ?? [] { query[item.name] = item.value ?? "" }
    var headers: [String: String] = [:]
    for line in lines.dropFirst() {
      guard let colon = line.firstIndex(of: ":") else { continue }
      let name = line[..<colon].lowercased()
      let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
      headers[name] = value
    }
    return FixtureRequest(
      method: String(parts[0]), path: components?.path ?? target, query: query, headers: headers,
      bodyBytesDeclared: Int(headers["content-length"] ?? "0") ?? 0)
  }

  static func reason(_ status: Int) -> String {
    switch status {
    case 200: return "OK"
    case 301: return "Moved Permanently"
    case 302: return "Found"
    case 307: return "Temporary Redirect"
    case 400: return "Bad Request"
    case 401: return "Unauthorized"
    case 404: return "Not Found"
    case 405: return "Method Not Allowed"
    case 500: return "Internal Server Error"
    case 503: return "Service Unavailable"
    default: return "Status"
    }
  }
}
