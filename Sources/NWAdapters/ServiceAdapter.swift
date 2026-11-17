import Foundation
import NWCore
import NWCredentials

/// What one poll of a service produced: its status and the events it
/// reported that this adapter has not handed out before.
public struct PollOutcome: Sendable {
  public var snapshot: ServiceSnapshot
  public var events: [Event]
}

public enum AdapterError: Error, Sendable, Equatable {
  case transport(TransportError)
  /// 401: the credential was refused. The connection stops polling.
  case unauthorized
  case httpStatus(Int, String)
  case decoding(String)
  /// The endpoint is not one this build may pair with (D-015).
  case refusedEndpoint(String)
  /// The process listening on the endpoint is not the paired service, so
  /// nothing was sent (D-015).
  case untrustedServer(String)

  public var pollFailure: PollFailure {
    switch self {
    case .transport(.timeout): return .timeout
    case .transport(let error): return .unreachable("\(error)")
    case .unauthorized: return .unauthorized
    case .httpStatus(let status, let code): return .protocolError("HTTP \(status) \(code)")
    case .decoding(let detail): return .protocolError("undecodable: \(detail)")
    case .refusedEndpoint(let detail): return .protocolError(detail)
    case .untrustedServer(let detail): return .untrustedServer(detail)
    }
  }
}

/// A read-only adapter for one service. Implementations reach the network
/// only through a `ReadOnlyTransport`, which can only `GET`.
public protocol ServiceAdapter: Sendable {
  var id: ServiceID { get }
  var displayName: String { get }
  var endpoint: URL { get }
  /// - Parameter observedAt: stamped on every event this poll returns.
  func poll(observedAt: Date) async throws(AdapterError) -> PollOutcome
}

/// D-015: an admin-class token (its scope cannot be reported) may only be
/// sent to a loopback endpoint.
public enum EndpointPolicy {
  public static func isLoopback(_ url: URL) -> Bool {
    guard let host = url.host?.lowercased() else { return false }
    if host == "localhost" || host == "::1" || host == "[::1]" { return true }
    let octets = host.split(separator: ".")
    return octets.count == 4 && octets.first == "127" && octets.allSatisfy { UInt8($0) != nil }
  }

  /// Returns the endpoint with a literal loopback address: `localhost` is
  /// rewritten to 127.0.0.1, so name resolution never decides where the
  /// token goes.
  public static func requireLoopbackForAdminToken(_ url: URL) throws(AdapterError) -> URL {
    guard url.scheme == "http" || url.scheme == "https" else {
      throw AdapterError.refusedEndpoint("only http(s) endpoints can be paired")
    }
    guard isLoopback(url) else {
      throw AdapterError.refusedEndpoint(
        "an admin-class token may only be paired with a loopback endpoint (D-015)")
    }
    guard url.host?.lowercased() == "localhost" else { return url }
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      throw AdapterError.refusedEndpoint("unusable endpoint")
    }
    components.host = "127.0.0.1"
    guard let literal = components.url else {
      throw AdapterError.refusedEndpoint("unusable endpoint")
    }
    return literal
  }
}

/// One list element, decoded on its own: an element that cannot be read is
/// `nil` (and counted), never the end of the whole list.
struct Lossy<T: Decodable>: Decodable {
  let value: T?
  init(from decoder: any Decoder) throws { value = try? T(from: decoder) }
}

extension Array {
  /// The readable elements, and how many were not.
  func readable<T>() -> ([T], Int) where Element == Lossy<T> {
    let values = compactMap(\.value)
    return (values, count - values.count)
  }
}

/// Small helpers shared by adapters.
enum Wire {
  static func decode<T: Decodable>(_ type: T.Type, _ reply: HTTPReply, what: String)
    throws(AdapterError) -> T
  {
    do {
      return try JSONDecoder().decode(T.self, from: repaired(reply.body))
    } catch {
      throw AdapterError.decoding("\(what): \(error)")
    }
  }

  /// Text the decoder would refuse, made decodable without guessing: invalid
  /// UTF-8 becomes U+FFFD, and a `\uD800`–`\uDFFF` escape that is not half
  /// of a valid pair becomes `\ufffd`. Valid input comes back unchanged. One
  /// bad string then costs one character, not the whole poll.
  static func repaired(_ data: Data) -> Data {
    var bytes = [UInt8](data)
    if String(validating: bytes, as: UTF8.self) == nil {
      bytes = Array(String(decoding: bytes, as: UTF8.self).utf8)
    }
    func unit(at i: Int) -> UInt16? {
      guard i + 5 < bytes.count, bytes[i] == 0x5C, bytes[i + 1] == 0x75 else { return nil }
      return UInt16(String(decoding: bytes[(i + 2)...(i + 5)], as: UTF8.self), radix: 16)
    }
    let replacement = Array("\\ufffd".utf8)
    var out: [UInt8] = []
    var changed = false
    var i = 0
    while i < bytes.count {
      guard bytes[i] == 0x5C, i + 1 < bytes.count else {
        out.append(bytes[i])
        i += 1
        continue
      }
      if let code = unit(at: i), (0xD800...0xDFFF).contains(code) {
        if code <= 0xDBFF, let low = unit(at: i + 6), (0xDC00...0xDFFF).contains(low) {
          out.append(contentsOf: bytes[i..<(i + 12)])  // a valid pair
          i += 12
        } else {
          out.append(contentsOf: replacement)
          changed = true
          i += 6
        }
        continue
      }
      out.append(bytes[i])  // any other escape: keep it and the escaped byte
      out.append(bytes[i + 1])
      i += 2
    }
    if !changed { return Data(bytes) }
    return Data(out)
  }

