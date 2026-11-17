import CryptoKit
import Foundation
import Security

/// A bearer credential that cannot be printed.
///
/// Every textual form (`description`, `debugDescription`, `dump`/`Mirror`,
/// string interpolation) yields `<redacted>`. The value leaves only through
/// `authorizationHeaderValue`, which the HTTP client puts on a request.
/// Never `Codable`: it cannot reach preferences, the store or a log by
/// accident.
public struct SecretToken: Sendable, Equatable, CustomStringConvertible,
  CustomDebugStringConvertible, CustomReflectable
{
  private let value: String

  /// `nil` for an empty value or one containing whitespace or control
  /// characters (a pasted newline would otherwise split a header).
  public init?(_ value: String) {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty,
      trimmed.unicodeScalars.allSatisfy({ $0.value > 0x20 && $0.value < 0x7F })
    else { return nil }
    self.value = trimmed
  }

  public var description: String { "<redacted>" }
  public var debugDescription: String { "<redacted>" }
  public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }

  /// The only way out: the `Authorization` header value.
  public func authorizationHeaderValue() -> String { "Bearer \(value)" }

  /// A short, non-reversible identifier for showing *which* token is paired
  /// (the first 8 hex digits of its SHA-256).
  public var fingerprint: String {
    let digest = SHA256.hash(data: Data(value.utf8))
    return "sha256:" + digest.prefix(4).map { String(format: "%02x", $0) }.joined()
  }

  public var byteCount: Int { value.utf8.count }
}

public enum CredentialError: Error, Equatable, Sendable {
  /// The credential store cannot be used from this process (for example the
  /// data-protection Keychain needs an entitled, signed app — N1).
  case unavailable(String)
  case failed(OSStatus)
  case invalidValue
}

/// Where a service's token comes from.
public protocol CredentialSource: Sendable {
  func token(account: String) throws(CredentialError) -> SecretToken?
}

/// The process environment (scratch instances, drills, CI). Variable names
/// are fixed per account; the value is never echoed.
public struct EnvironmentCredentials: CredentialSource {
  public let variables: [String: String]
  private let environment: [String: String]

  public init(
    variables: [String: String], environment: [String: String] = ProcessInfo.processInfo.environment
  ) {
    self.variables = variables
    self.environment = environment
  }

  public func token(account: String) throws(CredentialError) -> SecretToken? {
    guard let name = variables[account], let raw = environment[name] else { return nil }
    guard let token = SecretToken(raw) else { throw CredentialError.invalidValue }
    return token
  }
}

/// The system Keychain, data-protection class, this device only (D-018):
/// `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, never synchronized.
public struct KeychainCredentials: CredentialSource {
  public static let defaultService = "dev.akira-shirase-oss.native-workspace"
  public let service: String

  public init(service: String = KeychainCredentials.defaultService) {
    self.service = service
  }

  private func baseQuery(account: String) -> [CFString: Any] {
    [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: service,
      kSecAttrAccount: account,
      kSecUseDataProtectionKeychain: true,
      kSecAttrSynchronizable: false,
    ]
  }

  public func save(_ token: SecretToken, account: String) throws(CredentialError) {
    let raw = String(token.authorizationHeaderValue().dropFirst("Bearer ".count))
    var add = baseQuery(account: account)
    add[kSecValueData] = Data(raw.utf8)
    add[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    var status = SecItemAdd(add as CFDictionary, nil)
    if status == errSecDuplicateItem {
      let update: [CFString: Any] = [
        kSecValueData: Data(raw.utf8),
        kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
      ]
      status = SecItemUpdate(baseQuery(account: account) as CFDictionary, update as CFDictionary)
    }
    try check(status)
  }

  public func token(account: String) throws(CredentialError) -> SecretToken? {
    var query = baseQuery(account: account)
    query[kSecReturnData] = true
    query[kSecMatchLimit] = kSecMatchLimitOne
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecItemNotFound { return nil }
    try check(status)
    guard let data = item as? Data, let raw = String(data: data, encoding: .utf8),
      let token = SecretToken(raw)
    else { throw CredentialError.invalidValue }
    return token
  }

  /// Unpairing deletes the item. Deleting a missing item is not an error.
  public func delete(account: String) throws(CredentialError) {
    let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
    if status == errSecItemNotFound { return }
    try check(status)
  }

  private func check(_ status: OSStatus) throws(CredentialError) {
    switch status {
    case errSecSuccess: return
    case errSecMissingEntitlement, errSecNotAvailable, errSecInteractionNotAllowed:
      throw CredentialError.unavailable(
        "Keychain unavailable to this process (OSStatus \(status)); the data-protection "
          + "Keychain needs a signed app with a keychain entitlement (N1)")
    default:
      throw CredentialError.failed(status)
    }
  }
}

/// Keychain first, then the environment: the first source with a token wins.
/// A source that is unavailable is skipped, not fatal.
public struct ChainedCredentials: CredentialSource {
  public let sources: [any CredentialSource]
  public init(_ sources: [any CredentialSource]) { self.sources = sources }

  public func token(account: String) throws(CredentialError) -> SecretToken? {
    for source in sources {
      do {
        if let token = try source.token(account: account) { return token }
      } catch .unavailable {
        continue
      }
    }
    return nil
  }
}
