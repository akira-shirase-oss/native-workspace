import Foundation
import XCTest

@testable import NWCore

/// D-016: untrusted text is shown as visible escapes, never interpreted.
final class InertTextTests: XCTestCase {
  func testPlainASCIIIsUnchanged() {
    let line = "GET /health 200 3 ms"
    XCTAssertEqual(InertText.render(line), line)
  }

  func testEscapeSequencesBecomeVisible() {
    XCTAssertEqual(InertText.render("\u{1B}[31mred\u{1B}[0m"), "\\u{1B}[31mred\\u{1B}[0m")
    XCTAssertEqual(InertText.render("\u{9B}31m"), "\\u{9B}31m")
    XCTAssertEqual(InertText.render("bell\u{07}"), "bell\\u{07}")
    XCTAssertEqual(InertText.render("nul\u{0}"), "nul\\u{00}")
    XCTAssertEqual(InertText.render("del\u{7F}"), "del\\u{7F}")
  }

  func testBidiOverridesAndIsolatesBecomeVisible() {
    XCTAssertEqual(InertText.render("invoice\u{202E}fdp.exe"), "invoice\\u{202E}fdp.exe")
    for scalar in [0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069] {
      let raw = "a" + String(Unicode.Scalar(UInt32(scalar))!) + "b"
      let hex = String(scalar, radix: 16, uppercase: true)
      XCTAssertEqual(InertText.render(raw), "a\\u{\(hex)}b")
    }
  }

  func testInvisibleCharactersBecomeVisible() {
    XCTAssertEqual(InertText.render("a\u{200B}b\u{FEFF}c"), "a\\u{200B}b\\u{FEFF}c")
    XCTAssertEqual(InertText.render("tag\u{E0041}"), "tag\\u{E0041}")
  }

  func testNewlineCannotForgeASecondRow() {
    XCTAssertEqual(InertText.render("one\ntwo"), "one\\u{0A}two")
    XCTAssertEqual(InertText.render("one\ntwo", multiline: true), "one\ntwo")
    XCTAssertEqual(InertText.render("over\rwrite"), "over\\u{0D}write")
    XCTAssertEqual(InertText.render("tab\there"), "tab\there")
  }

  func testBackslashIsDoubledSoEscapesAreUnambiguous() {
    XCTAssertEqual(InertText.render("\\u{1B}"), "\\\\u{1B}")
    XCTAssertNotEqual(InertText.render("\u{1B}"), InertText.render("\\u{1B}"))
  }

  func testMarkupIsLeftAsLiteralText() {
    let markup = "**bold** [link](https://evil.example) <script>"
    XCTAssertEqual(InertText.render(markup), markup)
  }

  func testEveryHostileLineRendersWithNoActiveCharacter() {
    for line in HostileFixture.lines {
      let rendered = InertText.render(line)
      XCTAssertEqual(activeScalars(rendered), [], rendered)
    }
  }

  func testTheCodeCorpusIsInTheCommittedFixtureFile() throws {
    let url = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("fixtures/hostile-log-lines.json")
    struct File: Decodable { let lines: [String] }
    let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
    XCTAssertTrue(Set(HostileFixture.lines).isSubset(of: Set(file.lines)), "code and file drifted")
  }

  func testLongTextIsCutAndTheCutIsStated() {
    let long = String(repeating: "x", count: 5_000)
    let rendered = InertText.render(long, maxScalars: 100)
    XCTAssertTrue(rendered.hasPrefix(String(repeating: "x", count: 100)))
    XCTAssertTrue(rendered.hasSuffix("[4900 more characters not shown]"))
  }
}

/// The repository's `fixtures/hostile-log-lines.txt` is the durable copy;
/// this is the same corpus in code so the pure package needs no resources.
enum HostileFixture {
  static let lines: [String] = [
    "\u{1B}[2J\u{1B}[H\u{1B}[32mALL SYSTEMS OK\u{1B}[0m",
    "\u{1B}]8;;https://evil.example/\u{07}click me\u{1B}]8;;\u{07}",
    "\u{1B}]0;fake window title\u{07}",
    "invoice\u{202E}fdp.exe",
    "admin\u{2066}\u{2069} is fine",
    "\u{9B}31mC1 CSI\u{9B}0m",
    "zero\u{200B}width\u{FEFF}joiner\u{200D}",
    "first line\nFORGED: second row looks like a new event",
    "carriage\rreturn overwrite",
    "tag\u{E0041}\u{E0042}chars",
    "nul\u{0}byte and bell\u{07}",
    "line\u{2028}separator\u{2029}",
    "\u{61C}arabic letter mark\u{200E}\u{200F}",
  ]
}
