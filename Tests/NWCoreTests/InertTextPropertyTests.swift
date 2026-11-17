import XCTest

@testable import NWCore

/// The oracle is Unicode's own property data, not `InertText`'s list.
func activeScalars(_ text: String, multiline: Bool = false) -> [Unicode.Scalar] {
  text.unicodeScalars.filter { scalar in
    if scalar == "\t" || (multiline && scalar == "\n") { return false }
    let p = scalar.properties
    switch p.generalCategory {
    case .control, .format, .lineSeparator, .paragraphSeparator, .surrogate, .unassigned,
      .privateUse:
      return true
    default:
      break
    }
    return p.isDefaultIgnorableCodePoint || p.isBidiControl || p.isVariationSelector
      || p.isNoncharacterCodePoint
  }
}

func isCombiningMark(_ scalar: Unicode.Scalar) -> Bool {
  switch scalar.properties.generalCategory {
  case .nonspacingMark, .spacingMark, .enclosingMark: return true
  default: return false
  }
}

/// Longest run of combining marks in a string.
func longestMarkRun(_ text: String) -> Int {
  var longest = 0
  var run = 0
  for scalar in text.unicodeScalars {
    run = isCombiningMark(scalar) ? run + 1 : 0
    longest = max(longest, run)
  }
  return longest
}

/// F2: inertness is decided by Unicode property, for every scalar there is.
final class InertTextPropertyTests: XCTestCase {
  /// Combining marks kept per base character (more stack into unreadable,
  /// overlapping text).
  let markCap = 4

  func testNoScalarWithAnInvisibleOrControlPropertySurvivesRendering() {
    var missed: [UInt32] = []
    var checked = 0
    for value in UInt32(0)...0x10FFFF {
      guard let scalar = Unicode.Scalar(value), !activeScalars(String(scalar)).isEmpty else {
        continue
      }
      checked += 1
      let rendered = InertText.render("a" + String(scalar) + "b")
      if rendered.unicodeScalars.contains(scalar) { missed.append(value) }
    }
    XCTAssertGreaterThan(checked, 900_000, "the property set covers unassigned scalars too")
    XCTAssertEqual(
      missed.count, 0,
      "\(missed.count) scalars rendered raw, e.g. \(missed.prefix(12).map { String($0, radix: 16) })"
    )
  }

  func testTheProbedInvisiblesAreEscaped() {
    // Soft hyphen, combining grapheme joiner, Hangul fillers, Mongolian vowel
    // separator, deprecated format controls, variation selectors (both
    // blocks), musical and hieroglyph format controls, Arabic number sign,
    // Braille blank, object replacement character.
    let probes: [UInt32] = [
      0x00AD, 0x034F, 0x115F, 0x1160, 0x3164, 0xFFA0, 0x180E, 0x206A, 0x206B, 0x206C, 0x206D,
      0x206E, 0x206F, 0xFE00, 0xFE0F, 0xE0100, 0xE01EF, 0x1D173, 0x13430, 0x0600, 0x2800,
      0xFFFC,
    ]
    for value in probes {
      let scalar = Unicode.Scalar(value)!
      let rendered = InertText.render("x" + String(scalar) + "y")
      XCTAssertFalse(rendered.unicodeScalars.contains(scalar), "U+\(String(value, radix: 16)) raw")
      XCTAssertTrue(rendered.contains("\\u{"), "U+\(String(value, radix: 16)) not shown as escape")
    }
  }

  func testACombiningFloodIsCappedPerBase() {
    let flood = "e" + String(repeating: "\u{0301}", count: 500) + "x"
    let rendered = InertText.render(flood)
    XCTAssertLessThanOrEqual(longestMarkRun(rendered), markCap)
    XCTAssertTrue(rendered.hasSuffix("x"))
    XCTAssertTrue(rendered.contains("\\u{301}"), "the marks past the cap are shown as escapes")
    // Real text keeps its marks: Vietnamese stacks two.
    XCTAssertEqual(InertText.render("Vie\u{0302}\u{0323}t"), "Vie\u{0302}\u{0323}t")
  }

  func testEveryLineOfTheCommittedFixtureFileRendersInertByProperty() throws {
    let url = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("fixtures/hostile-log-lines.json")
    struct File: Decodable { let lines: [String] }
    let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
    XCTAssertGreaterThanOrEqual(file.lines.count, 30, "the probed scalars are in the fixture")
    for line in file.lines {
      for multiline in [false, true] {
        let rendered = InertText.render(line, multiline: multiline)
        XCTAssertEqual(activeScalars(rendered, multiline: multiline), [], line.debugDescription)
        XCTAssertLessThanOrEqual(longestMarkRun(rendered), markCap)
      }
    }
  }
}
