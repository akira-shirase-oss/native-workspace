import Darwin
import Foundation
import Security
import Synchronization

/// Which program answers on a loopback port: its executable and the hash of
/// its code directory (`cdhash`; `nil` for unsigned code).
public struct ServerIdentity: Sendable, Equatable, CustomStringConvertible {
  public var executable: String
  public var cdhash: String?

  public init(executable: String, cdhash: String?) {
    self.executable = executable
    self.cdhash = cdhash
  }

  public var description: String {
    "\(executable) (cdhash \(cdhash.map { String($0.prefix(12)) } ?? "none"))"
  }
}

/// The local address a listening socket is bound to.
public enum ListenAddress: Sendable, Hashable, CustomStringConvertible {
  case v4(UInt32)  // host byte order
  case v6([UInt8])  // 16 bytes

  public static let anyV4 = ListenAddress.v4(0)
  public static let anyV6 = ListenAddress.v6([UInt8](repeating: 0, count: 16))

  /// The literal an endpoint host names, or `nil` if it is not a literal.
  public init?(literal host: String) {
    let bare =
      host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
    var v4 = in_addr()
    if inet_pton(AF_INET, bare, &v4) == 1 {
      self = .v4(UInt32(bigEndian: v4.s_addr))
      return
    }
    var v6 = in6_addr()
    if inet_pton(AF_INET6, bare, &v6) == 1 {
      self = .v6(withUnsafeBytes(of: &v6) { Array($0) })
      return
    }
    return nil
  }

  /// IPv4-mapped IPv6 addresses are the IPv4 address they map.
  var normalized: ListenAddress {
    if case .v6(let bytes) = self, bytes.count == 16, bytes[0..<10].allSatisfy({ $0 == 0 }),
      bytes[10] == 0xFF, bytes[11] == 0xFF
    {
      return .v4(bytes[12...15].reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
    }
    return self
  }

  public var description: String {
    switch self {
    case .v4(let value):
      return "\(value >> 24).\((value >> 16) & 0xFF).\((value >> 8) & 0xFF).\(value & 0xFF)"
    case .v6(let bytes):
      var address = in6_addr()
      withUnsafeMutableBytes(of: &address) { $0.copyBytes(from: bytes.prefix(16)) }
      var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
      inet_ntop(AF_INET6, &address, &buffer, socklen_t(buffer.count))
      return String(
        decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
  }
}

/// One process's listening TCP socket on the port in question.
public struct ListenerSocket: Sendable, Equatable {
  public var pid: pid_t
  public var address: ListenAddress

  public init(pid: pid_t, address: ListenAddress) {
    self.pid = pid
    self.address = address
  }
}

/// Finds who listens on a loopback port, and who a process is.
public protocol ListenerIdentifying: Sendable {
  /// Every listening TCP socket on `port` among the processes this user may
  /// inspect (other users' sockets are invisible to libproc).
  func listeners(port: UInt16) -> [ListenerSocket]
  func identity(of pid: pid_t) -> ServerIdentity?
}

/// The kernel's own answer (libproc), over this user's processes. Identities
/// are cached by pid and start time, so a reused pid is identified afresh.
public final class LibprocListenerIdentifier: ListenerIdentifying {
  private let identities = Mutex<[String: ServerIdentity]>([:])

  public init() {}

  public func listeners(port: UInt16) -> [ListenerSocket] {
    let uid = getuid()
    let count = proc_listpids(UInt32(PROC_UID_ONLY), uid, nil, 0)
    guard count > 0 else { return [] }
    var pids = [pid_t](repeating: 0, count: Int(count) / MemoryLayout<pid_t>.size + 64)
    let bytes = proc_listpids(
      UInt32(PROC_UID_ONLY), uid, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
    guard bytes > 0 else { return [] }
    var found: [ListenerSocket] = []
    for pid in pids.prefix(Int(bytes) / MemoryLayout<pid_t>.size) where pid > 0 {
      for address in listening(pid: pid, port: port) {
        found.append(ListenerSocket(pid: pid, address: address))
      }
    }
    return found
  }

  func listening(pid: pid_t, port: UInt16) -> [ListenAddress] {
    let stride = MemoryLayout<proc_fdinfo>.stride
    let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
    guard bytes > 0 else { return [] }
    var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / stride + 16)
    let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * stride))
    guard got > 0 else { return [] }
    var addresses: [ListenAddress] = []
    for fd in fds.prefix(Int(got) / stride) where fd.proc_fdtype == PROX_FDTYPE_SOCKET {
      var info = socket_fdinfo()
      let size = Int32(MemoryLayout<socket_fdinfo>.size)
      guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size,
        info.psi.soi_kind == SOCKINFO_TCP
      else { continue }
      let tcp = info.psi.soi_proto.pri_tcp
      guard tcp.tcpsi_state == TSI_S_LISTEN,
        UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport)) == port
      else { continue }
      var local = tcp.tcpsi_ini.insi_laddr
      if tcp.tcpsi_ini.insi_vflag & UInt8(INI_IPV4) != 0 {
        addresses.append(.v4(UInt32(bigEndian: local.ina_46.i46a_addr4.s_addr)))
      } else {
        addresses.append(.v6(withUnsafeBytes(of: &local.ina_6) { Array($0) }))
      }
    }
    return addresses
  }

  public func identity(of pid: pid_t) -> ServerIdentity? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
    let key = "\(pid)@\(info.pbi_start_tvsec).\(info.pbi_start_tvusec)"
    if let known = identities.withLock({ $0[key] }) { return known }
    var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
    let executable = String(
      decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    let identity = ServerIdentity(executable: executable, cdhash: Self.cdhash(of: pid))
    identities.withLock { cache in
      if cache.count > 64 { cache.removeAll() }
      cache[key] = identity
    }
    return identity
  }

  static func cdhash(of pid: pid_t) -> String? {
    var code: SecCode?
    let attributes = [kSecGuestAttributePid: pid] as CFDictionary
    guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess,
      let code
    else { return nil }
    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else {
      return nil
    }
    var info: CFDictionary?
    guard
      SecCodeCopySigningInformation(
        staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
      let dictionary = info as? [String: Any],
      let unique = dictionary[kSecCodeInfoUnique as String] as? Data
    else { return nil }
    return unique.map { String(format: "%02x", $0) }.joined()
  }
}

