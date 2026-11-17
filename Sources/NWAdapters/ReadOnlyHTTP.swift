import Foundation
import NWCredentials
import Synchronization

/// A request the read-only build can make. There is no method parameter
/// anywhere in this module: the one `URLRequest` it produces is a `GET`
/// with no body (ROADMAP §N0 architecture check; D-013, D-015).
public struct ReadOnlyRequest: Sendable, Equatable {
  public let url: URL
  /// Only `Authorization` (from a `SecretToken`) and `Accept` are ever set.
  let token: SecretToken?

  public init(url: URL, token: SecretToken?) {
    self.url = url
    self.token = token
  }

  public var urlRequest: URLRequest {
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if let token {
      request.setValue(token.authorizationHeaderValue(), forHTTPHeaderField: "Authorization")
    }
    return request
  }
}

public struct HTTPReply: Sendable {
  public let status: Int
  public let body: Data
}

public enum TransportError: Error, Sendable, Equatable {
  case unreachable(String)
  case timeout
  /// The body (declared or received) exceeded the cap; the transfer was cut.
  case tooLarge(limit: Int)
  /// A redirect to another origin (or past the hop cap) was refused.
  case redirectRefused(String)
  case cancelled
  case notHTTP
}

/// Limits every request carries (workspace rule: deadlines on every I/O,
/// bounded bodies).
public struct TransportLimits: Sendable, Equatable {
  /// Longest silence between bytes.
  public var idleTimeout: TimeInterval
  /// Whole-request deadline, connect to last byte.
  public var deadline: TimeInterval
  public var maxResponseBytes: Int
  /// Same-origin redirects followed; a cross-origin one is always refused.
  public var maxRedirects: Int

  public static let standard = TransportLimits(
    idleTimeout: 1, deadline: 1, maxResponseBytes: 4 * 1024 * 1024, maxRedirects: 2)

  public init(
    idleTimeout: TimeInterval, deadline: TimeInterval, maxResponseBytes: Int, maxRedirects: Int
  ) {
    self.idleTimeout = idleTimeout
    self.deadline = deadline
    self.maxResponseBytes = maxResponseBytes
    self.maxRedirects = maxRedirects
  }
}

/// What adapters need from the network: a `GET` and nothing else.
public protocol ReadOnlyTransport: Sendable {
  func get(_ request: ReadOnlyRequest) async throws(TransportError) -> HTTPReply
}

