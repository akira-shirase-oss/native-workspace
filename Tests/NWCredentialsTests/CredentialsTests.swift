import XCTest

@testable import NWCredentials

final class SecretTokenTests: XCTestCase {
  let raw = "4f2c9a1e7b3d8f60a5c4e2b19d7f3a6c8e1b5d9f2a7c4e6b8d0f1a3c5e7b9d2f"

  func testNoTextualFormRevealsTheValue() throws {
    let token = try XCTUnwrap(SecretToken(raw))
    var dumped = ""
    dump(token, to: &dumped)
    let forms = [
      token.description, token.debugDescription, "\(token)", String(describing: token),
      String(reflecting: token), dumped, "\([token])", "\(Optional(token) as Any)",
    ]
    for form in forms {
      XCTAssertFalse(form.contains(raw), "leaked through: \(form)")
      XCTAssertFalse(form.contains(String(raw.prefix(8))), "partially leaked through: \(form)")
    }
    XCTAssertTrue(Mirror(reflecting: token).children.isEmpty)
    XCTAssertEqual(token.authorizationHeaderValue(), "Bearer \(raw)")
  }

  func testRejectsValuesThatCouldSplitAHeader() {
    XCTAssertNil(SecretToken(""))
    XCTAssertNil(SecretToken("   "))
    XCTAssertNil(SecretToken("abc def"))
    XCTAssertNil(SecretToken("abc\r\nX-Injected: 1"))
    XCTAssertNil(SecretToken("abc\u{7F}"))
    XCTAssertNotNil(SecretToken("  \(raw)\n"), "surrounding whitespace is trimmed")
  }

  func testFingerprintIdentifiesWithoutRevealing() throws {
    let token = try XCTUnwrap(SecretToken(raw))
    XCTAssertTrue(token.fingerprint.hasPrefix("sha256:"))
    XCTAssertEqual(token.fingerprint.count, "sha256:".count + 8)
    XCTAssertFalse(raw.contains(token.fingerprint.dropFirst("sha256:".count)))
    XCTAssertEqual(token.fingerprint, SecretToken(raw)?.fingerprint)
  }
}

final class CredentialSourceTests: XCTestCase {
  func testEnvironmentSourceReadsOnlyItsMappedVariable() throws {
    let env = EnvironmentCredentials(
      variables: ["service-monitor": "NW_SMON_TOKEN"],
      environment: ["NW_SMON_TOKEN": "abcdefabcdefabcdefabcdefabcdefab", "OTHER": "x"])
    XCTAssertEqual(
      try env.token(account: "service-monitor")?.authorizationHeaderValue(),
      "Bearer abcdefabcdefabcdefabcdefabcdefab")
    XCTAssertNil(try env.token(account: "durable-runner"))
  }

  func testEnvironmentSourceRefusesAnInvalidValue() {
    let env = EnvironmentCredentials(
      variables: ["service-monitor": "NW_SMON_TOKEN"], environment: ["NW_SMON_TOKEN": "a b"])
    XCTAssertThrowsError(try env.token(account: "service-monitor")) { error in
      XCTAssertEqual(error as? CredentialError, .invalidValue)
    }
  }

  struct Unavailable: CredentialSource {
    func token(account: String) throws(CredentialError) -> SecretToken? {
      throw CredentialError.unavailable("test")
    }
  }

  func testChainSkipsAnUnavailableStore() throws {
    let env = EnvironmentCredentials(
      variables: ["a": "T"], environment: ["T": "abcdefabcdefabcdefabcdefabcdefab"])
    let chain = ChainedCredentials([Unavailable(), env])
    XCTAssertNotNil(try chain.token(account: "a"))
  }

  /// Keychain round trip, this device only. The data-protection Keychain
  /// needs a signed app with a keychain entitlement; an unsigned `swift test`
  /// binary gets errSecMissingEntitlement, and the test says so instead of
  /// passing silently. The signed app target arrives in N1.
  func testKeychainRoundTripWhereTheProcessIsEntitled() throws {
    let keychain = KeychainCredentials(
      service: "dev.akira-shirase-oss.native-workspace.test.\(UUID())")
    let token = try XCTUnwrap(SecretToken("abcdefabcdefabcdefabcdefabcdefab"))
    do {
      try keychain.save(token, account: "service-monitor")
    } catch .unavailable(let reason) {
      throw XCTSkip("Keychain not available to this unsigned test process: \(reason)")
    }
    defer { try? keychain.delete(account: "service-monitor") }
    XCTAssertEqual(try keychain.token(account: "service-monitor"), token)
    try keychain.delete(account: "service-monitor")
    XCTAssertNil(try keychain.token(account: "service-monitor"))
  }
}