/// What the pairing trusts on the loopback port (D-015).
public enum ServerPin: Sendable, Equatable {
  /// The first identity seen is pinned for the session and shown.
  case trustOnFirstUse
  /// Named at pairing: the executable, and the cdhash if given.
  case expected(ServerIdentity)
}

/// The check before every request: the process that would accept a
/// connection to the endpoint's exact address and port must be the paired
/// program. That is the owner of a socket bound to that very address if
/// one exists (the kernel prefers it), otherwise of a wildcard socket
/// (0.0.0.0, or :: which also takes IPv4); more than one process for the
/// address, or none, is refused. It runs immediately before each request
/// (D-015), so the window between check and connection is the time
/// URLSession takes to open it — and a kept-alive connection stays with the
/// process that accepted it.
public final class ServerIdentityGate: Sendable {
  public let port: UInt16
  public let target: ListenAddress
  private let identifier: any ListenerIdentifying
  private let state: Mutex<ServerPin>

  public init(
    port: UInt16, target: ListenAddress = .v4(0x7F00_0001), pin: ServerPin,
    identifier: any ListenerIdentifying
  ) {
    self.port = port
    self.target = target.normalized
    self.identifier = identifier
    // The kernel reports the real path (/tmp is /private/tmp), so the pinned
    // path is resolved the same way — with realpath(3), not Foundation's
    // resolvingSymlinksInPath, which strips "/private" again.
    var canonical = pin
    if case .expected(let identity) = pin {
      canonical = .expected(
        ServerIdentity(
          executable: Self.realPath(identity.executable), cdhash: identity.cdhash?.lowercased()))
    }
    self.state = Mutex(canonical)
  }

  static func realPath(_ path: String) -> String {
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
    guard let resolved = realpath(path, &buffer) else { return path }
    return String(cString: resolved)
  }

  /// The process a connection to `target` reaches, or `nil` when there is
  /// none or more than one.
  public static func owner(of target: ListenAddress, among listeners: [ListenerSocket]) -> pid_t? {
    let target = target.normalized
    let exact = listeners.filter { $0.address.normalized == target }
    let candidates: [ListenerSocket]
    if !exact.isEmpty {
      candidates = exact
    } else {
      candidates = listeners.filter { listener in
        switch (listener.address.normalized, target) {
        case (.anyV6, _): return true  // :: takes IPv4 too unless IPV6_V6ONLY: assume it does
        case (.anyV4, .v4): return true
        default: return false
        }
      }
    }
    let pids = Set(candidates.map(\.pid))
    return pids.count == 1 ? pids.first : nil
  }

  /// The identity pinned so far (after trust-on-first-use, the one seen).
  public var pinned: ServerIdentity? {
    state.withLock { pin in
      if case .expected(let identity) = pin { return identity }
      return nil
    }
  }

  public func verify() throws(AdapterError) {
    let listeners = identifier.listeners(port: port)
    guard let pid = Self.owner(of: target, among: listeners),
      let found = identifier.identity(of: pid)
    else {
      throw AdapterError.untrustedServer(
        "no single listener of this user for \(target):\(port) to verify; not sending")
    }
    try state.withLock { pin throws(AdapterError) in
      switch pin {
      case .trustOnFirstUse:
        pin = .expected(found)
      case .expected(let expected):
        let sameProgram = expected.executable == Self.realPath(found.executable)
        let sameCode = expected.cdhash == nil || expected.cdhash == found.cdhash
        guard sameProgram, sameCode else {
          throw AdapterError.untrustedServer(
            "\(target):\(port) is served by \(found), not the paired \(expected); not sending")
        }
      }
    }
  }
}