/// URLSession, bounded: ephemeral (no cookies, cache or credential storage),
/// no proxy, no waiting for connectivity, a deadline on every request, a
/// response-size cap enforced while bytes arrive, and redirects only within
/// the original origin. Swift task cancellation cancels the transfer.
public final class BoundedURLSessionTransport: NSObject, ReadOnlyTransport, URLSessionDataDelegate,
  Sendable
{
  public let limits: TransportLimits
  private let tasks = Mutex<[Int: Pending]>([:])
  // Created once in init and never reassigned; URLSession is thread-safe.
  nonisolated(unsafe) private var session: URLSession!

  private struct Pending {
    var continuation: CheckedContinuation<HTTPReply, any Error>
    var origin: String
    var body = Data()
    var status = 0
    var redirects = 0
    var failure: TransportError?
  }

  public init(limits: TransportLimits = .standard) {
    self.limits = limits
    super.init()
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = limits.idleTimeout
    // The deadline is this transport's own timer (D-027); URLSession's
    // resource timeout is only a backstop, at twice the deadline.
    config.timeoutIntervalForResource = limits.deadline * 2
    config.waitsForConnectivity = false
    config.httpCookieStorage = nil
    config.httpShouldSetCookies = false
    config.urlCache = nil
    config.urlCredentialStorage = nil
    config.requestCachePolicy = .reloadIgnoringLocalCacheData
    config.connectionProxyDictionary = [:]
    config.httpMaximumConnectionsPerHost = 4
    let queue = OperationQueue()
    queue.maxConcurrentOperationCount = 1
    queue.name = "nw.transport.delegate"
    session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
  }

  deinit { session.invalidateAndCancel() }

  public func get(_ request: ReadOnlyRequest) async throws(TransportError) -> HTTPReply {
    let urlRequest = request.urlRequest
    // Defense in depth: the builder above is the only source of requests.
    guard urlRequest.httpMethod == "GET", urlRequest.httpBody == nil,
      urlRequest.httpBodyStream == nil
    else { throw TransportError.notHTTP }
    let task = session.dataTask(with: urlRequest)
    let id = task.taskIdentifier
    let origin = Self.origin(of: request.url)
    do {
      return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
          tasks.withLock { $0[id] = Pending(continuation: continuation, origin: origin) }
          if Task.isCancelled { task.cancel() }
          // The hard deadline. URLSession's resource timeout (twice this) is
          // only a backstop: once observed stretching past its limit.
          DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + limits.deadline) {
            [weak self] in
            self?.expire(task)
          }
          task.resume()
        }
      } onCancel: {
        task.cancel()
      }
    } catch let error as TransportError {
      throw error
    } catch {
      throw TransportError.unreachable("\(error)")
    }
  }

  static func origin(of url: URL) -> String {
    let scheme = url.scheme?.lowercased() ?? ""
    let host = url.host?.lowercased() ?? ""
    let port = url.port ?? (scheme == "https" ? 443 : 80)
    return "\(scheme)://\(host):\(port)"
  }

  // MARK: URLSessionDataDelegate

  public func urlSession(
    _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
  ) {
    guard let http = response as? HTTPURLResponse else {
      fail(dataTask, .notHTTP)
      completionHandler(.cancel)
      return
    }
    let limit = limits.maxResponseBytes
    let tooBig = response.expectedContentLength > Int64(limit)
    tasks.withLock { pending in
      pending[dataTask.taskIdentifier]?.status = http.statusCode
      if tooBig { pending[dataTask.taskIdentifier]?.failure = .tooLarge(limit: limit) }
    }
    completionHandler(tooBig ? .cancel : .allow)
  }

  public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data)
  {
    let limit = limits.maxResponseBytes
    let over = tasks.withLock { pending -> Bool in
      let id = dataTask.taskIdentifier
      guard let received = pending[id]?.body.count else { return false }
      if received + data.count > limit {
        pending[id]?.failure = .tooLarge(limit: limit)
        pending[id]?.body = Data()
        return true
      }
      // In place: copying the entry out and back copied the whole body on
      // every chunk (quadratic up to the cap).
      pending[id]?.body.append(data)
      return false
    }
    if over { dataTask.cancel() }
  }

  public func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    let maxRedirects = limits.maxRedirects
    let allowed = tasks.withLock { pending -> Bool in
      guard var entry = pending[task.taskIdentifier], let target = request.url else { return false }
      let sameOrigin = Self.origin(of: target) == entry.origin
      let stillGET = (request.httpMethod ?? "GET") == "GET" && request.httpBody == nil
      entry.redirects += 1
      if !sameOrigin || !stillGET || entry.redirects > maxRedirects {
        entry.failure = .redirectRefused(
          sameOrigin ? "more than \(maxRedirects) redirects" : "redirect to another origin")
        pending[task.taskIdentifier] = entry
        return false
      }
      pending[task.taskIdentifier] = entry
      return true
    }
    if allowed {
      completionHandler(request)
    } else {
      completionHandler(nil)
      task.cancel()
    }
  }

  public func urlSession(
    _ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?
  ) {
    guard let entry = tasks.withLock({ $0.removeValue(forKey: task.taskIdentifier) }) else {
      return
    }
    if let failure = entry.failure {
      entry.continuation.resume(throwing: failure)
      return
    }
    if let error {
      entry.continuation.resume(throwing: Self.classify(error))
      return
    }
    entry.continuation.resume(returning: HTTPReply(status: entry.status, body: entry.body))
  }

  private func expire(_ task: URLSessionTask) {
    let pending = tasks.withLock { pending -> Bool in
      guard pending[task.taskIdentifier] != nil else { return false }
      if pending[task.taskIdentifier]?.failure == nil {
        pending[task.taskIdentifier]?.failure = .timeout
      }
      return true
    }
    if pending { task.cancel() }
  }

  private func fail(_ task: URLSessionTask, _ failure: TransportError) {
    tasks.withLock { $0[task.taskIdentifier]?.failure = failure }
  }

  static func classify(_ error: any Error) -> TransportError {
    let ns = error as NSError
    guard ns.domain == NSURLErrorDomain else { return .unreachable(ns.localizedDescription) }
    switch ns.code {
    case NSURLErrorTimedOut: return .timeout
    case NSURLErrorCancelled: return .cancelled
    case NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost,
      NSURLErrorNotConnectedToInternet, NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
      return .unreachable(ns.localizedDescription)
    default:
      return .unreachable("\(ns.code) \(ns.localizedDescription)")
    }
  }
}