  static func errorCode(_ reply: HTTPReply) -> String {
    struct SMON: Decodable {
      struct Inner: Decodable { let code: String }
      let error: Inner
    }
    struct Durable: Decodable { let code: String }
    if let e = try? JSONDecoder().decode(SMON.self, from: reply.body) { return e.error.code }
    if let e = try? JSONDecoder().decode(Durable.self, from: reply.body) { return e.code }
    return "-"
  }

  /// RFC 3339 with any number of fractional digits (the services emit
  /// nanoseconds). Returns `nil` rather than guessing.
  static func rfc3339(_ text: String) -> Date? {
    let bytes = Array(text.utf8)
    func digits(_ start: Int, _ count: Int) -> Int? {
      guard start + count <= bytes.count else { return nil }
      var value = 0
      for byte in bytes[start..<start + count] {
        guard byte >= 48, byte <= 57 else { return nil }
        value = value * 10 + Int(byte - 48)
      }
      return value
    }
    guard bytes.count >= 20,
      let year = digits(0, 4), bytes[4] == 45, let month = digits(5, 2), bytes[7] == 45,
      let day = digits(8, 2), bytes[10] == 84 || bytes[10] == 116 || bytes[10] == 32,
      let hour = digits(11, 2), bytes[13] == 58, let minute = digits(14, 2), bytes[16] == 58,
      let second = digits(17, 2)
    else { return nil }
    var index = 19
    var fraction = 0.0
    if index < bytes.count, bytes[index] == 46 {
      index += 1
      var scale = 0.1
      let start = index
      while index < bytes.count, bytes[index] >= 48, bytes[index] <= 57 {
        fraction += Double(bytes[index] - 48) * scale
        scale /= 10
        index += 1
      }
      guard index > start else { return nil }
    }
    guard index < bytes.count else { return nil }
    var offset = 0
    switch bytes[index] {
    case 90, 122: index += 1
    case 43, 45:
      guard let oh = digits(index + 1, 2), bytes.count > index + 3, bytes[index + 3] == 58,
        let om = digits(index + 4, 2)
      else { return nil }
      offset = (oh * 3600 + om * 60) * (bytes[index] == 43 ? 1 : -1)
      index += 6
    default: return nil
    }
    guard index == bytes.count else { return nil }
    guard (1...12).contains(month), (1...31).contains(day), hour < 24, minute < 60, second < 61
    else { return nil }
    // Days from the civil date (H. Hinnant's algorithm): no Calendar on the
    // ingest path.
    let y = month <= 2 ? year - 1 : year
    let era = (y >= 0 ? y : y - 399) / 400
    let yoe = y - era * 400
    let mp = (month + 9) % 12
    let doy = (153 * mp + 2) / 5 + day - 1
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
    let days = era * 146_097 + doe - 719_468
    let seconds = Double(days * 86_400 + hour * 3600 + minute * 60 + second - offset)
    return Date(timeIntervalSince1970: seconds + fraction)
  }

  /// Characters a path segment keeps unencoded: RFC 3986 "unreserved".
  static let segmentAllowed = CharacterSet(
    charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

  /// `base` + one percent-encoded segment per element. A segment can never
  /// add a `/`, `?` or `#`, and empty, `.` and `..` segments are refused, so
  /// service data cannot steer a request to another path. Never traps.
  static func url(_ base: URL, _ segments: [String], query: [URLQueryItem] = [])
    throws(AdapterError) -> URL
  {
    guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
      throw AdapterError.refusedEndpoint("unusable endpoint")
    }
    var path = components.percentEncodedPath
    if path.hasSuffix("/") { path.removeLast() }
    for segment in segments {
      guard !segment.isEmpty, segment != ".", segment != "..",
        let encoded = segment.addingPercentEncoding(withAllowedCharacters: segmentAllowed)
      else { throw AdapterError.refusedEndpoint("refused a path segment from service data") }
      path += "/" + encoded
    }
    components.percentEncodedPath = path
    components.queryItems = query.isEmpty ? nil : query
    guard let url = components.url else {
      throw AdapterError.refusedEndpoint("could not build a request URL")
    }
    return url
  }
}
