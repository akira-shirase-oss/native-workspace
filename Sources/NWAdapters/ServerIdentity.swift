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

/// Finds the process that owns a listening TCP socket on a loopback port.
public protocol ListenerIdentifying: Sendable {
  /// `nil` when no listener is visible, or more than one process listens.
  func identify(port: UInt16) -> (pid: pid_t, identity: ServerIdentity)?
  /// Whether `pid` (started at `startTime`) still listens on `port`: the
  /// cheap check between full scans.
  func stillListening(pid: pid_t, startTime: UInt64, port: UInt16) -> Bool
  func startTime(of pid: pid_t) -> UInt64?
}

/// The kernel's own answer (libproc): every process the user may inspect,
/// its socket descriptors, the TCP listeners among them. A listener owned
/// by another user (root included) is invisible, so it is refused — the
/// gate fails closed.
public struct LibprocListenerIdentifier: ListenerIdentifying {
  public init() {}

  public func identify(port: UInt16) -> (pid: pid_t, identity: ServerIdentity)? {
    let count = proc_listallpids(nil, 0)
    guard count > 0 else { return nil }
    var pids = [pid_t](repeating: 0, count: Int(count) + 64)
    let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
    guard got > 0 else { return nil }
    let owners = pids.prefix(Int(got)).filter { $0 > 0 && listens(pid: $0, port: port) }
    guard owners.count == 1, let pid = owners.first, let identity = identity(of: pid) else {
      return nil
    }
    return (pid, identity)
  }

  public func stillListening(pid: pid_t, startTime: UInt64, port: UInt16) -> Bool {
    self.startTime(of: pid) == startTime && listens(pid: pid, port: port)
  }

  public func startTime(of pid: pid_t) -> UInt64? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
    return info.pbi_start_tvsec &* 1_000_000 &+ info.pbi_start_tvusec
  }

  func listens(pid: pid_t, port: UInt16) -> Bool {
    let stride = MemoryLayout<proc_fdinfo>.stride
    let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
    guard bytes > 0 else { return false }
    var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / stride + 16)
    let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * stride))
    guard got > 0 else { return false }
    for fd in fds.prefix(Int(got) / stride) where fd.proc_fdtype == PROX_FDTYPE_SOCKET {
      var info = socket_fdinfo()
      let size = Int32(MemoryLayout<socket_fdinfo>.size)
      guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size,
        info.psi.soi_kind == SOCKINFO_TCP
      else { continue }
      let tcp = info.psi.soi_proto.pri_tcp
      guard tcp.tcpsi_state == TSI_S_LISTEN else { continue }
      if UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport)) == port {
        return true
      }
    }
    return false
  }

  func identity(of pid: pid_t) -> ServerIdentity? {
    var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
    let executable = String(
      decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    return ServerIdentity(executable: executable, cdhash: Self.cdhash(of: pid))
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

/// The check before a token leaves the app: the process listening on the
/// endpoint's loopback port must be the paired one. A full scan finds the
/// listener; between scans, the cheap check confirms the same process
/// (pid and start time) still holds the port. The residual race — the
/// service dies and another process binds between the check and the
/// request — is milliseconds wide; D-015 records it.
public final class ServerIdentityGate: Sendable {
  public let port: UInt16
  private let identifier: any ListenerIdentifying
  private let state: Mutex<State>

  private struct State {
    var pin: ServerPin
    var verified: (pid: pid_t, start: UInt64)?
  }

  public init(port: UInt16, pin: ServerPin, identifier: any ListenerIdentifying) {
    self.port = port
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
    self.state = Mutex(State(pin: canonical))
  }

  static func realPath(_ path: String) -> String {
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
    guard let resolved = realpath(path, &buffer) else { return path }
    return String(cString: resolved)
  }

  /// The identity pinned so far (after trust-on-first-use, the one seen).
  public var pinned: ServerIdentity? {
    state.withLock { s in
      if case .expected(let identity) = s.pin { return identity }
      return nil
    }
  }

  public func verify() throws(AdapterError) {
    let cached = state.withLock { $0.verified }
    if let cached,
      identifier.stillListening(pid: cached.pid, startTime: cached.start, port: port)
    {
      return
    }
    guard let found = identifier.identify(port: port) else {
      state.withLock { $0.verified = nil }
      throw AdapterError.untrustedServer(
        "no single listener of this user on 127.0.0.1:\(port) to verify; not sending the token")
    }
    let start = identifier.startTime(of: found.pid) ?? 0
    try state.withLock { s throws(AdapterError) in
      switch s.pin {
      case .trustOnFirstUse:
        s.pin = .expected(found.identity)
      case .expected(let expected):
        let sameProgram = expected.executable == Self.realPath(found.identity.executable)
        let sameCode = expected.cdhash == nil || expected.cdhash == found.identity.cdhash
        guard sameProgram, sameCode else {
          s.verified = nil
          throw AdapterError.untrustedServer(
            "127.0.0.1:\(port) is served by \(found.identity), not the paired "
              + "\(expected); not sending the token")
        }
      }
      s.verified = (found.pid, start)
    }
  }
}
